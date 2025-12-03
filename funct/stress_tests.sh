#!/usr/bin/env bash
########################################################################
# stress_tests.sh — модуль стрес-тестів для DUT (UDM-Pro)
#
# Цей файл підключається з test_1.sh:
#   STRESS_LIB="$SCRIPT_DIR/funct/stress_tests.sh"
#   [ -r "$STRESS_LIB" ] && . "$STRESS_LIB"
#
# ВАЖЛИВО:
#  - Звідси ми НІЧОГО не запускаємо автоматично.
#  - Тут лише визначення функцій:
#        run_cpu_stress_test
#        run_memory_stress_test
#        run_disk_stress_test
#        run_network_stress_test
#        run_temperature_check
#        run_all_stress_tests
#
# Очікуємо, що:
#  - SCRIPT_DIR вже визначено в test_1.sh
#  - функція _dut_ssh() вже оголошена в test_1.sh
#  - SSH_PASS та інші змінні беруться з CONF.sh
########################################################################


##################################################################
# CPU stress test на DUT
# Навантажує CPU приблизно як "stress --cpu 4 --timeout 60",
# але без зовнішньої утиліти, лише засобами shell.
##################################################################
run_cpu_stress_test() {
    echo "Running CPU stress test..."
    # Відправляємо на DUT невеликий скрипт:
    # 1) Якщо на девайсі є 'stress' — використовуємо його.
    # 2) Інакше запускаємо 4 фонові процеси з busy-loop на ~60 секунд.
    _dut_ssh "192.168.1.1" '
        if command -v stress >/dev/null 2>&1; then
            echo "Using stress binary on DUT"
            stress --cpu 4 --timeout 60
        else
            echo "stress not found, using built-in busy loop"

            # Чотири "воркери" для навантаження CPU
            for i in 1 2 3 4; do
                (
                    # Створюємо "таймер": процес sleep на 60 секунд
                    sleep 60 & s=$!

                    # Поки sleep ще живий — крутимось у порожньому циклі
                    while kill -0 "$s" 2>/dev/null; do
                        :
                    done
                ) &
            done

            # Чекаємо, поки всі фонові воркери завершаться
            wait
        fi
    '
}
##################################################################


##################################################################
# Memory stress test на DUT
#
# 1) Якщо є memtester → використовуємо його (класика).
# 2) Якщо memtester Нема → робимо простий "саморобний" тест:
#    - створюємо в /tmp кілька великих файлів (через dd),
#    - пишемо їх паралельно (щоб навантажити RAM / кеш),
#    - читаємо назад і видаляємо.
##################################################################
run_memory_stress_test() {
    echo "Running memory stress test..."

    _dut_ssh "192.168.1.1" '
        if command -v memtester >/dev/null 2>&1; then
            echo "Using memtester on DUT"
            # ~1GB, 3 проходи (можна змінити при потребі)
            memtester 1024 3
        else
            echo "memtester not found, using simple /tmp-based memory stress"

            BASE_DIR="/tmp/mem_stress"
            mkdir -p "$BASE_DIR" 2>/dev/null || true

            # Робимо кілька "проходів" навантаження
            for pass in 1 2 3; do
                echo "Memory stress pass $pass..."

                # Кілька паралельних файлів (воркерів)
                for i in 1 2 3 4; do
                    (
                        # Кожен файл ~128MB: 8M * 16 = 128MB
                        # 4 воркери → ~512MB за один прохід.
                        dd if=/dev/zero of="$BASE_DIR/file_${pass}_$i.bin" \
                           bs=8M count=16 conv=fdatasync \
                           >/dev/null 2>&1

                        # Невеличка читальна фаза (додаткове навантаження кешу)
                        dd if="$BASE_DIR/file_${pass}_$i.bin" of=/dev/null \
                           bs=8M \
                           >/dev/null 2>&1
                    ) &
                done

                # Чекаємо, поки всі фонові воркери завершаться
                wait

                # Прибираємо файли цього проходу
                rm -f "$BASE_DIR"/file_"${pass}"_*.bin 2>/dev/null || true
            done

            # Прибираємо директорію
            rmdir "$BASE_DIR" 2>/dev/null || true

            echo "Simple memory stress completed"
        fi
    '
}
##################################################################


##################################################################
# Disk I/O stress test на DUT
# Пише й читає тимчасовий файл у /tmp, щоб прогнати диск / файлову систему.
##################################################################
run_disk_stress_test() {
    echo "Running disk I/O stress test..."

    _dut_ssh "192.168.1.1" '
        TEST_FILE="/tmp/disk_stress.bin"

        echo "Writing 512MB test file..."
        dd if=/dev/zero of="$TEST_FILE" bs=8M count=64 conv=fdatasync \
           >/dev/null 2>&1

        echo "Reading test file..."
        dd if="$TEST_FILE" of=/dev/null bs=8M \
           >/dev/null 2>&1

        rm -f "$TEST_FILE" 2>/dev/null || true
        echo "Disk I/O stress completed"
    '
}
##################################################################


##################################################################
# Network stress test
#
# Тут тільки "заглушка", бо реальний iPerf3-тест уже винесений у
# окремий модуль iperf3_test.sh (run_iperf_for_all_duts).
#
# Щоб не плодити дублікати логіки, цей стрес-тест просто пише,
# що для навантаження мережі треба використати основний iPerf-тест.
##################################################################
run_network_stress_test() {
    echo "Running network stress test..."
    echo "Network stress is handled by iperf3_test.sh (run_iperf_for_all_duts), skipping here."
}
##################################################################


##################################################################
# Temperature check
#
# Пробуємо:
#   1) sensors (якщо є)
#   2) sysfs /sys/class/thermal/thermal_zone0/temp
# Якщо немає нічого — просто пишемо, що дані недоступні.
##################################################################
run_temperature_check() {
    echo "Checking temperature..."

    _dut_ssh "192.168.1.1" '
        if command -v sensors >/dev/null 2>&1; then
            sensors
        elif [ -r /sys/class/thermal/thermal_zone0/temp ]; then
            t_raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "")
            if [ -n "$t_raw" ]; then
                awk -v t="$t_raw" "BEGIN { printf \"CPU temp: %.1f°C\n\", t/1000 }"
            else
                echo "Temperature sensor file is empty"
            fi
        else
            echo "Temperature info not available on DUT"
        fi
    '
}
##################################################################


##################################################################
# Головна обгортка для запуску всіх стрес-тестів підряд
##################################################################
run_all_stress_tests() {
    run_cpu_stress_test
    run_memory_stress_test
    run_disk_stress_test
    run_network_stress_test
    run_temperature_check
}
##################################################################
