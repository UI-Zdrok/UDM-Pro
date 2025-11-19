#!/usr/bin/env bash
# Переприв'язує профілі NetworkManager "DUT i LAN" до фактичних VLAN-інтерфейсів.
# Ми тепер можемо мати короткі імена v1000/v1001/... замість BASE.VLAN.
set -euo pipefail

log(){ printf '%s\n' "$*"; }
err(){ printf 'ERROR: %s\n' "$*" >&2; }

# 1) Підтягнемо CONF.sh (якщо передали)
if [[ -n "${CONF_FILE:-}" && -r "$CONF_FILE" ]]; then
  set +u
  # shellcheck disable=SC1090
  . "$CONF_FILE"
  set -u 2>/dev/null || true
fi

: "${BASE_IFACE:?BASE_IFACE не задано у CONF.sh}"
VLAN_BASE="${IPERF_VLAN_BASE:-1000}"
DUT_COUNT="${DUT_COUNT:-3}"

need(){ command -v "$1" >/dev/null 2>&1 || { err "Команда не знайдена: $1"; exit 127; }; }
need nmcli
need ip

# Пошук існуючого VLAN-інтерфейсу за base+vid
find_vlan_iface(){
  local base="$1" vid="$2"
  # 1) коротке ім'я v<vid>
  if ip link show "v${vid}" >/dev/null 2>&1; then
    printf 'v%s' "$vid"; return 0
  fi
  # 2) класичне <base>.<vid>
  if ip link show "${base}.${vid}" >/dev/null 2>&1; then
    printf '%s.%s' "$base" "$vid"; return 0
  fi
  # 3) будь-яке VLAN-ім'я з таким parent+vid
  ip -d link show type vlan | awk -v b="$base" -v v="$vid" '
    /^[0-9]+: / { n=$2; sub(":", "", n); split(n,a,"@"); ifname=a[1]; parent=a[2] }
    /vlan protocol 802\.1Q id/ { if ($0 ~ ("id " v)) { if (parent==b) { print ifname; exit 0 } } }
  '
}

for ((i=1;i<=DUT_COUNT;i++)); do
  vid=$(( VLAN_BASE + i - 1 ))
  ifname="$(find_vlan_iface "$BASE_IFACE" "$vid" || true)"
  if [[ -z "$ifname" ]]; then
    err "[DUT $i] Не знайдено інтерфейс для VID $vid на $BASE_IFACE. Запустіть prepare_vlan_ifaces.sh."
    continue
  fi

  cname="DUT ${i} LAN"
  if ! nmcli -t -f NAME con show | grep -Fxq "$cname"; then
    err "[DUT $i] Профіль \"$cname\" у NM не знайдено — пропускаю."
    continue
  fi

  log "[DUT $i] Прив'язую \"$cname\" до ifname=$ifname (VID $vid)"
  # Спроба оновити ключові поля (ігнор помилок, бо тип профілю може відрізнятися)
  nmcli con mod "$cname" connection.interface-name "$ifname" 2>/dev/null || true
  nmcli con mod "$cname" vlan.id "$vid" vlan.parent "$BASE_IFACE" 2>/dev/null || true

  # Активуємо профіль на потрібному інтерфейсі
  nmcli -w 5 con up "$cname" ifname "$ifname" || {
    err "[DUT $i] Не вдалося підняти \"$cname\" на $ifname"; exit 1; }
done

log "NetworkManager: прив'язки VLAN оновлено."

