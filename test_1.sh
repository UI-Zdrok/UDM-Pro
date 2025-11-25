#!/bin/bash

########################################################################
# ------ База шляху скрипта (папка проєкту) ------
# Це гарантує, що всі шляхи будуть відносно місця, де лежить test_1.sh

export SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
########################################################################


########################################################################
# ------ Підключення конфіга ------
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/CONF.sh}"
[ -r "$CONF_FILE" ] && . "$CONF_FILE" || echo "WARNING: CONF.sh not found, using built-ins"
########################################################################


########################################################################
# ------ Підключення check_port_status.sh ------
mkdir -p "$SCRIPT_DIR/funct" 2>/dev/null || true
# Підключаємо функцію перевірки портів
. "$SCRIPT_DIR/funct/check_port_status.sh"
########################################################################


########################################################################
# --- Підключення модуля ручного кроку RESET ---
RESET_LIB="$SCRIPT_DIR/funct/manual_reset.sh"
if [[ -r "$RESET_LIB" ]]; then
  # shellcheck source=/dev/null
  . "$RESET_LIB"          # дає функцію manual_reset_step
else
  echo "WARNING: $RESET_LIB не знайдено — крок RESET буде пропущено"
fi
########################################################################

########################################################################
# --- iPerf3 flags (дефолти) ---
ONLY_IPERF=0   # запустити ТІЛЬКИ iPerf3-тест
SKIP_IPERF=0   # пропустити iPerf3-тест у повному прогоні

# Базові дефолти інших прапорців (щоб вони гарантовано існували)
: "${SKIP_FW:=0}"
: "${SKIP_FAN:=0}"
: "${SKIP_PORT:=0}"
########################################################################


ensure_reachable() {
  local ip="$1"
  ping -c1 -W1 "$ip" >/dev/null 2>&1
}

# --- NM helpers (мають бути визначені ДО set_current_dut і ДО виклику _run_fw_check_upgrade) ---
_nm_con_exists() {
  local name="$1"
  nmcli -t -f NAME con show 2>/dev/null | grep -Fx -- "$name" >/dev/null
}

_nm_con_active() {
  local name="$1"
  nmcli -t -f NAME con show --active 2>/dev/null | grep -Fx -- "$name" >/dev/null
}

_nm_down_quiet() {
  local name="$1"
  _nm_con_active "$name" && nmcli -w 5 con down "$name" >/dev/null 2>&1 || true
}

_nm_up_safe() {
  local name="$1"
  if ! _nm_con_exists "$name"; then
    # Підійми профіль на першому доступному інтерфейсі (за потреби підстав свій IFACE)
    local ifname
    ifname="$(nmcli -t -f DEVICE dev status | head -n1)"
    nmcli con add type ethernet ifname "$ifname" con-name "$name" autoconnect no >/dev/null
  fi
  nmcli -w 15 con up "$name" >/dev/null 2>&1
}




########################################################################
# ------ FW модуль ------
FW_LIB="${FW_LIB:-"$SCRIPT_DIR/funct/fw_check_upgrade.sh"}"

# Вмикаємо зрозумілу діагностику помилок
set -Eeuo pipefail
trap 'echo "⚠️ ERROR: ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Підключаємо файл як бібліотеку (тільки визначення функцій!)
if [ -r "$FW_LIB" ]; then
  . "$FW_LIB"
else
  echo "⚠️ ERROR: fw_check_upgrade.sh not found at: $FW_LIB"
  exit 1
fi

# Перевіряємо, що функція з'явилась
if ! declare -F _run_fw_check_upgrade >/dev/null; then
  echo "⚠️ ERROR: _run_fw_check_upgrade is not defined after sourcing $FW_LIB"
  exit 1
fi
########################################################################


########################################################################
# ------ iPerf3 тест (через два локальні інтерфейси) ------
IPERF_LIB="$SCRIPT_DIR/funct/iperf3_test.sh"
if [ -r "$IPERF_LIB" ]; then
  . "$IPERF_LIB"
else
  echo "WARNING: $IPERF_LIB not found; iPerf3 test will be skipped" >&2
fi
########################################################################


########################################################################
# ------ Підготуємо папку логів і файл логів ------
LOG_DIR="${LOG_DIR:-"$SCRIPT_DIR/Logs"}"       		# fallback, якщо в CONF.sh не задано
RUN_LOG="$LOG_DIR/run_$(date +%F_%H-%M-%S).log" 	# окремий файл на кожен запуск
mkdir -p "$LOG_DIR"                              	# створюємо папку, якщо її нема

# ------ Централізоване логування всього stdout+stderr у файл запуску ------
# все логується у $RUN_LOG
exec > >(tee -a "$RUN_LOG") 2>&1

# --- fallback-логер на випадок, якщо _plog ще не визначений ---
if ! declare -F _plog >/dev/null 2>&1; then
  _plog() { echo "$*"; }
fi
########################################################################


########################################################################
#Підключення до пристрою
USPRO24_IP="192.168.0.135" 		# IP-адреса для USW-Pro-24
NM_ETHERNET_NAME="Wired connection 1" 	# назва підключення


#Массив для хранения состояния каждого порта
declare -A PORT_STATUS
########################################################################


########################################################################
# --- Розбір аргументів CLI для iPerf3 ---
for arg in "$@"; do
  case "$arg" in
    --only-iperf) ONLY_IPERF=1 ;;  # швидкий запуск лише iPerf3
    --skip-iperf) SKIP_IPERF=1 ;;  # пропустити iPerf3 у повному прогоні
  esac
done

# Якщо просили тільки iPerf3 — вимикаємо інші етапи
if [ "${ONLY_IPERF:-0}" -eq 1 ]; then
  SKIP_FW=1
  SKIP_FAN=1
  SKIP_PORT=1
fi
########################################################################


