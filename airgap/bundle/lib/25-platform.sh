#!/usr/bin/env bash
# Stage 2.5: stand up the platform layer (cert-manager + ArgoCD) fully offline.
#
# 1. Generate a self-signed Root CA if none is present at /etc/airgap-ca/.
# 2. Apply cert-manager (manifest snapshot in $BUNDLE_DIR/platform/).
# 3. Inject the CA keypair as a TLS secret and create the `airgap-ca` ClusterIssuer.
# 4. Apply ArgoCD + Ingress (TLS terminated by Traefik, cert issued by airgap-ca).
#
# Idempotent: re-running is safe — reuses existing CA, `apply` is declarative.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_DIR="$BUNDLE_DIR/platform"
CA_DIR=/etc/airgap-ca

KC=(k3s kubectl)

echo "==> [2.5/4] platform layer (cert-manager + ArgoCD)"

# --- 1) Root CA (self-signed, 10y) -------------------------------------------
if [[ ! -s "$CA_DIR/ca.crt" || ! -s "$CA_DIR/ca.key" ]]; then
    echo "    generating self-signed Root CA at $CA_DIR"
    install -d -m 0755 "$CA_DIR"
    openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
        -subj "/C=KR/O=Airgap Hackathon/CN=Airgap Hackathon Root CA" \
        -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" >/dev/null 2>&1
    chmod 600 "$CA_DIR/ca.key"
    chmod 644 "$CA_DIR/ca.crt"

    # Host trust so curl/kubectl on this box see a green cert.
    install -m 0644 "$CA_DIR/ca.crt" /usr/local/share/ca-certificates/airgap-ca.crt
    update-ca-certificates >/dev/null
else
    echo "    reusing existing CA at $CA_DIR"
fi

# --- 2) cert-manager ---------------------------------------------------------
echo "    applying cert-manager manifest"
"${KC[@]}" apply -f "$PLATFORM_DIR/cert-manager.yaml"

echo "    waiting for cert-manager rollout"
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
    "${KC[@]}" -n cert-manager rollout status deploy/"$d" --timeout=300s
done

# --- 3) CA secret + ClusterIssuer -------------------------------------------
echo "    creating airgap-ca-key-pair secret"
"${KC[@]}" -n cert-manager create secret tls airgap-ca-key-pair \
    --cert="$CA_DIR/ca.crt" --key="$CA_DIR/ca.key" \
    --dry-run=client -o yaml | "${KC[@]}" apply -f -

echo "    applying ClusterIssuer"
"${KC[@]}" apply -f "$PLATFORM_DIR/clusterissuer.yaml"

for _ in $(seq 1 30); do
    if "${KC[@]}" get clusterissuer airgap-ca \
        -o jsonpath='{.status.conditions[0].status}' 2>/dev/null | grep -q True; then
        break
    fi
    sleep 2
done

# --- 4) ArgoCD ---------------------------------------------------------------
echo "    applying ArgoCD manifest"
"${KC[@]}" get ns argocd >/dev/null 2>&1 || "${KC[@]}" create ns argocd
"${KC[@]}" apply -n argocd -f "$PLATFORM_DIR/argocd.yaml"

echo "    applying ArgoCD ingress + server.insecure ConfigMap"
"${KC[@]}" apply -f "$PLATFORM_DIR/argocd-ingress.yaml"

# Pick up insecure=true so Traefik terminates TLS without a double-handshake.
"${KC[@]}" -n argocd rollout restart deploy/argocd-server >/dev/null

echo "    waiting for ArgoCD rollout (image pulls may take a minute)"
for d in argocd-server argocd-repo-server argocd-redis argocd-dex-server \
         argocd-applicationset-controller argocd-notifications-controller; do
    "${KC[@]}" -n argocd rollout status deploy/"$d" --timeout=600s
done
"${KC[@]}" -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

echo "    platform layer up"
