#!/usr/bin/expect -f
set ip_addr [lindex $argv 0];

spawn ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "ubnt@192.168.0.135"
expect "password: "
send "ubnt\r"
expect "# "
send "telnet localhost\r"
expect "(UBNT) >"
send "enable\r"
expect "(UBNT) #"
send "vlan database\r"
expect "(UBNT) (Vlan)#"
send "vlan 1000-1011\r"
expect "(UBNT) (Vlan)#"
for {set i 1000} {$i < 1012} {incr i 1} {
    send "vlan name $i \"VLAN $i\"\r"
    expect "(UBNT) (Vlan)#"
}
send "exit\r"
expect "(UBNT) #"

send "configure\r"
expect " (Config)#"

for {set i 1} {$i < 25} {incr i 2} {
    send "interface 0/$i\r"
    expect "(Interface 0/$i)#"
    send "vlan participation exclude 1000-1011\r"
    expect "(Interface 0/$i)#"
    send "vlan tagging 1000\r"
    expect "(Interface 0/$i)#"
    send "exit\r"
    expect " (Config)#"
}

for {set i 1} {$i < 13} {incr i 1} {
    set pvid [expr {$i + 999}]
    set iface [expr {$i * 2}]
    send "interface 0/$iface\r"
    expect "(Interface 0/$iface)#"
    send "vlan pvid $pvid\r"
    expect "(Interface 0/$iface)#"
    send "vlan participation exclude 1"
    for {set j 1000} {$j < 1012} {incr j 1} {
        if { $j != $pvid } {
            send ",$j"
        }
    }
    send "\r"
    expect "(Interface 0/$iface)#"
    send "vlan participation include $pvid\r"
    expect "(Interface 0/$iface)#"
    send "exit\r"
    expect " (Config)#"
}

send "interface 0/25\r"
expect "(Interface 0/25)#"
send "vlan participation include 1000-1011\r"
expect "(Interface 0/25)#"
send "vlan tagging 1000-1011\r"
send "exit\r"
expect " (Config)#"

send "exit\r"
expect "(UBNT) #"
send "exit\r"
expect "(UBNT) >"
send "exit\r"