########################################################################
# ХЕЛПЕР 1: повертає локальну (source) IPv4 для DUT i з профілю NM.
# Використовує шаблон імені підключення з CONF.sh: CONNECTION_TEMPLATE="DUT %d LAN" або "DUT %d WLAN"
# Приклад: для dut_idx=1 отримаємо ім'я "DUT 1 LAN", піднімемо профіль і заберемо першу IP4.ADDRESS.
# Повертає локальну (source) IPv4 твоєї машини для DUT i з профілю NM
_dut_src_ip() {
    local dut_idx="${1:?_dut_src_ip: потрібно <dut_idx>}"

    # 1) Ім'я профілю з шаблону (LAN або WLAN — задаєш у CONF.sh)
    local con_name
    printf -v con_name "${CONNECTION_TEMPLATE:-DUT %d LAN}" "$dut_idx"

    # 2) Підняти профіль, якщо ще не активний (idempotent)
    nmcli -t -f NAME connection show --active | grep -Fxq -- "$con_name" \
        || nmcli connection up "$con_name" >/dev/null 2>&1 || true

    # 3) Взяти ТІЛЬКИ значення IP без ключа (нові nmcli)
    local ip_cidr
    ip_cidr="$(nmcli -g IP4.ADDRESS connection show "$con_name" 2>/dev/null | head -n1)"

    # 4) Фолбек для старіших nmcli, де йде "IP4.ADDRESS[1]:192.168.1.21/24"
    if [ -z "$ip_cidr" ]; then
        ip_cidr="$(nmcli -t -f IP4.ADDRESS connection show "$con_name" 2>/dev/null | head -n1)"
        ip_cidr="${ip_cidr#*:}"   # відрізаємо "IP4.ADDRESS[1]:"
    fi

    # 5) Прибрати маску /24 → лишити чисту адресу
    local src_ip="${ip_cidr%%/*}"

    # 6) Проста валідація IPv4
    if ! printf '%s' "$src_ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        return 1
    fi

    printf '%s\n' "$src_ip"
    return 0
}
########################################################################


########################################################################
# ХЕЛПЕР 2: мапінг "номер порту -> інтерфейс на DUT".
# Пріоритет:
#   1) якщо передано iface_hint — беремо його;
#   2) якщо у CONF.sh існує асоціативний масив PORT_IFNAME_DUT<dut_idx>, то беремо з нього;
#   3) фолбек — "eth<port_num>".
_dut_ifname() {
    local dut_idx="${1:?_dut_ifname: потрібно <dut_idx>}"
    local port_num="${2:?_dut_ifname: потрібно <port_num>}"
    local hint="${3:-}"

    # 1) Якщо є підказка інтерфейсу — використовуємо її
    [ -n "$hint" ] && { echo "$hint"; return; }

    # 2) Спробувати PORT_IFNAME_DUT<dut_idx> з CONF.sh
    local assoc="PORT_IFNAME_DUT${dut_idx}"
    if declare -p "$assoc" 2>/dev/null | grep -q 'declare -A'; then
        # shellcheck disable=SC2178
        local -n MAP="$assoc"   # nameref на масив
        if [ -n "${MAP[$port_num]+set}" ]; then
            echo "${MAP[$port_num]}"
            return
        fi
    fi

    # 3) Фолбек: eth<номер_порту>
    echo "eth${port_num}"
}
########################################################################


########################################################################
# ХЕЛПЕР 3

########################################################################


########################################################################
#гілка, яка не використовує netns
# --- TRUNK-режим: два VLAN-підінтерфейси на одній фізичній карті, без netns ---
iperf3_test_main_trunk() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    __iperf_log "⚠️ ERROR: iperf3 (trunk) потребує root (sudo)."
    return 1
  fi

  local dut_idx="$1"
  local IFACE_A="$2"      # наприклад enxa0cec87043c0.1000
  local IFACE_B="$3"      # наприклад enxa0cec87043c0.1011

  __ensure_logs_dir
  local log_file="Logs/iperf3_DUT${dut_idx}_$(date +%F_%H-%M-%S).log"

  local DURATION="${IPERF_DURATION:-10}"
  local PARALLEL="${IPERF_PARALLEL:-4}"
  local PROTOCOL="${IPERF_PROTOCOL:-tcp}"
  local UDP_RATE="${IPERF_UDP_RATE_M:-950}"
  local NET_BASE="${IPERF_NET_BASE:-10.10}"

  local IP_A="${NET_BASE}.${dut_idx}.1"
  local IP_B="${NET_BASE}.${dut_idx}.2"

  __iperf_log "----- iPerf3: start (DUT $dut_idx; $IFACE_A <-> $IFACE_B) -----"
  {
    echo "[TRUNK MODE]"
    echo "IFACE_A=$IFACE_A  -> $IP_A"
    echo "IFACE_B=$IFACE_B  -> $IP_B"
    echo "Duration=$DURATION, Parallel=$PARALLEL, Proto=$PROTOCOL, UDP_RATE(Mbps)=$UDP_RATE"
  } >>"$log_file"

  # Приведемо інтерфейси у UP; адреси призначимо тимчасово (ізольована мережа 10.10.x.x)
  ip link set "$IFACE_A" up 2>/dev/null || true
  ip link set "$IFACE_B" up 2>/dev/null || true

  # Обережно: якщо на підінтерфейсах вже були адреси - ми їх стираємо
  ip addr flush dev "$IFACE_A" || true
  ip addr flush dev "$IFACE_B" || true

  ip addr add "$IP_A/24" dev "$IFACE_A"
  ip addr add "$IP_B/24" dev "$IFACE_B"

  # Порог з урахуванням negotiated speed (якщо є ethtool)
  local THRESH_MIN_MBIT_A="$(__guess_min_threshold "$IFACE_A")"
  local THRESH_MIN_MBIT_B="$(__guess_min_threshold "$IFACE_B")"
  local THRESH_MIN_MBIT="$THRESH_MIN_MBIT_A"
  awk -v a="$THRESH_MIN_MBIT_A" -v b="$THRESH_MIN_MBIT_B" 'BEGIN{ exit !(a<=b) }' || THRESH_MIN_MBIT="$THRESH_MIN_MBIT_B"
  echo "Calculated MIN threshold (Mbps) = $THRESH_MIN_MBIT" >>"$log_file"

  # Сервер у root namespace (без -n)
  local srv_pid
  srv_pid="$(__start_server_once "" "$IP_A" "$log_file")"   # ns не потрібен; функція ігнорує параметр
  sleep 0.5

  # Клієнт у root namespace, біндимо джерело до IP_B
  local json_mbps
  json_mbps="$(__run_client_and_collect "" "$IP_A" "$IP_B" "$log_file" "$DURATION" "$PARALLEL" "$PROTOCOL" "$UDP_RATE")"
  json_mbps="${json_mbps:-0}"

  # Прибрати тимчасові адреси (акуратно)
  ip addr del "$IP_A/24" dev "$IFACE_A" 2>/dev/null || true
  ip addr del "$IP_B/24" dev "$IFACE_B" 2>/dev/null || true

  local Mbps_rounded
  Mbps_rounded="$(awk -v x="$json_mbps" 'BEGIN{printf "%.1f", x+0}')"

  local rc=1
  if awk -v m="$json_mbps" -v t="$THRESH_MIN_MBIT" 'BEGIN{ exit !(m>=t) }'; then
    __iperf_log "DUT $dut_idx: PASS — ${Mbps_rounded} Mbps (threshold ${THRESH_MIN_MBIT} Mbps)"
    rc=0
  else
    __iperf_log "DUT $dut_idx: FAIL — ${Mbps_rounded} Mbps (threshold ${THRESH_MIN_MBIT} Mbps)"
    rc=1
  fi

  echo "RESULT=${Mbps_rounded}Mbps; THRESH=${THRESH_MIN_MBIT}Mbps; STATUS=$([ $rc -eq 0 ] && echo PASS || echo ⚠️FAIL)" >>"$log_file"
  __iperf_log "----- iPerf3: done (DUT $dut_idx) -----"
  return "$rc"
}
########################################################################


