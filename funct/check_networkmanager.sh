#!/bin/bash
##!/usr/bin/env bash
set -Eeuo pipefail

# МОДУЛЬ: funct/check_networkmanager.sh
check_networkmanager() {
    #створюється порожній масив та виведення повідомлення
    FLAG_DUT_LAN_EXISTS=()
    echo "Checking NetworkManager configuration..."
    
    #ініціалізується нулями для кожного DUT
    for i in $(seq 1 "${DUT_COUNT:-2}"); do
        FLAG_DUT_LAN_EXISTS[$i]=0
    done
    
    #Отримання списку всіх мереж
    CONNECTIONS=$(nmcli con show)
    
########################################################################
	# НОРМАЛІЗАЦІЯ ІСНУЮЧИХ "DUT i LAN"
	# Якщо профіль "DUT i LAN" вже існує, але має НЕ vlan-тип
    for i in $(seq 1 "${DUT_COUNT:-2}"); do
        cname="DUT $i LAN"

        # Перевіряємо, чи взагалі є таке підключення в NM
        if nmcli -g NAME con show 2>/dev/null | grep -Fxq "$cname"; then
            # Дізнаємося тип підключення (ethernet / vlan / …)
            ctype="$(nmcli -g connection.type con show "$cname" 2>/dev/null || echo "")"

            # Якщо це НЕ VLAN – видаляємо, щоб створити правильно
            if [ "$ctype" != "vlan" ]; then
                echo "DUT $i LAN exists as type '$ctype' (must be 'vlan') — recreating..."
                nmcli con delete "$cname" || true

                # Позначаємо, що для цього DUT треба створити профіль заново
                FLAG_DUT_LAN_EXISTS[$i]=0
            fi
        fi
    done
########################################################################


########################################################################
    #Перевірка чи існують підключення для кожного DUT
    for i in $(seq 1 "${DUT_COUNT:-2}"); do
        if echo "$CONNECTIONS" | grep -q "$NM_ETHERNET_NAME"; then
            FLAG_DUT_LAN_EXISTS[$i]=1
            echo "DUT $i: NetworkManager connection exists"
        else
            echo "DUT $i: NetworkManager connection does not exist"
        fi
    done

    #Отримання списку всіх мережевих підключень (команда nmcli -g name con show виводить список імен всіх мережевих підключень).
    #Список мережевих підключень зберігається в масиві TEST_ARRAY.
    readarray -t TEST_ARRAY < <(nmcli -g name con show)
    #Перевірка наявності необхідних підключень
    for i in "${TEST_ARRAY[@]}"; do
        #Якщо знайдено підключення з ім'ям NM_ETHERNET_NAME, то змінна FLAG_NM_ETHERNET_NAME_EXISTS встановлюється в 1.
        if [ "$i" == "$NM_ETHERNET_NAME" ]; then FLAG_NM_ETHERNET_NAME_EXISTS=1;
        fi
        for j in $(seq 1 ${DUT_COUNT:-2}); do
            #Якщо знайдено підключення з ім'ям формату "DUT X LAN", де X - номер пристрою, відповідний елемент в масиві FLAG_DUT_LAN_EXISTS встановлюється в 1
            if [ "$i" == "DUT $j LAN" ]; then FLAG_DUT_LAN_EXISTS[$j]=1;
            fi
        done
    done

    #Якщо підключення NM_ETHERNET_NAME не існує, виводиться повідомлення і сценарій завершується
    if [ ! "$FLAG_NM_ETHERNET_NAME_EXISTS" ]; then
        echo "Connection \"$NM_ETHERNET_NAME\" does not exist!"
        exit 1
    fi

    #Якщо підключення існує, воно активується командою nmcli con up "$NM_ETHERNET_NAME"
    nmcli con up "$NM_ETHERNET_NAME"

    #Створення підключень для DUT, якщо вони не існують
    for i in $(seq 1 ${DUT_COUNT:-2}); do
        if [ "${FLAG_DUT_LAN_EXISTS[$i]}" -ne 1 ]; then
            echo "DUT $i LAN connection does not exist, creating..."
            #Визначається MASTER_IFACE_NAME (ідентифікатор основного інтерфейсу) для NM_ETHERNET_NAME
            
            MASTER_IFACE_NAME=$(nmcli -m tabular -f connection.uuid con show "$NM_ETHERNET_NAME" | tail -n1 | tr -d "[:space:]")
            DUT_SRC_ADDR="192.168.1.$(($i+20))/24"
            VLAN_ID=$(($i+999))
            nmcli con add type vlan connection.id "DUT $i LAN" connection.autoconnect no vlan.id "$VLAN_ID" vlan.parent "$MASTER_IFACE_NAME" ipv4.method manual ipv4.addresses "$DUT_SRC_ADDR" ipv4.may-fail no
        fi
    done
    echo "____________________________________________________________________________________________________"
}
