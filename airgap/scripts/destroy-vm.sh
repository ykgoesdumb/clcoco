#!/usr/bin/env bash
# destroy-vm.sh <vm-name>
# Fully removes a VM (libvirt domain + disk + seed).
set -euo pipefail

VM="${1:-}"
[[ -n "$VM" ]] || { echo "usage: $0 <vm-name>"; exit 2; }

POOL_DIR="/var/lib/libvirt/images/airgap"

sudo virsh destroy "$VM" 2>/dev/null || true
sudo virsh undefine "$VM" --remove-all-storage --snapshots-metadata --managed-save 2>&1 | tail -3 || true
sudo rm -fv "$POOL_DIR/${VM}.qcow2" "$POOL_DIR/${VM}-seed.iso"
echo "==> $VM destroyed"