########################################################################
#Виклик тесту перевірки швидеості через iperf
run_iperf_for_all_duts() {
  # якщо модуль не підключився — просто пропускаємо
  type iperf3_test_run_for_dut >/dev/null 2>&1 || return 0

  if [ "${IPERF_ENABLE:-1}" -ne 1 ] || [ "${SKIP_IPERF:-0}" -eq 1 ]; then
    _plog "iPerf3: skipped (disabled by config or flag)"
    return 0
  fi

  local failures=0
  local dut_count="${DUT_COUNT:-2}"   # або як у тебе визначено кількість DUT
  
    # Кешуємо sudo — щоб prepare та ip-команди всередині модуля не питали пароль по 100 разів
  if ! sudo -n true 2>/dev/null; then
    _plog "iPerf3: requesting sudo for ip commands (ip link/addr/rule/route)"
    sudo -v || { _plog "iPerf3: sudo cancelled — skipping iPerf3"; return 1; }
  fi

  # Підготуємо VLAN-підінтерфейси для всіх DUTів (створить, якщо нема)
  CONF_FILE="$CONF_FILE" bash "$SCRIPT_DIR/funct/prepare_vlan_ifaces.sh"
  
	for dut in $(seq 1 "$dut_count"); do
    	_plog "----- iPerf3: start ----- (DUT $dut)"
	mkdir -p Logs 2>/dev/null || true
	CONF_FILE="$CONF_FILE" bash "$IPERF_LIB" "$dut" | tee -a "Logs/iperf3_DUT${dut}_$(date +%F_%H-%M-%S).log"
	rc=${PIPESTATUS[0]}
    _plog "----- iPerf3: done ------ (DUT $dut) rc=$rc"

    [ $rc -ne 0 ] && failures=$((failures+1))
  done

  if [ $failures -gt 0 ]; then
    return 1
  fi
  return 0
}
########################################################################


##################################################################
function check_networkmanager() {
    #створюється порожній масив та виведення повідомлення
    FLAG_DUT_LAN_EXISTS=()
    echo "Checking NetworkManager configuration..."
    
    #ініціалізується нулями для кожного DUT
    for i in $(seq 1 $DUT_COUNT); do
        FLAG_DUT_LAN_EXISTS[$i]=0
    done
    
    #Отримання списку всіх мереж
    CONNECTIONS=$(nmcli con show)

    #Перевірка чи існують підключення для кожного DUT
    for i in $(seq 1 $DUT_COUNT); do
        if echo "$CONNECTIONS" | grep -q "$NM_ETHERNET_NAME"; then
            FLAG_DUT_LAN_EXISTS[$i]=1
            echo "DUT $i: NetworkManager connection exists"
        else
            echo "DUT $i: NetworkManager connection does not exist"
        fi
    done

    #Отримання списку всіх мережевих підключень (команда nmcli -g name con show виводить список імен всіх мережевих підключень).
    #Список мережевих підключень зберігається в масиві TEST_ARRAY.
    readarray -t TEST_ARRAY < <(nmcli -g name con show)
    #Перевірка наявності необхідних підключень
    for i in "${TEST_ARRAY[@]}"; do
        #Якщо знайдено підключення з ім'ям NM_ETHERNET_NAME, то змінна FLAG_NM_ETHERNET_NAME_EXISTS встановлюється в 1.
        if [ "$i" == "$NM_ETHERNET_NAME" ]; then FLAG_NM_ETHERNET_NAME_EXISTS=1;
        fi
        for j in $(seq 1 $DUT_COUNT); do
            #Якщо знайдено підключення з ім'ям формату "DUT X LAN", де X - номер пристрою, відповідний елемент в масиві FLAG_DUT_LAN_EXISTS встановлюється в 1
            if [ "$i" == "DUT $j LAN" ]; then FLAG_DUT_LAN_EXISTS[$j]=1;
            fi
        done
    done

    #Якщо підключення NM_ETHERNET_NAME не існує, виводиться повідомлення і сценарій завершується
    if [ ! "$FLAG_NM_ETHERNET_NAME_EXISTS" ]; then
        echo "Connection \"$NM_ETHERNET_NAME\" does not exist!"
        exit 1
    fi

    #Якщо підключення існує, воно активується командою nmcli con up "$NM_ETHERNET_NAME"
    nmcli con up "$NM_ETHERNET_NAME"

    #Створення підключень для DUT, якщо вони не існують
    for i in $(seq 1 $DUT_COUNT); do
        if [ "${FLAG_DUT_LAN_EXISTS[$i]}" -ne 1 ]; then
            echo "DUT $i LAN connection does not exist, creating..."
            #Визначається MASTER_IFACE_NAME (ідентифікатор основного інтерфейсу) для NM_ETHERNET_NAME
            
            MASTER_IFACE_NAME=$(nmcli -m tabular -f connection.uuid con show "$NM_ETHERNET_NAME" | tail -n1 | tr -d "[:space:]")
            DUT_SRC_ADDR="192.168.1.$(($i+20))/24"
            VLAN_ID=$(($i+999))
            nmcli con add type vlan connection.id "DUT $i LAN" connection.autoconnect no vlan.id "$VLAN_ID" vlan.parent "$MASTER_IFACE_NAME" ipv4.method manual ipv4.addresses "$DUT_SRC_ADDR" ipv4.may-fail no
        fi
    done
}
##################################################################


##################################################################
create_nm_profile_if_missing() {
  local name="$1"
  nmcli -t -f NAME con show | grep -Fx -- "$name" >/dev/null 2>&1 && return 0
  # створюємо профіль на активному інтерфейсі (підставте свою карту, якщо треба)
  local ifname="$(nmcli -t -f DEVICE dev status | head -n1)"
  nmcli con add type ethernet ifname "$ifname" con-name "$name" autoconnect no
}
# виклик перед циклами:
for j in $(seq 1 "$DUT_COUNT"); do create_nm_profile_if_missing "DUT $j LAN"; done
##################################################################


