#!/usr/bin/env bash
# ============================================================================
# iperf3_test.sh  — окремий модуль для пропускної здатності через DUT
# ----------------------------------------------------------------------------
# Ідея: один Linux-хост з ДВОМА фізичними інтерфейсами, підключеними до
#       різних портів DUT (switch/UDM-Pro). Створюємо 2 network namespace:
#       nsA <-> IFACE_A 10.10.<DUT>.1/24
#       nsB <-> IFACE_B 10.10.<DUT>.2/24
#       Запускаємо iperf3 server у nsA і client у nsB.
#       Трафік фізично проходить через DUT між двома портами.
#
# Вимоги:
#   - root (або sudo) для операцій з namespace
#   - встановлені: iperf3, iproute2 (ip), awk, sed; (python3 бажано для JSON)
#   - інтерфейси, що використовуються, НЕ повинні бути під керуванням NetworkManager
#     під час тесту (або NM-конект вимкнений).
#
# Конфігурація береться з CONF.sh (через змінні середовища):
#   IPERF_ENABLE=1                 # включити/виключити тест
#   IPERF_DURATION=10              # сек, тривалість
#   IPERF_PARALLEL=4               # кількість паралельних потоків
#   IPERF_PROTOCOL=tcp|udp         # режим
#   IPERF_UDP_RATE_M=950           # Mbps для UDP
#   IPERF_MIN_MBIT=900             # поріг "пройшов"
#   IPERF_NET_BASE="10.10"         # базова мережа: 10.10.<DUT>.x/24
#   declare -A IPERF_IFACE_PAIR    # пари інтерфейсів для кожного DUT: "ifA:ifB"
#     IPERF_IFACE_PAIR[1]="enp3s0:enp4s0"
#     IPERF_IFACE_PAIR[2]="enp5s0:enp6s0"
#
# Виклик із основного скрипта:
#   iperf3_test_main <dut_idx> <if1> <if2>
# або   iperf3_test_run_for_dut <dut_idx>   # витягне пари з CONF.sh
#
# Логи: Logs/iperf3_DUT<idx>_<timestamp>.log та коротке резюме у stdout.
# Код виходу: 0 = PASS, 1 = FAIL/помилка.
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# --- внутрішній логер (вписується у Logs та у консоль) ---
__iperf_log() {
  local msg="[$(date +'%F %T')] $*"
  # Якщо головний логер визначений у тесті — використати його
  if type _plog >/dev/null 2>&1; then
    _plog "$msg"
  else
    echo "$msg"
  fi
}

# --- підготовка каталогів логів ---
__ensure_logs_dir() {
  mkdir -p Logs || mkdir -p ./Logs || true
}

# --- безпечне повернення інтерфейсу назад у root namespace ---
__move_iface_back_to_root() {
  local ns="$1"
  local ifc="$2"
  # Якщо інтерфейс ще існує у вказаному ns — повернути у root (netns 1)
  if ip netns exec "$ns" bash -c "ip link show '$ifc' >/dev/null 2>&1"; then
    ip -n "$ns" link set "$ifc" netns 1 || true
  fi
}

# --- очистка namespace ---
__cleanup_namespaces() {
  local nsA="$1" nsB="$2" ifA="$3" ifB="$4"
  # спробувати зупинити процеси iperf3, якщо ще живі
  pkill -f "ip netns exec $nsA iperf3 -s" >/dev/null 2>&1 || true
  pkill -f "ip netns exec $nsB iperf3 -c" >/dev/null 2>&1 || true

  __move_iface_back_to_root "$nsA" "$ifA"
  __move_iface_back_to_root "$nsB" "$ifB"

  # видалити NS, якщо існують
  ip netns del "$nsA" >/dev/null 2>&1 || true
  ip netns del "$nsB" >/dev/null 2>&1 || true
}

# --- визначення мінімального порогу в залежності від negotiated speed (етхтул) ---
__guess_min_threshold() {
  local ifc="$1"
  local default_min="${IPERF_MIN_MBIT:-900}"

  if ! command -v ethtool >/dev/null 2>&1; then
    echo "$default_min"; return 0
  fi

  local spd
  spd="$(ethtool "$ifc" 2>/dev/null | awk -F': ' '/^Speed/{print $2}' | tr -d '\r')" || true
  case "$spd" in
    100Mb/s)  echo "${IPERF_MIN_100M:-90}" ;;
    1000Mb/s) echo "${IPERF_MIN_1G:-930}" ;;
    2500Mb/s) echo "${IPERF_MIN_2G5:-2400}" ;;
    10000Mb/s) echo "${IPERF_MIN_10G:-9500}" ;;
    *) echo "$default_min" ;;
  esac
}

