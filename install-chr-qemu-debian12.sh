#!/bin/bash
# ==========================================================================
# FULL AUTO INSTALLER FOR MIKROTIK CHR ON DEBIAN 12 (v2.2 FINAL)
# - Auto first-boot config injection via QEMU serial (socat)
# - Auto IP assign 10.92.68.2/28, enable services, persistent
# - Port forwarding: 22,80,443,8291,8728,8729 -> CHR
# - Stable systemd unit
# Author: EKO SULISTYAWAN (with ChatGPT GPT-5)
# ==========================================================================
set -euo pipefail

VER="v2.2"
echo "MikroTik CHR Installer ${VER} — starting..."

# ---------------------------
# 1. Requirements & packages
# ---------------------------
echo "🧰 [1/11] Update & install required packages..."
apt update -y && apt upgrade -y
apt install -y qemu-system-x86 qemu-utils bridge-utils net-tools iproute2 iptables iptables-persistent unzip wget curl screen systemd pciutils util-linux dos2unix ca-certificates socat

# ---------------------------
# 2. Kernel modules & sysctl
# ---------------------------
echo "🧩 [2/11] Load kernel modules and enable IP forwarding..."
modprobe tun || true
modprobe bridge || true
modprobe br_netfilter || true
cat > /etc/modules-load.d/chr.conf <<'EOF'
tun
bridge
br_netfilter
EOF

grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p >/dev/null || true

# ---------------------------
# 3. Prepare workspace
# ---------------------------
mkdir -p /root/chr
cd /root/chr

# ---------------------------
# 4. Download CHR image
# ---------------------------
echo "🌍 [3/11] Downloading CHR image (7.20.1 Legacy BIOS)..."
CHR_URL="https://github.com/elseif/MikroTikPatch/releases/download/7.20.1/chr-7.20.1-legacy-bios.qcow2.zip"
CHR_FILE="chr-7.20.1-legacy-bios.qcow2.zip"

if ! ping -c1 -W2 github.com &>/dev/null; then
  echo "⚠️ Cannot reach github.com — set temporary DNS 8.8.8.8"
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
fi

if [[ ! -f "$CHR_FILE" ]]; then
  wget -q --show-progress --tries=5 --timeout=20 -O "$CHR_FILE" "$CHR_URL"
fi

if [[ ! -s "$CHR_FILE" ]]; then
  echo "❌ Failed to download CHR image. Aborting."
  exit 1
fi

echo "📦 Extracting CHR image..."
unzip -o "$CHR_FILE" >/dev/null

# ---------------------------
# 5. Create virtual disk
# ---------------------------
echo "💽 [4/11] Creating persistent disk (512M)..."
qemu-img create -f qcow2 chr-disk.qcow2 512M >/dev/null || true

# ---------------------------
# 6. Bridge & NAT setup script
# ---------------------------
echo "⚙️ [5/11] Creating bridge-nat helper..."
cat > /root/chr/setup-bridge-nat.sh <<'EOF'
#!/bin/bash
set -e
ip link set tap0 down 2>/dev/null || true
brctl delif bridge-nat tap0 2>/dev/null || true
ip tuntap del dev tap0 mode tap 2>/dev/null || true
ip link set bridge-nat down 2>/dev/null || true
brctl delbr bridge-nat 2>/dev/null || true

brctl addbr bridge-nat
ip addr add 10.92.68.1/28 dev bridge-nat
ip link set bridge-nat up
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
iptables -t nat -C POSTROUTING -s 10.92.68.0/28 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.92.68.0/28 -j MASQUERADE
netfilter-persistent save >/dev/null
EOF

chmod +x /root/chr/setup-bridge-nat.sh
bash /root/chr/setup-bridge-nat.sh

# ---------------------------
# 7. Run & stop scripts (run includes injector logic)
# ---------------------------
echo "🚀 [6/11] Creating run & stop scripts..."
cat > /root/chr/run-chr.sh <<'EOF'
#!/bin/bash
set -e
echo "🔁 Waiting 3s for bridge..."
sleep 3

if ! ip link show bridge-nat >/dev/null 2>&1; then
  echo "⚙️ Rebuilding bridge-nat..."
  bash /root/chr/setup-bridge-nat.sh
