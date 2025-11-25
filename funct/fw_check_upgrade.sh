#ЗАЛЕЖНОСТІ:
#   - ENV/vars: DUT_COUNT (кількість DUT, до 10), LOG_DIR (з CONF.sh)
#   - ФУНКЦІЇ: set_current_dut <i>, run_dut_command <cmd>
#   - Використовує стандартні утиліти: awk, sed, ping, sleep, nohup
#
# ЗМІННІ КОНФІГУРАЦІЇ УСЕРЕДИНІ ФУНКЦІЇ:
#   - FW_EXPECTED_VERSION — очікувана версія на фінальній перевірці.
#   - FW_UPGRADE_URI — посилання на *.bin для проміжних/цільових оновлень.


#ДЕ ЩО ЗМІНИТИ:
#   1) Очікувану версію:
#      ЗМІНИТИ МІЖ лапками у рядку: FW_EXPECTED_VERSION="UDMPRO.al324.v3.2.12.7765dbb.240126.0152" —> на вашу ціль.
#   2) Посилання на прошивки в if-гілках — МІЖ лапками "https://...bin" —> на ваші URL.
#
# ЛОГИ:
#   - Вивід іде у stdout; у головному сценарії зробіть tee у "$LOG_DIR".
#   - Приклад: _run_fw_check_upgrade | tee -a "$LOG_FILE"
#
# УВАГА: Функція розрахована на DUT_COUNT до 10. Якщо більше — збільшіть значення у CONF.sh або у головному скрипті.
#
# НЕ додавайте shebang у бібліотеку; цей файл ПІДКЛЮЧАЄТЬСЯ командою `source`.

#!/usr/bin/env bash
set -Eeuo pipefail

