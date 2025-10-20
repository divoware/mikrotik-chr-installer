#!/bin/bash
# Install / Reinstall MikroTik CHR on Debian 12 (QEMU, bridge NAT)
# Filename: install-chr-qemu-debian12.sh
# Notes:
# - Local LAN: 10.0.0.0/28
# - Host bridge IP: 10.0.0.1/28
# - CHR internal IP (guest): 10.0.0.2/28
# - Script is idempotent and includes extra delays & retries for slow VPS disks
# - Creates systemd service /etc/systemd/system/chr.service and a helper force-inject.sh

set -euo pipefail
SH_DIR="/root/chr"
REPO_DIR="/root/mikrotik-chr-installer"
BRIDGE_NAME="bridge-nat"
TAP_NAME="tap0"
BRIDGE_IP="10.0.0.1/28"
CHR_IP="10.0.0.2/28"
CHR_IMAGE_URL="https://github.com/elseif/MikroTikPatch/releases/download/7.20.1/chr-7.20.1-legacy-bios.qcow2.zip"
CHR_IMAGE_ZIP="/root/chr/chr-7.20.1-legacy-bios.qcow2.zip"
CHR_IMAGE="/root/chr/chr-7.20.1-legacy-bios.qcow2"
CHR_DISK="/root/chr/chr-disk.qcow2"
SERVICE_FILE="/etc/systemd/system/chr.service"
INJECT_SCRIPT="/root/chr/force-inject.sh"
INIT_RSC="/root/chr/init-config.rsc"

# -------------- helper funcs
log(){ echo "[install] $*"; }

# -------------- prepare directory
log "Preparing directory $SH_DIR"
rm -rf "$SH_DIR"
mkdir -p "$SH_DIR"

log "Installing dependencies"
apt update
apt install -y qemu-system-x86 bridge-utils wget unzip socat iproute2 iptables || true

# -------------- cleanup
log "Cleaning old interfaces and services (if any)"
systemctl stop chr 2>/dev/null || true
pkill -f qemu-system-x86_64 2>/dev/null || true
sleep 1
ip link del $TAP_NAME 2>/dev/null || true
ip link del $BRIDGE_NAME 2>/dev/null || true
rm -rf /root/chr* /etc/systemd/system/chr.service || true

# -------------- bridge & tap
log "Creating bridge $BRIDGE_NAME and assigning IP $BRIDGE_IP"
ip link add name "$BRIDGE_NAME" type bridge 2>/dev/null || true
ip addr flush dev "$BRIDGE_NAME" || true
ip addr add $BRIDGE_IP dev "$BRIDGE_NAME" || true
ip link set dev "$BRIDGE_NAME" up

log "Creating tap $TAP_NAME"
ip tuntap add dev "$TAP_NAME" mode tap 2>/dev/null || true
ip link set "$TAP_NAME" master "$BRIDGE_NAME" || true
ip link set dev "$TAP_NAME" up
ip link set dev "$BRIDGE_NAME" promisc on
ip link set dev "$TAP_NAME" promisc on