##################################################################
#відправляє тимчасову інструкцію на USW-Pro-24
function setup_usw_pro_24() {
    echo "Sending volatile configuration to USW-Pro-24 at $USPRO24_IP, please wait..."
    #./expect-usw-pro-24-setup.sh $USPRO24_IP 2>&1 >/dev/null: Запускает скрипт expect-usw-pro-24-setup.sh с IP-адресом устройства. 
    #Стандартный вывод и ошибки перенаправляются, чтобы скрыть их
    ./expect-usw-pro-24-setup.sh $USPRO24_IP 2>&1 >/dev/null
}
##################################################################


##################################################################
#Функція очікує натискання клавіши для продовження виконання скрипту
press_any_key() {
    read -n 1 -s -r -p "Press any key to continue..."
    echo ""
}
##################################################################


##################################################################
#функція виконує команду SSH на DUT з IP 192.168.1.1
# НЕ глушить stderr, щоб у логах було видно причину (host unreachable, auth, тощо).
run_dut_command() {
  local ip="${DUT_IPS[$((CURRENT_DUT-1))]:-192.168.1.1}"
  sshpass -p "${SSH_PASS:-ui}" ssh \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    "${SSH_USER:-root}@$ip" "$@" 2>/dev/null
}

# Те саме, але ніколи не ламає пайплайни у set -e|pipefail
run_dut_command_quiet() {
  run_dut_command "$@" >/dev/null 2>&1 || true
}
##################################################################



##################################################################
#функція завантажує файл на пристрій під управлінням IP 192.168.1.1 з використанням SCP (до успіху)
# Завантажити файл(и) на /tmp активного DUT
# ------------------------------------------------------------
# dut_upload <локальний_файл> [<віддалений_повний_шлях_на_DUT>]
# Копіює файл на поточний DUT (IP береться з $DUT_IP або 192.168.1.1).
# За замовчуванням кладе у /tmp з тим же ім'ям.
# Параметри з CONF.sh:
#   SSH_PASS            — пароль root (якщо потрібен). Якщо порожній — використовує key-based auth.
# Додатково (опційно через env):
#   LAB_IGNORE_HOSTKEY  — =1 (дефолт) ігнорувати known_hosts (зручно для стенду з однаковим IP) ;
#                         =0 — перевіряти ключі як звичайно.
#   VERIFY_UPLOAD       — =1 перевіряти md5 після копіювання (потрібен md5sum на DUT).
# Пише діагностику у $LOG_DIR (папку створить).
# Повертає 0/1.
# ------------------------------------------------------------
function dut_upload() {
    local src="${1:-}"
    local dst="${2:-}"
    local ip="${DUT_IP:-192.168.1.1}"
    local user="${DUT_USER:-root}"

    # --- базові перевірки ---
    if [ -z "$src" ]; then
        echo "dut_upload: не вказано локальний файл" >&2
        return 1
    fi
    if [ ! -r "$src" ]; then
        echo "dut_upload: файл '$src' не існує або недоступний" >&2
        return 1
    fi
    if [ -z "$dst" ]; then
        dst="/tmp/$(basename "$src")"
    fi

    # --- підготовка логів ---
    mkdir -p "$LOG_DIR"
    local logf="$LOG_DIR/upload_$(date +%F_%H-%M-%S).log"

    # --- SSH/SCP опції (не ламають інші скрипти, бо локальні для цієї функції) ---
    local -a SSH_OPTS=()
    if [ "${LAB_IGNORE_HOSTKEY:-1}" = "1" ]; then
        SSH_OPTS+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null)
    fi

    # --- вибір способу: ключі або пароль (sshpass) ---
    local -a CMD
    if [ -n "${SSH_PASS:-}" ]; then
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "dut_upload: встанови sshpass або прибери SSH_PASS (зараз: пароль задано, але sshpass відсутній)" | tee -a "$logf" >&2
            return 1
        fi
        CMD=(sshpass -p "$SSH_PASS" scp "${SSH_OPTS[@]}" -q -- "$src" "${user}@${ip}:${dst}")
    else
        CMD=(scp "${SSH_OPTS[@]}" -q -- "$src" "${user}@${ip}:${dst}")
    fi

    # --- саме копіювання ---
    if ! "${CMD[@]}" 2>>"$logf"; then
        echo "dut_upload: копіювання '$src' → ${user}@${ip}:$dst FAILED" | tee -a "$logf" >&2
        return 1
    fi

    # --- опційна верифікація md5 ---
    if [ "${VERIFY_UPLOAD:-0}" = "1" ]; then
        local md5_local md5_remote
        if command -v md5sum >/dev/null 2>&1; then
            md5_local="$(md5sum "$src" | awk '{print $1}')"
            # з паролем/без пароля — та ж логіка, що й для scp
            if [ -n "${SSH_PASS:-}" ]; then
                md5_remote="$(sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" -q "${user}@${ip}" "md5sum '$dst' 2>/dev/null | awk '{print \$1}'")"
            else
                md5_remote="$(ssh "${SSH_OPTS[@]}" -q "${user}@${ip}" "md5sum '$dst' 2>/dev/null | awk '{print \$1}'")"
            fi
            if [ -z "$md5_remote" ] || [ "$md5_local" != "$md5_remote" ]; then
                echo "dut_upload: MD5 mismatch ($md5_local != $md5_remote) для '$dst' на DUT" | tee -a "$logf" >&2
                return 1
            fi
        else
            echo "dut_upload: md5sum недоступний локально — пропускаю перевірку" | tee -a "$logf"
        fi
    fi

    [ -n "${DEBUG:-}" ] && echo "dut_upload: OK '$src' → ${user}@${ip}:$dst" | tee -a "$logf"
    return 0
}


##################################################################


##################################################################
# Хелпер
# На поточному DUT: залити файли та перевірити синтаксис on-device скрипта
# Викликаємо ПЕРЕД будь-якою on-device функцією
run_ondevice_preflight() {
    local conf_bn
    conf_bn="$(basename "$CONF_FILE")"

    # 1) Залити файли у /tmp
    dut_upload "$SCRIPT_DIR/on-device-tests.sh"    || return 1
    dut_upload "$CONF_FILE"                        || return 1

    # 2) Права + синтаксис (щоб бачити зрозумілу причину, якщо щось не так)
    run_dut_command "chmod +x /tmp/on-device-tests.sh && bash -n /tmp/on-device-tests.sh" || return 1
}
##################################################################


