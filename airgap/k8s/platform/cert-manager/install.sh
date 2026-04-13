#!/usr/bin/env bash
# install.sh — deploy cert-manager to the airgap k3s cluster and wire our
# private Root CA as a ClusterIssuer. Run from the host.
#
# Result: any Ingress/Certificate with
#   annotations: cert-manager.io/cluster-issuer: airgap-ca
# gets a leaf cert signed by /etc/airgap-ca/ca.{crt,key} on the infra VM.
# All VMs already trust that CA (distribute-ca.sh), so browsers see green.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/../../../scripts/bootstrap-net.sh"

MASTER_IP=192.168.10.20
INFRA_IP=192.168.10.10
NODES=(k3s-master k3s-worker1 k3s-worker2)
CM_VERSION="${CM_VERSION:-v1.15.3}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
ssh_node() { ssh "${SSH_OPTS[@]}" airgap@"$1" "$2"; }
KUBE()     { ssh_node "$MASTER_IP" "sudo kubectl $*"; }

echo "==> [1/6] Pulling CA keypair from infra VM ($INFRA_IP)"
CA_TMP="$(mktemp -d)"
trap 'rm -rf "$CA_TMP"' EXIT
ssh_node "$INFRA_IP" "sudo cat /etc/airgap-ca/ca.crt" > "$CA_TMP/ca.crt"
ssh_node "$INFRA_IP" "sudo cat /etc/airgap-ca/ca.key" > "$CA_TMP/ca.key"
chmod 600 "$CA_TMP/ca.key"

echo "==> [2/6] Opening temp egress on 3 k3s nodes"
for n in "${NODES[@]}"; do "$BOOTSTRAP" on "$n"; done
sleep 3

echo "==> [3/6] Installing cert-manager $CM_VERSION"
KUBE apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CM_VERSION}/cert-manager.yaml"

echo "    waiting for rollout…"
KUBE -n cert-manager rollout status deploy/cert-manager            --timeout=300s
KUBE -n cert-manager rollout status deploy/cert-manager-webhook    --timeout=300s
KUBE -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s

echo "==> [4/6] Injecting CA keypair as Secret (cert-manager/airgap-ca-key-pair)"
scp "${SSH_OPTS[@]}" -q "$CA_TMP/ca.crt" "$CA_TMP/ca.key" airgap@"$MASTER_IP":/tmp/
ssh_node "$MASTER_IP" "sudo kubectl -n cert-manager create secret tls airgap-ca-key-pair \
    --cert=/tmp/ca.crt --key=/tmp/ca.key --dry-run=client -o yaml | sudo kubectl apply -f -; \
  sudo shred -u /tmp/ca.crt /tmp/ca.key 2>/dev/null || sudo rm -f /tmp/ca.crt /tmp/ca.key"

echo "==> [5/6] Applying ClusterIssuer"
scp "${SSH_OPTS[@]}" -q "$SCRIPT_DIR/clusterissuer.yaml" airgap@"$MASTER_IP":/tmp/
KUBE apply -f /tmp/clusterissuer.yaml

echo "    waiting for ClusterIssuer Ready…"
for _ in {1..30}; do
  if KUBE get clusterissuer airgap-ca -o jsonpath='{.status.conditions[0].status}' 2>/dev/null | grep -q True; then
    break
  fi
  sleep 2
done

echo "==> [6/6] Closing egress"
for n in "${NODES[@]}"; do "$BOOTSTRAP" off "$n"; done

echo
echo "==> Result"
KUBE get clusterissuer
echo
echo "==> Usage: annotate any Ingress with"
echo "     cert-manager.io/cluster-issuer: airgap-ca"
echo "     and add spec.tls: [{ hosts: [host], secretName: host-tls }]"
