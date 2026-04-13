#!/usr/bin/env bash
# wait-for-vms.sh
# Blocks until SSH is reachable on every VM in vm-spec.conf.
# Usage: ./wait-for-vms.sh [timeout_seconds]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="$SCRIPT_DIR/vm-spec.conf"
TIMEOUT="${1:-600}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))

echo "==> Waiting up to ${TIMEOUT}s for SSH on all VMs"
while IFS=: read -r NAME IP _REST; do
  [[ "$NAME" =~ ^# ]] && continue
  [[ -z "$NAME" ]] && continue
  printf '    %-14s %-16s ' "$NAME" "$IP"
  while true; do
    if nc -z -w 2 "$IP" 22 2>/dev/null; then
      echo "UP"
      break
    fi
    if [[ $(date +%s) -gt $DEADLINE ]]; then
      echo "TIMEOUT"
      exit 1
    fi
    sleep 3
  done
done < "$SPEC_FILE"
echo "==> All VMs reachable via SSH."
