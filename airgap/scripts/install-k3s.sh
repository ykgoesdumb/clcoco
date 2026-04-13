#!/usr/bin/env bash
# install-k3s.sh — bring up a 3-node k3s cluster (1 server + 2 agents).
# Runs ON the host. Temporarily opens egress on each k3s VM via
# bootstrap-net.sh, runs the official k3s installer, then closes egress.
#
# Rationale: heavy components (k3s binary, CNI images, kernel bits)
# install in minutes when pulling from the internet. Once up, the
# cluster operates entirely inside the airgap net.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/bootstrap-net.sh"

MASTER_NAME=k3s-master
MASTER_IP=192.168.10.20
declare -A AGENTS=( [k3s-worker1]=192.168.10.21 [k3s-worker2]=192.168.10.22 )

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
ssh_vm() { ssh "${SSH_OPTS[@]}" airgap@"$1" "$2"; }

open_egress()  { "$BOOTSTRAP" on  "$1"; sleep 2; }
close_egress() { "$BOOTSTRAP" off "$1"; }

echo "==> [1/3] k3s server on $MASTER_NAME ($MASTER_IP)"
open_egress "$MASTER_NAME"
ssh_vm "$MASTER_IP" "curl -sfL https://get.k3s.io | \
  INSTALL_K3S_CHANNEL=stable \
  INSTALL_K3S_EXEC='server --tls-san $MASTER_IP --write-kubeconfig-mode 644' \
  sh -"

echo "   waiting for master Ready…"
for _ in {1..30}; do
  if ssh_vm "$MASTER_IP" "sudo kubectl get node $MASTER_NAME 2>/dev/null | grep -q ' Ready '"; then
    break
  fi
  sleep 2
done
ssh_vm "$MASTER_IP" "sudo kubectl get nodes"

TOKEN=$(ssh_vm "$MASTER_IP" "sudo cat /var/lib/rancher/k3s/server/node-token")
close_egress "$MASTER_NAME"

echo
echo "==> [2/3] k3s agents"
for W in "${!AGENTS[@]}"; do
  IP="${AGENTS[$W]}"
  echo "-- $W ($IP)"
  open_egress "$W"
  ssh_vm "$IP" "curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL=stable \
    K3S_URL=https://$MASTER_IP:6443 \
    K3S_TOKEN='$TOKEN' \
    sh -"
  close_egress "$W"
done

echo
echo "==> [3/3] waiting for all 3 nodes Ready"
for _ in {1..30}; do
  COUNT=$(ssh_vm "$MASTER_IP" "sudo kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready '" || echo 0)
  [[ "$COUNT" == "3" ]] && break
  sleep 3
done
ssh_vm "$MASTER_IP" "sudo kubectl get nodes -o wide"

echo
echo "==> Exporting kubeconfig to host"
mkdir -p "$HOME/.kube"
ssh_vm "$MASTER_IP" "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s|127.0.0.1|$MASTER_IP|" > "$HOME/.kube/airgap-config"
chmod 600 "$HOME/.kube/airgap-config"
echo "    kubeconfig: $HOME/.kube/airgap-config"
echo "    usage: export KUBECONFIG=\$HOME/.kube/airgap-config && kubectl get nodes"
echo
echo "==> Done."
