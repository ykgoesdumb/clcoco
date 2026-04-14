#!/usr/bin/env bash
# portfwd.sh {apply|flush|status}
# Host iptables rules so teammates can reach VMs through the host's WiFi IP.
# Default upstream NIC is wlp15s0; override with UPSTREAM_IF env var.
set -euo pipefail

CMD="${1:-apply}"
# Space-separated list of inbound interfaces to accept DNAT on.
# Default: WiFi (local LAN) + tailscale0 (remote teammates over tailnet).
UPSTREAM_IFS="${UPSTREAM_IFS:-wlp15s0 tailscale0}"
BRIDGE_IF="virbr-airgap"
AIRGAP_CIDR="192.168.10.0/24"

# external_port:vm_ip:vm_port  ; keep in sync with team docs
MAPS=(
  "2200:192.168.10.10:22"     # infra
  "2201:192.168.10.11:22"     # gitea
  "2202:192.168.10.12:22"     # harbor
  "2203:192.168.10.20:22"     # k3s-master
  "2204:192.168.10.21:22"     # k3s-worker1
  "2205:192.168.10.22:22"     # k3s-worker2
  "2206:192.168.10.100:22"    # dev
  "3000:192.168.10.11:3000"   # gitea web
  "8443:192.168.10.12:443"    # harbor web (host-only indirection; VM-internal is 443)
  "30080:192.168.10.21:30080" # k8s NodePort (worker1)
)

COMMENT="airgap-portfwd"

flush() {
  # Remove every rule tagged with $COMMENT from the three chains we touch.
  # Note: `iptables -S` emits comments unquoted (no spaces in $COMMENT),
  # so we grep for the bare token.
  # `head -1` closes its stdin early → SIGPIPE upstream → pipefail kills the
  # script; turn pipefail off locally for the duration of the flush.
  set +o pipefail
  trap 'set -o pipefail' RETURN
  local PAT="--comment $COMMENT"

  while sudo iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "$PAT"; do
    RULE=$(sudo iptables -t nat -S PREROUTING | grep -- "$PAT" | head -1 | sed 's/^-A /-D /')
    # shellcheck disable=SC2086
    sudo iptables -t nat $RULE
  done

  while sudo iptables -S FORWARD 2>/dev/null | grep -q -- "$PAT"; do
    RULE=$(sudo iptables -S FORWARD | grep -- "$PAT" | head -1 | sed 's/^-A /-D /')
    # shellcheck disable=SC2086
    sudo iptables $RULE
  done

  while sudo iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "$PAT"; do
    RULE=$(sudo iptables -t nat -S POSTROUTING | grep -- "$PAT" | head -1 | sed 's/^-A /-D /')
    # shellcheck disable=SC2086
    sudo iptables -t nat $RULE
  done
}

apply() {
  flush

  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # Port-forward rules — DNAT on every upstream interface listed.
  for m in "${MAPS[@]}"; do
    IFS=: read -r EXT_PORT VM_IP VM_PORT <<<"$m"

    for IF in $UPSTREAM_IFS; do
      sudo iptables -t nat -A PREROUTING -i "$IF" -p tcp --dport "$EXT_PORT" \
        -j DNAT --to-destination "${VM_IP}:${VM_PORT}" \
        -m comment --comment "$COMMENT"
    done

    # Accept from external to VM (post-DNAT dest). One filter rule per VM:port
    # is enough — DNAT already happened, so iif no longer matters here.
    # Must go BEFORE libvirt's LIBVIRT_FWI REJECT for isolated networks → use -I.
    sudo iptables -I FORWARD 1 -d "$VM_IP" -p tcp --dport "$VM_PORT" \
      -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT \
      -m comment --comment "$COMMENT"
  done

  # Return-path: accept established replies from bridge back out each upstream.
  for IF in $UPSTREAM_IFS; do
    sudo iptables -I FORWARD 1 -i "$BRIDGE_IF" -o "$IF" \
      -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
      -m comment --comment "$COMMENT"
  done

  # SNAT so VM sees host's bridge IP as source (VM has no default gateway)
  sudo iptables -t nat -A POSTROUTING -d "$AIRGAP_CIDR" -o "$BRIDGE_IF" \
    -j MASQUERADE \
    -m comment --comment "$COMMENT"

  echo "==> Applied $(wc -l < <(sudo iptables-save | grep "$COMMENT")) rules"
  status
}

status() {
  echo "=== PREROUTING (nat) ==="
  sudo iptables -t nat -S PREROUTING | grep "$COMMENT" || echo "(none)"
  echo
  echo "=== POSTROUTING (nat) ==="
  sudo iptables -t nat -S POSTROUTING | grep "$COMMENT" || echo "(none)"
  echo
  echo "=== FORWARD (filter) ==="
  sudo iptables -S FORWARD | grep "$COMMENT" || echo "(none)"
}

case "$CMD" in
  apply)  apply ;;
  flush)  flush; echo "==> Flushed rules tagged $COMMENT" ;;
  status) status ;;
  *) echo "usage: $0 {apply|flush|status}" >&2; exit 2 ;;
esac
