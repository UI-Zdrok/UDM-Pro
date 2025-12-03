#!/bin/bash
# ============================================================
# collect_logs.sh
# ------------------------------------------------------------
# Модуль ДЛЯ ХОСТА (Linux), який збирає знімок логів з кожного DUT.
#
# ВАЖЛИВО:
#   - очікує, що в test_1.sh вже визначено:
#       LOG_DIR, RUN_TS, RUN_DIR
#       функції: set_current_dut, run_dut_command
#       хелпери: _dut_mac_for_logs, _dut_log_dir_for_current
#
# Результат:
#   Для одного запуску буде структура:
#     Logs/run_YYYY-MM-DD_HH-MM-SS/
#       dut_1_28704e2b29f5/
#         dmesg.txt
#         syslog.txt
#         meminfo.txt
#         cpuinfo.txt
#         df.txt
#         ps.txt
#         uname.txt
#       dut_2_e43883230439/
#         ...
# ============================================================

# Допоміжна функція: пишемо в stdout і, за бажанням, у RUN_LOG
_log_host() {
    echo "$@"
    if [ -n "${RUN_LOG:-}" ]; then
        echo "$@" >> "$RUN_LOG"
    fi
}

run_logs_snapshot() {
    # Безпечні дефолти, якщо раптом щось не виставлено
    LOG_DIR="${LOG_DIR:-"$SCRIPT_DIR/Logs"}"
    RUN_TS="${RUN_TS:-$(date +%F_%H-%M-%S)}"
    RUN_DIR="${RUN_DIR:-"$LOG_DIR/run_$RUN_TS"}"
    mkdir -p "$RUN_DIR"

    _log_host "----- LogsSnapshot: start -----"

    local max_dut="${DUT_COUNT:-1}"
    local i
    for i in $(seq 1 "$max_dut"); do
        # Підключаємось до потрібного DUT
        set_current_dut "$i"

        # 1) MAC (очищений, без двокрапок)
        local mac_clean
        mac_clean="$(_dut_mac_for_logs)"

        # 2) Папка для цього DUT у поточному запуску
        local DUT_DIR
        DUT_DIR="$(_dut_log_dir_for_current "$i" "$mac_clean")"

        _log_host "Collecting logs from DUT $i (MAC=$mac_clean) -> $DUT_DIR"

        # ---------------- dmesg ----------------
        if ! run_dut_command "dmesg" >"$DUT_DIR/dmesg.txt" 2>&1; then
            _log_host "  [DUT $i] WARNING: failed to collect dmesg"
        fi

        # ---------------- system log ----------------
        if ! run_dut_command '
            if command -v logread >/dev/null 2>&1; then
                echo "### logread ###"
                logread
            elif [ -f /var/log/messages ]; then
                echo "### tail /var/log/messages (last 500 lines) ###"
                tail -n 500 /var/log/messages
            elif [ -f /var/log/syslog ]; then
                echo "### tail /var/log/syslog (last 500 lines) ###"
                tail -n 500 /var/log/syslog
            elif command -v journalctl >/dev/null 2>&1; then
                echo "### journalctl -n 500 ###"
                journalctl -n 500
            else
                echo "No known system log source (logread/messages/syslog/journalctl) found."
            fi
        ' >"$DUT_DIR/syslog.txt" 2>&1; then
            _log_host "  [DUT $i] WARNING: failed to collect system log"
        fi

        # ---------------- meminfo ----------------
        if ! run_dut_command "cat /proc/meminfo" >"$DUT_DIR/meminfo.txt" 2>&1; then
            _log_host "  [DUT $i] WARNING: failed to collect /proc/meminfo"
        fi

        # ---------------- cpuinfo ----------------
        if ! run_dut_command "cat /proc/cpuinfo" >"$DUT_DIR/cpuinfo.txt" 2>&1; then
            _log_host "  [DUT $i] WARNING: failed to collect /proc/cpuinfo"
        fi

        # ---------------- df -h ----------------
        if ! run_dut_command "df -h" >"$DUT_DIR/df.txt" 2>&1; then
            _log_host "  [DUT $i] WARNING: failed to collect df -h"
        fi

        # ---------------- ps ----------------
        if ! run_dut_command "ps w" >"$DUT_DIR/ps.txt" 2>&1; then
            _log_host "  [DUT $i] WARNING: failed to collect ps"
        fi

        # ---------------- uname -a ----------------
        if ! run_dut_command "uname -a" >"$DUT_DIR/uname.txt" 2>&1; then
            _log_host "  [DUT $i] WARNING: failed to collect uname -a"
        fi

        _log_host "  [DUT $i] logs snapshot collected."
    done

    _log_host "----- LogsSnapshot: done -----"
}
