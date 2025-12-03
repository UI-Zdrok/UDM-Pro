#!/bin/bash


# Зміни у майбутньому Підтягнути пороги з CONF.sh у тести
#Щоб усе керувалось централізовано:
#у __dut_system_test_cpu_count: замінити 4 → $EXPECTED_CPUS;
#у __dut_system_test_mem_count: замінити локальну MEM_COUNT_EXPECTED → $MEM_MIN_KB;
#у __dut_system_test_memory: count=768 → count="$MEMTEST_MIB", md5-суми → $MD5_ZERO і $MD5_FF.

# підхоплення конфіга з on-device-tests.sh
CONF_PATH="${CONF_FILE:-/tmp/CONF.sh}"
if [ -f "$CONF_PATH" ]; then
  # shellcheck disable=SC1090
  . "$CONF_PATH"
else
  echo "Config not found: $CONF_PATH" >&2
  exit 1
fi


#централізовано керувати порогами/шляхами/логами
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${CONF_FILE:-$SCRIPT_DIR/CONF.sh}"
if [ -r "$CONF_FILE" ]; then . "$CONF_FILE"; else echo "WARNING: CONF.sh not found, using built-ins"; fi


#FAIL, якщо чогось критично не вистачає у прошивці.
for bin in dd md5sum grep awk hciconfig swconfig ifconfig timeout; do
  command -v "$bin" >/dev/null || { echo "Missing $bin"; exit 1; }
done


function __log() {
	# Проста функція логування: додає рядок у файл логу в /tmp
	# За потреби можливо змінити шлях/імʼя логу.
	mkdir -p "$LOG_DIR"
	echo "$(date +'%F %T') $@" | tee -a "$LOG_FILE" >> /tmp/refurbish_test_log
}
########################################################################


########################################################################
# управління статусом та паралелізм

function __test_done() {
    # Очищення службового файлу
    rm -f /ssd1/factory-test-file.bin
    mkdir -p "$LOG_DIR"
    # НЕ перезаписуємо STATUS_FILE, якщо вже встановлено FAILED/PASSED
    if [ ! -s "$STATUS_FILE" ]; then
        echo "DONE" > "$STATUS_FILE"
    fi
    touch /tmp/refurbish_test_done
    exit
}

#----------------------------------------------------------------------------

function __bail() {
    __log "$@"
    mkdir -p "$LOG_DIR"
    echo "FAILED: $*" > "$STATUS_FILE"
    touch /tmp/refurbish_test_failed
    exit 1
}

export __log
export __bail
########################################################################


######################################################################## РЕАЛІЗУВАТИ
# Перевірка вільного місця на основних розділах
__dut_system_test_storage_usage() {
    # ми хочемо подивитися root, /data, /mnt/data, /srv, тощо
    local min_root_pct=15   # мінімум 15% вільно
    local min_data_pct=15

    __log "Checking filesystem usage..."

    df -h | __log

    # приклад перевірки кореня
    local used_pct
    used_pct="$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
    if [ -n "$used_pct" ] && [ "$used_pct" -gt $((100 - min_root_pct)) ]; then
        __bail "Root FS usage too high: ${used_pct}% used"
        return 1
    fi

    # аналогічно можна перевірити /data або /srv
    __log "Filesystem usage OK"
    return 0
}
########################################################################


