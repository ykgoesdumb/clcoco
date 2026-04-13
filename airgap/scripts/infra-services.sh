#!/usr/bin/env bash
# infra-services.sh — runs ON the infra VM (192.168.10.10)
# Configures dnsmasq (DNS for *.airgap.local) and chrony (authoritative NTP)
# for the air-gapped 192.168.10.0/24 subnet.
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "must run as root"; exit 1; }

echo "==> Writing /etc/airgap-hosts"
cat > /etc/airgap-hosts <<EOF
192.168.10.10   infra        infra.airgap.local
192.168.10.11   gitea        gitea.airgap.local
192.168.10.12   harbor       harbor.airgap.local
192.168.10.20   k3s-master   k3s-master.airgap.local
192.168.10.21   k3s-worker1  k3s-worker1.airgap.local
192.168.10.22   k3s-worker2  k3s-worker2.airgap.local
192.168.10.100  dev          dev.airgap.local
EOF

echo "==> Writing /etc/dnsmasq.d/airgap.conf"
cat > /etc/dnsmasq.d/airgap.conf <<'EOF'
# Airgap authoritative DNS
interface=enp1s0
bind-interfaces
listen-address=127.0.0.1,192.168.10.10
no-resolv
no-hosts
addn-hosts=/etc/airgap-hosts
domain=airgap.local
expand-hosts
local=/airgap.local/
domain-needed
bogus-priv
log-facility=/var/log/dnsmasq.log
cache-size=1000

# Wildcard for per-app ingress: *.apps.airgap.local → k3s-worker1 (Traefik nodeport host)
# Lets teams create any app.apps.airgap.local without touching DNS.
address=/apps.airgap.local/192.168.10.21

# Reverse (PTR) resolution for 192.168.10.0/24 is auto-generated from
# /etc/airgap-hosts because expand-hosts is set. No extra config needed.
EOF

# Disable systemd-resolved's stub listener on :53 so dnsmasq can own DNS cleanly.
echo "==> Disabling systemd-resolved stub listener"
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/airgap.conf <<EOF
[Resolve]
DNSStubListener=no
EOF
systemctl restart systemd-resolved

# Ensure /etc/resolv.conf points to our dnsmasq (not systemd-resolved stub)
ln -sf /etc/resolv-airgap.conf /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv-airgap.conf <<EOF
nameserver 127.0.0.1
search airgap.local
options edns0
EOF
rm -f /etc/resolv.conf
ln -s /etc/resolv-airgap.conf /etc/resolv.conf

echo "==> Restart dnsmasq"
systemctl enable --now dnsmasq
systemctl restart dnsmasq
sleep 1
systemctl --no-pager --lines=0 status dnsmasq | head -5

echo "==> dnsmasq sanity: dig harbor.airgap.local"
dig +short @127.0.0.1 harbor.airgap.local || true
dig +short @127.0.0.1 k3s-master.airgap.local || true

echo
echo "==> Writing /etc/chrony/chrony.conf"
cat > /etc/chrony/chrony.conf <<'EOF'
# Air-gapped authoritative NTP for 192.168.10.0/24.
# No external upstream. Use the local clock as reference at stratum 10.

# Use chrony drift / keys defaults
driftfile /var/lib/chrony/drift
ntsdumpdir /var/lib/chrony
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1.0 3

# Serve the airgap subnet
allow 192.168.10.0/24

# Fallback: when no real upstream is reachable, advertise local clock at stratum 10
local stratum 10

# Bind on the internal NIC only
bindaddress 192.168.10.10
EOF

echo "==> Restart chrony"
systemctl enable --now chrony
systemctl restart chrony
sleep 1
chronyc -n sources 2>/dev/null || true
chronyc -n tracking 2>/dev/null | head -10 || true

echo
echo "==> infra-services.sh complete"