##################################################################
# Хелпер
# На поточному DUT: підключити on-device файл і ВИКЛИКАТИ конкретну функцію
# При цьому блокуємо автозапуск “головного блоку” через RUN_ONDEVICE_MAIN=0
run_ondevice_func() {
    local func="$1"; shift
    local conf_bn
    conf_bn="$(basename "$CONF_FILE")"

    run_dut_command \
      "RUN_ONDEVICE_MAIN=0 CONF_FILE=/tmp/$conf_bn bash -lc '. /tmp/on-device-tests.sh; type $func >/dev/null; $func \"$@\"'"
}
##################################################################


##################################################################
#функція керую мережевим з'єднанням для DUT
set_current_dut() {
  CURRENT_DUT="$1"
  for f in $(seq 1 "$DUT_COUNT"); do
    local name="DUT $f LAN"
    if [ "$f" -eq "$1" ]; then
      _nm_up_safe "$name" || { echo "⚠️ ERROR: cannot bring up \"$name\""; return 1; }
    else
      _nm_down_quiet "$name"
    fi
  done
}
##################################################################


##################################################################
function _run_self_tests() {
	#Ініціалізація масиву для зберігання MAC-адрес невдалих пристроїв
	FAILED_DUT=()
	for i in $(seq 1 $DUT_COUNT); do
        	#Встановлює поточний DUT
        	set_current_dut "$i"
        	run_dut_command "cat /sys/class/net/eth0/address"
        
        	#Завантажуємо файли на DUT (у /tmp)
        	dut_upload "$SCRIPT_DIR/on-device-tests.sh"
		dut_upload "$CONF_FILE"
		
		# Права (скрипт — виконуваний, конфіг — лише читання)
        	run_dut_command "chmod +x /tmp/on-device-tests.sh && chmod 600 /tmp/$(basename "$CONF_FILE")"
        	echo "Starting test on DUT $i"
        
        	#Запускає тестовий скрипт
        	run_dut_command "nohup env CONF_FILE=/tmp/$(basename "$CONF_FILE") bash /tmp/on-device-tests.sh </dev/null >/tmp/on-device-tests.log 2>&1 &"
        	#or
		#run_dut_command "nohup bash /tmp/on-device-tests.sh /tmp/$(basename "$CONF_FILE") </dev/null >/tmp/on-device-tests.log 2>&1 &"
	done

    #Цикл перевіряє, чи завершилися тести на всіх пристроях, шляхом перевірки наявності файлу /tmp/refurbish_test_done
    DUT_NOT_DONE=1
    while [ "$DUT_NOT_DONE" -eq "1" ]; do
        DUT_NOT_DONE=0
        for i in $(seq 1 $DUT_COUNT); do
            set_current_dut "$i"
            run_dut_command "[ ! -f /tmp/refurbish_test_done ]" && DUT_NOT_DONE=1 && echo "Waiting on DUT $i..."
        done
    done
    
    OVERALL_FAIL=0
	for i in $(seq 1 "$DUT_COUNT"); do
		set_current_dut "$i"
		if run_dut_command "[ -f /tmp/refurbish_test_failed ]"; then
		    echo "DUT $i: self-tests FAILED"
		    OVERALL_FAIL=1
		elif run_dut_command "[ -f /tmp/refurbish_test_passed ]"; then
		    echo "DUT $i: self-tests PASSED"
		else
		    echo "DUT $i: self-tests UNKNOWN (no markers)"
		    OVERALL_FAIL=1
		fi
	done

	# Зафіксувати провал для зовнішньої логіки
	if [ "$OVERALL_FAIL" -ne 0 ]; then
		return 1
	fi


    #Перевірка результатів тестів та збір логів
    BAIL=0
    for i in $(seq 1 $DUT_COUNT); do
        set_current_dut "$i"
        DUT_MAC=$(run_dut_command "cat /sys/class/net/eth0/address" | sed 's/://g')
        run_dut_command "cat /tmp/refurbish_test_log" | tee "$LOG_DIR/$DUT_MAC-selftest-$(date +\"%Y-%m-%d_%H-%M-%S\").txt"
        echo "$DUT_MAC"
        echo ""
        if run_dut_command "[ -f /tmp/refurbish_test_passed ] && [ ! -f /tmp/refurbish_test_failed ]"; then
            echo "$DUT_MAC self-tests passed"
            echo "____________________________________________________________________________________________________"
            echo ""
        else
            echo "$DUT_MAC self-tests ⚠️ failed!"
            echo "____________________________________________________________________________________________________"
            echo ""
            FAILED_DUT+=($DUT_MAC)
            BAIL=1
        fi
    done
    #Виведення списку невдалих пристроїв (якщо такі є) та вихід з функції
    if [ "$BAIL" -eq "1" ]; then
        echo -e "\n\n\n\nSome devices ⚠️ failed testing:"
        for i in ${FAILED_DUT[@]}; do
            echo "$i"
        done
        exit 1
    fi
}
##################################################################


##################################################################
# Функції з on-device-tests

# ------------------------------------------------------------
# Перевірка портів на всіх DUT.
# - На КОЖНИЙ DUT заливає on-device-tests.sh і CONF.sh (у /tmp)
# - Робить префлайт (chmod + syntax check)
# - Викликає ЛИШЕ функцію __dut_8370_test (без автозапуску інших тестів)
# - Логи пише в $LOG_DIR/port_tests_*.log
function run_port_tests() {
    # 1) Логи
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/port_tests_$(date +%F_%H-%M-%S).log"

    # 2) Підсумки по кожному DUT
    declare -A TEST_RESULTS

    # 3) Цикл по DUT (дефолт 1, якщо DUT_COUNT не задано)
    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        # Виставляємо контекст поточного DUT (IP, MAC тощо)
        set_current_dut "$i"

        echo "Running port tests on DUT $i" | tee -a "$LOG_FILE"

        # 3.1) Префлайт: заливка файлів + права + перевірка синтаксису
        if ! run_ondevice_preflight; then
            echo "Port tests on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"
            echo "run_port_tests FINISHED" | tee -a "$LOG_FILE"
            continue
        fi

        # 3.2) Виклик on-device функції (без автозапуску головного блоку)
        if run_ondevice_func "__dut_8370_test"; then
            echo "Port tests on DUT $i passed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="passed"
        else
            echo "Port tests on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"
        fi

        # 3.3) Маркер завершення для читабельності логів (як у твоєму виводі)
        echo "run_port_tests FINISHED" | tee -a "$LOG_FILE"
    done

	# 4) Підсумок + код повернення
	echo "Port test results:" | tee -a "$LOG_FILE"
	overall_fail=0
	for i in $(seq 1 "${DUT_COUNT:-1}"); do
		res="${TEST_RESULTS[$i]:-n/a}"
		echo "DUT $i: $res" | tee -a "$LOG_FILE"
		[ "$res" = "failed" ] && overall_fail=1
	done
	return $overall_fail

}

