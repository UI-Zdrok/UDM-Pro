#!/usr/bin/env bash
# Готує VLAN-підінтерфейси на хості для всіх DUTів за формулою:
# ifname = BASE_IFACE . (IPERF_VLAN_BASE + dut - 1)
# Сценарій безпечний: якщо інтерфейс існує — пропускає.

set -euo pipefail

# Логер у консоль
_log() { printf '%s\n' "$*"; }

# Обережно підтягнути конфіг, якщо його передали через CONF_FILE
if [[ -n "${CONF_FILE:-}" && -r "$CONF_FILE" ]]; then
  set +u
  # shellcheck disable=SC1090
  . "$CONF_FILE"
  set -u 2>/dev/null || true
fi

# Перевірки мінімальних змінних
BASE_IFACE="${BASE_IFACE:-${BASE:-}}"
IPERF_VLAN_BASE="${IPERF_VLAN_BASE:-1000}"
DUT_COUNT="${DUT_COUNT:-3}"

if [[ -z "$BASE_IFACE" ]]; then
  echo "ERROR: BASE_IFACE не задано. Додайте у CONF.sh: BASE_IFACE=\"<інтерфейс>\"" >&2
  exit 1
fi


# Обчислює коректне ім'я VLAN-інтерфейсу з урахуванням ліміту 15 символів
_vifname() {
  local base="$1" vid="$2"
  local candidate="${base}.${vid}"
  if (( ${#candidate} <= 15 )); then
    printf '%s' "$candidate"
  else
    printf 'v%d' "$vid"    # коротке ім'я, наприклад v1000
  fi
}

# Знаходить існуюче ім'я VLAN-інтерфейсу за base+vid (якщо вже створений під іншим ім'ям)
_find_vlan_iface_by_vid() {
  local base="$1" vid="$2"
  ip -d link show type vlan | awk -v b="$base" -v v="$vid" '
    /^[0-9]+: / { name=$2; sub(":", "", name); split(name, a, "@"); ifname=a[1]; parent=a[2] }
    /vlan protocol 802\.1Q id/ { if ($0 ~ ("id " v)) { if (parent==b) { print ifname; exit 0 } } }
  '
}




# Модуль VLAN (на випадок, якщо не підвантажений)
sudo modprobe 8021q 2>/dev/null || true

for ((d=1; d<=DUT_COUNT; d++)); do
  vid=$(( IPERF_VLAN_BASE + d - 1 ))
  ifname="$(_vifname "$BASE_IFACE" "$vid")"

  if ! ip link show "$ifname" >/dev/null 2>&1; then
    pretty="${BASE_IFACE}.${vid}"
    _log "[DUT $d] Створюю $ifname (vid=$vid; базове ім'я було б $pretty, але могло не влізти в 15 симв.)"
    if ! sudo ip link add link "$BASE_IFACE" name "$ifname" type vlan id "$vid" 2>/dev/null; then
      # Можливо, VLAN уже існує під іншим ім'ям (наприклад, $pretty)
      alt="$(_find_vlan_iface_by_vid "$BASE_IFACE" "$vid")"
      if [[ -n "$alt" ]]; then
        _log "[DUT $d] VLAN $vid уже існує як '$alt' — використовую його"
        ifname="$alt"
      else
        echo "ERROR: [DUT $d] Не вдалося створити $ifname і не знайдено існуючого інтерфейсу для VID $vid" >&2
        exit 1
      fi
    fi
  else
    _log "[DUT $d] $ifname вже існує — пропускаю створення"
  fi

  sudo ip link set "$ifname" up
done




_log "VLAN інтерфейси готові."
