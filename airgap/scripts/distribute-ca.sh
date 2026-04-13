#!/usr/bin/env bash
# distribute-ca.sh — runs ON the libvirt host.
# Pulls the Root CA (and server certs) from the infra VM, then fans them out
# to every other VM:
#   * Installs ca.crt → /usr/local/share/ca-certificates/airgap-ca.crt + update-ca-certificates
#   * Points systemd-resolved at 192.168.10.10 for *.airgap.local
#   * Stages harbor.{crt,key} on harbor VM and gitea.{crt,key} on gitea VM
#     (Registry / Git-CI engineers wire these into their services later.)
set -euo pipefail

INFRA_IP="192.168.10.10"
DNS_IP="$INFRA_IP"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="$SCRIPT_DIR/vm-spec.conf"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "==> Pulling CA + server certs from infra VM"
ssh "${SSH_OPTS[@]}" airgap@"$INFRA_IP" \
  "sudo tar -czf /tmp/airgap-certs.tgz -C /etc/airgap-ca ca.crt harbor.crt harbor.key gitea.crt gitea.key && sudo chown airgap:airgap /tmp/airgap-certs.tgz"
scp "${SSH_OPTS[@]}" airgap@"$INFRA_IP":/tmp/airgap-certs.tgz "$STAGE/"
ssh "${SSH_OPTS[@]}" airgap@"$INFRA_IP" "rm -f /tmp/airgap-certs.tgz"

echo "==> Checksum of CA bundle for fingerprint tracking"
sha256sum "$STAGE/airgap-certs.tgz"

# The script that will run INSIDE each target VM. Stdin gets the tarball.
VM_APPLY=$(cat <<'REMOTE'
set -euo pipefail
VM_NAME="$1"
DNS_IP="$2"
TAR_PATH=/tmp/airgap-certs.tgz
CA_STAGE_DIR=/opt/airgap-ca
CA_SYSTEM_PATH=/usr/local/share/ca-certificates/airgap-ca.crt

sudo install -d -m 0755 "$CA_STAGE_DIR"
sudo tar -xzf "$TAR_PATH" -C "$CA_STAGE_DIR"
sudo chmod 600 "$CA_STAGE_DIR"/*.key 2>/dev/null || true
sudo chmod 644 "$CA_STAGE_DIR"/*.crt
sudo chown -R root:root "$CA_STAGE_DIR"

# Prune server certs for VMs that shouldn't hold them
case "$VM_NAME" in
  harbor) sudo rm -f "$CA_STAGE_DIR/gitea.crt" "$CA_STAGE_DIR/gitea.key" ;;
  gitea)  sudo rm -f "$CA_STAGE_DIR/harbor.crt" "$CA_STAGE_DIR/harbor.key" ;;
  *)      sudo rm -f "$CA_STAGE_DIR/harbor.crt" "$CA_STAGE_DIR/harbor.key" \
                      "$CA_STAGE_DIR/gitea.crt"  "$CA_STAGE_DIR/gitea.key" ;;
esac

# System trust
sudo install -m 0644 "$CA_STAGE_DIR/ca.crt" "$CA_SYSTEM_PATH"
sudo update-ca-certificates --fresh 2>&1 | tail -3

# Point resolver at infra dnsmasq for *.airgap.local (and as primary DNS)
sudo mkdir -p /etc/systemd/resolved.conf.d
cat <<EOF | sudo tee /etc/systemd/resolved.conf.d/airgap.conf >/dev/null
[Resolve]
DNS=$DNS_IP
Domains=airgap.local ~airgap.local
EOF
sudo systemctl restart systemd-resolved

# Verify resolution + trust
getent hosts harbor.airgap.local || true
echo "[ok] $VM_NAME"
rm -f "$TAR_PATH"
REMOTE
)

# Iterate over every VM except infra itself (infra already has the originals).
while IFS=: read -r NAME IP _REST; do
  [[ "$NAME" =~ ^# ]] && continue
  [[ -z "$NAME" ]] && continue
  [[ "$NAME" == "infra" ]] && continue

  echo
  echo "==> $NAME ($IP)"
  scp "${SSH_OPTS[@]}" "$STAGE/airgap-certs.tgz" airgap@"$IP":/tmp/
  ssh "${SSH_OPTS[@]}" airgap@"$IP" "bash -s $NAME $DNS_IP" <<<"$VM_APPLY"
done < "$SPEC_FILE"

# infra VM: make sure its own systemd trust also knows the CA (it generated it,
# but /etc/ssl/certs bundle doesn't automatically include /etc/airgap-ca/ca.crt).
echo
echo "==> infra (self-install of CA into system trust)"
ssh "${SSH_OPTS[@]}" airgap@"$INFRA_IP" "sudo install -m 0644 /etc/airgap-ca/ca.crt /usr/local/share/ca-certificates/airgap-ca.crt && sudo update-ca-certificates --fresh 2>&1 | tail -2"

echo
echo "==> Distribution complete."