_run_fw_check_upgrade() {
    
    FW_EXPECTED_VERSION="UDMPRO.al324.v4.3.6.fb6f502.250705.2119"
    FW_UPGRADE_IN_PROGRESS=0
    UPGRADE_CHECK=1
    
    while [ $UPGRADE_CHECK -eq 1 ]; do
        UPGRADE_CHECK=0
        for i in `seq 1 $DUT_COUNT`; do
            set_current_dut "$i"
            # 1) Визначаємо IP активного DUT (як у run_dut_command)
		local ip="${DUT_IPS[$((CURRENT_DUT-1))]:-192.168.1.1}"

		# 2) Перевіряємо, що DUT взагалі доступний
		if ! ensure_reachable "$ip"; then
		  echo "ERROR: DUT $CURRENT_DUT ($ip) не пінгується. Перевір LAN-профіль/кабель/живлення."
		  return 1
		fi

		# 3) Беремо MAC із кількох можливих інтерфейсів (UDM/UDR/USW можуть відрізнятися)
		local mac_raw=""
		mac_raw="$(run_dut_command 'cat /sys/class/net/eth0/address || cat /sys/class/net/br0/address || cat /sys/class/net/lan0/address' || true)"

		# 4) Нормалізуємо (забираємо двокрапки) БЕЗ пайплайна — щоб не ламав set -o pipefail
		local DUT_MAC="${mac_raw//:/}"

		if [ -z "$DUT_MAC" ]; then
		  echo "ERROR: Не вдалося зчитати MAC на DUT $CURRENT_DUT ($ip). Перевір пароль/SSH доступ/шлях до інтерфейсу."
		  return 1
		fi
		echo "INFO: DUT $CURRENT_DUT ($ip) MAC=${DUT_MAC}"


            if [ -z "$DUT_MAC" ]; then echo "Communication error DUT $i, bailing..."; exit 1; 
            fi

            FW_VERSION=$(run_dut_command "cat /usr/lib/version")
                if [ "$FW_VERSION" != "$FW_EXPECTED_VERSION" ]; then # перевіряє чи співпадає версія пристрою з очікуваной
                echo "Current FW Version: $FW_VERSION"
                echo "Expected FW Version: $FW_EXPECTED_VERSION"

                #Аналіз версії програми
                FW_MAJOR=$(echo "$FW_VERSION" | awk -F '.' '{print $3;}' | sed s'/v//')
                FW_MINOR=$(echo "$FW_VERSION" | awk -F '.' '{print $4;}')
                FW_PATCH=$(echo "$FW_VERSION" | awk -F '.' '{print $5;}')
                echo "Major: $FW_MAJOR, Minor: $FW_MINOR, Patch: $FW_PATCH"

                UPGRADE_REQUIRED=0
                if [ "${FW_MAJOR:-0}" -eq 1 ]; then
                    UPGRADE_REQUIRED=1
                    #if [ "${FW_MINOR:-0}" -lt 12 ] || ([ "${FW_MINOR:-0}" -eq 12 ] && [ "${FW_PATCH:-0}" -lt 38 ]); then
                    if [ "${FW_MINOR:-0}" -lt 12 ] || { [ "${FW_MINOR:-0}" -eq 12 ] && [ "${FW_PATCH:-0}" -lt 38 ]; }; then
                        FW_UPGRADE_URI="http://fw-download.ubnt.com/data/udm/1adc-udmpro-1.12.38-ca8a490ac2b04247abb3f7d3e3eae01a.bin"
                    else
                        FW_UPGRADE_URI="http://fw-download.ubnt.com/data/udm/e2cf-udmpro-2.4.27-795aaf430714433faaea9e0dfeb4e5bf.bin"
                    fi
                fi
                if [ "${FW_MAJOR:-0}" -eq 2 ]; then
                    if [ "${FW_MINOR:-0}" -lt 4 ] || ([ "${FW_MINOR:-0}" -eq 4 ] && [ "${FW_PATCH:-0}" -lt 27 ]); then
                        UPGRADE_REQUIRED=1
                        FW_UPGRADE_URI="https://fw-download.ubnt.com/data/udm/e2cf-udmpro-2.4.27-795aaf430714433faaea9e0dfeb4e5bf.bin"
                    elif [ "${FW_MINOR:-0}" -lt 5 ] || ([ "${FW_MINOR:-0}" -eq 5 ] && [ "${FW_PATCH:-0}" -lt 17 ]); then
                        UPGRADE_REQUIRED=1
                        FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/10c9-UDMPRO-2.5.17-4ef0556d8b844aa6ac43c695ef076479.bin"
                    else
                        UPGRADE_REQUIRED=1
                        FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/fb51-UDMPRO-3.0.20-c9d8c62c8a9a4ef18413881434197f30.bin"
                    fi
                fi
                if [ "${FW_MAJOR:-0}" -eq 3 ]; then
                    if [ "${FW_MINOR:-0}" -lt 1 ] || ([ "${FW_MINOR:-0}" -eq 1 ] && [ "${FW_PATCH:-0}" -lt 15 ]); then
                        UPGRADE_REQUIRED=1
                        FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/6982-UDMPRO-3.1.15-6d62a07a-7a86-4bf1-90a4-f4029bf0e7aa.bin"
                    elif [ "${FW_MINOR:-0}" -eq 1 ] && [ "${FW_PATCH:-0}" -lt 16 ]; then
                        UPGRADE_REQUIRED=1
                        FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/84e6-UDMPRO-3.1.16-54b0d2b8-e966-4dbf-973e-bbc84c58ce47.bin"
                    elif [ "${FW_MINOR:-0}" -eq 2 ] && [ "${FW_PATCH:-0}" -lt 7 ]; then
                        UPGRADE_REQUIRED=1
                        FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/7514-UDMPRO-3.2.7-9f58607c-4e10-4974-920a-4699b8cee57c.bin"
                    elif [ "${FW_MINOR:-0}" -eq 2 ] && [ "${FW_PATCH:-0}" -lt 9 ]; then
                        UPGRADE_REQUIRED=1
                        FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/5adb-UDMPRO-3.2.9-06d3e7d3-b93c-48ed-baeb-d804bc4c090d.bin"
                    else
                        UPGRADE_REQUIRED=1
                        FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/7b91-UDMPRO-4.0.21-815ad824-3992-449d-8a0f-c731232bb20f.bin"
                        #FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/b1a0-UDMPRO-3.2.12-24a7e106-d7e6-4c63-aefa-046c7eaf5a8e.bin"
                    fi
                fi
                if [ "${FW_MAJOR:-0}" -eq 4 ]; then
                	if [ "${FW_MINOR:-0}" -lt 0 ] || ([ "${FW_MINOR:-0}" -eq 0 ] && [ "${FW_PATCH:-0}" -lt 21 ]); then
                		UPGRADE_REQUIRED=1
                		FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/7b91-UDMPRO-4.0.21-815ad824-3992-449d-8a0f-c731232bb20f.bin"
                	elif [ "${FW_MINOR:-0}" -eq 1 ] && [ "${FW_PATCH:-0}" -lt 13 ]; then
                		UPGRADE_REQUIRED=1
                		FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/b012-UDMPRO-4.1.13-4bc426ae-2619-4f5f-8d19-7502798be61a.bin"
                	elif [ "${FW_MINOR:-0}" -eq 1 ] && [ "${FW_PATCH:-0}" -lt 22 ]; then
                		UPGRADE_REQUIRED=1
                		FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/171a-UDMPRO-4.1.22-6d3b9408-0ec3-4a3b-a15e-aade09f1302c.bin"
                	else
                		UPGRADE_REQUIRED=1
                		FW_UPGRADE_URI="https://fw-download.ubnt.com/data/unifi-dream/5669-UDMPRO-4.3.6-e98a53a1-ecf1-4186-88bd-3773b40bdc7b.bin"
                	fi
                fi
                
                                
                if [ $UPGRADE_REQUIRED -eq 1 ]; then 
                    UPGRADE_CHECK=1; 
                    echo "$DUT_MAC: FW version check FAIL"
                    echo "Expected $FW_EXPECTED_VERSION"
                    echo "Got $FW_VERSION"
                    echo "Trying upgrade... please wait, this could take a long time."
                    echo ""
                    run_dut_command "nohup ubnt-systool fwupdate $FW_UPGRADE_URI 2>/dev/null >/dev/null &"
                    FW_UPGRADE_IN_PROGRESS=1
                fi
            fi
        done
		
        if [ "$FW_UPGRADE_IN_PROGRESS" -eq "1" ]; then
            sleep 300

            DUT_UPGRADE_FINISHED=0
            while [ "$DUT_UPGRADE_FINISHED" -ne "1" ]; do
                DUT_UPGRADE_FINISHED=1
                sleep 120
                for i in `seq 1 $DUT_COUNT`; do
                    set_current_dut "$i"
                    DUT_MAC=$(run_dut_command "cat /sys/class/net/eth0/address" | sed 's/://g')   

                    if ! ping -c 1 192.168.1.1 2>/dev/null >/dev/null; then
                        echo "Still waiting for upgrade to finish..."
                        DUT_UPGRADE_FINISHED=0
                    fi
                done
            done
        fi
    done

    for i in $(seq 1 $DUT_COUNT); do
        set_current_dut "$i"
        DUT_MAC=$(run_dut_command "cat /sys/class/net/eth0/address" | sed 's/://g')

        FW_VERSION=$(run_dut_command "cat /usr/lib/version")
        if [ "$FW_VERSION" != "$FW_EXPECTED_VERSION" ]; then
            echo "$DUT_MAC: FW version check FAIL"
            echo "Expected $FW_EXPECTED_VERSION"
            echo "Got $FW_VERSION"
            exit 1
        else
            echo "$DUT_MAC: FW version check PASS"
        fi
    done
    echo "____________________________________________________________________________________________________"

}

