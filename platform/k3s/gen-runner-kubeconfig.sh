#!/bin/bash
# Build a minimal kubeconfig for the gitea-runner ServiceAccount and print
# it base64-encoded so the Gitea team can paste it into the KUBECONFIG secret.
#
# Run on the k3s master (or any host with cluster-admin kubeconfig).
# Requires: gitea-runner-rbac.yaml already applied.
#
# Usage:
#   ./gen-runner-kubeconfig.sh               # prints base64 to stdout
#   ./gen-runner-kubeconfig.sh /tmp/kc.b64   # writes to file
#
# Env overrides:
#   APISERVER — cluster endpoint (default: auto from current-context)
#   CA_FILE   — cluster CA PEM  (default: /opt/airgap-ca/ca.crt if present, else from k3s.yaml)

set -euo pipefail

OUT="${1:-}"
NS=apps
SA=gitea-runner
SECRET=gitea-runner-token

KUBECTL="${KUBECTL:-kubectl}"

# Pull SA token. The Secret created by gitea-runner-rbac.yaml is populated by k8s async;
# retry briefly in case this runs right after apply.
for _ in 1 2 3 4 5; do
    TOKEN="$($KUBECTL -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
    [[ -n "$TOKEN" ]] && break
    sleep 2
done
if [[ -z "${TOKEN:-}" ]]; then
    echo "오류: $NS/$SECRET 에 token 없음 — gitea-runner-rbac.yaml 적용됐는지 확인" >&2
    exit 1
fi

APISERVER="${APISERVER:-$($KUBECTL config view --minify -o jsonpath='{.clusters[0].cluster.server}')}"

if [[ -z "${CA_FILE:-}" ]]; then
    if [[ -r /opt/airgap-ca/ca.crt ]]; then
        CA_FILE=/opt/airgap-ca/ca.crt
    else
        CA_FILE="$(mktemp)"
        trap 'rm -f "$CA_FILE"' EXIT
        $KUBECTL config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$CA_FILE"
    fi
fi
CA_B64="$(base64 < "$CA_FILE" | tr -d '\n')"

KUBECONFIG_YAML=$(cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: airgap
    cluster:
      server: ${APISERVER}
      certificate-authority-data: ${CA_B64}
contexts:
  - name: gitea-runner
    context:
      cluster: airgap
      namespace: ${NS}
      user: gitea-runner
current-context: gitea-runner
users:
  - name: gitea-runner
    user:
      token: ${TOKEN}
EOF
)

ENCODED="$(printf '%s\n' "$KUBECONFIG_YAML" | base64 | tr -d '\n')"

if [[ -n "$OUT" ]]; then
    printf '%s' "$ENCODED" > "$OUT"
    echo "wrote $OUT ($(wc -c < "$OUT") bytes, base64)"
else
    printf '%s\n' "$ENCODED"
fi