# Зворотна сумісність зі старою назвою
function _run_port_tests() { run_port_tests "$@"; }


# ------------------------------------------------------------
# Перевірка Fans
function run_fan_tests() {
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/fan_tests_$(date +%F_%H-%M-%S).log"
    declare -A TEST_RESULTS

    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        set_current_dut "$i"
        echo "Running fan tests on DUT $i" | tee -a "$LOG_FILE"

        if ! run_ondevice_preflight; then
            echo "Fan tests on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"; continue
        fi

        if run_ondevice_func "__dut_system_test_fans" 2>&1 | tee -a "$LOG_FILE" | tail -n +1 >/dev/null; then
            echo "Fan tests on DUT $i passed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="passed"
        else
            echo "Fan tests on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"
        fi

        echo "run_fan_tests FINISHED" | tee -a "$LOG_FILE"
    done

    echo "Fan test results:" | tee -a "$LOG_FILE"
    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$LOG_FILE"
    done
}


# ------------------------------------------------------------
# Перевірка Memory
function run_memory_tests() {
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/memory_tests_$(date +%F_%H-%M-%S).log"
    declare -A TEST_RESULTS

    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        set_current_dut "$i"
        echo "Running memory tests on DUT $i" | tee -a "$LOG_FILE"

        if ! run_ondevice_preflight; then
            echo "Memory tests on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"; continue
        fi

        if run_ondevice_func "__dut_system_test_memory" 2>&1 | tee -a "$LOG_FILE" | tail -n +1 >/dev/null; then
            echo "Memory tests on DUT $i passed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="passed"
        else
            echo "Memory tests on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"
        fi

        echo "run_memory_tests FINISHED" | tee -a "$LOG_FILE"
    done

    echo "Memory test results:" | tee -a "$LOG_FILE"
    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$LOG_FILE"
    done
}


# ------------------------------------------------------------
# Перевірка SATA HDD
function run_sata_tests() {
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/sata_tests_$(date +%F_%H-%M-%S).log"
    declare -A TEST_RESULTS

    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        set_current_dut "$i"
        echo "Running SATA tests on DUT $i" | tee -a "$LOG_FILE"

        if ! run_ondevice_preflight; then
            echo "SATA tests on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"; continue
        fi

        if run_ondevice_func "__dut_system_test_sata_hdd" 2>&1 | tee -a "$LOG_FILE" | tail -n +1 >/dev/null; then
            echo "SATA tests on DUT $i passed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="passed"
        else
            echo "SATA tests on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"
        fi

        echo "run_sata_tests FINISHED" | tee -a "$LOG_FILE"
    done

    echo "SATA test results:" | tee -a "$LOG_FILE"
    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$LOG_FILE"
    done
}


# ------------------------------------------------------------
# Перевірка eMMC
function run_emmc_tests() {
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/emmc_tests_$(date +%F_%H-%M-%S).log"
    declare -A TEST_RESULTS

    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        set_current_dut "$i"
        echo "Running eMMC tests on DUT $i" | tee -a "$LOG_FILE"

        if ! run_ondevice_preflight; then
            echo "eMMC tests on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"; continue
        fi

        if run_ondevice_func "__dut_system_test_emmc" 2>&1 | tee -a "$LOG_FILE" | tail -n +1 >/dev/null; then
            echo "eMMC tests on DUT $i passed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="passed"
        else
            echo "eMMC tests on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"
        fi

        echo "run_emmc_tests FINISHED" | tee -a "$LOG_FILE"
    done

    echo "eMMC test results:" | tee -a "$LOG_FILE"
    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$LOG_FILE"
    done
}


# ------------------------------------------------------------
# Перевірка Bluetooth
function run_bluetooth_tests() {
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/bluetooth_tests_$(date +%F_%H-%M-%S).log"
    declare -A TEST_RESULTS
    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        set_current_dut "$i"
        echo "Running Bluetooth tests on DUT $i" | tee -a "$LOG_FILE"
        if ! run_ondevice_preflight; then
            echo "Bluetooth tests on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"; echo "run_bluetooth_tests FINISHED" | tee -a "$LOG_FILE"; continue
        fi
        if run_ondevice_func "__dut_system_test_bluetooth" 2>&1 | tee -a "$LOG_FILE" | tail -n +1 >/dev/null; then
            echo "Bluetooth tests on DUT $i passed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="passed"
        else
            echo "Bluetooth tests on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="failed"
        fi
        echo "run_bluetooth_tests FINISHED" | tee -a "$LOG_FILE"
    done
    echo "Bluetooth test results:" | tee -a "$LOG_FILE"
    for i in $(seq 1 "${DUT_COUNT:-1}"); do echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$LOG_FILE"; done
}



# ------------------------------------------------------------
# Перевірка Sensors
function run_sensors_tests() {
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/sensors_tests_$(date +%F_%H-%M-%S).log"
    declare -A TEST_RESULTS
    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        set_current_dut "$i"
        echo "Running sensors tests on DUT $i" | tee -a "$LOG_FILE"
        if ! run_ondevice_preflight; then
            echo "Sensors tests on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"; echo "run_sensors_tests FINISHED" | tee -a "$LOG_FILE"; continue
        fi
        if run_ondevice_func "__dut_system_test_sensors" 2>&1 | tee -a "$LOG_FILE" | tail -n +1 >/dev/null; then
            echo "Sensors tests on DUT $i passed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="passed"
        else
            echo "Sensors tests on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="failed"
        fi
        echo "run_sensors_tests FINISHED" | tee -a "$LOG_FILE"
    done
    echo "Sensors test results:" | tee -a "$LOG_FILE"
    for i in $(seq 1 "${DUT_COUNT:-1}"); do echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$LOG_FILE"; done
}

# ------------------------------------------------------------
# Перевірка cpu count
function run_cpu_count_tests() {
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/cpu_count_$(date +%F_%H-%M-%S).log"
    declare -A TEST_RESULTS
    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        set_current_dut "$i"
        echo "Running CPU count test on DUT $i" | tee -a "$LOG_FILE"
        if ! run_ondevice_preflight; then
            echo "CPU count on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"; echo "run_cpu_count_tests FINISHED" | tee -a "$LOG_FILE"; continue
        fi
        if run_ondevice_func "__dut_system_test_cpu_count" 2>&1 | tee -a "$LOG_FILE" | tail -n +1 >/dev/null; then
            echo "CPU count on DUT $i passed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="passed"
        else
            echo "CPU count on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="failed"
        fi
        echo "run_cpu_count_tests FINISHED" | tee -a "$LOG_FILE"
    done
    echo "CPU count results:" | tee -a "$LOG_FILE"
    for i in $(seq 1 "${DUT_COUNT:-1}"); do echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$LOG_FILE"; done
}