########################################################################
#MD5
# Стрес-тест пам'яті:
#   - розмір блоку беремо з MEMTEST_MIB (МіБ)
#   - к-сть проходів з MEMTEST_PASSES
#   - еталонні MD5:
#       * спочатку пробуємо взяти з CONF.sh (MD5_ZERO, MD5_FF)
#       * якщо там їх немає — рахуємо динамічно
function __dut_system_test_memory() {
	# 1) Розмір тесту (MiB) та к-сть проходів
    local mib="${MEMTEST_MIB:-256}"
    local passes="${MEMTEST_PASSES:-1}"
    [ "$passes" -ge 1 ] || passes=1

    __log "Running memory tests... size=${mib}MiB, passes=${passes}"

    # 2) Еталонні MD5: спочатку беремо з CONF.sh
    local ref_zero ref_ff
    ref_zero="${MD5_ZERO:-}"
    ref_ff="${MD5_FF:-}"

    # 3) Якщо в CONF.sh не задані — рахуємо їх на льоту
    if [ -z "$ref_zero" ] || [ -z "$ref_ff" ]; then
        __log "MD5_ZERO/MD5_FF not set in CONF.sh — computing dynamically for ${mib}MiB"

        # ZERO (0x00)
        ref_zero="$(head -c "${mib}M" /dev/zero | md5sum | awk '{print $1}')" \
            || { __bail "Cannot compute MD5 ZERO"; return 1; }

        # FF (0xFF)
        ref_ff="$(head -c "${mib}M" /dev/zero | tr '\0' '\377' | md5sum | awk '{print $1}')" \
            || { __bail "Cannot compute MD5 FF"; return 1; }
    else
        __log "Using MD5_ZERO/MD5_FF from CONF.sh for ${mib}MiB"
    fi


    # 4) Основний цикл тесту
    local i
    for i in $(seq 1 "$passes"); do
        __log "Memory test pass $i / $passes"

        # --- 0x00 ---
        if ! dd if=/dev/zero of=/tmp/memtest.bin bs=1M count="$mib" \
              oflag=sync iflag=fullblock status=none; then
            __bail "dd ZERO failed (maybe not enough /tmp space)"
            return 1
        fi

        local m
        m="$(md5sum /tmp/memtest.bin | awk '{print $1}')"
        rm -f /tmp/memtest.bin

        if [ "$m" != "$ref_zero" ]; then
            __bail "Memory test ZERO md5 mismatch ($m != $ref_zero)"
            return 1
        fi

        # --- 0xFF ---
        if ! head -c "${mib}M" /dev/zero | tr '\0' '\377' \
             | dd of=/tmp/memtest.bin bs=1M oflag=sync iflag=fullblock status=none; then
            __bail "dd FF failed (maybe not enough /tmp space)"
            return 1
        fi

        m="$(md5sum /tmp/memtest.bin | awk '{print $1}')"
        rm -f /tmp/memtest.bin

        if [ "$m" != "$ref_ff" ]; then
            __bail "Memory test FF md5 mismatch ($m != $ref_ff)"
            return 1
        fi
    done

    __log "Memory test PASS"
    return 0
}
########################################################################


########################################################################
# Перевірка к-сті CPU: очікуємо рівно 4 процесори
function __dut_system_test_cpu_count() {
    # Скільки CPU ми очікуємо (з конфіга або 4 за замовчуванням)
    local expected="${EXPECTED_CPUS:-4}"
    
    # Фактична кількість процесорів на DUT
    local CPU_COUNT
    CPU_COUNT="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)"

    if [ "$CPU_COUNT" -ne "$expected" ]; then
        # Якщо щось не співпало — лог і FAIL
        __bail "Found $CPU_COUNT CPUs instead of ${expected} CPUs, FAIL"
    else
        # Все як очікується
        __log "Found $CPU_COUNT CPUs (expected ${expected}), PASS"
    fi
}
########################################################################


# Перевірка обсягу RAM: очікуємо >= ~3.9 ГБ (3900000 kB у MemTotal)
# Перевірка обсягу оперативної пам'яті (без стрес-тестів)
function __dut_system_test_mem_count() {
    local min="${MEM_MIN_KB:-0}"
    local mt
    mt="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"

    # захист від порожніх значень
    case "$mt" in (*[!0-9]*) mt=0;; esac
    case "$min" in (*[!0-9]*) min=0;; esac

    echo "RAM: MemTotal=${mt} kB (expected ≥ ${min} kB, nominal ${MEM_EXPECTED_KB:-n/a} kB)"

    if [ "$mt" -lt "$min" ]; then
        echo "FAIL: RAM too low (${mt} < ${min})"
        return 1
    fi

    echo "PASS: RAM ok"
    return 0
}


