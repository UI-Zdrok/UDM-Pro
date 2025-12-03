#!/bin/bash
# ============================================================
# check_storage_usage.sh
# ------------------------------------------------------------
# Перевіряє файлову систему DUT на наявність вільного місця.
# Викликається з test_1.sh через run_ondevice_func "__dut_system_test_storage_usage".
# Логіка:
#   - беремо тільки "нормальні" точки монтування: /, /data, /mnt/data, /srv
#   - ігноруємо tmpfs, системні readonly-розділи тощо
#   - якщо вільного місця < 15% → FAIL
# ============================================================

# На випадок, якщо скрипт колись запустять без on-device-tests.sh:
# якщо __log / __bail ще не визначені – робимо прості заглушки.
if ! command -v __log >/dev/null 2>&1; then
    __log() { echo "$@"; }
fi

if ! command -v __bail >/dev/null 2>&1; then
    __bail() { __log "$@"; return 1; }
fi

# Функція для запуску безпосередньо на DUT
__dut_system_test_storage_usage() {
    # Мінімально допустимий відсоток ВІЛЬНОГО місця
    # Можна винести у CONF.sh як MIN_ROOT_FREE_PCT / MIN_DATA_FREE_PCT при бажанні.
    local min_root_free_pct=15   # мінімум 15% вільно на /
    local min_data_free_pct=15   # мінімум 15% вільно на /data, /mnt/data, /srv

    __log "=== Checking filesystem usage (/, /data, /mnt/data, /srv) ==="

    # Список точок монтування, які нас цікавлять
    # (якщо якихось з них немає на конкретному DUT – просто пропустимо)
    local mounts=(
        "/"
        "/data"
        "/mnt/data"
        "/srv"
    )

    local m
    for m in "${mounts[@]}"; do
        # Якщо такої папки немає – пропускаємо
        [ -d "$m" ] || continue

        # Беремо другий рядок з df -P <mount>
        # Поле 5 – used%, наприклад "43%"
        local line used_pct free_pct min_pct
        line="$(df -P "$m" 2>/dev/null | awk 'NR==2{print}')"
        [ -n "$line" ] || continue

        used_pct="$(printf '%s\n' "$line" | awk '{gsub("%","",$5); print $5}')"
        # Якщо з якихось причин не змогли отримати число – пропускаємо цей розділ
        case "$used_pct" in (*[!0-9]*|'') continue;; esac

        free_pct=$((100 - used_pct))

        # Для кореня використовуємо один поріг, для інших – інший (поки однаковий)
        if [ "$m" = "/" ]; then
            min_pct="$min_root_free_pct"
        else
            min_pct="$min_data_free_pct"
        fi

        __log "FS $m: used=${used_pct}% free=${free_pct}% (min free ${min_pct}%)"

        if [ "$free_pct" -lt "$min_pct" ]; then
            __bail "FS $m has only ${free_pct}% free (< ${min_pct}%), FAIL"
            return 1
        fi
    done

    __log "Storage usage OK on all checked filesystems"
    return 0
}
