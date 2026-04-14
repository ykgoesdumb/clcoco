#!/bin/bash
# seed.sh — Gitea 부트스트랩 (org/repo + runner 등록 토큰)
#
# 전제: install-on-vm.sh가 이미 admin+PAT를 생성하고 $DATA_DIR/admin.token에 저장.
#
# 산출물:
#   - 조직 clcoco (없으면 생성)
#   - 리포 clcoco/hello (없으면 생성, 샘플 워크플로 + README push)
#   - $DATA_DIR/runner.env : GITEA_RUNNER_REGISTRATION_TOKEN=... (컴포즈 runner용)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-/opt/gitea}"
API="http://localhost:3000/api/v1"
ORG="${ORG:-clcoco}"
REPO="${REPO:-hello}"
ADMIN_USER="${ADMIN_USER:-gitea-admin}"

TOKEN_FILE="$DATA_DIR/admin.token"
[ -s "$TOKEN_FILE" ] || {
    echo "오류: $TOKEN_FILE 없음 — install-on-vm.sh 먼저 실행"
    exit 1
}
TOKEN=$(cat "$TOKEN_FILE")

auth=(-H "Authorization: token $TOKEN" -H "Content-Type: application/json")

# ── org ───────────────────────────────────
if curl -fsS "${auth[@]}" "$API/orgs/$ORG" >/dev/null 2>&1; then
    echo "org $ORG 이미 존재"
else
    echo "org $ORG 생성"
    curl -fsS "${auth[@]}" -X POST "$API/orgs" \
        -d "{\"username\":\"$ORG\",\"visibility\":\"public\"}" >/dev/null
fi

# ── repo ──────────────────────────────────
if curl -fsS "${auth[@]}" "$API/repos/$ORG/$REPO" >/dev/null 2>&1; then
    echo "repo $ORG/$REPO 이미 존재"
else
    echo "repo $ORG/$REPO 생성"
    curl -fsS "${auth[@]}" -X POST "$API/orgs/$ORG/repos" \
        -d "{\"name\":\"$REPO\",\"auto_init\":true,\"default_branch\":\"main\",\"readme\":\"Default\"}" >/dev/null

    # 샘플 워크플로 커밋 (Contents API, base64)
    if [ -f "$SCRIPT_DIR/../runner/workflow-template.yml" ]; then
        CONTENT=$(base64 -w0 < "$SCRIPT_DIR/../runner/workflow-template.yml" 2>/dev/null \
              || base64 < "$SCRIPT_DIR/../runner/workflow-template.yml" | tr -d '\n')
        curl -fsS "${auth[@]}" -X POST \
            "$API/repos/$ORG/$REPO/contents/.gitea/workflows/ci.yml" \
            -d "{\"branch\":\"main\",\"message\":\"chore: add CI template\",\"content\":\"$CONTENT\"}" >/dev/null
        echo "샘플 워크플로 push 완료"
    fi
fi

# ── runner registration token ─────────────
# /admin/runners/registration-token 는 시스템-전역 runner용 토큰
RESP=$(curl -fsS "${auth[@]}" "$API/admin/runners/registration-token" || true)
REG_TOKEN=$(echo "$RESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

if [ -z "$REG_TOKEN" ]; then
    echo "API 미지원 — gitea CLI로 폴백"
    REG_TOKEN=$(docker exec -u git gitea gitea actions generate-runner-token 2>/dev/null \
                | tr -d ' \r\n')
fi

[ -n "$REG_TOKEN" ] || {
    echo "오류: runner 등록 토큰 발급 실패"
    exit 1
}

umask 077
cat > "$DATA_DIR/runner.env" <<EOF
GITEA_RUNNER_REGISTRATION_TOKEN=$REG_TOKEN
GITEA_RUNNER_NAME=airgap-runner-1
EOF
echo "runner.env 저장 → $DATA_DIR/runner.env"
