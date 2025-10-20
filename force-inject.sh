#!/bin/bash
# Final force-inject.sh (smart injector)
set -euo pipefail
SOCK_HOST=127.0.0.1
SOCK_PORT=5000
RSC="/root/chr/init-config.rsc"
LOG="/root/chr/inject.log"
RETRIES=40
SLEEP=3

log(){ echo -e "[INJECT] $*"; }

log "Starting injector (will wait until CHR console ready). Logging to $LOG"
echo "[INJECT] START $(date)" >> "$LOG"

for i in $(seq 1 $RETRIES); do
  # try to read banner (short timeout)
  if timeout 3 socat - TCP:${SOCK_HOST}:${SOCK_PORT},connect-timeout=3 2>/dev/null | head -n 1 | grep -i -E "router|mikrotik|login" >/dev/null 2>&1; then
    log "Detected CHR banner (try $i)"
    break
  fi
  # quick connectivity test
  if timeout 2 bash -c "</dev/tcp/${SOCK_HOST}/${SOCK_PORT}" 2>/dev/null; then
    log "Socket open but banner not yet. try $i/$RETRIES"
  else
    log "Socket not open yet (try $i/$RETRIES)"
  fi
  sleep $SLEEP
done

# final check: ensure socket open
if ! timeout 3 bash -c "</dev/tcp/${SOCK_HOST}/${SOCK_PORT}" 2>/dev/null; then
  log "ERROR: socket ${SOCK_HOST}:${SOCK_PORT} not open after retries; aborting" | tee -a "$LOG"
  exit 1
fi

log "Injecting $RSC via socat (slowly)"
while IFS= read -r line; do
  printf "%s\n" "$line" | socat - TCP:${SOCK_HOST}:${SOCK_PORT},connect-timeout=5 || true
  sleep 0.12
done < "$RSC"

log "Injection finished at $(date)" | tee -a "$LOG"
