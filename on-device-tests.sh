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

function __test_done() {
	# Очищення службового файлу (якщо існує) та маркер "завершено"
	rm -f /ssd1/factory-test-file.bin
	mkdir -p "$LOG_DIR"
	echo "DONE" > "$STATUS_FILE"
	touch /tmp/refurbish_test_done
	exit
}

function __bail() {
	# Аварійний вихід: зафіксувати повідомлення про помилку, поставити маркер FAIL
	# і перейти до загального завершення (__test_done)
	__log "$@"
	mkdir -p "$LOG_DIR"
	echo "FAILED: $*" > "$STATUS_FILE"
	touch /tmp/refurbish_test_failed
	__test_done
}

export __log
export __bail

function __dut_system_test_memory() {
	# Тест RAM через роботу з великим файлом у tmpfs (/tmp):
	# 5 проходів; у кожному — файл 768MiB заповнюється нулями та одиницями,
	# далі звіряється md5. Якщо вміст спотворився — считаємо, що проблема з RAM/IO.
    	__log "Running memory tests..."
    	for i in `seq 1 5`; do
        	__log "Memory test pass $i / 5"

		# --- Патерн 0x00 ---
		# Створюємо файл з нулів у /tmp (має бути tmpfs, тобто RAM)
		dd if=/dev/zero of=/tmp/memtest.bin bs=1M count=768
		MEM_TEST_MD5_RESULT=$(md5sum /tmp/memtest.bin | awk '{print $1;}')
		rm /tmp/memtest.bin

		if [ "$MEM_TEST_MD5_RESULT" != "72b74a1ecec4fd35ec0c7278202130a8" ]; then
			__bail "Memory test 0 FAIL $MEM_TEST_MD5_RESULT"
		fi

        	# Очікувана md5 для 768MiB з нулів; якщо не збіглась — фіксуємо FAIL
        	cat /dev/zero | tr '\0x0' '\377' | dd of=/tmp/memtest.bin bs=1M count=768 iflag=fullblock
        	MEM_TEST_MD5_RESULT=$(md5sum /tmp/memtest.bin | awk '{print $1;}')
        	rm /tmp/memtest.bin
        	
        	# --- Патерн 0xFF ---
		# Перетворюємо нулі на 0xFF потоком tr і пишемо той самий обсяг
		# iflag=fullblock гарантує читання повних блоків
        	if [ "$MEM_TEST_MD5_RESULT" != "e39e7b63a593381a6f1b4b2eebdda109" ]; then
            		__bail "Memory test 255 FAIL $MEM_TEST_MD5_RESULT"
        	fi
    	done

    	__log "Memory tests PASS"
}

# Перевірка к-сті CPU: очікуємо рівно 4 процесори
function __dut_system_test_cpu_count() {
	CPU_COUNT=`cat /proc/cpuinfo | grep processor | wc -l`

	if [ "$CPU_COUNT" -ne "4" ]; then
 		__bail "Found $CPU_COUNT CPUs instead of 4 CPUs, FAIL"
	else
		__log "4 CPUs found, PASS"
	fi
}

# Перевірка обсягу RAM: очікуємо >= ~3.9 ГБ (3900000 kB у MemTotal)
function __dut_system_test_mem_count() {
	MEM_COUNT=`cat /proc/meminfo | grep MemTotal | awk '{print $2;}'`
    	MEM_COUNT_EXPECTED="3900000"

    	if [ "$MEM_COUNT" -lt "$MEM_COUNT_EXPECTED" ]; then
        	__bail "Found $MEM_COUNT kB memory instead of  > $MEM_COUNT_EXPECTED kB memory, FAIL"
    	else
        	__log "Found $MEM_COUNT kB memory, PASS"
    	fi
}

# SATA: наявність лінку, монтування та грубий тест швидкості запису
function __dut_system_test_sata_hdd() {
	# Перевіряємо швидкість лінку (узгодження) через sysfs
	SATA_SPEED="$(cat "$SATA_LINK_PATH" 2>/dev/null || echo "unknown")"
	ok=0
	for spd in "${ALLOWED_SATA_SPEEDS[@]}"; do
		[ "$SATA_SPEED" = "$spd" ] && ok=1 && break
	done
		[ "$ok" -eq 1 ] && __log "SATA HDD linked @ $SATA_SPEED, PASS" || __bail "SATA HDD link error $SATA_SPEED, FAIL"

    	# Точка монтування повинна бути /volume1
	SATA_MNT=$(df -h "$SATA_MNT_POINT" | tail -n1 | awk '{print $6;}')
	if [ "$SATA_MNT" != "$SATA_MNT_POINT" ]; then
        	__bail "HDD not mounted at $SATA_MNT_POINT, FAIL"
    	else
        	_log "HDD mounted at $SATA_MNT_POINT, PASS"
    	fi

    	#Швидкість: запис 1GiB з conv=sync має вміститись у 15с
    	timeout "$HDD_WRITE_TIMEOUT" dd if=/dev/zero of="$SATA_MNT_POINT/speed-test.bin" \
       		bs=1M count="$HDD_WRITE_MB" conv=sync 2>/dev/null >/dev/null \
  	&& __log "write test file to HDD, PASS" \
  	|| __bail "writing test file to HDD too slow, FAIL"
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
    	Перевіряємо очікувану кількість секторів (два допустимі значення для різних вендорів)
    	EMMC_SECTORS=`cat /sys/devices/platform/soc/fd820000.pcie-external1/pci0002:00/0002:00:00.0/0002:01:00.0/usb2/2-1/2-1:1.0/host4/target4:0:0/4:0:0:0/block/boot/size`

    	# TODO діапазон +/- близько 16 ГБ секторів для розміщення різних чіпів 
    	# 30777344 == Toshiba/Kioxia
    	# 30535680 == Samsung
    	if [ "$EMMC_SECTORS" -ne "30777344" ] && [ "$EMMC_SECTORS" -ne "30535680" ]; then
        	__bail "eMMC size check FAIL, expected 30777344 or 30535680 got $EMMC_SECTORS"
    	else
        	__log "eMMC size check PASS"
    	fi

    	# Датчики температури: усі в межах 20..80°C (значення у міліградусах Цельсія)
    	if ! touch /data/test.bin; then
        	__bail "/data not writeable, FAIL"
    	else
        	__log "/data writeable, PASS"
    	fi
    	rm /data/test.bin
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

    	Перевірка на "нульові" тахометричні значення (означає: не читається/не крутиться)
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


# --------------- Головний блок виконання ---------------

# Приберемо старі маркери попередніх прогонів (якщо були)
rm /tmp/refurbish_test_*

# ці тести фактично миттєві
__dut_system_test_bluetooth
__dut_system_test_emmc
__dut_system_test_sensors
__dut_8370_test
__dut_8370_cpu_port_test
__dut_system_test_cpu_count
__dut_system_test_mem_count

# Довгі перевірки — паралельно, щоб зекономити час
__dut_system_test_fans &
__dut_system_test_sata_hdd &
__dut_system_test_memory &

# Чекаємо завершення усіх паралельних задач
wait

# Успіх: ставимо відповідний маркер і йдемо на коректне завершення
mkdir -p "$LOG_DIR"
echo "PASSED" > "$STATUS_FILE"
touch "/tmp/refurbish_test_passed"
__test_done
