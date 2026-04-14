#!/bin/bash
# Harbor 프로젝트 생성
# mirror (public): 외부 이미지 미러용
# apps   (private): 자체 빌드 앱 이미지용
# edge   (private): edge-demo 자체 이미지용

set -e

HARBOR_URL="https://harbor.airgap.local"
ADMIN_USER="admin"
ADMIN_PASS="clcoco"

# ─────────────────────────────────────────
# Harbor API 대기
# ─────────────────────────────────────────
echo "--- Harbor API 대기 중 ---"
API_READY=false
for i in $(seq 1 30); do
    if curl -sk -o /dev/null -w "%{http_code}" \
        "${HARBOR_URL}/api/v2.0/systeminfo" | grep -q "200"; then
        echo "Harbor API 준비됨"
        API_READY=true
        break
    fi
    echo "대기 중... ($i/30)"
    sleep 5
done

if [ "$API_READY" = "false" ]; then
    echo "오류: Harbor API가 150초 내에 응답하지 않음. Harbor가 정상 기동됐는지 확인하세요."
    exit 1
fi

# ─────────────────────────────────────────
# 프로젝트 생성 함수
# ─────────────────────────────────────────
create_project() {
    local name=$1
    local public=$2   # true / false

    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
        -X POST "${HARBOR_URL}/api/v2.0/projects" \
        -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\": \"${name}\", \"public\": ${public}}")

    if [ "$HTTP_CODE" = "201" ]; then
        echo "  생성 완료: $name"
    elif [ "$HTTP_CODE" = "409" ]; then
        echo "  이미 존재: $name (스킵)"
    else
        echo "  오류: $name 생성 실패 (HTTP $HTTP_CODE)"
        exit 1
    fi
}

echo "--- 프로젝트 생성 ---"
create_project "mirror" true    # 외부 이미지 미러 (public)
create_project "apps"   false   # 자체 빌드 앱 (private)
create_project "edge"   false   # edge-demo (private)
echo "--- 프로젝트 생성 완료 ---"
