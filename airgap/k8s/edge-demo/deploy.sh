#!/usr/bin/env bash
# deploy.sh — apply edge-demo manifests to the airgap k3s cluster.
# Runs on the host. Opens temp egress on all 3 k3s nodes so image pulls
# and the bridge initContainer's pip install can complete, waits for
# rollouts, then closes egress again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/../../scripts/bootstrap-net.sh"

MASTER_IP=192.168.10.20
NODES=(k3s-master k3s-worker1 k3s-worker2)

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
KUBE() { ssh "${SSH_OPTS[@]}" airgap@"$MASTER_IP" "sudo kubectl $*"; }

echo "==> [1/4] Opening temp egress on 3 k3s nodes"
for n in "${NODES[@]}"; do "$BOOTSTRAP" on "$n"; done
sleep 3

echo "==> [2/4] Shipping manifests to master (excluding burst Job)"
ssh "${SSH_OPTS[@]}" airgap@"$MASTER_IP" "rm -rf /tmp/edge-demo && mkdir -p /tmp/edge-demo"
# 60-burst-job is on-demand only — see scripts/run-burst.sh
for f in "$SCRIPT_DIR"/*.yaml; do
  case "$(basename "$f")" in
    60-burst-job.yaml) continue ;;
  esac
  scp "${SSH_OPTS[@]}" -q "$f" airgap@"$MASTER_IP":/tmp/edge-demo/
done

echo "==> [3/4] Applying manifests"
KUBE apply -f /tmp/edge-demo/

echo "    waiting for rollouts…"
KUBE -n edge-demo rollout status deploy/mosquitto         --timeout=180s
KUBE -n edge-demo rollout status statefulset/timescaledb  --timeout=300s
KUBE -n edge-demo rollout status statefulset/sensor-sim   --timeout=180s
KUBE -n edge-demo rollout status deploy/mqtt-tsdb-bridge  --timeout=300s
KUBE -n edge-demo rollout status deploy/edge-agent        --timeout=300s

echo "==> [4/4] Closing egress"
for n in "${NODES[@]}"; do "$BOOTSTRAP" off "$n"; done

echo
echo "==> Pods"
KUBE -n edge-demo get pods -o wide
echo
echo "==> Recent readings"
KUBE -n edge-demo exec statefulset/timescaledb -- \
  psql -U edge -d sensors -c \
  "SELECT source, COUNT(*) AS n, MAX(ts) AS last FROM readings GROUP BY source ORDER BY source;" || true
echo
echo "==> Grafana:  https://grafana.apps.airgap.local/  (admin/admin)"
echo "    Dashboards: 'Factory Line 1', 'Bridge Comparison: Python vs Rust'"
echo "==> Burst:    airgap/scripts/run-burst.sh   (10K msgs, climax of demo)"
echo "==> MQTT:     mosquitto.edge-demo.svc:1883  (cluster-internal)"
