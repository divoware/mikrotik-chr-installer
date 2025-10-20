# Initial RouterOS configuration
/ip address add address=10.0.0.2/28 interface=ether1
/ip service enable winbox
/ip service set www disabled=yes
/ip firewall filter add chain=input connection-state=established,related action=accept comment="allow established"
/ip firewall filter add chain=input src-address=10.0.0.0/28 action=accept comment="allow LAN"
/ip firewall filter add chain=input protocol=tcp dst-port=8291,22,80,443 action=accept comment="allow mgmt"
/ip firewall filter add chain=input action=drop comment="drop all other"
