#!/usr/bin/env bash
# Build the Rust edge-agent image on the libvirt host (which has internet
# via Tailscale) and import it into all k3s nodes' containerd image stores.
#
# Lab-only convenience: skips the vendor/ flow used by the offline bundle
# (see ../bundle/build-bundle.sh for the airgap-pure path).
set -euo pipefail

IMAGE="${IMAGE:-localhost/edge-agent:0.2.0}"
HOST_USER="${HOST_USER:-ykgoesdumb}"           # ssh alias for the libvirt host
REMOTE_DIR="${REMOTE_DIR:-/tmp/edge-agent-build}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/edge-agent"

echo "==> [1/4] rsync source to $HOST_USER:$REMOTE_DIR"
ssh -o ExitOnForwardFailure=no "$HOST_USER" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
rsync -az -e 'ssh -o ExitOnForwardFailure=no' --exclude target --exclude vendor "$SRC/" "$HOST_USER:$REMOTE_DIR/"

echo "==> [2/4] docker build $IMAGE on $HOST_USER (online)"
ssh -o ExitOnForwardFailure=no "$HOST_USER" "cd $REMOTE_DIR && docker build -t $IMAGE -f Containerfile.dev ."

echo "==> [3/4] save → /tmp/edge-agent.tar"
ssh -o ExitOnForwardFailure=no "$HOST_USER" "docker save -o /tmp/edge-agent.tar $IMAGE && ls -lh /tmp/edge-agent.tar"

echo "==> [4/4] distribute to k3s nodes"
ssh -o ExitOnForwardFailure=no "$HOST_USER" "IMAGE=$IMAGE TAR=/tmp/edge-agent.tar bash -s" < "$REPO_ROOT/scripts/import-edge-agent.sh"

echo
echo "==> $IMAGE is now in every k3s node's containerd image store"
echo "    Trigger a rollout if the deployment is already running:"
echo "      kubectl --context=airgap -n edge-demo rollout restart deploy/edge-agent"
