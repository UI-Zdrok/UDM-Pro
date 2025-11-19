# funct/check_port_status.sh
# shellcheck shell=bash
# МАКСИМАЛЬНО прокоментовано й безпечно під set -u / set -e.


check_port_status() {
  # Аргументи:
  #   $1 = dut_idx (обов’язково)
  #   $2 = port_num (обов’язково)
  #   $3 = iface_hint (необов’язково; якщо порожньо — візьмемо eth<port_num>)
  local dut_idx="${1:?check_port_status: потрібно <dut_idx>}"
  local port_num="${2:?check_port_status: потрібно <port_num>}"
  local iface_hint="${3:-}"

  # === 0) БЕЗПЕКА / ДЕФОЛТИ (щоб не було "unbound variable") ===================
  : "${USE_TELNET_FOR_SPEED:=1}"         # дозволяємо telnet localhost як фолбек
  : "${ENFORCE_PORT_SPEED:=0}"           # 1 = якщо швидкість ≠ EXPECTED_PORT_SPEED → FAIL
  : "${EXPECTED_PORT_SPEED:=1000}"       # очікувана швидкість (Mb/s)
  : "${FAIL_ON_SPEED_NA:=0}"             # 1 = якщо швидкість n/a → FAIL
  : "${DUT_SSH_USER:=root}"              # користувач на DUT
  : "${DUT_TARGET_IP:=192.168.1.1}"      # всі DUT мають однаковий IP (ти так казав)

  # === 1) Логи ================================================================
  local _LOG_DIR="${LOG_DIR:-"$SCRIPT_DIR/Logs"}"
  mkdir -p "$_LOG_DIR" 2>/dev/null || true
  local _LOG_FILE="$_LOG_DIR/port_status_$(date +%F_%H-%M-%S).log"
  _plog_port() { echo "$@"; echo "$@" >> "$_LOG_FILE"; }

  _plog_port "----- PortStatus: start -----"

  # === 2) SRC/DST/IFACE =======================================================
  # SRC (наш локальний IP для маршруту до конкретного DUT)
  local src_ip=""
  if declare -f _dut_src_ip >/dev/null 2>&1; then
    src_ip="$(_dut_src_ip "$dut_idx")"
  else
    # Якщо немає твоєї внутрішньої функції — читаємо з NM по шаблону
    local con_name; printf -v con_name "${CONNECTION_TEMPLATE:-DUT %d LAN}" "$dut_idx"
    src_ip="$(nmcli -t -f IP4.ADDRESS connection show "$con_name" 2>/dev/null \
              | awk -F'[ /]' 'NR==1{print $1}')"
  fi

  # DST (IP DUT) — для SSH/CLI
  local dst_ip="$DUT_TARGET_IP"

  # IFACE (ім’я інтерфейсу на DUT; для ethtool): підказка або eth<port_num>
  local ifname="$iface_hint"
  if [ -z "$ifname" ]; then
    if declare -f _dut_ifname >/dev/null 2>&1; then
      ifname="$(_dut_ifname "$dut_idx" "$port_num" "")"
    else
      ifname="eth$port_num"
    fi
  fi

# --- SSH транспорт: sshpass (якщо є пароль) + окремий ControlPath на кожен DUT ---
# ControlPath робимо унікальним для кожного DUT, інакше мультиплекс може «піти» не тим VLAN.
local _ctrl_dir="${SSH_CTRL_DIR:-"$SCRIPT_DIR/.sshctl"}"
mkdir -p "$_ctrl_dir" 2>/dev/null || true
local _ctrl_path="$_ctrl_dir/cm-%r@%h:%p-dut${dut_idx}"

if [ -n "${DUT_SSH_PASS:-}" ] && [ "${SSH_USE_SSHPASS:-1}" -eq 1 ] && command -v sshpass >/dev/null 2>&1; then
  # Безпечніше через змінну середовища, щоб пароль не світився у `ps`
  export SSHPASS="$DUT_SSH_PASS"
  SSH_BASE=(sshpass -e ssh
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=2
    -o PreferredAuthentications=keyboard-interactive,password
    -o PubkeyAuthentication=no
    -o ControlMaster=auto
    -o ControlPath="$_ctrl_path"
    -o ControlPersist="${SSH_CONTROL_PERSIST:-120}"
    -b "$src_ip"
  )
else
  # Без пароля: або ключі, або нічого — тоді відрубаємо будь-які інтерективні запити
  SSH_BASE=(ssh
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=2
    -o ControlMaster=auto
    -o ControlPath="$_ctrl_path"
    -o ControlPersist="${SSH_CONTROL_PERSIST:-120}"
    -b "$src_ip"
  )
fi


  _plog_port "(DUT $dut_idx, port $port_num, ifname='$ifname', src_ip=$src_ip, dst_ip=$dst_ip)"

  # === 3) ethtool/sysfs (перший прохід; може бути неточним для switch-портів) ==
  local et="" link="" speed="" speed_mbps=""
  et="$("${SSH_BASE[@]}" "$DUT_SSH_USER@$dst_ip" "ethtool $ifname 2>/dev/null || true" 2>/dev/null)" || true
  link="$(printf '%s\n' "$et" | awk -F': ' '/[Ll]ink detected/{print $2}' | tr -d '\r' | head -n1)"
  speed="$(printf '%s\n' "$et" | awk -F': ' '/^Speed/{print $2}' | tr -d '\r' | head -n1)"
  if [ -n "$speed" ]; then
    speed_mbps="$(printf '%s' "$speed" | sed -E 's/[Mm][Bb]\/s//;s/[[:space:]]//g')"
    if [ "$speed_mbps" = "-1" ] || printf '%s' "$speed" | grep -qi 'unknown'; then
      speed=""; speed_mbps=""
    fi
  fi

  # === 4) Визначаємо номер рядка ASIC/CLI (0-based зазвичай) ==================
  local sw_p=""                             # рядок у swconfig/CLI таблиці
  eval "sw_p=\${PORT_SWITCHNUM_DUT${dut_idx}[$port_num]:-}"
  if [ -z "$sw_p" ]; then
    sw_p=$((port_num-1))                    # фолбек: 1->0, 8->7
  fi
  _plog_port "DUT $dut_idx: map port $port_num -> ASIC row $sw_p"

  # === 5) Читаємо ПРАВДУ зі switch-чіпа (swconfig) ============================
  # автодетект імені swconfig-девайса (інколи не switch0)
  local swdev=""
  swdev=$("${SSH_BASE[@]}" "$DUT_SSH_USER@$dst_ip" "swconfig list 2>/dev/null | awk '{print \$2}'" 2>/dev/null | head -n1) || true
  [ -z "$swdev" ] && swdev="switch0"

  local sw_line=""
  sw_line=$("${SSH_BASE[@]}" "$DUT_SSH_USER@$dst_ip" \
            "command -v swconfig >/dev/null 2>&1 && swconfig dev $swdev port '$sw_p' get link 2>/dev/null || true" \
            2>/dev/null) || true
  [ -n "$sw_line" ] && _plog_port "DUT $dut_idx: swconfig raw: $sw_line"

  if printf '%s\n' "$sw_line" | grep -q 'link:'; then
    if printf '%s\n' "$sw_line" | grep -q 'link:up'; then link="yes"; else link="no"; fi
  fi
  if printf '%s\n' "$sw_line" | grep -q 'speed:'; then
    speed_mbps="$(printf '%s\n' "$sw_line" | sed -n 's/.*speed:\([0-9]\+\).*/\1/p' | head -n1)"
    [ -n "$speed_mbps" ] && speed="${speed_mbps}Mb/s"
  fi

  # === 6) Якщо досі нема link/speed — падаємо на telnet localhost (CLI) =======
  if { [ -z "$speed_mbps" ] || [ -z "$link" ]; } && [ "${USE_TELNET_FOR_SPEED:-1}" -eq 1 ]; then
    local cli_out="" cli_line="" s_guess=""
    cli_out=$("${SSH_BASE[@]}" "$DUT_SSH_USER@$dst_ip" \
              "(echo; sleep 0.2; echo enable; sleep 0.2; echo 'show interfaces status'; sleep 0.2; echo exit; sleep 0.1) | telnet localhost 2>/dev/null" \
              2>/dev/null) || true
    cli_line="$(printf '%s\n' "$cli_out" | awk -v p="$sw_p" '$1==p{print; exit}')" || true
    [ -n "$cli_line" ] && _plog_port "DUT $dut_idx: cli row[$sw_p]: $cli_line"

    if [ -n "$cli_line" ]; then
      if printf '%s\n' "$cli_line" | grep -qi '\bup\b'; then link="yes"; fi
      if printf '%s\n' "$cli_line" | grep -qi '\bdown\b'; then link="no"; fi
      s_guess="$(printf '%s\n' "$cli_line" | grep -Eo '(10|100|1000|2500|5000|10000)M' | head -n1 | tr -d 'M')"
      if [ -n "$s_guess" ]; then speed_mbps="$s_guess"; speed="${speed_mbps}Mb/s"; fi
    fi
  fi

  # === 7) Висновок ============================================================
  if [ "$link" = "yes" ]; then
    if [ "${ENFORCE_PORT_SPEED:-0}" -eq 1 ] && [ -n "$speed_mbps" ] && [ "$speed_mbps" -ne "${EXPECTED_PORT_SPEED:-1000}" ]; then
      echo "Port $port_num is connected (speed $speed) — ⚠️ FAIL (policy)"
      _plog_port "----- PortStatus: done -----"; return 1
    fi
    if [ "${FAIL_ON_SPEED_NA:-0}" -eq 1 ] && [ -z "$speed_mbps" ]; then
      _plog_port "DUT $dut_idx: Port $port_num ($ifname) піднятий, speed=n/a — політика вимагає ⚠️ FAIL"
      echo "Port $port_num is connected (speed n/a) — ⚠️ FAIL (policy)"
      _plog_port "----- PortStatus: done -----"; return 1
    fi
    _plog_port "DUT $dut_idx: Port $port_num ($ifname) піднятий, speed=${speed:-n/a}"
    echo "Port $port_num is connected"
    _plog_port "----- PortStatus: done -----"; return 0
  else
    _plog_port "DUT $dut_idx: Port $port_num ($ifname) не піднятий (Link detected: ${link:-unknown})"
    echo "Port $port_num is not connected"
    _plog_port "----- PortStatus: done -----"; return 1
  fi
}
