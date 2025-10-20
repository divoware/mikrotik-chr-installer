# Initial RouterOS configuration (injected by host)
# - set ether1 IP 10.0.0.2/28
# - enable winbox
/ip address add address=10.0.0.2/28 interface=ether1
/ip service enable winbox
/ip service set www disabled=yes
# basic firewall: allow established/related, allow LAN and common management ports, drop rest
/ip firewall filter add chain=input connection-state=established,related action=accept comment="allow established"
/ip firewall filter add chain=input src-address=10.0.0.0/28 action=accept comment="allow from internal"
/ip firewall filter add chain=input protocol=tcp dst-port=8291,22,80,443 action=accept comment="allow mgmt ports"
/ip firewall filter add chain=input action=drop comment="drop other input"
