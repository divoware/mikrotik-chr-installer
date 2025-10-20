#!/bin/bash
# force-inject.sh: wait for QEMU serial socket and inject initial RouterOS config
# Expects init-config.rsc to be in the same directory (/root/chr/init-config.rsc)
set -euo pipefail
HOST_SOCKET=127.0.0.1:5000
RSC_FILE="/root/chr/init-config.rsc"
RETRIES=18
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
  sleep 0.12
done < "$RSC_FILE"

log "Injection finished"
