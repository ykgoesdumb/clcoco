#!/usr/bin/env bash
# create-vm.sh <vm-name>
# Provisions one air-gapped VM from vm-spec.conf using cloud-init + virt-install.
# Disks + seed ISOs land in /var/lib/libvirt/images/airgap/.
set -euo pipefail

VM="${1:-}"
if [[ -z "$VM" ]]; then
  echo "usage: $0 <vm-name>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRGAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_FILE="$SCRIPT_DIR/vm-spec.conf"
POOL_DIR="/var/lib/libvirt/images/airgap"
BASE_IMG="$POOL_DIR/base-jammy.qcow2"
HOST_PUBKEY="${HOST_PUBKEY:-$HOME/.ssh/id_rsa.pub}"

[[ -f "$SPEC_FILE" ]] || { echo "missing $SPEC_FILE" >&2; exit 1; }
[[ -f "$BASE_IMG" ]]  || { echo "missing base image $BASE_IMG — run install-host.sh first" >&2; exit 1; }
[[ -f "$HOST_PUBKEY" ]] || { echo "missing $HOST_PUBKEY" >&2; exit 1; }

LINE="$(grep -E "^${VM}:" "$SPEC_FILE" || true)"
[[ -n "$LINE" ]] || { echo "no spec for VM '$VM' in $SPEC_FILE" >&2; exit 1; }

IFS=: read -r NAME IP VCPU RAM_MB DISK_GB <<<"$LINE"
echo "==> $NAME  ip=$IP  vcpu=$VCPU  ram=${RAM_MB}M  disk=${DISK_GB}G"

# Build /etc/hosts body from the whole inventory (so VMs can ping each other by name
# before dnsmasq on infra.airgap.local is up).
HOSTS_BODY="$(awk -F: '/^[a-z]/ {printf "      %-18s %s %s.airgap.local\n", $2, $1, $1}' "$SPEC_FILE")"

PUBKEY_CONTENT="$(cat "$HOST_PUBKEY")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- user-data ----
cat > "$TMP/user-data" <<EOF
#cloud-config
hostname: ${NAME}
fqdn: ${NAME}.airgap.local
preserve_hostname: false
manage_etc_hosts: false

users:
  - name: airgap
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "airgap"
    ssh_authorized_keys:
      - "${PUBKEY_CONTENT}"

ssh_pwauth: true
chpasswd:
  expire: false

growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false

write_files:
  - path: /etc/hosts
    permissions: '0644'
    content: |
      127.0.0.1 localhost
      ::1       localhost
${HOSTS_BODY}

runcmd:
  - [ systemctl, restart, systemd-resolved ]
EOF

# ---- meta-data ----
cat > "$TMP/meta-data" <<EOF
instance-id: ${NAME}-$(date +%s)
local-hostname: ${NAME}
EOF

# ---- network-config v2 (static IP, no gateway → isolated network) ----
cat > "$TMP/network-config" <<EOF
version: 2
ethernets:
  primary:
    match:
      name: "en*"
    dhcp4: false
    dhcp6: false
    addresses:
      - ${IP}/24
EOF

sudo mkdir -p "$POOL_DIR"

SEED="$POOL_DIR/${NAME}-seed.iso"
DISK="$POOL_DIR/${NAME}.qcow2"

sudo cloud-localds -v \
  --network-config "$TMP/network-config" \
  "$SEED" "$TMP/user-data" "$TMP/meta-data"

# Overlay disk on base image, resized to target size
if [[ -f "$DISK" ]]; then
  echo "   disk $DISK already exists — skipping qemu-img create"
else
  sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$DISK" "${DISK_GB}G"
fi
sudo chown libvirt-qemu:kvm "$DISK" "$SEED"

if sudo virsh dominfo "$NAME" &>/dev/null; then
  echo "   domain $NAME already defined — skipping virt-install"
  exit 0
fi

sudo virt-install \
  --name "$NAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPU" \
  --cpu host-passthrough \
  --os-variant ubuntu22.04 \
  --disk path="$DISK",format=qcow2,bus=virtio \
  --disk path="$SEED",device=cdrom \
  --network network=airgap-net,model=virtio \
  --graphics none \
  --import \
  --noautoconsole \
  --noreboot

# Start the VM (virt-install --noreboot defines but does not start)
sudo virsh start "$NAME"
echo "==> $NAME started"
