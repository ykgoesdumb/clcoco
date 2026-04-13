#!/usr/bin/env bash
# create-all-vms.sh
# Batch-provision every VM in vm-spec.conf. Sequential to keep virt-install stable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="$SCRIPT_DIR/vm-spec.conf"

awk -F: '/^[a-z]/ {print $1}' "$SPEC_FILE" | while read -r NAME; do
  "$SCRIPT_DIR/create-vm.sh" "$NAME"
done

echo "==> All VMs provisioned. Current state:"
sudo virsh list --all
