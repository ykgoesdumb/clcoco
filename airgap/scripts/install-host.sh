#!/usr/bin/env bash
# install-host.sh
# One-shot host prep: stages base image + defines airgap-net.
# Idempotent; safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRGAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POOL_DIR="/var/lib/libvirt/images/airgap"
BASE_SRC="$HOME/airgap/images/jammy-server-cloudimg-amd64.img"
BASE_DST="$POOL_DIR/base-jammy.qcow2"

echo "==> Ensure pool dir $POOL_DIR"
sudo mkdir -p "$POOL_DIR"
sudo chown root:libvirt "$POOL_DIR" 2>/dev/null || sudo chown root:kvm "$POOL_DIR"
sudo chmod 0775 "$POOL_DIR"

echo "==> Stage base image"
if [[ ! -f "$BASE_DST" ]]; then
  [[ -f "$BASE_SRC" ]] || { echo "ERROR: base image missing at $BASE_SRC"; exit 1; }
  sudo cp -v "$BASE_SRC" "$BASE_DST"
  sudo chown libvirt-qemu:kvm "$BASE_DST"
  sudo chmod 0644 "$BASE_DST"
else
  echo "   $BASE_DST already present"
fi

echo "==> Define airgap-net if missing"
if ! sudo virsh net-info airgap-net &>/dev/null; then
  sudo virsh net-define "$SCRIPT_DIR/airgap-net.xml"
  sudo virsh net-autostart airgap-net
  sudo virsh net-start airgap-net
else
  echo "   airgap-net already defined"
fi

echo "==> Summary"
sudo virsh net-list --all
ls -lh "$BASE_DST"
echo "Host ready. Next: ./create-vm.sh <name>  or  ./create-all-vms.sh"
