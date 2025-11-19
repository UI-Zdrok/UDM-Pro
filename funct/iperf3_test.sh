#!/usr/bin/env bash
# =====================================================================
#  iperf3_test.sh — iPerf3 для DUT-ів через trunk + VLAN (USW-Pro-24)
#
#  Ідея:
#    - На хості є підінтерфейси BASE_IFACE.<VLAN>.
#    - У кожного DUT однаковий GW/Server: 192.168.1.1 (сам DUT).
#    - Щоб одночасно ходити до однакової адреси 192.168.1.1 на різних VLAN,
#      ми не переносимо інтерфейси в netns (бо це ламалось під sudo),
#      а використовуємо policy routing:
#         * даємо хосту унікальну адресу 192.168.1.(22+N-1) на кожному VLAN
#         * додаємо ip rule: "from 192.168.1.(22+N-1) -> своя таблиця"
#         * у тій таблиці маршрут до 192.168.1.0/24 через відповідний VLAN
#      iPerf3 запускаємо з прив’язкою джерела: -B <ця унікальна адреса>.
#
#  Очікувані змінні (підхоплюються з CONF.sh, якщо CONF_FILE задано):
#    BASE_IFACE         — базовий trunk-інтерфейс на ПК (напр. enxa0cec87043c0)
#    IPERF_VLAN_BASE    — перший VLAN (DUT1=1000, DUT2=1001, ...)
#    IPERF_HOST_NET_BASE— "192.168.1" (мережа DUTів)
#    IPERF_HOST_IP_START— з якої адреси видаємо хосту (22 => DUT1=.22, DUT2=.23, ...)
#    IPERF_SERVER       — адреса сервера iPerf3 на DUT (за замовч. 192.168.1.1)
#    IPERF_TIME         — тривалість (-t), сек (за замовч. 10)
#    IPERF_PARALLEL     — паралельні потоки (-P) (за замовч. 1)
#    IPERF_EXTRA_ARGS   — додаткові аргументи iPerf3 (необов'язково)
#    declare -A IPERF_IFACE_PAIR — явні пари "ifA:ifB" на кожен DUT (необов'язково)
#
#  Виклик напряму:
#     CONF_FILE="$PWD/CONF.sh" bash funct/iperf3_test.sh <dut_index>
#
#  Права:
#     Сам файл НЕ треба запускати під sudo.
#     Усередині для ip-команд викликається sudo ТІЛЬКИ точково.
# =====================================================================
# Гарантуємо нормальний PATH навіть у “чистому” середовищі
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Де шукати бінарник iPerf3:
# 1) якщо задано IPERF3_BIN — беремо його
# 2) інакше — шукаємо в PATH
IPERF3_BIN="${IPERF3_BIN:-$(command -v iperf3 2>/dev/null || true)}"

# ---------------------------- утиліти/лог -----------------------------
_log() { printf '%s\n' "$*"; }
_err() { printf 'ERROR: %s\n' "$*" >&2; }

_need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { _err "Команда не знайдена: $1"; return 127; }
}

_find_vlan_iface_by_vid() {
  local base="$1" vid="$2"
  ip -d link show type vlan | awk -v b="$base" -v v="$vid" '
    /^[0-9]+: / { name=$2; sub(":", "", name); split(name, a, "@"); ifname=a[1]; parent=a[2] }
    /vlan protocol 802\.1Q id/ { if ($0 ~ ("id " v)) { if (parent==b) { print ifname; exit 0 } } }
  '
}


