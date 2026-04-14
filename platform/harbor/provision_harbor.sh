#!/bin/bash
# Harbor 프로젝트 + 로봇 계정 프로비저닝 스크립트
# setup_harbor.sh 실행 완료 후 실행

set -e

HARBOR_URL="https://harbor.airgap.local"
ADMIN_USER="admin"
ADMIN_PASS="clcoco"
PROJECT_NAME="clcoco"
ROBOT_NAME="clcoco"

echo "===== Harbor 프로비저닝 시작 ====="

# ─────────────────────────────────────────
# Harbor가 뜰 때까지 대기
# install.sh 직후 바로 실행하면 API가 아직 안 올라와있을 수 있음
# ─────────────────────────────────────────
echo "--- Harbor API 대기 중 ---"
for i in $(seq 1 30); do
    if curl -sk -o /dev/null -w "%{http_code}" \
        "${HARBOR_URL}/api/v2.0/systeminfo" | grep -q "200"; then
        echo "Harbor API 준비됨"
        break
    fi
    echo "대기 중... ($i/30)"
    sleep 5
done

# ─────────────────────────────────────────
# 프로젝트 생성
# Gitea Actions가 이미지를 push할 폴더
# harbor.airgap.local/clcoco/myapp:v1 형태로 사용됨
# ─────────────────────────────────────────
echo "--- 프로젝트 생성: $PROJECT_NAME ---"
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X POST "${HARBOR_URL}/api/v2.0/projects" \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -d "{
        \"project_name\": \"${PROJECT_NAME}\",
        \"public\": false
    }")

if [ "$HTTP_CODE" = "201" ]; then
    echo "프로젝트 생성 완료: $PROJECT_NAME"
elif [ "$HTTP_CODE" = "409" ]; then
    echo "프로젝트 이미 존재: $PROJECT_NAME (스킵)"
else
    echo "오류: 프로젝트 생성 실패 (HTTP $HTTP_CODE)"
    exit 1
fi

# ─────────────────────────────────────────
# 로봇 계정 생성
# Gitea Actions가 Harbor에 로그인할 때 쓰는 자동화용 계정
# 사람 계정(admin) 대신 쓰는 이유: 비밀번호 변경/계정 삭제 시 파이프라인 영향 없게
# Harbor 프로젝트 레벨 로봇 계정 이름 형식: robot$<프로젝트명>+<로봇이름>
# ─────────────────────────────────────────
echo "--- 로봇 계정 생성: $ROBOT_NAME ---"
RESPONSE=$(curl -sk -w "\n%{http_code}" \
    -X POST "${HARBOR_URL}/api/v2.0/robots" \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"${ROBOT_NAME}\",
        \"level\": \"project\",
        \"permissions\": [
            {
                \"kind\": \"project\",
                \"namespace\": \"${PROJECT_NAME}\",
                \"access\": [
                    {\"resource\": \"repository\", \"action\": \"push\"},
                    {\"resource\": \"repository\", \"action\": \"pull\"}
                ]
            }
        ]
    }")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -1)

if [ "$HTTP_CODE" = "201" ]; then
    ROBOT_SECRET=$(echo "$BODY" | grep -o '"secret":"[^"]*"' | cut -d'"' -f4)
    echo "===== 로봇 계정 생성 완료 ====="
    echo ""
    echo "  이름:      robot\$${PROJECT_NAME}+${ROBOT_NAME}"
    echo "  비밀번호:  $ROBOT_SECRET"
    echo ""
    echo "  Gitea Actions secret에 등록하세요:"
    echo "  HARBOR_USERNAME=robot\$${PROJECT_NAME}+${ROBOT_NAME}"
    echo "  HARBOR_PASSWORD=$ROBOT_SECRET"
elif [ "$HTTP_CODE" = "409" ]; then
    echo "로봇 계정 이미 존재: $ROBOT_NAME (스킵)"
else
    echo "오류: 로봇 계정 생성 실패 (HTTP $HTTP_CODE)"
    exit 1
fi

echo "===== Harbor 프로비저닝 완료 ====="
