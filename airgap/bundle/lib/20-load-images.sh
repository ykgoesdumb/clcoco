#!/usr/bin/env bash
# Stage 2: load app container images into k3s containerd.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGES_DIR="$BUNDLE_DIR/images"

echo "==> [2/3] loading app images into containerd"

shopt -s nullglob
tars=("$IMAGES_DIR"/*.tar)
if [[ ${#tars[@]} -eq 0 ]]; then
    echo "    no image tars under $IMAGES_DIR — aborting" >&2
    exit 1
fi

for tar in "${tars[@]}"; do
    echo "    importing $(basename "$tar")"
    k3s ctr images import "$tar"
done

echo "    ${#tars[@]} image tar(s) imported"