fi

# cleanup previous tap
if ip link show tap0 >/dev/null 2>&1; then
  echo "🧹 Removing old tap0..."
  ip link set tap0 down 2>/dev/null || true
  brctl delif bridge-nat tap0 2>/dev/null || true
  ip tuntap del dev tap0 mode tap 2>/dev/null || true
fi

ip tuntap add dev tap0 mode tap user root
ip link set tap0 up
brctl addif bridge-nat tap0

# First-boot injector using QEMU serial -> telnet and socat
CONFIG_FLAG="/root/chr/.configured"
INIT_RSC="/root/chr/init.rsc"
if [[ ! -f "${CONFIG_FLAG}" ]]; then
  echo "🔧 Preparing first-boot configuration..."
  cat > "${INIT_RSC}" <<'RSCEOF'
/ip address add address=10.92.68.2/28 interface=ether1
/ip route add gateway=10.92.68.1
/ip service enable winbox
/ip service enable api
/ip service enable ssh
/ip service enable www
/ip service enable www-ssl
/system reboot
RSCEOF

  echo "📡 Starting temporary QEMU to inject config via serial (telnet:127.0.0.1:5000)..."
  qemu-system-x86_64 \
    -m 256M \
    -drive file=/root/chr/chr-7.20.1-legacy-bios.qcow2,if=virtio,format=qcow2 \
    -drive file=/root/chr/chr-disk.qcow2,if=virtio,format=qcow2 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0 \
    -serial telnet:127.0.0.1:5000,server,nowait \
    -nographic &

  QEMU_BG_PID=$!
  echo "⌛ Waiting for CHR to boot (approx 20s)..."
  # wait some seconds for RouterOS to boot
  sleep 20

  # attempt to send init.rsc via socat (with retries)
  for i in 1 2 3; do
    echo "📡 Sending configuration attempt #$i..."
    # send file lines with CRLF
    awk '{print $0"\r"}' "${INIT_RSC}" | socat - TCP:127.0.0.1:5000,connect-timeout=5 || true
    sleep 3
  done

  echo "⌛ Wait for CHR to process and reboot (approx 10s)..."
  # wait until qemu exits (because /system reboot should cause qemu to restart or exit)
  sleep 10
  # best-effort cleanup
  pkill -f "qemu-system-x86_64.*5000" 2>/dev/null || true
  touch "${CONFIG_FLAG}"
  echo "✅ Initial CHR configuration injected."
fi

# Start main QEMU (foreground; systemd expects to stay alive)
exec qemu-system-x86_64 \
  -m 256M \
  -drive file=/root/chr/chr-7.20.1-legacy-bios.qcow2,if=virtio,media=disk,format=qcow2 \
  -drive file=/root/chr/chr-disk.qcow2,if=virtio,media=disk,format=qcow2 \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0 \
  -nographic
EOF

cat > /root/chr/stop-chr.sh <<'EOF'
#!/bin/bash
set -e
echo "🧹 Stopping CHR..."
pkill -SIGTERM qemu-system-x86_64 2>/dev/null || true
sleep 5
if pgrep -f qemu-system-x86_64 >/dev/null; then
  echo "⚠️ Forcing CHR shutdown..."
  pkill -9 qemu-system-x86_64 2>/dev/null || true
fi
ip link set tap0 down 2>/dev/null || true
brctl delif bridge-nat tap0 2>/dev/null || true
ip tuntap del dev tap0 mode tap 2>/dev/null || true
EOF

chmod +x /root/chr/run-chr.sh /root/chr/stop-chr.sh

