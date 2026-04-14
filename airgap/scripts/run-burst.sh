#!/usr/bin/env bash
# Trigger the burst Job in edge-demo. Re-runnable: deletes any prior Job first.
# Watches until completion. Use this during the demo while the comparison
# dashboard is on screen — Python p99/in_flight will spike, Rust will stay flat.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOB_YAML="$REPO_ROOT/k8s/edge-demo/60-burst-job.yaml"
NS=edge-demo
CTX="${KUBECTL_CONTEXT:-airgap}"
KUBE() { kubectl --context="$CTX" -n "$NS" "$@"; }

echo "==> deleting prior burst Job (if any)"
KUBE delete job burst --ignore-not-found

echo "==> applying $JOB_YAML"
KUBE apply -f "$JOB_YAML"

echo "==> waiting for burst pod"
KUBE wait --for=condition=ready pod -l app=burst --timeout=60s || true
KUBE logs -f -l app=burst --tail=-1
