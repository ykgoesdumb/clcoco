#!/bin/bash
# Producer-side helper: collect docker-ce .deb + deps into ./docker-debs/.
# Runs on any host with docker/podman (macOS OK — we use a Linux container).
# build-bundle.sh copies this directory into $STAGE/docker/ when present.
#
# Why: Harbor VM install-on-vm.sh needs /opt/offline-bundle/docker/*.deb when
# egress is truly closed. With bootstrap-net the online apt path works too, so
# this helper is optional — run it before bundling if you want belt-and-suspenders.
#
# Usage:
#   ./fetch-docker-debs.sh                    # defaults to ubuntu 24.04 (noble)
#   UBUNTU_CODENAME=jammy ./fetch-docker-debs.sh
#
# Output:
#   platform/harbor/install/docker-debs/*.deb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/docker-debs"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-noble}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
[[ "$UBUNTU_CODENAME" == "jammy" ]] && UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:22.04}"

CRI="${CRI:-podman}"
if ! command -v "$CRI" >/dev/null 2>&1; then
    CRI=docker
fi

mkdir -p "$OUT"
echo "==> fetching docker-ce debs for Ubuntu $UBUNTU_CODENAME → $OUT"

"$CRI" run --rm -v "$OUT:/out" "$UBUNTU_IMAGE" bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg apt-utils
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo 'deb [arch='\$(dpkg --print-architecture)' signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $UBUNTU_CODENAME stable' \
    > /etc/apt/sources.list.d/docker.list
apt-get update -qq
mkdir -p /downloads
cd /downloads
apt-get download \$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances \
    docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    | grep '^\w' | sort -u)
cp /downloads/*.deb /out/
"

echo
echo "done — $(ls "$OUT"/*.deb 2>/dev/null | wc -l | tr -d ' ') deb(s) in $OUT"
