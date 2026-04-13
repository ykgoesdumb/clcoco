#!/usr/bin/env bash
# infra-ca.sh — runs ON the infra VM.
# Creates a private Root CA under /etc/airgap-ca and issues server certs
# for Harbor and Gitea.
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "must run as root"; exit 1; }

CA_DIR=/etc/airgap-ca
CA_KEY=$CA_DIR/ca.key
CA_CRT=$CA_DIR/ca.crt
CA_SRL=$CA_DIR/ca.srl
CA_CN="Airgap Hackathon Root CA"
CA_DAYS=3650
SERVER_DAYS=825  # keep under Apple/iOS 825-day ceiling for compatibility

install -d -m 0755 "$CA_DIR"

if [[ ! -f "$CA_KEY" ]]; then
  echo "==> Generating Root CA key"
  openssl genrsa -out "$CA_KEY" 4096
  chmod 600 "$CA_KEY"
else
  echo "==> Root CA key already exists — keeping"
fi

if [[ ! -f "$CA_CRT" ]]; then
  echo "==> Self-signing Root CA cert (${CA_DAYS}d)"
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" \
    -out "$CA_CRT" \
    -subj "/C=KR/O=Airgap Hackathon/CN=${CA_CN}" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "basicConstraints=critical,CA:TRUE"
else
  echo "==> Root CA cert already exists — keeping"
fi

issue_cert() {
  local NAME="$1"; shift
  local CN="$1"; shift
  # Remaining args are SANs in 'DNS:...' or 'IP:...' form
  local SAN
  SAN="$(IFS=,; echo "$*")"

  local KEY="$CA_DIR/${NAME}.key"
  local CSR="$CA_DIR/${NAME}.csr"
  local CRT="$CA_DIR/${NAME}.crt"
  local EXT="$CA_DIR/${NAME}.ext"

  echo "==> [$NAME] key + CSR (CN=$CN, SAN=$SAN)"
  openssl genrsa -out "$KEY" 2048
  chmod 600 "$KEY"

  openssl req -new -key "$KEY" -out "$CSR" -subj "/CN=${CN}"

  cat > "$EXT" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${SAN}
EOF

  openssl x509 -req -in "$CSR" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -CAserial "$CA_SRL" -out "$CRT" -days "$SERVER_DAYS" -sha256 \
    -extfile "$EXT"

  echo "   -> $CRT"
}

# Harbor: harbor.airgap.local + short hostname + IP SAN
issue_cert harbor "harbor.airgap.local" \
  "DNS:harbor.airgap.local" "DNS:harbor" "IP:192.168.10.12"

# Gitea: gitea.airgap.local + short hostname + IP SAN
issue_cert gitea "gitea.airgap.local" \
  "DNS:gitea.airgap.local" "DNS:gitea" "IP:192.168.10.11"

# World-readable certs (not keys)
chmod 644 "$CA_CRT" "$CA_DIR"/*.crt
chmod 600 "$CA_DIR"/*.key

echo
echo "==> CA and server certs in $CA_DIR"
ls -la "$CA_DIR"
echo
echo "==> Verify Harbor cert chains to CA"
openssl verify -CAfile "$CA_CRT" "$CA_DIR/harbor.crt"
openssl verify -CAfile "$CA_CRT" "$CA_DIR/gitea.crt"
