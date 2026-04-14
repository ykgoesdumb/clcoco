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
"$SCRIPT_DIR/lib/25-platform.sh"
"$SCRIPT_DIR/lib/30-apply-manifests.sh"

NODE_IP="$(hostname -I | awk '{print $1}')"
ARGO_PW="$(k3s kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

cat <<EOF

==============================================
 install complete
==============================================
 Node IP:              ${NODE_IP}
 kubeconfig:           /etc/rancher/k3s/k3s.yaml
 kubectl:              /usr/local/bin/kubectl (symlinked to k3s)

 Grafana (HTTPS):      https://grafana.apps.airgap.local/
 ArgoCD  (HTTPS):      https://argocd.apps.airgap.local/
                       user=admin  pass=${ARGO_PW:-<see argocd-initial-admin-secret>}

 Add to client /etc/hosts so hostnames resolve:
   ${NODE_IP}  grafana.apps.airgap.local  argocd.apps.airgap.local

 Trust CA on client (optional, to avoid -k):
   scp root@${NODE_IP}:/etc/airgap-ca/ca.crt /usr/local/share/ca-certificates/airgap-ca.crt
   sudo update-ca-certificates

 Verify:
   sudo k3s kubectl -n edge-demo get pods
   sudo k3s kubectl -n argocd       get pods
EOF