# SATA: наявність лінку, монтування та грубий тест швидкості запису
function __dut_system_test_sata_hdd() {
    # 0) Якщо немає шляху лінку — SKIP
    if [ ! -e "$SATA_LINK_PATH" ]; then
        __log "SKIP: SATA link path not found ($SATA_LINK_PATH)"
        return 0
    fi

    # 1) Лінк швидкість
    local SATA_SPEED; SATA_SPEED="$(cat "$SATA_LINK_PATH" 2>/dev/null || echo "unknown")"
    local ok=0
    for spd in "${ALLOWED_SATA_SPEEDS[@]:-1.5 Gbps 3.0 Gbps 6.0 Gbps}"; do
        [ "$SATA_SPEED" = "$spd" ] && ok=1 && break
    done
    if [ "$ok" -eq 1 ]; then
        __log "SATA HDD linked @ $SATA_SPEED, PASS"
    else
        __log "SKIP: SATA link speed unknown/not matched ($SATA_SPEED)"
        return 0
    fi

    # 2) Монтування
    if ! mountpoint -q "$SATA_MNT_POINT"; then
        __log "SKIP: mountpoint $SATA_MNT_POINT not present"
        return 0
    fi
    __log "HDD mounted at $SATA_MNT_POINT, PASS"

    # 3) Швидкість запису (грубо)
    if timeout "$HDD_WRITE_TIMEOUT" dd if=/dev/zero of="$SATA_MNT_POINT/speed-test.bin" bs=1M count="$HDD_WRITE_MB" oflag=sync status=none; then
        __log "HDD write test PASS"
        rm -f "$SATA_MNT_POINT/speed-test.bin"
        return 0
    else
        __bail "HDD write too slow or failed (>${HDD_WRITE_TIMEOUT}s)"
        rm -f "$SATA_MNT_POINT/speed-test.bin"
        return 1
    fi
}


# Перевірка портів switch 8370 (фізичні порти 0..7 і 9)
function __dut_8370_test() {
	# Примітка: цикл йде в порядку "9, 0..7" — так було у вихідному коді.
    	for i in 9 `seq 0 7`; do
        	# Лінк up?
        	[ `swconfig dev switch0 port "$i" show | grep "link:up" | wc -l` -eq "1" ] && __log "Port $i link UP" || __bail "Port $i link down, FAIL"
        	# Швидкість 1000?
        	[ `swconfig dev switch0 port "$i" show | grep "1000baseT" | wc -l` -eq "1" ] && __log "Port $i link speed 1000" || __bail "Port $i link speed != 1000, FAIL"
        	# Повний дуплекс?
        	[ `swconfig dev switch0 port "$i" show | grep "full-duplex" | wc -l` -eq "1" ] && __log "Port $i link full-duplex" || __bail "Port $i link != full-duplex, FAIL"
        	# RX лічильник > 0?
        	[ `swconfig dev switch0 port "$i" show | grep "rx_byte" | awk '{print $2;}'` -gt "0" ] && __log "Port $i rx_byte >0" || __bail "Port $i rx_byte == 0, FAIL"
        	# TX лічильник > 0?
        	[ `swconfig dev switch0 port "$i" show | grep "tx_byte" | awk '{print $2;}'` -gt "0" ] && __log "Port $i tx_byte >0" || __bail "Port $i tx_byte == 0, FAIL"
    	done


#	local IFACE="${PORT_TEST_IFACE:-eth8}"
#	local REQ="${REQUIRED_PORT_SPEED_MBPS:-1000}"

#	[ -d "/sys/class/net/$IFACE" ] || { echo "Port test: interface $IFACE not found, FAIL"; return 1; }
#	[ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null || echo 0)" = "1" ] || { echo "Port test: $IFACE carrier DOWN, FAIL"; return 1; }

#	local speed="$(cat /sys/class/net/$IFACE/speed 2>/dev/null || true)"
#	[ -z "$speed" -o "$speed" = "-1" ] && speed="$(ethtool "$IFACE" 2>/dev/null | awk -F'[: ]+' '/Speed:/{gsub(/[^0-9]/,"",$2); print $2}')"
#	[ -z "$speed" ] && { echo "Port test: $IFACE up (speed unknown), PASS (soft)"; return 0; }
#	echo "$speed" | grep -Eq '^[0-9]+$' || { echo "Port test: $IFACE speed '$speed' not numeric, FAIL"; return 1; }
#	[ "$speed" -lt "$REQ" ] && { echo "Port test: $IFACE speed $speed < $REQ, FAIL"; return 1; }

#	echo "Port test: $IFACE up $speed Mb/s, PASS"
#	return 0

}

