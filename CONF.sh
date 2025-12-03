########################################
# CONF.sh — централізовані налаштування
########################################


################################################################################
# Якщо SCRIPT_DIR не задано зовнішнім скриптом — визначимо автоматично.
# BASH_SOURCE[0] всередині "source" вказує саме на цей файл CONF.sh
if [[ -z "${SCRIPT_DIR:-}" ]]; then
  # Папка, де лежить CONF.sh (у вашій структурі це корінь проєкту)
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
################################################################################


################################################################################
# 0)
DUT_COUNT=3											# кількість
# WAN інтерфейс на DUT (UDM-Pro зазвичай eth8; для USW-Pro-24 WAN нема — залиште порожнім) ${WAN_IFACE:-}
WAN_IFACE="eth8"
NM_ETHERNET_NAME="Wired connection 1"				# базовий профіль NM, який виводить у VLAN
SSH_USER="root"
SSH_PASS="ui"                						# або "ubnt" пароль
DUT_SSH_USER="root"         						# або "ubnt" — як у тебе на UDM-Pro
DUT_SSH_PASS="${DUT_SSH_PASS:-$SSH_PASS}"           # ← тут твій пароль
# IP DUT (у вас всі DUT-и мають 192.168.1.1, але різні VLAN)
DUT_IP="192.168.1.1"


# 1) Логи
LOG_DIR="${LOG_DIR:-"$SCRIPT_DIR/Logs"}"                    # стандартна папка для логів
LOG_DATE="$(date +%F)"
LOG_HOST="$(hostname)"
LOG_BASENAME="refurbish_test_${LOG_HOST}_${LOG_DATE}"
LOG_FILE="${LOG_DIR}/${LOG_BASENAME}.log"    				# Файл логу
STATUS_FILE="${LOG_DIR}/refurbish_test.status"  			# Файл-статус (PASSED/FAILED/DONE)

################################################################################
# 2) Очікувані параметри системи RAM count 
EXPECTED_CPUS=4												# скільки CPU ядер ми очікуємо на DUT
#MEM_MIN_KB=3900000                           				# ~3.9GB
#MEM_EXPECTED_KB=${MEM_EXPECTED_KB:-4096000}
MEM_MIN_KB=${MEM_MIN_KB:-3800000}      						# мінімально допустимо, з запасом (kB), напр. для 2GB ≈ 1.9e6
MEM_EXPECTED_KB=${MEM_EXPECTED_KB:-4096000}

################################################################################
# 3) Пам’ять (RAM) — параметри тесту
MEMTEST_MIB=${MEMTEST_MIB:-256}          		# обсяг для одного проходу (MiB). 128M достатньо і швидко. 768
MEMTEST_PASSES=${MEMTEST_PASSES:-1}      		# скільки проходів (1..5). Для стенду 1 достатньо.
MD5_ZERO="1f5039e50bd66b290c56684d8550c6c2"  	# 256 MiB нулів
MD5_FF="82eccec9a16f73a4b576c04a57edd729"    	# 256 MiB 0xFF

################################################################################
# 4) SATA/диск
SATA_LINK_PATH=${SATA_LINK_PATH:-/sys/class/ata_link/link1/sata_spd}	# якщо немає — тест зробить SKIP # "/sys/class/ata_link/link1/sata_spd"
ALLOWED_SATA_SPEEDS=("1.5 Gbps" "3.0 Gbps" "6.0 Gbps")
SATA_MNT_POINT=${SATA_MNT_POINT:-/volume1}                 		# якщо немає монтування — SKIP # <<< п.7 стосується саме цього "/volume1"
HDD_WRITE_MB=${HDD_WRITE_MB:-256}                            	# 1 GiB = 1024
HDD_WRITE_TIMEOUT=${HDD_WRITE_TIMEOUT:-60}                      # сек 15

################################################################################
# 5) Bluetooth (якщо блутузу немає у пристрої постаіити 0)
BT_REQUIRED=1

################################################################################
# 6) eMMC — припустимі розміри (сектори)
EMMC_SECTORS_ALLOWED=("30777344" "30535680")
EMMC_SIZE_PATH=${EMMC_SIZE_PATH:-/sys/block/mmcblk0/size}  # якщо немає — SKIP
DATA_PART=${DATA_PART:-/data}                              # перевірка запису; якщо немає/RO — SKIP

################################################################################
# 7) Датчики (діапазон у міліградусах Цельсія)
TEMP_MIN=20000
TEMP_MAX=80000

################################################################################
# 8) Вентилятори — пороги RPM
# CPU fan
CPU_FAN_MIN_IDLE=250
CPU_FAN_MIN_MID=2500
CPU_FAN_MIN_MAX=6500
CPU_FAN_MAX_IDLE=2000
CPU_FAN_MAX_MID=4000
CPU_FAN_MAX_MAX=8000
# HDD fan
HDD_FAN_MIN_MID=3000
HDD_FAN_MIN_MAX=8000
HDD_FAN_MAX_IDLE=2200
HDD_FAN_MAX_MID=5500

################################################################################
# 9) Шляхи до сенсорів/вентиляторів (якщо колись знадобиться міняти)
SENSORS_BASE="/sys/devices/platform/soc/fd880000.i2c-pld/i2c-0/i2c-4/4-002e"
CPU_DIE_TEMP_PATH="/sys/class/thermal/thermal_zone0/temp"
MB_TEMP1_PATH="${SENSORS_BASE}/temp1_input"
MB_TEMP2_PATH="${SENSORS_BASE}/temp2_input"
MB_TEMP3_PATH="${SENSORS_BASE}/temp3_input"
PWM1_PATH="${SENSORS_BASE}/pwm1"
PWM2_PATH="${SENSORS_BASE}/pwm2"
FAN1_TACH_PATH="${SENSORS_BASE}/fan1_input"
FAN2_TACH_PATH="${SENSORS_BASE}/fan2_input"