# --- запуск серверу (одна сесія, -1) ---
__start_server_once() {
  local nsA="$1" ipA="$2" log_file="$3"
  # -1     : завершити після однієї клієнтської сесії
  # -B ipA : бінд на конкретну адресу
  ip netns exec "$nsA" bash -c "iperf3 -s -1 -B '$ipA' " >>"$log_file" 2>&1 &
  echo $!  # pid
}

# --- запуск клієнта та збір результатів ---
__run_client_and_collect() {
  local nsB="$1" ipA="$2" ipB="$3" log_file="$4" duration="$5" parallel="$6" proto="$7" udp_rate="$8"

  local args="-c $ipA -B $ipB -t $duration -P $parallel -f m"
  if [[ "$proto" == "udp" ]]; then
    args="$args -u -b ${udp_rate}M"
  fi

  # Увімкнемо JSON для надійного парсингу, але одночасно пишемо людинозрозумілий лог
  local json_out
  json_out="$(ip netns exec "$nsB" bash -c "iperf3 $args -J 2>&1" | tee -a "$log_file")"

  # Спробуємо дістати Mbps з JSON python-ом (якщо є), інакше грубий grep
  if command -v python3 >/dev/null 2>&1; then
    # Для TCP беремо отриману суму, для UDP — сумарну bits_per_second (receiver)
    local py="
import sys, json
data=json.load(sys.stdin)
# iperf3 різниться між TCP/UDP: у TCP є end.sum_received.bits_per_second,
# для UDP — end.sum.bits_per_second або end.sum_received.bits_per_second залежно від версії
bps=None
for path in [
  ('end','sum_received','bits_per_second'),
  ('end','sum','bits_per_second'),
  ('end','sum_sent','bits_per_second')
]:
  d=data
  try:
    for k in path: d=d[k]
    if isinstance(d,(int,float)): bps=d; break
  except Exception: pass
if bps is None:
  # Спроба по потокам
  try:
    bps=sum(float(s['bits_per_second']) for s in data['end']['streams'])
  except Exception:
    bps=0.0
print(bps/1e6)
"
    echo "$json_out" | python3 -c "$py"
  else
    # Фолбек: шукаємо рядок з 'receiver' та 'SUM', беремо останнє число перед 'Mbits/sec'
    printf '%s\n' "$json_out" | awk '/receiver/ && /SUM/ {line=$0} END{print line}' |
      sed -E 's/.* ([0-9]+\.[0-9]+|[0-9]+) Mbits\/sec.*/\1/'
  fi
}