# Перевірка CPU‑порту з боку інтерфейсу switch0: мають рухатись пакети
function __dut_8370_cpu_port_test() {
	[ `ifconfig switch0 | grep "RX packets" | awk '{print $3;}'` -gt "0" ] && __log "CPU port, CPU-side RX packets >0" || __bail "CPU port, CPU-side RX packets == 0, FAIL"
	[ `ifconfig switch0 | grep "TX packets" | awk '{print $3;}'` -gt "0" ] && __log "CPU port, CPU-side TX packets >0" || __bail "CPU port, CPU-side TX packets == 0, FAIL"
}

# Перевірка наявності Bluetooth (інтерфейс має бути UP RUNNING)
function __dut_system_test_bluetooth() {
	BLUETOOTH_UP_RUNNING=`hciconfig | grep "UP RUNNING" | wc -l`

    	if [ "$BLUETOOTH_UP_RUNNING" -ne "1" ]; then
        	__bail "Bluetooth not found, FAIL"
    	else
        	__log "Bluetooth found, PASS"
    	fi
}


# eMMC: перевірка розміру та можливості запису у /data
function __dut_system_test_emmc() {
    # 0) Чи є eMMC?
    if [ ! -e /dev/mmcblk0 ] && [ ! -e "$EMMC_SIZE_PATH" ]; then
        __log "SKIP: eMMC not present (/dev/mmcblk0 and $EMMC_SIZE_PATH missing)"
        return 0
    fi

    # 1) Розмір у секторах
    local EMMC_SECTORS
    EMMC_SECTORS="$(cat "$EMMC_SIZE_PATH" 2>/dev/null || echo "")"
    if [ -z "$EMMC_SECTORS" ]; then
        __log "SKIP: cannot read eMMC size at $EMMC_SIZE_PATH"
    else
        case "$EMMC_SECTORS" in (*[!0-9]*) EMMC_SECTORS=0;; esac
        # Допускаємо кілька вендорних значень або близький діапазон
        if [ "$EMMC_SECTORS" -eq 30777344 ] || [ "$EMMC_SECTORS" -eq 30535680 ]; then
            __log "eMMC size check PASS ($EMMC_SECTORS sectors)"
        else
            __log "WARN: eMMC size unexpected ($EMMC_SECTORS) — accept for now"
        fi
    fi

    # 2) Перевірка запису на /data (якщо є)
    if [ -d "$DATA_PART" ] && [ -w "$DATA_PART" ]; then
        if touch "$DATA_PART/test.bin" 2>/dev/null; then
            __log "/data writeable, PASS"
            rm -f "$DATA_PART/test.bin"
            return 0
        else
            __bail "$DATA_PART not writeable, FAIL"
            return 1
        fi
    else
        __log "SKIP: $DATA_PART not present or not writeable"
        return 0
    fi
}