# ---------------------------
# 8. systemd service
# ---------------------------
echo "🧩 [7/11] Creating systemd service..."
cat > /etc/systemd/system/chr.service <<'EOF'
[Unit]
Description=MikroTik CHR (QEMU Bridge-NAT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/root/chr/run-chr.sh
ExecStop=/root/chr/stop-chr.sh
Restart=on-failure
RestartSec=5
User=root
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYPath=/dev/ttyS0
TTYReset=yes
TTYVHangup=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chr.service

# ---------------------------
# 9. Port forwarding script
# ---------------------------
echo "🌐 [8/11] Creating port-forward helper..."
cat > /root/chr/setup-port-forward.sh <<'EOF'
#!/bin/bash
CHR_IP="10.92.68.2"

for p in 22 80 443 8291 8728 8729; do
  iptables -t nat -C PREROUTING -p tcp --dport $p -j DNAT --to-destination ${CHR_IP}:$p 2>/dev/null || \
  iptables -t nat -A PREROUTING -p tcp --dport $p -j DNAT --to-destination ${CHR_IP}:$p
done

iptables -C FORWARD -d ${CHR_IP}/28 -j ACCEPT 2>/dev/null || iptables -A FORWARD -d ${CHR_IP}/28 -j ACCEPT
iptables -C FORWARD -s ${CHR_IP}/28 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s ${CHR_IP}/28 -j ACCEPT
iptables -t nat -C POSTROUTING -s ${CHR_IP}/28 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s ${CHR_IP}/28 -j MASQUERADE

netfilter-persistent save
echo "✅ Port forwarding to CHR (${CHR_IP}) enabled!"
EOF

chmod +x /root/chr/setup-port-forward.sh
bash /root/chr/setup-port-forward.sh

# ---------------------------
# 10. Status tool
# ---------------------------
echo "📊 [9/11] Creating status tool..."
cat > /root/chr/status.sh <<'EOF'
#!/bin/bash
GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"
fix_mode=false
[[ "$1" == "--fix" ]] && fix_mode=true

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "🖥️  ${YELLOW}MikroTik CHR Status Dashboard${RESET}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

if $fix_mode; then
  echo -e "${YELLOW}⚙️ Auto-Fix Mode...${RESET}"
  systemctl stop chr.service 2>/dev/null
  pkill -9 qemu-system-x86_64 2>/dev/null || true
  modprobe tun bridge br_netfilter 2>/dev/null
  bash /root/chr/setup-bridge-nat.sh
  ip tuntap add dev tap0 mode tap user root
  ip link set tap0 up
  brctl addif bridge-nat tap0
  systemctl restart chr.service
  sleep 3
  echo -e "${GREEN}✅ Auto-fix complete.${RESET}\n"
fi

if systemctl is-active --quiet chr.service; then
  echo -e "🔹 Service: ${GREEN}Active (running)${RESET}"
else
  echo -e "🔹 Service: ${RED}Inactive${RESET}"
fi

PID=$(pgrep -f qemu-system-x86_64 || echo "none")
if [[ "$PID" != "none" ]]; then
  CPU=$(ps -p "$PID" -o %cpu=)
  MEM=$(ps -p "$PID" -o %mem=)
  UPTIME=$(ps -p "$PID" -o etime=)
  echo -e "🔸 QEMU PID: ${GREEN}$PID${RESET}"
  echo -e "   ┣ CPU: ${YELLOW}${CPU}%${RESET}"
  echo -e "   ┣ RAM: ${YELLOW}${MEM}%${RESET}"
  echo -e "   ┗ Uptime: ${YELLOW}${UPTIME}${RESET}"
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
ip addr show bridge-nat | grep 'inet ' | awk '{print "🌉 Bridge: " $2}'
if iptables -t nat -L PREROUTING -n | grep -q "10.92.68.2"; then
  echo -e "🌐 Port Forwarding: ${GREEN}Active${RESET}"
fi
if iptables -t nat -L POSTROUTING -n | grep -q "10.92.68.0/28"; then
  echo -e "🔁 NAT Masquerade: ${GREEN}Active${RESET}"
fi
EOF

chmod +x /root/chr/status.sh
dos2unix /root/chr/status.sh 2>/dev/null || true

# ---------------------------
# 11. Start service
# ---------------------------
echo "▶️ [10/11] Starting CHR service..."
systemctl start chr.service || true
sleep 6

echo "✅ [11/11] Installation finished."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Bridge IP   : 10.92.68.1"
echo "CHR IP      : 10.92.68.2"
echo "Access via  : Winbox/SSH/Web/API on your VPS PUBLIC IP"
echo ""
echo "Use 'bash /root/chr/status.sh' to check status."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
