#!/usr/bin/env bash
# Distribute the edge-agent image to all k3s nodes and import via ctr.
# No Harbor yet, so we bypass a registry and go directly into each node's
# containerd image store. Runs on the libvirt host.
set -euo pipefail

IMAGE="${IMAGE:-localhost/edge-agent:0.1.0}"
TAR="${TAR:-/tmp/edge-agent.tar}"
NODES=(k3s-master k3s-worker1 k3s-worker2)
NODE_IPS=(192.168.10.20 192.168.10.21 192.168.10.22)

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

echo "==> saving $IMAGE to $TAR"
docker save -o "$TAR" "$IMAGE"
ls -lh "$TAR"

for ip in "${NODE_IPS[@]}"; do
    echo "==> $ip: scp + ctr import"
    scp "${SSH_OPTS[@]}" -q "$TAR" "airgap@${ip}:/tmp/edge-agent.tar"
    ssh "${SSH_OPTS[@]}" "airgap@${ip}" \
        'sudo k3s ctr images import /tmp/edge-agent.tar && rm /tmp/edge-agent.tar'
done

echo "==> verifying on each node"
for ip in "${NODE_IPS[@]}"; do
    echo "--- $ip"
    ssh "${SSH_OPTS[@]}" "airgap@${ip}" \
        "sudo k3s ctr images ls -q | grep edge-agent || echo '(not found)'"
done