################################################################################
# 9) Порти
# SSH доступ до DUT (усі DUT мають однаковий логін/пароль)


# Очікувана швидкість порту (Mb/s) за замовчуванням
EXPECTED_PORT_SPEED=1000		# що чекаємо (Mb/s)
ENFORCE_PORT_SPEED=1          		# 1 = валити тест, якщо speed != EXPECTED_PORT_SPEED
USE_TELNET_FOR_SPEED=1
FAIL_ON_SPEED_NA=1            		# 1 = валити тест, якщо швидкість невідома (n/a)
PORT_LIST=(1 2 3 4 5 6 7 8)		# Які порти ганяти
# Всі DUT мають однаковий цільовий IP:
DUT_TARGET_IP="192.168.1.1"
# Ім'я профілю з якого беремо локальну IP для кожного DUT.
# Якщо Wi-Fi, поміняй на "DUT %d WLAN"
CONNECTION_TEMPLATE="DUT %d LAN"		#CONNECTION_TEMPLATE="DUT %d WLAN

# Мапа "людський номер (1..8) -> номер у CLI/ASIC (0..7)"
declare -A PORT_SWITCHNUM_DUT1=(
  [1]=0 [2]=1 [3]=2 [4]=3 [5]=4 [6]=5 [7]=6 [8]=7
)
# Для DUT2, якщо 0-базна — 1->0, 2->1, ... 8->7
declare -A PORT_SWITCHNUM_DUT2=(
  [1]=0 [2]=1 [3]=2 [4]=3 [5]=4 [6]=5 [7]=6 [8]=7
)
declare -A PORT_SWITCHNUM_DUT3=(
  [1]=0 [2]=1 [3]=2 [4]=3 [5]=4 [6]=5 [7]=6 [8]=7
)
declare -A PORT_SWITCHNUM_DUT4=(
  [1]=0 [2]=1 [3]=2 [4]=3 [5]=4 [6]=5 [7]=6 [8]=7
)
declare -A PORT_SWITCHNUM_DUT5=(
  [1]=0 [2]=1 [3]=2 [4]=3 [5]=4 [6]=5 [7]=6 [8]=7
)
declare -A PORT_SWITCHNUM_DUT6=(
  [1]=0 [2]=1 [3]=2 [4]=3 [5]=4 [6]=5 [7]=6 [8]=7
)

# ===== iPerf3 test config =====
IPERF_ENABLE=1             # 1=вмикати, 0=пропускати
IPERF_MODE=trunk           # <<< ДОДАЛИ: використовуємо trunk-режим, без netns
IPERF_DURATION=10          # сек
IPERF_PARALLEL=4           # паралельні потоки
IPERF_PROTOCOL=tcp         # tcp | udp
IPERF_UDP_RATE_M=950       # Mbps для UDP (якщо UDP-тест)
IPERF_MIN_MBIT=900         # поріг "проходить" за замовчуванням
# якщо є ethtool — модуль сам підлаштує поріг під 100M/1G/2.5G/10G
IPERF_NET_BASE="10.10"     # адреси будуть 10.10.<DUT>.1 і 10.10.<DUT>.2/24
IPERF_VLAN_BASE=1000


IPERF3_BIN="/usr/bin/iperf3"
BASE_IFACE="enxa0cec87043c0" # Фізичний інтерфейс ПК, підключений до trunk 0/25 (USW-Pro-24)
# Для кожного DUT вкажи пару локальних інтерфейсів (ліва/права «ноги» до двох портів DUT)
# Приклад для 2 DUT. Можна задати до 10.
declare -A IPERF_IFACE_PAIR
IPERF_IFACE_PAIR[1]="enxa0cec87043c0.1000:enxa0cec87043c0.1011"
# Якщо на DUT немає iperf3 — звідси будемо завантажувати статичний бінарник
# Покладіть сюди підходящий для вашого DUT файл (назвіть 'iperf3_dut', зробіть його виконуваним).
DUT_IPERF_LOCAL="$SCRIPT_DIR/fw/iperf3_dut"
# Куди скопіювати на DUT
DUT_IPERF_REMOTE="/tmp/iperf3_dut"
# Не обов'язково, але можна задати точніші пороги під швидкість лінка:
IPERF_MIN_100M=90
IPERF_MIN_1G=930
IPERF_MIN_2G5=2400
IPERF_MIN_10G=9500
################################################################################


################################################################################
# 15 --- ручний крок RESET ---
RESET_PROMPT=1                # 1 – показувати крок RESET; 0 – пропустити
RESET_PROMPT_MODE="all"       # "all" – одна підказка для всіх DUT; "per-dut" – окремо для кожного
RESET_HOLD_SECONDS=10         # скільки тримати кнопку
RESET_TIMEOUT=90              # максимум секунд очікування на крок
RESET_CHECK_ONLINE=0      # 1 – після RESET перевіряти ping, 0 – не перевіряти

# Для перевірки онлайн (ping):
PING_HOST=192.168.1.1     # В тебе він спільний на всіх VLAN
PING_TRIES=20
PING_DELAY=2