# Таке саме правило іменування, як у prepare_vlan_ifaces.sh
_vifname() {
  local base="$1" vid="$2"
  local candidate="${base}.${vid}"
  if (( ${#candidate} <= 15 )); then
    printf '%s' "$candidate"
  else
    printf 'v%d' "$vid"
  fi
}



# ---------------------- підстановки/формули ---------------------------
# Повертає "ifA:ifB" для DUT. Спершу дивимось у масив IPERF_IFACE_PAIR[d],
# інакше будуємо з BASE_IFACE та VLAN формулою.
_get_iface_pair() {
  local dut="$1"

  # Явне налаштування у CONF.sh?
  if [[ -n "${IPERF_IFACE_PAIR[$dut]:-}" ]]; then
    # Дозволяємо і "ifA,ifB" — замінимо на "ifA:ifB"
    printf '%s' "${IPERF_IFACE_PAIR[$dut]//,/:}"
    return 0
  fi

  # Автопобудова за формулою
  local base="${BASE_IFACE:-${BASE:-}}"
  local vbase="${IPERF_VLAN_BASE:-1000}"

  if [[ -z "$base" ]]; then
    _err "BASE_IFACE не задано і не знайдено BASE. Додайте BASE_IFACE у CONF.sh"
    return 1
  fi

	local vid=$(( vbase + dut - 1 ))
	local ifn="$(_vifname "$base" "$vid")"
	printf '%s:%s' "$ifn" "$ifn"
}

# Обчислює унікальну джерельну IP на хості для цього DUT:
#  DUT1 -> 192.168.1.22, DUT2 -> 192.168.1.23, ...
_host_ip_for_dut() {
  local dut="$1"
  local net="${IPERF_HOST_NET_BASE:-192.168.1}"
  local start="${IPERF_HOST_IP_START:-22}"
  printf '%s.%d' "$net" "$(( start + dut - 1 ))"
}

# ------------------------ policy routing для DUT -----------------------
# Налаштовуємо:
#  - піднімаємо ifname
#  - даємо адресу <src>/24 на ifname (скидаємо інші глобальні)
#  - в таблиці <table_id> робимо маршрут до 192.168.1.0/24 через ifname
#  - правило: "from <src>/32 table <table_id>"
_setup_policy_for_dut() {
  local dut="$1" ifname="$2"
  local net="${IPERF_HOST_NET_BASE:-192.168.1}"
  local src; src="$(_host_ip_for_dut "$dut")"
  local vbase="${IPERF_VLAN_BASE:-1000}"
  local table_id=$(( vbase + dut - 1 ))
  local base="${BASE_IFACE:-${BASE:-}}"

  _need_cmd ip || return $?

  # Якщо такого імені немає — пошукаємо існуюче за VID+BASE
  if ! ip link show "$ifname" >/dev/null 2>&1; then
    local alt="$(_find_vlan_iface_by_vid "$base" "$table_id")"
    if [[ -n "$alt" ]]; then
      _log "[DUT $dut] Замість '$ifname' використовую існуючий інтерфейс '$alt'"
      ifname="$alt"
    else
      _err "[DUT $dut] Інтерфейса немає: $ifname (і не знайдено VLAN $table_id на $base)"
      return 1
    fi
  fi

  sudo ip link set "$ifname" up


  # Додаємо нашу джерельну адресу, якщо її ще нема
  ip -4 addr show dev "$ifname" | grep -q " $src/" || sudo ip addr add "${src}/24" dev "$ifname" 2>/dev/null || true

  sudo ip route replace "${net}.0/24" dev "$ifname" src "$src" table "$table_id"
  sudo ip rule del from "${src}/32" table "$table_id" 2>/dev/null || true
  sudo ip rule add from "${src}/32" table "$table_id" priority "$((3000 + dut))"
}


# ------------------------ головний ран для DUT ------------------------
# Виконує: визначає інтерфейси, готує policy routing, запускає iPerf3.
iperf3_test_run_for_dut() {
  local dut="$1"
  if [[ -z "$dut" ]]; then
    _err "Не передано номер DUT"; return 2
  fi

  	IPERF3_BIN="${IPERF3_BIN:-iperf3}"
	_need_cmd "$IPERF3_BIN" || return $?


  # 1) Які інтерфейси?
  local pair; pair="$(_get_iface_pair "$dut")" || return 1
  pair="${pair//,/:}"                       # уніфікуємо розділювач
  local ifA="${pair%%:*}"; local ifB="${pair#*:}"  # ifB зарезервовано «на майбутнє»

  if [[ -z "$ifA" ]]; then
    _err "[DUT $dut] Не визначено інтерфейс"; return 1
  fi

  # 2) Готуємо policy routing
  _setup_policy_for_dut "$dut" "$ifA" || return 1

  # 3) Параметри iPerf3
  local server="${IPERF_SERVER:-192.168.1.1}"
  local src; src="$(_host_ip_for_dut "$dut")"
  local t="${IPERF_TIME:-10}"
  local p="${IPERF_PARALLEL:-1}"
  local extra="${IPERF_EXTRA_ARGS:-}"

  _log "----- iPerf3: start ----- (DUT $dut)"
  # Прив'язуємося до джерела (policy routing гарантує вихід саме через свій VLAN)
  "$IPERF3_BIN" -c "$server" -B "$src" -t "$t" -P "$p" $extra
  local rc=$?
  _log "----- iPerf3: done ------ (DUT $dut) rc=$rc"
  return "$rc"
}

# ---------------- backward-compat шими (старі назви) ------------------
iperf3_test_main()        { iperf3_test_run_for_dut "$@"; }
iperf3_test_main_trunk()  { iperf3_test_run_for_dut "$@"; }

# --------------------------- entrypoint --------------------------------
# Дозволяємо викликати файл напряму:
#   CONF_FILE=/шлях/до/CONF.sh bash funct/iperf3_test.sh <dut>
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Якщо передали конфіг — підвантажимо обережно (без жорсткого set -u)
  if [[ -n "${CONF_FILE:-}" && -r "$CONF_FILE" ]]; then
    set +u
    # shellcheck disable=SC1090
    . "$CONF_FILE"
    set -u 2>/dev/null || true
  fi

  if [[ -z "${1:-}" ]]; then
    echo "Usage: CONF_FILE=\"\$PWD/CONF.sh\" bash funct/iperf3_test.sh <dut_index>"
    exit 2
  fi

  iperf3_test_run_for_dut "$1"
fi
