#!/usr/bin/env bash
# Stage 3: kubectl apply all manifests, wait for edge-demo rollout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFESTS_DIR="$BUNDLE_DIR/manifests"

echo "==> [3/3] applying manifests"

k3s kubectl apply -R -f "$MANIFESTS_DIR"

echo "    waiting for edge-demo rollouts…"
k3s kubectl -n edge-demo rollout status deploy/mosquitto         --timeout=180s
k3s kubectl -n edge-demo rollout status statefulset/timescaledb  --timeout=300s
k3s kubectl -n edge-demo rollout status statefulset/sensor-sim   --timeout=180s
k3s kubectl -n edge-demo rollout status deploy/edge-agent        --timeout=180s
k3s kubectl -n edge-demo rollout status deploy/grafana           --timeout=180s
