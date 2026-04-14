#!/bin/bash
# Register org-level Gitea Actions secrets so clcoco/hello's workflow works
# without anyone pasting tokens into the UI.
#
# Gathers:
#   HARBOR_USER  — literal "robot$gitea-runner"
#   HARBOR_PASS  — fetched from Harbor (robot must exist; robots.sh made it) or $HARBOR_TOKEN_FILE
#   KUBECONFIG   — base64 kubeconfig for gitea-runner SA in apps ns
#                  (env KUBECONFIG_B64 or $KUBECONFIG_FILE)
#
# Uses the Gitea admin PAT written by install-on-vm.sh ($DATA_DIR/admin.token).
#
# Usage:
#   # Direct creds
#   HARBOR_PASS='<robot$gitea-runner secret>' KUBECONFIG_B64='<base64 kubeconfig>' \
#       ./register-secrets.sh
#
#   # Or point to the robots.sh tokens file + a kubeconfig file
#   HARBOR_TOKEN_FILE=~/harbor-robot-tokens.txt KUBECONFIG_FILE=/tmp/kc.b64 \
#       ./register-secrets.sh

set -euo pipefail

DATA_DIR="${DATA_DIR:-/opt/gitea}"
API="${GITEA_API:-http://localhost:3000/api/v1}"
ORG="${ORG:-clcoco}"

TOKEN_FILE="$DATA_DIR/admin.token"
[ -s "$TOKEN_FILE" ] || { echo "오류: $TOKEN_FILE 없음" >&2; exit 1; }
GTEA_TOKEN=$(cat "$TOKEN_FILE")
auth=(-H "Authorization: token $GTEA_TOKEN" -H "Content-Type: application/json")

# ── resolve HARBOR_PASS ───────────────────────────
HARBOR_USER="${HARBOR_USER:-robot\$gitea-runner}"
if [ -z "${HARBOR_PASS:-}" ]; then
    HARBOR_TOKEN_FILE="${HARBOR_TOKEN_FILE:-$HOME/harbor-robot-tokens.txt}"
    if [ -s "$HARBOR_TOKEN_FILE" ]; then
        HARBOR_PASS=$(awk -F': ' '/^robot\$gitea-runner:/ {print $2; exit}' "$HARBOR_TOKEN_FILE" | tr -d ' \r\n')
    fi
fi
[ -n "${HARBOR_PASS:-}" ] || {
    cat >&2 <<EOF
오류: HARBOR_PASS 확보 실패.
  - robots.sh 실행 결과가 $HARBOR_TOKEN_FILE 에 있어야 함, 또는
  - HARBOR_PASS 환경변수 직접 지정
EOF
    exit 1
}

# ── resolve KUBECONFIG (base64) ───────────────────
if [ -z "${KUBECONFIG_B64:-}" ]; then
    if [ -n "${KUBECONFIG_FILE:-}" ] && [ -s "$KUBECONFIG_FILE" ]; then
        KUBECONFIG_B64=$(tr -d '\r\n' < "$KUBECONFIG_FILE")
    fi
fi
[ -n "${KUBECONFIG_B64:-}" ] || {
    cat >&2 <<EOF
오류: KUBECONFIG_B64 확보 실패.
  - k3s-master 에서 gen-runner-kubeconfig.sh 출력(base64) 을 파일로 받아 KUBECONFIG_FILE 지정, 또는
  - KUBECONFIG_B64 환경변수 직접 지정
EOF
    exit 1
}

# ── JSON escape helper (python preferred; fallback to sed) ─────────
json_string() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
    else
        # Minimal escape: backslash, double-quote, newline. Good enough for tokens/base64.
        sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{printf "\""} {if(NR>1)printf "\\n"; printf "%s",$0} END{printf "\""}'
    fi
}

put_secret() {
    local name="$1"
    local value="$2"
    local val_json
    val_json=$(printf '%s' "$value" | json_string)
    # Gitea PUT /orgs/{org}/actions/secrets/{secretname} — upsert.
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" \
        -X PUT "$API/orgs/$ORG/actions/secrets/$name" \
        -d "{\"data\":${val_json}}")
    if [[ "$code" =~ ^2 ]]; then
        echo "    $name → OK ($code)"
    else
        echo "    $name → 실패 (HTTP $code)" >&2
        exit 1
    fi
}

echo "==> registering Gitea org secrets on $ORG"
put_secret HARBOR_USER "$HARBOR_USER"
put_secret HARBOR_PASS "$HARBOR_PASS"
put_secret KUBECONFIG  "$KUBECONFIG_B64"
echo "완료. 다음 push 부터 clcoco/hello 워크플로가 secret 없이도 성공."
