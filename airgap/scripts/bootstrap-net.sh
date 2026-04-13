#!/usr/bin/env bash
# bootstrap-net.sh {on|off} <vm_name>
# Temporarily opens internet egress for a single airgap VM so packages can be
# installed during Phase 0 bootstrap. In the real hackathon flow this is
# replaced by pre-staged offline bundles.
#
# "on"  — adds SNAT on host + default route + DNS on VM
# "off" — reverts everything → VM is back in airgap
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE="$SCRIPT_DIR/vm-spec.conf"
UPSTREAM_IF="${UPSTREAM_IF:-wlp15s0}"
BRIDGE_GW="192.168.10.1"
TMP_DNS="${TMP_DNS:-1.1.1.1}"
COMMENT="airgap-bootstrap"

CMD="${1:-}"
VM="${2:-}"
[[ -n "$CMD" && -n "$VM" ]] || { echo "usage: $0 {on|off} <vm_name>"; exit 2; }

LINE="$(grep -E "^${VM}:" "$SPEC_FILE" || true)"
[[ -n "$LINE" ]] || { echo "no spec for '$VM'"; exit 1; }
IFS=: read -r _ IP _ _ _ <<<"$LINE"

ssh_vm() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      airgap@"$IP" "$@"
}

case "$CMD" in
  on)
    echo "==> Enabling temporary egress for $VM ($IP)"
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # Allow forwarding from this VM out the upstream NIC
    sudo iptables -I FORWARD 1 -s "$IP" -o "$UPSTREAM_IF" \
      -j ACCEPT -m comment --comment "$COMMENT-$VM"
    sudo iptables -I FORWARD 1 -d "$IP" -i "$UPSTREAM_IF" \
      -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
      -m comment --comment "$COMMENT-$VM"

    # SNAT so external sees host IP
    sudo iptables -t nat -A POSTROUTING -s "$IP" -o "$UPSTREAM_IF" \
      -j MASQUERADE -m comment --comment "$COMMENT-$VM"

    # VM-side: default route + DNS (save old resolv.conf first)
    ssh_vm "sudo ip route replace default via $BRIDGE_GW dev enp1s0; \
            if [ -L /etc/resolv.conf ]; then sudo cp -L /etc/resolv.conf /etc/resolv.conf.airgap-save && sudo rm /etc/resolv.conf; fi; \
            echo 'nameserver $TMP_DNS' | sudo tee /etc/resolv.conf >/dev/null"

    echo "==> $VM online. Test: ssh airgap@$IP 'curl -I https://archive.ubuntu.com'"
    ;;

  off)
    echo "==> Disabling egress for $VM ($IP)"

    # VM-side: remove default route + restore resolv.conf
    ssh_vm "sudo ip route del default via $BRIDGE_GW 2>/dev/null || true; \
            if [ -f /etc/resolv.conf.airgap-save ]; then sudo mv /etc/resolv.conf.airgap-save /etc/resolv.conf; \
            else sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; fi" || true

    # Host-side: remove rules tagged with this VM
    TAG="$COMMENT-$VM"
    while sudo iptables -S FORWARD | grep -q -- "--comment \"$TAG\""; do
      RULE=$(sudo iptables -S FORWARD | grep -- "--comment \"$TAG\"" | head -1 | sed 's/^-A /-D /')
      # shellcheck disable=SC2086
      sudo iptables $RULE
    done
    while sudo iptables -t nat -S POSTROUTING | grep -q -- "--comment \"$TAG\""; do
      RULE=$(sudo iptables -t nat -S POSTROUTING | grep -- "--comment \"$TAG\"" | head -1 | sed 's/^-A /-D /')
      # shellcheck disable=SC2086
      sudo iptables -t nat $RULE
    done

    # Verify airgap restored
    if ssh_vm "timeout 3 curl -s -o /dev/null -w '%{http_code}' https://1.1.1.1" 2>/dev/null | grep -qv 000; then
      echo "WARN: $VM still has egress — check manually!"
    else
      echo "==> $VM back in airgap"
    fi
    ;;

  *)
    echo "usage: $0 {on|off} <vm_name>" >&2; exit 2 ;;
esac
