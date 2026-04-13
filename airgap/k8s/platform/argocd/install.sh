#!/usr/bin/env bash
# install.sh — deploy Argo CD to the airgap k3s cluster with TLS-terminating
# Traefik Ingress backed by cert-manager (airgap-ca ClusterIssuer).
#
# Prerequisite: cert-manager installed + airgap-ca ClusterIssuer Ready.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/../../../scripts/bootstrap-net.sh"

MASTER_IP=192.168.10.20
NODES=(k3s-master k3s-worker1 k3s-worker2)
ARGO_VERSION="${ARGO_VERSION:-v2.12.3}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
ssh_node() { ssh "${SSH_OPTS[@]}" airgap@"$1" "$2"; }
KUBE()     { ssh_node "$MASTER_IP" "sudo kubectl $*"; }

echo "==> [1/5] Checking prerequisite: cert-manager ClusterIssuer airgap-ca"
if ! KUBE get clusterissuer airgap-ca -o jsonpath='{.status.conditions[0].status}' 2>/dev/null | grep -q True; then
  echo "ERROR: ClusterIssuer airgap-ca not Ready. Run cert-manager/install.sh first." >&2
  exit 1
fi

echo "==> [2/5] Opening temp egress on 3 k3s nodes"
for n in "${NODES[@]}"; do "$BOOTSTRAP" on "$n"; done
sleep 3

echo "==> [3/5] Installing Argo CD $ARGO_VERSION"
KUBE get ns argocd 2>/dev/null || KUBE create ns argocd
KUBE apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"

echo "    applying insecure-mode ConfigMap + Ingress"
scp "${SSH_OPTS[@]}" -q "$SCRIPT_DIR/ingress.yaml" airgap@"$MASTER_IP":/tmp/argocd-ingress.yaml
KUBE apply -f /tmp/argocd-ingress.yaml

# Restart argocd-server so it picks up server.insecure=true from ConfigMap
KUBE -n argocd rollout restart deploy/argocd-server

echo "    waiting for rollout… (image pulls may take a few minutes)"
KUBE -n argocd rollout status deploy/argocd-server               --timeout=600s
KUBE -n argocd rollout status deploy/argocd-repo-server          --timeout=600s
KUBE -n argocd rollout status deploy/argocd-redis                --timeout=600s
KUBE -n argocd rollout status deploy/argocd-dex-server           --timeout=600s
KUBE -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

echo "==> [4/5] Waiting for TLS cert issuance (cert-manager → airgap-ca)"
for _ in {1..60}; do
  if KUBE -n argocd get secret argocd-tls 2>/dev/null | grep -q 'kubernetes.io/tls'; then
    break
  fi
  sleep 2
done
KUBE -n argocd get certificate argocd-tls || true

echo "==> [5/5] Closing egress"
for n in "${NODES[@]}"; do "$BOOTSTRAP" off "$n"; done

echo
echo "==> Argo CD up"
KUBE -n argocd get pods
PW=$(KUBE -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
echo
echo "==> URL:      https://argocd.apps.airgap.local/"
echo "==> Username: admin"
echo "==> Password: $PW"
echo "    (rotate with: argocd account update-password, then delete argocd-initial-admin-secret)"
