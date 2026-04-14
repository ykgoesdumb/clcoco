#!/usr/bin/env bash
# Stage 1: install k3s in airgap mode on this host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
K3S_DIR="$BUNDLE_DIR/k3s"

echo "==> [1/3] k3s airgap install"

if command -v k3s >/dev/null 2>&1; then
    echo "    k3s already present — skipping install"
else
    install -m 0755 "$K3S_DIR/k3s" /usr/local/bin/k3s

    install -d -m 0755 /var/lib/rancher/k3s/agent/images
    install -m 0644 "$K3S_DIR/airgap-images.tar.zst" \
        /var/lib/rancher/k3s/agent/images/airgap-images.tar.zst

    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" \
        sh "$K3S_DIR/install.sh"
fi

ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl

echo "    waiting for node Ready…"
for _ in $(seq 1 60); do
    if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
        echo "    node Ready"
        exit 0
    fi
    sleep 2
done
echo "    node did not become Ready in 120s" >&2
exit 1
