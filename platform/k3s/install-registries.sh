#!/bin/bash
# Render registries.yaml on every k3s node and restart k3s.
# Run on the master VM (192.168.10.20) — reaches workers over the airgap LAN.
#
# Usage:
#   HARBOR_TOKEN='<robot$k3s-puller password>' ./install-registries.sh
#
# Env overrides:
#   NODES   — space-separated "host:role" pairs (default below)
#   SSH     — ssh command (default: ssh -o StrictHostKeyChecking=no)
#   USER    — remote user (default: airgap)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPL="$SCRIPT_DIR/registries.yaml.tmpl"

TOKEN="${HARBOR_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
    echo "오류: HARBOR_TOKEN 환경변수 필요 (robot\$k3s-puller 토큰)" >&2
    exit 2
fi

NODES="${NODES:-192.168.10.20:master 192.168.10.21:agent 192.168.10.22:agent}"
SSH="${SSH:-ssh -o StrictHostKeyChecking=no}"
REMOTE_USER="${USER:-airgap}"

RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
sed "s|@HARBOR_TOKEN@|${TOKEN//|/\\|}|g" "$TMPL" > "$RENDERED"

for entry in $NODES; do
    host="${entry%%:*}"
    role="${entry##*:}"
    svc="k3s"
    [[ "$role" == "agent" ]] && svc="k3s-agent"

    echo "==> $host ($role) → /etc/rancher/k3s/registries.yaml + restart $svc"
    $SSH "$REMOTE_USER@$host" "sudo mkdir -p /etc/rancher/k3s"
    scp -o StrictHostKeyChecking=no "$RENDERED" "$REMOTE_USER@$host:/tmp/registries.yaml"
    $SSH "$REMOTE_USER@$host" "sudo install -m 0600 /tmp/registries.yaml /etc/rancher/k3s/registries.yaml && sudo systemctl restart $svc && rm -f /tmp/registries.yaml"
done

echo
echo "완료. 검증:"
echo "  ssh $REMOTE_USER@<node> sudo crictl pull harbor.airgap.local/mirror/alpine:3.19"
