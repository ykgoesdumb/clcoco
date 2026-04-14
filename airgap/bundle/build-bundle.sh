#!/usr/bin/env bash
# Producer-side: assembles the offline install bundle.
# Meant to run on a Linux machine with internet (GitHub Actions runner, dev box).
# Requires: podman or docker, curl, tar, cargo (for the vendor step).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AIRGAP_DIR="$REPO_ROOT/airgap"

VERSION="${VERSION:-0.1.1}"
K3S_VERSION="${K3S_VERSION:-v1.31.3+k3s1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.3}"
ARGO_VERSION="${ARGO_VERSION:-v2.12.3}"
STAGE_ROOT="${STAGE_ROOT:-$SCRIPT_DIR/dist}"
STAGE="$STAGE_ROOT/clcoco-bundle-$VERSION"
OUT_TGZ="$STAGE_ROOT/clcoco-bundle-$VERSION.tgz"

CRI="${CRI:-podman}"
if ! command -v "$CRI" >/dev/null 2>&1; then
    CRI=docker
fi

APP_IMAGES=(
    "docker.io/eclipse-mosquitto:2"
    "docker.io/timescale/timescaledb:latest-pg16"
    "docker.io/grafana/grafana:11.1.0"
)
EDGE_AGENT_IMAGE="localhost/edge-agent:$VERSION"

echo "==> staging at $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{lib,k3s,images,manifests/edge-demo,platform,src,docs}

echo "==> [1/6] copying installer scripts"
install -m 0755 "$SCRIPT_DIR/install.sh"   "$STAGE/install.sh"
install -m 0755 "$SCRIPT_DIR/uninstall.sh" "$STAGE/uninstall.sh"
install -m 0755 "$SCRIPT_DIR"/lib/*.sh     "$STAGE/lib/"
install -m 0644 "$SCRIPT_DIR/README.md"    "$STAGE/README.md"

echo "==> [2/6] fetching k3s $K3S_VERSION"
curl -fsSL -o "$STAGE/k3s/k3s" \
    "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s"
chmod +x "$STAGE/k3s/k3s"
curl -fsSL -o "$STAGE/k3s/airgap-images.tar.zst" \
    "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst"
curl -fsSL -o "$STAGE/k3s/install.sh" \
    "https://get.k3s.io"
chmod +x "$STAGE/k3s/install.sh"

echo "==> [3/6] building edge-agent image"
(
    cd "$AIRGAP_DIR/edge-agent"
    cargo fetch
    cargo vendor > .cargo/config.toml
    "$CRI" build -t "$EDGE_AGENT_IMAGE" -f Containerfile .
)

echo "==> [4/7] fetching platform manifests (cert-manager $CERT_MANAGER_VERSION, ArgoCD $ARGO_VERSION)"
curl -fsSL -o "$STAGE/platform/cert-manager.yaml" \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
curl -fsSL -o "$STAGE/platform/argocd.yaml" \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"
cp "$AIRGAP_DIR/k8s/platform/cert-manager/clusterissuer.yaml" "$STAGE/platform/"
cp "$AIRGAP_DIR/k8s/platform/argocd/ingress.yaml"             "$STAGE/platform/argocd-ingress.yaml"

# Harvest image refs straight from the manifests we just fetched so the
# offline image set stays in lockstep with the manifest versions.
mapfile -t PLATFORM_IMAGES < <(
    grep -hE '^\s*image:' "$STAGE/platform/cert-manager.yaml" "$STAGE/platform/argocd.yaml" \
        | awk '{print $2}' | tr -d '"' | sort -u
)
echo "    ${#PLATFORM_IMAGES[@]} platform image(s) referenced"

echo "==> [5/7] pulling & saving app + platform images"
for img in "${APP_IMAGES[@]}" "${PLATFORM_IMAGES[@]}"; do
    # Flatten registry path into a safe filename (slashes/colons -> dashes).
    safe="$(echo "$img" | tr '/:' '-' )"
    echo "    $img"
    "$CRI" pull "$img"
    "$CRI" save -o "$STAGE/images/${safe}.tar" "$img"
done
"$CRI" save -o "$STAGE/images/edge-agent-${VERSION}.tar" "$EDGE_AGENT_IMAGE"

echo "==> [6/7] copying manifests + Rust source (with vendor)"
# Base manifests from the lab stack (skip 40-bridge.yaml — replaced by Rust edge-agent).
for f in 00-namespace 10-mosquitto 20-timescaledb 30-sensor-sim 41-edge-agent 50-grafana; do
    cp "$AIRGAP_DIR/k8s/edge-demo/${f}.yaml" "$STAGE/manifests/edge-demo/"
done
# Bundle-specific overlays (if any).
shopt -s nullglob
for f in "$SCRIPT_DIR"/manifests/edge-demo/*.yaml; do
    cp "$f" "$STAGE/manifests/edge-demo/"
done
shopt -u nullglob

mkdir -p "$STAGE/src/edge-agent"
cp -r "$AIRGAP_DIR"/edge-agent/{Cargo.toml,Cargo.lock,Containerfile,src,vendor,.cargo} \
      "$STAGE/src/edge-agent/"

echo "==> [7/7] tar $OUT_TGZ"
tar czf "$OUT_TGZ" -C "$STAGE_ROOT" "$(basename "$STAGE")"

echo
echo "bundle: $OUT_TGZ"
du -h "$OUT_TGZ"
