#!/bin/bash
# ============================================================
# check_processes.sh
# ------------------------------------------------------------
# Модуль ДЛЯ ХОСТА (Linux), який перевіряє важливі процеси на DUT.
#
# Очікує, що у test_1.sh вже визначено:
#   - LOG_DIR, RUN_TS, RUN_DIR
#   - DUT_COUNT
#   - функції: set_current_dut, run_dut_command
#   - хелпери: _dut_mac_for_logs, _dut_log_dir_for_current
#
# Результат:
#   Logs/run_YYYY-MM-DD_HH-MM-SS/
#     processes_summary.log
#     dut_1_<MAC>/
#       processes.log
#     dut_2_<MAC>/
#       processes.log
#     ...
#
# Список процесів:
#   - за замовчуванням: unifi-os, switchd, netifd, ubnt-device, nginx
#   - можна перевизначити в CONF.sh через:
#       PROCESS_LIST="unifi-os switchd netifd ubnt-device nginx"
# ============================================================

# Допоміжна функція: лог у консоль +, за бажанням, у RUN_LOG
_cp_log_host() {
    echo "$@"
    if [ -n "${RUN_LOG:-}" ]; then
        echo "$@" >> "$RUN_LOG"
    fi
}

run_process_checks() {
    # Страховка: якщо раптом щось не виставлено
    LOG_DIR="${LOG_DIR:-"$SCRIPT_DIR/Logs"}"
    RUN_TS="${RUN_TS:-$(date +%F_%H-%M-%S)}"
    RUN_DIR="${RUN_DIR:-"$LOG_DIR/run_$RUN_TS"}"
    mkdir -p "$RUN_DIR"

    # Тут буде короткий підсумок по всіх DUT
    local SUMMARY_FILE="$RUN_DIR/processes_summary.log"

    _cp_log_host "----- Processes: start -----" | tee -a "$SUMMARY_FILE"

    # Беремо к-сть DUT (якщо не задано – хоч 1)
    local max_dut="${DUT_COUNT:-1}"

    # Список процесів:
    #   - якщо PROCESS_LIST задано у CONF.sh – беремо його
    #   - інакше використовуємо дефолтний набір
    local procs_string
    procs_string="${PROCESS_LIST:-"unifi-os switchd netifd ubnt-device nginx"}"

    # Перетворюємо строку в масив
    # shellcheck disable=SC2206
    local procs=($procs_string)

    declare -A TEST_RESULTS

    local i
    for i in $(seq 1 "$max_dut"); do
        # Переходимо до поточного DUT (це впливає на run_dut_command)
        set_current_dut "$i"

        # Отримуємо MAC без двокрапок (для імені папки)
        local mac_clean
        mac_clean="$(_dut_mac_for_logs)"

        # Папка для логів цього DUT у поточному запуску
        local DUT_DIR
        DUT_DIR="$(_dut_log_dir_for_current "$i" "$mac_clean")"

        # Лог-файл саме для перевірки процесів цього DUT
        local LOG_FILE="$DUT_DIR/processes.log"

        echo "Checking processes on DUT $i (MAC=$mac_clean)" \
            | tee -a "$LOG_FILE" | tee -a "$SUMMARY_FILE"

        # Перевіряємо кожен процес з масиву
        local p fail=0
        for p in "${procs[@]}"; do
            # pgrep -x шукає процес з точним ім'ям
            if run_dut_command "pgrep -x '$p' >/dev/null 2>&1"; then
                echo "  [$p] OK" | tee -a "$LOG_FILE"
            else
                echo "  [$p] MISSING ❌" | tee -a "$LOG_FILE"
                fail=1
            fi
        done

        if [ "$fail" -eq 0 ]; then
            echo "DUT $i: all processes present ✅" \
                | tee -a "$LOG_FILE" | tee -a "$SUMMARY_FILE"
            TEST_RESULTS[$i]="passed"
        else
            echo "DUT $i: some processes are missing ❌" \
                | tee -a "$LOG_FILE" | tee -a "$SUMMARY_FILE"
            TEST_RESULTS[$i]="failed"
        fi

        echo "" >>"$LOG_FILE"
    done

    # Підсумок по всіх DUT
    echo "----- Processes: summary -----" | tee -a "$SUMMARY_FILE"
    for i in $(seq 1 "$max_dut"); do
        echo "DUT $i: ${TEST_RESULTS[$i]:-n/a}" | tee -a "$SUMMARY_FILE"
    done

    echo "----- Processes: done -----" | tee -a "$SUMMARY_FILE"
}
