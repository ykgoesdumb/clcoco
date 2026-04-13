#!/usr/bin/env bash
# Airgap install entry.
# Runs the three stages in order: k3s → image load → manifest apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "must run as root (try: sudo $0)" >&2
    exit 1
fi

"$SCRIPT_DIR/lib/10-k3s.sh"
"$SCRIPT_DIR/lib/20-load-images.sh"
"$SCRIPT_DIR/lib/30-apply-manifests.sh"

NODE_IP="$(hostname -I | awk '{print $1}')"

cat <<EOF

==============================================
 install complete
==============================================
 Grafana (NodePort):  http://${NODE_IP}:30080/
 kubeconfig:          /etc/rancher/k3s/k3s.yaml
 kubectl:             /usr/local/bin/kubectl (symlinked to k3s)

 Verify:
   sudo k3s kubectl -n edge-demo get pods
EOF
