#!/bin/bash
# force-inject.sh
# Robust injector to send init.rsc via serial to CHR
set -euo pipefail

CHR_DIR="/root/chr"
INIT_RSC="${CHR_DIR}/init.rsc"
FLAG="${CHR_DIR}/.configured"
SERIAL_PORT=5000
QEMU_BIN="$(command -v qemu-system-x86_64 || true)"
TIMEOUT=120

if [[ -z "$QEMU_BIN" ]]; then
  echo "qemu-system-x86_64 not found. Install qemu-system-x86 first."
  exit 1
fi

if ! command -v socat >/dev/null 2>&1; then
  echo "Installing socat..."
  apt update -y && apt install -y socat
fi

mkdir -p "$CHR_DIR"
cd "$CHR_DIR"

cat > "$INIT_RSC" <<'RSC'
/ip address add address=10.92.68.2/28 interface=ether1
/ip route add gateway=10.92.68.1
/ip service enable winbox
/ip service enable api
/ip service enable ssh
/ip service enable www
/ip service enable www-ssl
/system reboot
RSC

rm -f "$FLAG"

echo "Stopping chr.service and killing existing qemu..."
systemctl stop chr.service 2>/dev/null || true
pkill -9 qemu-system-x86_64 2>/dev/null || true
sleep 1

if ! ip link show bridge-nat >/dev/null 2>&1; then
  if [[ -x "${CHR_DIR}/setup-bridge-nat.sh" ]]; then
    bash "${CHR_DIR}/setup-bridge-nat.sh"
  else
    echo "bridge-nat missing and setup-bridge-nat.sh not found. Exiting."
    exit 1
  fi
fi

ip link set tap0 down 2>/dev/null || true
brctl delif bridge-nat tap0 2>/dev/null || true
ip tuntap del dev tap0 mode tap 2>/dev/null || true

ip tuntap add dev tap0 mode tap user root
ip link set tap0 up
brctl addif bridge-nat tap0

echo "Starting temporary QEMU to inject configuration (serial telnet:127.0.0.1:${SERIAL_PORT})..."
"${QEMU_BIN}" \
  -m 256M \
  -drive file="${CHR_DIR}/chr-7.20.1-legacy-bios.qcow2",if=virtio,format=qcow2 \
  -drive file="${CHR_DIR}/chr-disk.qcow2",if=virtio,format=qcow2 \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0 \
  -serial telnet:127.0.0.1:${SERIAL_PORT},server,nowait \
  -nographic &

QEMU_PID=$!
echo "QEMU PID: $QEMU_PID"

echo "Waiting for serial port 127.0.0.1:${SERIAL_PORT} (timeout ${TIMEOUT}s)..."
START_TS=$(date +%s)
while true; do
  (echo > /dev/tcp/127.0.0.1/${SERIAL_PORT}) >/dev/null 2>&1 && break
  sleep 1
  NOW=$(date +%s)
  if (( NOW - START_TS >= TIMEOUT )); then
    echo "Timed out waiting for serial port. Killing temporary QEMU."
    kill "$QEMU_PID" 2>/dev/null || true
    exit 2
  fi
done
echo "Serial port ready. Sending init.rsc ..."

for attempt in 1 2 3; do
  echo "Attempt #${attempt} -> sending ${INIT_RSC} to serial..."
  awk '{printf "%s\r\n", $0}' "${INIT_RSC}" | socat - TCP:127.0.0.1:${SERIAL_PORT},connect-timeout=5 || true
  sleep 3
done

echo "Give RouterOS time to apply config and reboot (wait 20s)..."
sleep 20

pkill -f "qemu-system-x86_64.*${SERIAL_PORT}" 2>/dev/null || true
sleep 2

touch "$FLAG"
echo "✅ Injection done. Flag created: ${FLAG}"

systemctl start chr.service 2>/dev/null || true
echo "Started chr.service (if available)."
echo "Done. Check status with: bash /root/chr/status.sh and ping -c3 10.92.68.2"
