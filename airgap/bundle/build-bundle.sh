#!/usr/bin/env bash
# Producer-side: assembles the offline install bundle.
# Meant to run on a Linux machine with internet (GitHub Actions runner, dev box).
# Requires: podman or docker, curl, tar, cargo (for the vendor step).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AIRGAP_DIR="$REPO_ROOT/airgap"
PLATFORM_DIR_REPO="$REPO_ROOT/platform"

VERSION="${VERSION:-0.1.1}"
K3S_VERSION="${K3S_VERSION:-v1.31.3+k3s1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.3}"
ARGO_VERSION="${ARGO_VERSION:-v2.12.3}"
HARBOR_VERSION="${HARBOR_VERSION:-v2.10.2}"
STAGE_ROOT="${STAGE_ROOT:-$SCRIPT_DIR/dist}"
STAGE="$STAGE_ROOT/clcoco-bundle-$VERSION"
OUT_TGZ="$STAGE_ROOT/clcoco-bundle-$VERSION.tgz"

CRI="${CRI:-podman}"
if ! command -v "$CRI" >/dev/null 2>&1; then
    CRI=docker
fi

# Direct-into-k3s app images (loaded by install.sh lib/20-load-images.sh).
# Kept independent of Harbor so the edge-demo comes up BEFORE Harbor is ready.
APP_IMAGES=(
    "docker.io/eclipse-mosquitto:2"
    "docker.io/timescale/timescaledb:latest-pg16"
    "docker.io/grafana/grafana:11.1.0"
)
EDGE_AGENT_IMAGE="localhost/edge-agent:$VERSION"

# Catalog of images the team later pushes into Harbor mirror/.
# Single source of truth: platform/harbor/images/IMAGES.txt.
IMAGES_TXT="$PLATFORM_DIR_REPO/harbor/images/IMAGES.txt"

echo "==> staging at $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{lib,k3s,images,manifests/edge-demo,platform,src,docs}

echo "==> [1/10] copying installer scripts"
install -m 0755 "$SCRIPT_DIR/install.sh"   "$STAGE/install.sh"
install -m 0755 "$SCRIPT_DIR/uninstall.sh" "$STAGE/uninstall.sh"
install -m 0755 "$SCRIPT_DIR"/lib/*.sh     "$STAGE/lib/"
install -m 0644 "$SCRIPT_DIR/README.md"    "$STAGE/README.md"

echo "==> [2/10] fetching k3s $K3S_VERSION"
curl -fsSL -o "$STAGE/k3s/k3s" \
    "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s"
chmod +x "$STAGE/k3s/k3s"
curl -fsSL -o "$STAGE/k3s/airgap-images.tar.zst" \
    "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst"
curl -fsSL -o "$STAGE/k3s/install.sh" \
    "https://get.k3s.io"
chmod +x "$STAGE/k3s/install.sh"

echo "==> [3/10] building edge-agent image"
(
    cd "$AIRGAP_DIR/edge-agent"
    cargo fetch
    cargo vendor > .cargo/config.toml
    "$CRI" build -t "$EDGE_AGENT_IMAGE" -f Containerfile .
)

echo "==> [4/10] fetching platform manifests (cert-manager $CERT_MANAGER_VERSION, ArgoCD $ARGO_VERSION)"
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

echo "==> [5/10] pulling & saving app + platform images (direct-to-k3s)"
for img in "${APP_IMAGES[@]}" "${PLATFORM_IMAGES[@]}"; do
    # Flatten registry path into a safe filename (slashes/colons -> dashes).
    safe="$(echo "$img" | tr '/:' '-' )"
    echo "    $img"
    "$CRI" pull "$img"
    "$CRI" save -o "$STAGE/images/${safe}.tar" "$img"
done
"$CRI" save -o "$STAGE/images/edge-agent-${VERSION}.tar" "$EDGE_AGENT_IMAGE"

echo "==> [6/10] copying platform/ scripts (harbor, gitea, k3s)"
for d in harbor gitea k3s; do
    src="$PLATFORM_DIR_REPO/$d"
    if [[ -d "$src" ]]; then
        mkdir -p "$STAGE/platform/$d"
        cp -r "$src"/. "$STAGE/platform/$d/"
        echo "    platform/$d → bundle"
    else
        echo "    platform/$d 없음 — 스킵 (담당자 작업 전)"
    fi
done

echo "==> [7/10] fetching Harbor offline installer $HARBOR_VERSION"
mkdir -p "$STAGE/platform/harbor/install"
curl -fsSL -o "$STAGE/platform/harbor/install/harbor-offline-installer-${HARBOR_VERSION}.tgz" \
    "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz"

echo "==> [8/10] pulling team mirror images from IMAGES.txt"
MIRROR_DIR="$STAGE/platform/harbor/mirror-images"
mkdir -p "$MIRROR_DIR"
mcount=0
if [[ -f "$IMAGES_TXT" ]]; then
    while IFS= read -r img || [[ -n "$img" ]]; do
        # Skip comments / blank lines (matches pull-all.sh / push-all.sh filter).
        [[ "$img" =~ ^#|^[[:space:]]*$ ]] && continue
        # Use the SAME filename encoding as platform/harbor/images/pull-all.sh.
        # push-all.sh joins IMAGES.txt + this encoding to locate tars — keep lockstep.
        fname=$(echo "$img" | tr '/: ' '_').tar
        echo "    $img"
        "$CRI" pull "$img" >/dev/null
        "$CRI" save -o "$MIRROR_DIR/$fname" "$img"
        mcount=$((mcount + 1))
    done < "$IMAGES_TXT"
    # Ship IMAGES.txt alongside tars so push-all.sh has its single source of truth.
    cp "$IMAGES_TXT" "$MIRROR_DIR/IMAGES.txt"
fi
echo "    $mcount mirror image(s) staged for Harbor push"

echo "==> [9/10] copying manifests + Rust source (with vendor)"
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

echo "==> [10/10] tar $OUT_TGZ"
tar czf "$OUT_TGZ" -C "$STAGE_ROOT" "$(basename "$STAGE")"

echo
echo "bundle: $OUT_TGZ"
du -h "$OUT_TGZ"
