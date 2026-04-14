#!/bin/bash
# Harbor 시스템 레벨 로봇 계정 생성
# gitea-runner: push+pull (apps, edge) — Gitea Actions용
# k3s-puller:   pull-only (mirror, apps, edge) — k3s imagePullSecret용

set -e

HARBOR_URL="https://harbor.airgap.local"
ADMIN_USER="admin"
ADMIN_PASS="clcoco"   # PoC 기본값 — 고객사 반입 전 변경

# 발급 토큰은 stdout 뿐 아니라 파일에도 저장 — 재발급 없이 재조회 가능
TOKEN_FILE="${TOKEN_FILE:-$HOME/harbor-robot-tokens.txt}"

# ─────────────────────────────────────────
# 로봇 계정 생성 함수
# ─────────────────────────────────────────
create_robot() {
    local name=$1
    local permissions=$2

    RESPONSE=$(curl -sk -w "\n%{http_code}" \
        -X POST "${HARBOR_URL}/api/v2.0/robots" \
        -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${name}\", \"level\": \"system\", \"permissions\": ${permissions}}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | head -1)

    if [ "$HTTP_CODE" = "201" ]; then
        SECRET=$(echo "$BODY" | grep -o '"secret":"[^"]*"' | cut -d'"' -f4)
        echo "  이름:     robot\$${name}"
        echo "  비밀번호: $SECRET"
        # 권한 0600 으로 기록 — 스크롤 놓쳐도 복구 가능
        ( umask 077; echo "robot\$${name}: ${SECRET}" >> "$TOKEN_FILE" )
        echo "  저장됨:   $TOKEN_FILE"
    elif [ "$HTTP_CODE" = "409" ]; then
        echo "  이미 존재: $name (스킵)"
    else
        echo "  오류: $name 생성 실패 (HTTP $HTTP_CODE)"
        exit 1
    fi
}

echo "--- 로봇 계정 생성 ---"

echo "[1/2] gitea-runner (push+pull: apps, edge)"
create_robot "gitea-runner" '[
    {"kind":"project","namespace":"apps","access":[{"resource":"repository","action":"push"},{"resource":"repository","action":"pull"}]},
    {"kind":"project","namespace":"edge","access":[{"resource":"repository","action":"push"},{"resource":"repository","action":"pull"}]}
]'

echo ""
echo "[2/2] k3s-puller (pull-only: mirror, apps, edge)"
create_robot "k3s-puller" '[
    {"kind":"project","namespace":"mirror","access":[{"resource":"repository","action":"pull"}]},
    {"kind":"project","namespace":"apps","access":[{"resource":"repository","action":"pull"}]},
    {"kind":"project","namespace":"edge","access":[{"resource":"repository","action":"pull"}]}
]'

echo ""
echo "--- 로봇 계정 생성 완료 ---"
echo ""
echo "위 비밀번호를 아래 담당자에게 전달하세요:"
echo "  gitea-runner → Gitea 담당자 (Actions secret 등록)"
echo "  k3s-puller   → k3s 담당자 (imagePullSecret 생성)"
