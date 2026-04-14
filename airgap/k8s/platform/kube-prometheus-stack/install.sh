#!/usr/bin/env bash
# install.sh — install kube-prometheus-stack on the airgap k3s cluster via
# the built-in helm-controller. Opens temporary egress for the duration of
# the chart pull + image pulls, then closes it.
#
# Result: Grafana exposed at https://grafana.apps.airgap.local/ (admin/admin)
# replacing the standalone edge-demo Grafana. Prometheus discovers the
# bridge ServiceMonitors automatically (selector NilUsesHelmValues = false).
#
# Prerequisite: cert-manager + airgap-ca ClusterIssuer Ready (Grafana ingress
# uses it for TLS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/../../../scripts/bootstrap-net.sh"

MASTER_IP=192.168.10.20
NODES=(k3s-master k3s-worker1 k3s-worker2)

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
ssh_node() { ssh "${SSH_OPTS[@]}" airgap@"$1" "$2"; }
KUBE()     { ssh_node "$MASTER_IP" "sudo kubectl $*"; }

echo "==> [1/5] Checking prerequisite: cert-manager ClusterIssuer airgap-ca"
if ! KUBE get clusterissuer airgap-ca -o jsonpath='{.status.conditions[0].status}' 2>/dev/null | grep -q True; then
  echo "ERROR: ClusterIssuer airgap-ca not Ready. Run cert-manager/install.sh first." >&2
  exit 1
fi

echo "==> [2/5] Opening temp egress on 3 k3s nodes (chart + image pulls)"
for n in "${NODES[@]}"; do "$BOOTSTRAP" on "$n"; done
sleep 3

echo "==> [3/5] Applying HelmChart"
scp "${SSH_OPTS[@]}" -q "$SCRIPT_DIR/helmchart.yaml" airgap@"$MASTER_IP":/tmp/kps.yaml
KUBE apply -f /tmp/kps.yaml

echo "    waiting for helm-controller to finish helm install (up to 8 min)…"
for _ in {1..96}; do
  if KUBE -n monitoring get deploy kps-grafana >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

echo "==> [4/5] Waiting for rollouts"
KUBE -n monitoring rollout status deploy/kps-grafana                                  --timeout=600s
KUBE -n monitoring rollout status deploy/kps-kube-state-metrics                       --timeout=600s
KUBE -n monitoring rollout status deploy/kps-operator                                 --timeout=600s
KUBE -n monitoring rollout status statefulset/prometheus-kps-prometheus               --timeout=900s
KUBE -n monitoring rollout status statefulset/alertmanager-kps-alertmanager           --timeout=600s

echo "    waiting for Grafana TLS secret"
for _ in {1..60}; do
  if KUBE -n monitoring get secret grafana-tls 2>/dev/null | grep -q 'kubernetes.io/tls'; then
    break
  fi
  sleep 2
done

echo "==> [5/5] Closing egress"
for n in "${NODES[@]}"; do "$BOOTSTRAP" off "$n"; done

echo
echo "==> kube-prometheus-stack up"
KUBE -n monitoring get pods
echo
echo "==> Grafana:    https://grafana.apps.airgap.local/   (admin / admin)"
echo "==> Prometheus: kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090"
