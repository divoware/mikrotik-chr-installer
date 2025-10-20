# init-config.rsc (final)
# - set ether1 IP 10.0.0.2/28
# - enable services & basic NAT/firewall
/ip address add address=10.0.0.2/28 interface=ether1
/ip route add gateway=10.0.0.1
/ip dns set servers=8.8.8.8
/ip service enable winbox
/ip service enable api
/ip service enable ssh
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade
/system note set show-at-login=no