# ------------------------------------------------------------
# Перевірка CPU port map
function run_switch_cpu_port_tests() {
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/switch_cpu_port_$(date +%F_%H-%M-%S).log"
    declare -A TEST_RESULTS
    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        set_current_dut "$i"
        echo "Running 8370 CPU port test on DUT $i" | tee -a "$LOG_FILE"
        if ! run_ondevice_preflight; then
            echo "8370 CPU port on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"; echo "run_switch_cpu_port_tests FINISHED" | tee -a "$LOG_FILE"; continue
        fi
        if run_ondevice_func "__dut_8370_cpu_port_test" 2>&1 | tee -a "$LOG_FILE" | tail -n +1 >/dev/null; then
            echo "8370 CPU port on DUT $i passed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="passed"
        else
            echo "8370 CPU port on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="failed"
        fi
        echo "run_switch_cpu_port_tests FINISHED" | tee -a "$LOG_FILE"
    done
    echo "8370 CPU port results:" | tee -a "$LOG_FILE"
    for i in $(seq 1 "${DUT_COUNT:-1}"); do echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$LOG_FILE"; done
}
# ------------------------------------------------------------
# Перевірка RAM
function run_mem_count_tests() {
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/mem_count_$(date +%F_%H-%M-%S).log"
    declare -A TEST_RESULTS

    for i in $(seq 1 "${DUT_COUNT:-1}"); do
        set_current_dut "$i"
        echo "Running mem-count test on DUT $i" | tee -a "$LOG_FILE"

        if ! run_ondevice_preflight; then
            echo "Mem-count on DUT $i ⚠️ failed (preflight)" | tee -a "$LOG_FILE"
            TEST_RESULTS[$i]="failed"; echo "run_mem_count_tests FINISHED" | tee -a "$LOG_FILE"; continue
        fi

        if run_ondevice_func "__dut_system_test_mem_count" 2>&1 | tee -a "$LOG_FILE" | tail -n +1 >/dev/null; then
            echo "Mem-count on DUT $i passed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="passed"
        else
            echo "Mem-count on DUT $i ⚠️ failed" | tee -a "$LOG_FILE"; TEST_RESULTS[$i]="failed"
        fi

        echo "run_mem_count_tests FINISHED" | tee -a "$LOG_FILE"
    done

    echo "Mem-count results:" | tee -a "$LOG_FILE"
    for i in $(seq 1 "${DUT_COUNT:-1}"); do echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$LOG_FILE"; done
}
##################################################################


##################################################################
function _run_wan_tests() {
    for i in $(seq 1 $DUT_COUNT); do
        set_current_dut "$i"
        DUT_MAC=`run_dut_command "cat /sys/class/net/eth0/address" | sed 's/://g'`

	# Якщо WAN_IFACE не задано або інтерфейсу нема на пристрої — пропускаємо WAN-тести
	if [ -z "$WAN_IFACE" ] || ! run_dut_command "ip link show $WAN_IFACE >/dev/null 2>&1"; then
	    echo "$DUT_MAC: WAN tests skipped (no WAN_IFACE)"
	else
	    # 1G link state?
	    if run_dut_command "ethtool $WAN_IFACE | grep -q 'Link detected: yes'"; then
		echo "$DUT_MAC: $WAN_IFACE link is up"
	    else
		echo "$DUT_MAC: $WAN_IFACE link is NOT up, ⚠️ FAIL"
		exit 1
	    fi

	    # 1G link speed?
	    if run_dut_command "ethtool $WAN_IFACE | grep -q 'Speed: 1000Mb/s'"; then
		echo "$DUT_MAC: $WAN_IFACE link is 1000M"
	    else
		echo "$DUT_MAC: $WAN_IFACE link is NOT 1000M, ⚠️ FAIL"
		exit 1
	    fi

	    # Reachability
	    if run_dut_command "ping -c 1 -W 1 ui.com >/dev/null 2>&1" ; then
		echo "$DUT_MAC: WAN ping passed"
	    else
		echo "$DUT_MAC: WAN ping ⚠️ failed"
		exit 1
	    fi
	fi

    done
    echo "run_wan_tests $DUT_MAC FINISHED"
}
##################################################################


##################################################################
function run_cpu_stress_test() {
    echo "Running CPU stress test..."
    sshpass -p "${SSH_PASS:-ui}" ssh -o StrictHostKeyChecking=no root@192.168.1.1 "stress --cpu 4 --timeout 60"
}
##################################################################


##################################################################
function run_memory_stress_test() {
    echo "Running memory stress test..."
    sshpass -p "${SSH_PASS:-ui}" ssh -o StrictHostKeyChecking=no root@192.168.1.1 "memtester 1024 5"
}
##################################################################


##################################################################
function run_disk_stress_test() {
    echo "Running disk I/O stress test..."
    sshpass -p "${SSH_PASS:-ui}" ssh -o StrictHostKeyChecking=no root@192.168.1.1 "dd if=/dev/zero of=/tmp/testfile bs=1G count=10 oflag=direct"
}
##################################################################


##################################################################
function run_network_stress_test() {
    echo "Running network stress test..."
    sshpass -p "${SSH_PASS:-ui}" ssh -o StrictHostKeyChecking=no root@192.168.1.1 "iperf3 -c <server-ip> -t 60 -P 10"
}
##################################################################


##################################################################
function run_temperature_check() {
    echo "Checking temperature..."
    sshpass -p "${SSH_PASS:-ui}" ssh -o StrictHostKeyChecking=no root@192.168.1.1 "sensors"
}
##################################################################


##################################################################
function run_all_stress_tests() {			#
    run_cpu_stress_test						#
    run_memory_stress_test					#
    run_disk_stress_test					#
    run_network_stress_test					#
    run_temperature_check					#
}
##################################################################

