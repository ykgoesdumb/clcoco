#!/usr/bin/env bash
# Revert all demo VMs to a named qcow2 snapshot. Intended for between-rehearsal reset.
# Runs on the host that owns the VMs.
#
# Usage:
#   demo/reset.sh                       # revert to latest demo-ready-* snapshot
#   demo/reset.sh demo-ready-20260414   # revert to specific snapshot

set -euo pipefail

VMS=(airgap-infra airgap-harbor airgap-gitea airgap-k3s-master)
SNAP="${1:-}"

if [[ -z "$SNAP" ]]; then
    # newest demo-ready-* across VMs (they should be in sync)
    SNAP=$(sudo virsh snapshot-list "${VMS[0]}" --name 2>/dev/null \
        | awk '/^demo-ready-/{print $1}' | sort -r | head -1)
    [[ -n "$SNAP" ]] || { echo "오류: ${VMS[0]} 에 demo-ready-* 스냅샷 없음" >&2; exit 1; }
    echo "==> 최신 스냅샷: $SNAP"
fi

echo "==> revert to $SNAP on ${#VMS[@]} VMs"
for vm in "${VMS[@]}"; do
    if ! sudo virsh snapshot-list "$vm" --name 2>/dev/null | grep -qx "$SNAP"; then
        echo "  건너뜀: $vm (해당 스냅샷 없음)" >&2
        continue
    fi
    echo "  $vm → $SNAP"
    sudo virsh snapshot-revert --domain "$vm" --snapshotname "$SNAP" --running
done

echo
echo "==> 대기: VM 내 서비스 재기동"
sleep 10
echo "==> 검증"
exec "$(dirname "$0")/verify.sh"