# --- основна функція: запускає тест на вказаних двох інтерфейсах ---
iperf3_test_main() {
  # Якщо явно вказали TRUNK-режим — запускаємо його гілку
  if [ "${IPERF_MODE:-}" = "trunk" ]; then
    iperf3_test_main_trunk "$@"
    return $?
  fi

  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    __iperf_log "ERROR: iperf3 тест потребує root (sudo)."
    return 1
  fi

  local dut_idx="$1"
  local IFACE_A="$2"
  local IFACE_B="$3"

  __ensure_logs_dir
  local log_file="Logs/iperf3_DUT${dut_idx}_$(date +%F_%H-%M-%S).log"

  # Налаштування (із CONF.sh або дефолти)
  local DURATION="${IPERF_DURATION:-10}"
  local PARALLEL="${IPERF_PARALLEL:-4}"
  local PROTOCOL="${IPERF_PROTOCOL:-tcp}"
  local UDP_RATE="${IPERF_UDP_RATE_M:-950}"
  local NET_BASE="${IPERF_NET_BASE:-10.10}"

  # Обчислюємо адреси
  local IP_A="${NET_BASE}.${dut_idx}.1"
  local IP_B="${NET_BASE}.${dut_idx}.2"
  local NS_A="iperfA_dut${dut_idx}"
  local NS_B="iperfB_dut${dut_idx}"

  __iperf_log "----- iPerf3: start (DUT $dut_idx; $IFACE_A <-> $IFACE_B) -----"
  {
    echo "IFACE_A=$IFACE_A  -> $IP_A"
    echo "IFACE_B=$IFACE_B  -> $IP_B"
    echo "Duration=$DURATION, Parallel=$PARALLEL, Proto=$PROTOCOL, UDP_RATE(Mbps)=$UDP_RATE"
  } >>"$log_file"

  # попередня очистка, якщо щось лишилось
  __cleanup_namespaces "$NS_A" "$NS_B" "$IFACE_A" "$IFACE_B"

  # Створюємо NS та переносимо інтерфейси
  ip netns add "$NS_A"
  ip netns add "$NS_B"

  ip link set "$IFACE_A" down
  ip link set "$IFACE_B" down

  ip link set "$IFACE_A" netns "$NS_A"
  ip link set "$IFACE_B" netns "$NS_B"

  ip -n "$NS_A" addr flush dev "$IFACE_A" || true
  ip -n "$NS_B" addr flush dev "$IFACE_B" || true

  ip -n "$NS_A" addr add "$IP_A/24" dev "$IFACE_A"
  ip -n "$NS_B" addr add "$IP_B/24" dev "$IFACE_B"

  ip -n "$NS_A" link set lo up
  ip -n "$NS_B" link set lo up
  ip -n "$NS_A" link set "$IFACE_A" up
  ip -n "$NS_B" link set "$IFACE_B" up

  # Порог за замовчуванням/з урахуванням швидкості лінку
  local THRESH_MIN_MBIT_A
  THRESH_MIN_MBIT_A="$(__guess_min_threshold "$IFACE_A")"
  local THRESH_MIN_MBIT_B
  THRESH_MIN_MBIT_B="$(__guess_min_threshold "$IFACE_B")"
  # Візьмемо менший з двох як робочий поріг
  local THRESH_MIN_MBIT="$THRESH_MIN_MBIT_A"
  awk -v a="$THRESH_MIN_MBIT_A" -v b="$THRESH_MIN_MBIT_B" 'BEGIN{ exit !(a<=b) }' || THRESH_MIN_MBIT="$THRESH_MIN_MBIT_B"

  echo "Calculated MIN threshold (Mbps) = $THRESH_MIN_MBIT" >>"$log_file"

  # Сервер (одна сесія) у фоні
  local srv_pid
  srv_pid="$(__start_server_once "$NS_A" "$IP_A" "$log_file")"
  sleep 0.5

  # Клієнт та збір виміру
  local Mbps
  Mbps="$(__run_client_and_collect "$NS_B" "$IP_A" "$IP_B" "$log_file" "$DURATION" "$PARALLEL" "$PROTOCOL" "$UDP_RATE")"
  Mbps="${Mbps:-0}"

  # Очистка
  __cleanup_namespaces "$NS_A" "$NS_B" "$IFACE_A" "$IFACE_B"

  # Округлення до одного знаку після коми
  local Mbps_rounded
  Mbps_rounded="$(awk -v x="$Mbps" 'BEGIN{printf "%.1f", x+0}')"

  # PASS/FAIL
  local rc=1
  if awk -v m="$Mbps" -v t="$THRESH_MIN_MBIT" 'BEGIN{ exit !(m>=t) }'; then
    __iperf_log "DUT $dut_idx: PASS — ${Mbps_rounded} Mbps (threshold ${THRESH_MIN_MBIT} Mbps)"
    rc=0
  else
    __iperf_log "DUT $dut_idx: FAIL — ${Mbps_rounded} Mbps (threshold ${THRESH_MIN_MBIT} Mbps)"
    rc=1
  fi

  echo "RESULT=${Mbps_rounded}Mbps; THRESH=${THRESH_MIN_MBIT}Mbps; STATUS=$([ $rc -eq 0 ] && echo PASS || echo FAIL)" >>"$log_file"
  __iperf_log "----- iPerf3: done (DUT $dut_idx) -----"
  return "$rc"
}

# --- шпаргалка: запуск за даними з масиву IPERF_IFACE_PAIR у CONF.sh ---
iperf3_test_run_for_dut() {
  local dut_idx="$1"
  # масив асоціативний: потрібна bash 4+
  local pair="${IPERF_IFACE_PAIR[$dut_idx]:-}"
  if [[ -z "${pair}" ]]; then
    __iperf_log "DUT $dut_idx: не задано IPERF_IFACE_PAIR[$dut_idx] у CONF.sh"
    return 1
  fi
  local ifA="${pair%%:*}"
  local ifB="${pair#*:}"
  iperf3_test_main "$dut_idx" "$ifA" "$ifB"
}