# Датчики температури: усі в межах 20..80°C (значення у міліградусах Цельсія)
function __dut_system_test_sensors() {
    CPU_DIE_TEMP=`cat /sys/class/thermal/thermal_zone0/temp`
    MB_CPU_TEMP=`cat /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/temp1_input`
    MB_RSW_TEMP=`cat /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/temp2_input`
    MB_ADT7475_TEMP=`cat /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/temp3_input`

    if [ "$CPU_DIE_TEMP" -gt "80000" ] || [ "$CPU_DIE_TEMP" -lt "20000" ]; then
        __bail "CPU die temperature out of range!  $CPU_DIE_TEMP, FAIL"
    else
        __log "CPU die temperature $CPU_DIE_TEMP within range, PASS"
    fi

    if [ "$MB_CPU_TEMP" -gt "80000" ] || [ "$MB_CPU_TEMP" -lt "20000" ]; then
        __bail "CPU (motherboard) temperature out of range!  $MB_CPU_TEMP, FAIL"
    else
        __log "CPU (motherboard) temperature $MB_CPU_TEMP within range, PASS"
    fi

    if [ "$MB_RSW_TEMP" -gt "80000" ] || [ "$MB_RSW_TEMP" -lt "20000" ]; then
        __bail "Gigabit switch temperature out of range!  $MB_RSW_TEMP, FAIL"
    else
        __log "Gigabit switch temperature $MB_RSW_TEMP within range, PASS"
    fi

    if [ "$MB_ADT7475_TEMP" -gt "80000" ] || [ "$MB_ADT7475_TEMP" -lt "20000" ]; then
        __bail "ADT7475 temperature out of range!  $MB_ADT7475_TEMP, FAIL"
    else
        __log "ADT7475 temperature $MB_ADT7475_TEMP within range, PASS"
    fi
}

