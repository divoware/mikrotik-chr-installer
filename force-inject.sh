#!/bin/bash
# force-inject.sh — safely inject init config into CHR
set -euo pipefail
SOCK=127.0.0.1:5000
RSC="/root/chr/init-config.rsc"
RETRIES=15
SLEEP=3
log(){ echo -e "\033[1;33m[INJECT]\033[0m $*"; }

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
