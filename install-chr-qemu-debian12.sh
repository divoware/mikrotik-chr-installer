#!/bin/bash
# Final version: install-chr-qemu-debian12.sh
# Clean installer for MikroTik CHR on Debian 12 (QEMU Bridge NAT)
# Local LAN: 10.0.0.0/28 | Bridge: 10.0.0.1 | CHR: 10.0.0.2

set -euo pipefail

BRIDGE="bridge-nat"
TAP="tap0"
BRIDGE_IP="10.0.0.1/28"
CHR_IP="10.0.0.2/28"
CHR_DIR="/root/chr"
CHR_IMG="/root/chr/chr-7.20.1-legacy-bios.qcow2"
CHR_DISK="/root/chr/chr-disk.qcow2"
CHR_ZIP="/root/chr/chr-7.20.1-legacy-bios.qcow2.zip"
SERVICE_FILE="/etc/systemd/system/chr.service"
INJECT_SCRIPT="/root/chr/force-inject.sh"
INIT_RSC="/root/chr/init-config.rsc"
IMG_URL="https://github.com/elseif/MikroTikPatch/releases/download/7.20.1/chr-7.20.1-legacy-bios.qcow2.zip"

log(){ echo -e "\\033[1;36m[CHR-INSTALL]\\033[0m $*"; }

log "Installing dependencies"
apt update -y
apt install -y qemu-system-x86 bridge-utils wget unzip socat iproute2 iptables

log "Stopping any existing CHR instance"
systemctl stop chr 2>/dev/null || true
pkill -f qemu-system-x86_64 2>/dev/null || true
sleep 1

log "Cleaning old files"
rm -rf "$CHR_DIR" /root/chr-* "$SERVICE_FILE"
mkdir -p "$CHR_DIR"

log "Creating bridge and tap"
ip link del $BRIDGE 2>/dev/null || true
ip link del $TAP 2>/dev/null || true
ip link add name $BRIDGE type bridge
ip addr add $BRIDGE_IP dev $BRIDGE
ip link set $BRIDGE up
ip tuntap add dev $TAP mode tap
ip link set $TAP master $BRIDGE
ip link set $TAP up

log "Downloading CHR image"
cd "$CHR_DIR"
wget -O "$CHR_ZIP" "$IMG_URL"
unzip -o "$CHR_ZIP"
mv chr-*.qcow2 "$CHR_IMG"

log "Creating persistent CHR disk"
qemu-img create -f qcow2 "$CHR_DISK" 2G

log "Creating init RouterOS script"
cat > "$INIT_RSC" <<'EOF'
# Initial RouterOS configuration
/ip address add address=10.0.0.2/28 interface=ether1
/ip service enable winbox
/ip service set www disabled=yes
/ip firewall filter add chain=input connection-state=established,related action=accept comment="allow established"
/ip firewall filter add chain=input src-address=10.0.0.0/28 action=accept comment="allow LAN"
/ip firewall filter add chain=input protocol=tcp dst-port=8291,22,80,443 action=accept comment="allow mgmt"
/ip firewall filter add chain=input action=drop comment="drop all other"
EOF

log "Creating force-inject.sh"
cat > "$INJECT_SCRIPT" <<'EOF'
#!/bin/bash
# force-inject.sh — safely inject init config into CHR
set -euo pipefail
SOCK=127.0.0.1:5000
RSC="/root/chr/init-config.rsc"
RETRIES=15
SLEEP=3
log(){ echo -e "\\033[1;33m[INJECT]\\033[0m $*"; }

for i in $(seq 1 $RETRIES); do
  if timeout 2 bash -c "</dev/tcp/127.0.0.1/5000" 2>/dev/null; then
    log "Socket ready (try $i)"
    break
  else
    log "Waiting for CHR serial socket (try $i/$RETRIES)..."
    sleep $SLEEP
  fi
done

log "Injecting $RSC into CHR"
while IFS= read -r line; do
  echo "$line" | socat - TCP:$SOCK,connect-timeout=5 || true
  sleep 0.15
done < "$RSC"
log "Injection complete"
EOF
chmod +x "$INJECT_SCRIPT"

log "Creating systemd service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MikroTik CHR (QEMU Bridge NAT)
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'ip tuntap add dev $TAP mode tap 2>/dev/null || true'
ExecStartPre=/bin/bash -c 'ip link set $TAP master $BRIDGE 2>/dev/null || true'
ExecStartPre=/bin/bash -c 'ip link set $TAP up 2>/dev/null || true'
ExecStart=/usr/bin/qemu-system-x86_64 -m 256M -drive file=$CHR_IMG,if=virtio,media=disk,format=qcow2 -drive file=$CHR_DISK,if=virtio,media=disk,format=qcow2 -netdev tap,id=net0,ifname=$TAP,script=no,downscript=no -device virtio-net-pci,netdev=net0 -nographic -serial telnet:127.0.0.1:5000,server,nowait
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chr --now

log "Configuring NAT rules"
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A PREROUTING -p tcp --dport 8291 -j DNAT --to-destination 10.0.0.2:8291
iptables -t nat -A POSTROUTING -s 10.0.0.0/28 -o eth0 -j MASQUERADE
iptables -I FORWARD -i $BRIDGE -o eth0 -j ACCEPT
iptables -I FORWARD -i eth0 -o $BRIDGE -j ACCEPT

log "Running injector after delay (wait for CHR boot)"
sleep 25
"$INJECT_SCRIPT" || true

log "✅ Installation done. Check with: systemctl status chr"