# Тести вентиляторів (PWM + тахометр):
# • перевірити, що PWM канали працюють
# • вентилятори підключені, датчики дають ненульові значення
# • RPM у розумних межах на різних PWM рівнях
function __dut_system_test_fans() {
	__log "Running fan tests..."
    	
    	# HDD fan — pwm1/fan1_input
    	echo 127 > /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/pwm1
    	sleep 10
    	HDD_FAN_MID=`cat /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/fan1_input`

    	echo 255 > /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/pwm1
    	sleep 10
    	HDD_FAN_MAX=`cat /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/fan1_input`

    	echo 0 > /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/pwm1
    	sleep 10
    	HDD_FAN_IDLE=`cat /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/fan1_input`

    	# CPU fan — pwm2/fan2_input
    	echo 127 > /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/pwm2
    	sleep 10
    	CPU_FAN_MID=`cat /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/fan2_input`

    	echo 255 > /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/pwm2
    	sleep 10
    	CPU_FAN_MAX=`cat /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/fan2_input`

    	echo 0 > /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/pwm2
    	sleep 10
    	CPU_FAN_IDLE=`cat /sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e/fan2_input`

    	#Перевірка на "нульові" тахометричні значення (означає: не читається/не крутиться)
    	if [ "$CPU_FAN_IDLE" -eq "0" ] ||
       		[ "$CPU_FAN_MID" -eq "0" ] ||
       		[ "$CPU_FAN_MAX" -eq "0" ] ||
       		[ "$HDD_FAN_MID" -eq "0" ] ||
       		[ "$HDD_FAN_MAX" -eq "0" ]; then
        	__log "CPU $CPU_FAN_IDLE $CPU_FAN_MID $CPU_FAN_MAX"
        	__log "HDD $HDD_FAN_IDLE $HDD_FAN_MID $HDD_FAN_MAX"
        	__bail "Read zero value from fan tachometer channel, FAIL"
    	fi
   
	# Межі RPM для CPU вентилятора (мінімум на idle/mid/max)
    	if [ "$CPU_FAN_IDLE" -lt "250" ] || [ "$CPU_FAN_MID" -lt "2500" ] || [ "$CPU_FAN_MAX" -lt "6500" ]; then
        	__log "CPU $CPU_FAN_IDLE $CPU_FAN_MID $CPU_FAN_MAX"
        	__log "HDD $HDD_FAN_IDLE $HDD_FAN_MID $HDD_FAN_MAX"
        	__bail "CPU fan is running slow, FAIL"
    	fi
    	
	# Межі RPM для HDD вентилятора (мінімум на mid/max)
    	if [ "$HDD_FAN_MID" -lt "3000" ] || [ "$HDD_FAN_MAX" -lt "8000" ]; then
        	__log "CPU $CPU_FAN_IDLE $CPU_FAN_MID $CPU_FAN_MAX"
        	__log "HDD $HDD_FAN_IDLE $HDD_FAN_MID $HDD_FAN_MAX"
        	__bail "HDD fan is running slow, FAIL"
    	fi

	# Граничні значення зверху для CPU вентилятора (аномально високі RPM)
	if [ "$CPU_FAN_IDLE" -gt "2000" ] || [ "$CPU_FAN_MID" -gt "4000" ] || [ "$CPU_FAN_MAX" -gt "8000" ]; then
        	__log "CPU $CPU_FAN_IDLE $CPU_FAN_MID $CPU_FAN_MAX"
        	__log "HDD $HDD_FAN_IDLE $HDD_FAN_MID $HDD_FAN_MAX"
        	__bail "CPU fan RPM too fast, FAIL"
    	fi
	
	# Граничні значення зверху для HDD вентилятора
    	if [ "$HDD_FAN_IDLE" -gt "2200" ] || [ "$HDD_FAN_MID" -gt "5500" ] || [ "$HDD_FAN_MAX" -gt "10500" ]; then
        	__log "CPU $CPU_FAN_IDLE $CPU_FAN_MID $CPU_FAN_MAX"
        	__log "HDD $HDD_FAN_IDLE $HDD_FAN_MID $HDD_FAN_MAX"
        	__bail "HDD fan RPM too fast, FAIL"
    	fi

   	__log "Fan tests PASS"
}


########################################################################
# Підключаємо додатковий модуль (якщо існує)
[ -f "/tmp/check_storage_usage.sh" ] && source /tmp/check_storage_usage.sh
########################################################################


########################################################################
# --------------- Головний блок виконання ---------------
if [ "${RUN_ONDEVICE_MAIN:-1}" -eq 1 ]; then
# Приберемо старі маркери попередніх прогонів (якщо були)


# ці тести фактично миттєві
__dut_system_test_bluetooth
__dut_system_test_emmc
__dut_system_test_sensors
__dut_8370_test
__dut_8370_cpu_port_test
__dut_system_test_cpu_count
__dut_system_test_mem_count

#----------------------------------------------------------------------------
# Довгі перевірки — паралельно
pids=()
__dut_system_test_fans &       pids+=($!)
__dut_system_test_sata_hdd &   pids+=($!)
__dut_system_test_memory &     pids+=($!)

fail=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        fail=1
    fi
done

mkdir -p "$LOG_DIR"
if [ -f /tmp/refurbish_test_failed ] || [ "$fail" -ne 0 ]; then
    echo "FAILED" > "$STATUS_FILE"
    # без __test_done, щоб не перетерти статус
    touch /tmp/refurbish_test_done
    exit 1
fi

echo "PASSED" > "$STATUS_FILE"
touch "/tmp/refurbish_test_passed"
touch /tmp/refurbish_test_done
exit 0

#----------------------------------------------------------------------------

# Чекаємо завершення усіх паралельних задач
wait

# Успіх: ставимо відповідний маркер і йдемо на коректне завершення
mkdir -p "$LOG_DIR"
echo "PASSED" > "$STATUS_FILE"
touch "/tmp/refurbish_test_passed"
__test_done

fi


