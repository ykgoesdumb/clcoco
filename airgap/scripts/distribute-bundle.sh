#!/usr/bin/env bash
# Push the bundle tgz to every target VM and unpack into /opt/offline-bundle/.
# Runs on the host machine that owns the VMs (same box that built the bundle).
#
# Uses the internal LAN IPs from airgap/docs/TEAM-ACCESS.md §2 (192.168.10.x),
# not the Tailscale port-forwards — assumes this runs on the VM host itself.
#
# Usage:
#   airgap/scripts/distribute-bundle.sh                    # picks newest dist/*.tgz
#   airgap/scripts/distribute-bundle.sh path/to/bundle.tgz
#
# Env overrides:
#   TARGETS — space-separated "<short>:<ip>" pairs
#             (default: harbor:192.168.10.12 gitea:192.168.10.11 k3s-master:192.168.10.20 infra:192.168.10.10)
#   USER    — remote user (default: airgap)
#   REMOTE  — unpack directory on each VM (default: /opt/offline-bundle)
#   SSH     — ssh command (default: ssh with airgap defaults)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/bundle/dist"

TGZ="${1:-}"
if [[ -z "$TGZ" ]]; then
    TGZ=$(ls -t "$DIST_DIR"/clcoco-bundle-*.tgz 2>/dev/null | head -1 || true)
    if [[ -z "$TGZ" ]]; then
        echo "오류: $DIST_DIR/clcoco-bundle-*.tgz 없음 — airgap/bundle/build-bundle.sh 먼저 실행" >&2
        exit 1
    fi
fi
[[ -f "$TGZ" ]] || { echo "오류: $TGZ 파일 없음" >&2; exit 1; }

TARGETS="${TARGETS:-harbor:192.168.10.12 gitea:192.168.10.11 k3s-master:192.168.10.20 infra:192.168.10.10}"
REMOTE_USER="${USER:-airgap}"
REMOTE="${REMOTE:-/opt/offline-bundle}"
SSH="${SSH:-ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR}"
SCP="${SCP:-scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR}"

TGZ_BASENAME=$(basename "$TGZ")
SIZE=$(du -h "$TGZ" | cut -f1)

echo "==> bundle: $TGZ ($SIZE)"
echo "==> targets: $TARGETS"
echo "==> unpacking to $REMOTE on each"
echo

for entry in $TARGETS; do
    short="${entry%%:*}"
    host="${entry##*:}"

    echo "--- $short ($host) ---"
    # Copy
    $SCP "$TGZ" "$REMOTE_USER@$host:/tmp/$TGZ_BASENAME"
    # Unpack (strip=1 so $REMOTE gets install.sh/lib/... at its root, matching per-VM README paths)
    $SSH "$REMOTE_USER@$host" "sudo mkdir -p $REMOTE && sudo tar xzf /tmp/$TGZ_BASENAME --strip=1 -C $REMOTE && sudo chown -R root:root $REMOTE && rm -f /tmp/$TGZ_BASENAME"
    # Quick verify
    $SSH "$REMOTE_USER@$host" "test -f $REMOTE/install.sh && echo '    ok: install.sh 존재'"
    echo
done

echo "완료. 다음 단계:"
echo "  harbor    : sudo $REMOTE/platform/harbor/install/install-on-vm.sh"
echo "              sudo $REMOTE/platform/harbor/images/push-all.sh"
echo "  k3s-master: sudo $REMOTE/install.sh"
echo "  gitea     : sudo $REMOTE/platform/gitea/install/install-on-vm.sh"