##################################################################
function _dut_touch_tests()
{
    echo -e "\n\n(all units) Touch the screen and verify that it responds to touch"
    press_any_key
    
    echo -e "\n\n(all units) Check that the picture on the screen looks OK (bright, no visual artifacts, stuck pixels, etc)"
    press_any_key

    echo -e "\n\n(all units) Check that the hard drive indicator LED is WHITE"
    press_any_key
        
    echo -e "\n\n(all units) Check that the link status LEDs on ports 1 thru 9 on the DUT are GREEN"
    press_any_key

    echo -e "\n\n(all units) Check that the link status LED port 11 on the DUT is GREEN"
    press_any_key
    echo "____________________________________________________________________________________________________"
    
    # -----  Кнопка скидання ----- 
	#for i in $(seq 1 "${DUT_COUNT:-2}"); do
	#	set_current_dut "$i"
	#	sleep 2

    	# інтерфейс для цього DUT: v1000..v1011 (формула 999+i)
    #	src_if="v$((999+i))"

    	# 1) Підказка користувачу — ЗАВЖДИ
    #	printf "\n\n(DUT #%d) Briefly press the RESET button (do NOT hold it)\n" "$i"

    	# 2) Ping як діагностика (не блокує підказку)
    #	if ! ping -I "$src_if" -c1 -W1 192.168.1.1 >/dev/null 2>&1; then
    #    	echo "WARN: ping via $src_if ⚠️ failed for DUT #$i (продовжуємо за натисканням кнопки)"
    #	fi

    	# 3) Чекаємо подію від кнопки на DUT
    	#    Якщо у тебе точно event0 — лишай як було;
    	#    нижче — трохи тихіша версія з 'status=none'
    #	run_dut_command "dd if=/dev/input/event0 of=/dev/null bs=96 count=1 status=none" >/dev/null 2>&1
	#done
    
    
}
##################################################################

mkdir -p "$LOG_DIR"

check_networkmanager
echo "Please make sure that all DUTs are powered off."
press_any_key

setup_usw_pro_24

echo "Please turn on all DUTs and wait for them to finish booting."
press_any_key

echo "For manual tests, the script will give you a series of prompts.  For each prompt, follow the instructions.  If the test passes, press any key.  If the test ⚠️ fails, abort the script by hitting Ctrl+C."
press_any_key



##################################################################

############################ ВИКОНАННЯ ###########################

##################################################################

#Виклик функцій
_dut_touch_tests

echo "Starting automated tests, please wait..."
echo "____________________________________________________________________________________________________"


##################################################################
echo "----- FW: start -----"
(
  # У підоболонці тимчасово без "еррехіт" і без pipefail — як у testORIG.sh
  set +e +o pipefail
	# Перед FW-апдейтом переконаймось, що NM-профілі прив'язані до реальних інтерфейсів
	CONF_FILE="$CONF_FILE" bash "$SCRIPT_DIR/funct/nm_fix_vlan_bindings.sh"

  _run_fw_check_upgrade
)
rc=$?
echo "----- FW: done ------"
echo "____________________________________________________________________________________________________"
echo ""
if [ "$rc" -ne 0 ]; then
  echo "⚠️ ERROR: FW step ⚠️ failed with code $rc"
  exit "$rc"
fi
##################################################################


##################################################################
echo "----- NetworkManager: start -----"
check_networkmanager
echo "----- NetworkManager: done ------"
echo "____________________________________________________________________________________________________"
echo ""
##################################################################


##################################################################
echo "----- PortStatus: start -----"
echo ""

for i in $(seq 1 "$DUT_COUNT"); do
	echo "Running port tests on DUT $i"
	# Активуємо лише профіль поточного DUT і гасимо інші **DUT-профілі** (Wi-Fi/VPN не чіпаємо)
	_con_for() { printf "${CONNECTION_TEMPLATE:-DUT %d LAN}" "$1"; }

	# Вимкнути інші DUT-профілі, крім поточного
	for j in $(seq 1 "${DUT_COUNT:-1}"); do
	  if [ "$j" -ne "$i" ]; then
		nmcli con down "$(_con_for "$j")" >/dev/null 2>&1 || true
	  fi
	done

	# Увімкнути профіль поточного DUT
	nmcli con up "$(_con_for "$i")" >/dev/null 2>&1 || true


	# вимакає усі з'єднання крім з DUT
	# Активуємо лише профіль поточного DUT і гасимо інші (щоб маршрути/ARP не плутались)
	#_con_for() { printf "${CONNECTION_TEMPLATE:-DUT %d LAN}" "$1"; }

	#nmcli -t -f NAME con show --active | grep -Fvx -- "$(_con_for "$i")" \
	#| xargs -r -I{} nmcli con down "{}" >/dev/null 2>&1 || true

	#nmcli con up "$(_con_for "$i")" >/dev/null 2>&1 || true

	# (Опційно) короткий роут-чек: має показати саме інтерфейс/VLAN цього DUT
	route_line="$(ip route get "$DUT_TARGET_IP" from "$(_dut_src_ip "$i")" 2>/dev/null | head -n1)"
	echo "DUT $i route: $route_line"

	for port in "${PORT_LIST[@]}"; do
		if check_port_status "$i" "$port"; then
			echo "DUT $i: port $port OK"
		else
      			echo "DUT $i: port $port ⚠️ FAILED"
    		fi
  	done
done
echo "----- PortStatus: done ------"
echo "____________________________________________________________________________________________________"
echo ""
##################################################################


##################################################################
_run_wan_tests
echo "____________________________________________________________________________________________________"
echo ""
##################################################################

##################################################################
echo "----- on-device-tests: start -----"
: "${OVERALL_FAIL:=0}"   # якщо ще не ініціалізований — зроби 0; інакше збережи попередній стан
if ! run_port_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
#if ! run_fan_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
if ! run_bluetooth_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
if ! run_sensors_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
if ! run_switch_cpu_port_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
if ! run_cpu_count_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
if ! run_mem_count_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
if ! run_memory_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
if ! run_sata_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
if ! run_emmc_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
#if ! run_wan_tests; then OVERALL_FAIL=1; fi
echo "____________________________________________________________________________________________________"
echo ""
if [ "${OVERALL_FAIL:-0}" -ne 0 ]; then
  echo "on-device-tests: overall FAILED"
  exit 1
else
  echo "on-device-tests: overall PASSED"
fi

echo "----- on-device-tests: done ------"
echo "____________________________________________________________________________________________________"
echo ""
##################################################################


##################################################################
# Виклик функцій для стрес-тестів
#run_all_stress_tests
##################################################################


##################################################################
# Звавнтажує файли на DUT
_run_self_tests			
##################################################################


##################################################################
#echo "----- IPERF: start -----"
#if [ "${ONLY_IPERF:-0}" -eq 1 ]; then
#  run_iperf_for_all_duts || OVERALL_FAIL=1
#else
  # ... інші тести ...
#  run_iperf_for_all_duts || OVERALL_FAIL=1
  # ... інші тести ...
#fi
#echo "----- IPERF: done ------"
#echo "____________________________________________________________________________________________________"
#echo ""
##################################################################


echo ""
echo ""
echo ""
if [ "${OVERALL_FAIL:-0}" -eq 0 ]; then
    echo "All devices passed."
else
    echo "Some devices FAILED."
    exit 1
fi

