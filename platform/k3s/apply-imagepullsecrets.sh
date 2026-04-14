#!/bin/bash
# Create Harbor imagePullSecret in every namespace that pulls from Harbor.
# Thin wrapper around platform/harbor/manifests/create-imagepullsecret.sh.
#
# Usage:
#   HARBOR_TOKEN='<robot$k3s-puller password>' ./apply-imagepullsecrets.sh
#
# Env overrides:
#   NAMESPACES — space-separated list (default: apps edge-demo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../harbor/manifests/create-imagepullsecret.sh"

TOKEN="${HARBOR_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
    echo "오류: HARBOR_TOKEN 환경변수 필요" >&2
    exit 2
fi

NAMESPACES="${NAMESPACES:-apps edge-demo}"

for ns in $NAMESPACES; do
    kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
    echo "==> harbor-pull-secret → $ns"
    bash "$HELPER" "$TOKEN" "$ns"
done