# -------------- download CHR image
log "Downloading CHR image (if missing)"
if [ ! -f "$CHR_IMAGE" ]; then
  cd "$SH_DIR"
  wget -O "${CHR_IMAGE_ZIP}" "$CHR_IMAGE_URL" || true
  if [ -f "${CHR_IMAGE_ZIP}" ]; then
    unzip -o "${CHR_IMAGE_ZIP}" -d "$SH_DIR"
    # look for qcow2 inside zip
    found=$(ls "$SH_DIR"/*.qcow2 2>/dev/null | head -n1 || true)
    if [ -n "$found" ]; then
      mv -f "$found" "$CHR_IMAGE"
    fi
  fi
fi

# if still missing, abort
if [ ! -f "$CHR_IMAGE" ]; then
  log "ERROR: CHR image not found. Please place the CHR qcow2 at $CHR_IMAGE and rerun."
  exit 1
fi

# -------------- create persistent disk
log "Creating persistent disk $CHR_DISK (if missing)"
if [ ! -f "$CHR_DISK" ]; then
  qemu-img create -f qcow2 "$CHR_DISK" 2G
fi

# -------------- create helper init rsc for RouterOS injection
cat > "$INIT_RSC" <<'EOF'
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
EOF

# -------------- create force-inject.sh
cat > "$INJECT_SCRIPT" <<'EOF'
#!/bin/bash
# force-inject.sh: wait for QEMU serial socket and inject initial RouterOS config
set -euo pipefail
HOST_SOCKET=127.0.0.1:5000
RSC_FILE="/root/chr/init-config.rsc"
RETRIES=15
SLEEP=3

log(){ echo "[inject] $*"; }

log "Waiting for CHR serial socket $HOST_SOCKET"
for i in $(seq 1 $RETRIES); do
  if timeout 2 bash -c "</dev/tcp/127.0.0.1/5000" 2>/dev/null; then
    log "CHR serial socket is reachable (try $i)"
    break
  else
    log "CHR serial not ready (try $i/$RETRIES). Sleeping $SLEEP s..."
    sleep $SLEEP
  fi
  if [ $i -eq $RETRIES ]; then
    log "WARNING: CHR serial socket did not become available after $((RETRIES*SLEEP))s"
  fi
done

log "Injecting init script into CHR via socat"
# send the RSC lines with small pauses to avoid overwhelming slow VM
while IFS= read -r line; do
  printf "%s\n" "$line" | socat - TCP:${HOST_SOCKET},connect-timeout=5 || true
  sleep 0.15
done < "$RSC_FILE"

log "Injection finished"
EOF
chmod +x "$INJECT_SCRIPT"

# copy init rsc to SH_DIR
cp -f "$INIT_RSC" "$SH_DIR/"

# -------------- systemd service
log "Creating systemd service $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MikroTik CHR (QEMU Bridge-NAT)
After=network.target

[Service]
Type=simple
# ensure tap exists before start
ExecStartPre=/bin/bash -c 'ip tuntap add dev $TAP_NAME mode tap 2>/dev/null || true'
ExecStartPre=/bin/bash -c 'ip link set $TAP_NAME master $BRIDGE_NAME 2>/dev/null || true'
ExecStartPre=/bin/bash -c 'ip link set $TAP_NAME up 2>/dev/null || true'
ExecStartPre=/bin/bash -c 'ip link set $BRIDGE_NAME up 2>/dev/null || true'
ExecStart=/usr/bin/qemu-system-x86_64 -m 256M \
  -drive file=$CHR_IMAGE,if=virtio,media=disk,format=qcow2 \
  -drive file=$CHR_DISK,if=virtio,media=disk,format=qcow2 \
  -netdev tap,id=net0,ifname=$TAP_NAME,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0 \
  -nographic -serial telnet:127.0.0.1:5000,server,nowait

Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chr --now

# -------------- host iptables
log "Applying host NAT and forwarding rules"
sysctl -w net.ipv4.ip_forward=1 || true
iptables -t nat -D PREROUTING -p tcp --dport 8291 -j DNAT --to-destination 10.0.0.2:8291 2>/dev/null || true
iptables -t nat -A PREROUTING -p tcp --dport 8291 -j DNAT --to-destination 10.0.0.2:8291
iptables -t nat -D PREROUTING -p tcp --dport 22291 -j DNAT --to-destination 10.0.0.2:8291 2>/dev/null || true
iptables -t nat -A PREROUTING -p tcp --dport 22291 -j DNAT --to-destination 10.0.0.2:8291
iptables -t nat -D POSTROUTING -s 10.0.0.0/28 -o eth0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -s 10.0.0.0/28 -o eth0 -j MASQUERADE
iptables -D FORWARD -i $BRIDGE_NAME -o eth0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i eth0 -o $BRIDGE_NAME -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -i $BRIDGE_NAME -o eth0 -j ACCEPT
iptables -I FORWARD -i eth0 -o $BRIDGE_NAME -j ACCEPT

# -------------- allow CHR injection to run (give QEMU time)
log "Allowing time for QEMU/CHR to boot before injection (robust wait)"
# try the injection script — it has its own retries
$INJECT_SCRIPT || true

log "Installation finished. Check status with: systemctl status chr and bash $SH_DIR/status.sh"
exit 0
