#!/bin/bash
# Fixed and clean version of install-chr-qemu-debian12.sh
# Works on Debian 12, no CRLF, no syntax errors

set -euo pipefail

BRIDGE="bridge-nat"
TAP="tap0"
BRIDGE_IP="10.0.0.1/28"
CHR_IP="10.0.0.2/28"
CHR_DIR="/root/chr"
CHR_IMG="$CHR_DIR/chr-7.20.1-legacy-bios.qcow2"
CHR_DISK="$CHR_DIR/chr-disk.qcow2"
CHR_ZIP="$CHR_DIR/chr-7.20.1-legacy-bios.qcow2.zip"
IMG_URL="https://github.com/elseif/MikroTikPatch/releases/download/7.20.1/chr-7.20.1-legacy-bios.qcow2.zip"
SERVICE_FILE="/etc/systemd/system/chr.service"
INJECT_SCRIPT="$CHR_DIR/force-inject.sh"
INIT_RSC="$CHR_DIR/init-config.rsc"

log() { echo -e "[CHR-INSTALL] $*"; }

log "Installing dependencies (qemu, bridge-utils, socat, unzip, iptables)"
apt update -y
apt install -y qemu-system-x86 bridge-utils wget unzip socat iproute2 iptables || true

log "Creating working directory $CHR_DIR"
mkdir -p "$CHR_DIR"

log "Stopping any existing CHR service"
systemctl stop chr 2>/dev/null || true
pkill -f qemu-system-x86_64 2>/dev/null || true
sleep 1

log "Setting up bridge $BRIDGE with IP $BRIDGE_IP"
ip link add name "$BRIDGE" type bridge 2>/dev/null || true
ip addr flush dev "$BRIDGE" || true
ip addr add "$BRIDGE_IP" dev "$BRIDGE" || true
ip link set dev "$BRIDGE" up || true

log "Creating TAP interface $TAP and attaching to bridge"
ip tuntap add dev "$TAP" mode tap 2>/dev/null || true
ip link set "$TAP" master "$BRIDGE" 2>/dev/null || true
ip link set dev "$TAP" up || true
ip link set dev "$BRIDGE" promisc on 2>/dev/null || true
ip link set dev "$TAP" promisc on 2>/dev/null || true

log "Downloading CHR image if not present"
if [ ! -f "$CHR_IMG" ]; then
  cd "$CHR_DIR"
  wget -O "$CHR_ZIP" "$IMG_URL" || true
  if [ -f "$CHR_ZIP" ]; then
    unzip -o "$CHR_ZIP" -d "$CHR_DIR" || true
    found=$(ls "$CHR_DIR"/*.qcow2 2>/dev/null | head -n1 || true)
    if [ -n "$found" ]; then
      mv -f "$found" "$CHR_IMG" || true
    fi
  fi
fi

if [ ! -f "$CHR_IMG" ]; then
  log "ERROR: CHR image not found at $CHR_IMG. Please place it manually and re-run."
  exit 1
fi

log "Creating persistent disk if not exists"
if [ ! -f "$CHR_DISK" ]; then
  qemu-img create -f qcow2 "$CHR_DISK" 2G
fi

log "Copying init-config.rsc and force-inject.sh if available"
if [ -f ./init-config.rsc ]; then cp ./init-config.rsc "$INIT_RSC"; fi
if [ -f ./force-inject.sh ]; then cp ./force-inject.sh "$INJECT_SCRIPT"; fi

# Fallback: create minimal config if not found
if [ ! -f "$INIT_RSC" ]; then
cat > "$INIT_RSC" <<'EOF'
/ip address add address=10.0.0.2/28 interface=ether1
/ip route add gateway=10.0.0.1
/ip dns set servers=8.8.8.8
/ip service enable winbox
/ip service enable api
/ip service enable ssh
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade
EOF
fi

# Fallback: minimal injector
if [ ! -f "$INJECT_SCRIPT" ]; then
cat > "$INJECT_SCRIPT" <<'EOF'
#!/bin/bash
for i in {1..10}; do
  if timeout 2 bash -c "</dev/tcp/127.0.0.1/5000" 2>/dev/null; then
    break
  fi
  sleep 3
done
while IFS= read -r l; do
  printf "%s\n" "$l" | socat - TCP:127.0.0.1:5000,connect-timeout=5 || true
  sleep 0.1
done < "$INIT_RSC"
EOF
chmod +x "$INJECT_SCRIPT"
fi

log "Creating systemd service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MikroTik CHR (QEMU Bridge-NAT)
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'ip tuntap add dev $TAP mode tap 2>/dev/null || true'
ExecStartPre=/bin/bash -c 'ip link set $TAP master $BRIDGE 2>/dev/null || true'
ExecStartPre=/bin/bash -c 'ip link set $TAP up 2>/dev/null || true'
ExecStartPre=/bin/bash -c 'ip link set $BRIDGE up 2>/dev/null || true'
ExecStart=/usr/bin/qemu-system-x86_64 -m 256M -drive file=$CHR_IMG,if=virtio,media=disk,format=qcow2 -drive file=$CHR_DISK,if=virtio,media=disk,format=qcow2 -netdev tap,id=net0,ifname=$TAP,script=no,downscript=no -device virtio-net-pci,netdev=net0 -nographic -serial telnet:127.0.0.1:5000,server,nowait
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chr --now || true

log "Enabling IP forwarding and NAT"
sysctl -w net.ipv4.ip_forward=1 || true

# Cleanup and re-add firewall rules
iptables -t nat -D PREROUTING -i eth0 -p tcp --dport 8291 -j DNAT --to-destination $CHR_IP:8291 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 10.0.0.0/28 -o eth0 -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i eth0 -o $BRIDGE -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i $BRIDGE -o eth0 -j ACCEPT 2>/dev/null || true

iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8291 -j DNAT --to-destination $CHR_IP:8291
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 22291 -j DNAT --to-destination $CHR_IP:8291
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 22 -j DNAT --to-destination $CHR_IP:22
iptables -t nat -A POSTROUTING -s 10.0.0.0/28 -o eth0 -j MASQUERADE
iptables -I FORWARD -i eth0 -o $BRIDGE -p tcp --dport 8291 -j ACCEPT
iptables -I FORWARD -i $BRIDGE -o eth0 -j ACCEPT

log "Starting CHR and waiting for injector..."
sleep 6
chmod +x "$INJECT_SCRIPT"
"$INJECT_SCRIPT" || true

for try in 1 2 3; do
  sleep $((try * 20))
  if timeout 2 bash -c "</dev/tcp/10.0.0.2/8291" 2>/dev/null; then
    log "CHR reachable on 10.0.0.2:8291 (try $try)"
    break
  fi
  log "CHR not reachable yet (try $try)"
done

log "Installation complete. Check with: systemctl status chr"
