#!/bin/bash
# Gitea 전체 설치 스크립트 (install-on-vm.sh)
#
# 실행 순서:
#   1. root/docker 확인
#   2. Harbor CA 신뢰 + /etc/hosts 엔트리 (Harbor 이미지 pull 목적)
#   3. compose db + gitea 기동
#   4. admin 계정 생성 + PAT 발급 (gitea CLI)
#   5. seed.sh 호출 — org/repo + runner registration token 발급
#   6. compose runner 기동 (--profile runner)
#   7. 최종 검증 출력
#
# 환경 변수 (모두 선택):
#   AIRGAP_CA    : Harbor CA 경로 (기본 /opt/airgap-ca/ca.crt)
#   HARBOR_FQDN  : 기본 harbor.airgap.local
#   HARBOR_IP    : 기본 192.168.10.10
#   DATA_DIR     : compose 작업 디렉토리 (기본 /opt/gitea)
#   ADMIN_USER   : 기본 gitea-admin
#   ADMIN_PASS   : 기본 admin_pass_change_me
#   ADMIN_EMAIL  : 기본 admin@airgap.local

set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "오류: root로 실행 필요 (sudo bash $0)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIRGAP_CA="${AIRGAP_CA:-/opt/airgap-ca/ca.crt}"
HARBOR_FQDN="${HARBOR_FQDN:-harbor.airgap.local}"
HARBOR_IP="${HARBOR_IP:-192.168.10.10}"
DATA_DIR="${DATA_DIR:-/opt/gitea}"
ADMIN_USER="${ADMIN_USER:-gitea-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin_pass_change_me}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@airgap.local}"

export ADMIN_USER DATA_DIR

echo "========================================="
echo " Gitea 전체 설치 시작"
echo "========================================="

# ─────────────────────────────────────────
# [1/6] Docker / Compose 확인
# ─────────────────────────────────────────
echo ""
echo "[1/6] Docker / Compose 확인"
echo "-----------------------------------------"
command -v docker >/dev/null 2>&1 || {
    echo "오류: docker 미설치. Harbor VM 기준으로 설치 후 재시도."
    exit 1
}
docker compose version >/dev/null 2>&1 || {
    echo "오류: docker compose 플러그인 미설치."
    exit 1
}

# ─────────────────────────────────────────
# [2/6] Harbor CA 신뢰 + /etc/hosts
# ─────────────────────────────────────────
echo ""
echo "[2/6] Harbor CA 신뢰 + /etc/hosts"
echo "-----------------------------------------"
if [ ! -s "$AIRGAP_CA" ]; then
    echo "경고: $AIRGAP_CA 없음 — Harbor 이미지 pull 실패 시 AIRGAP_CA 지정 필요"
else
    install -d -m 0755 "/etc/docker/certs.d/$HARBOR_FQDN"
    install -m 0644 "$AIRGAP_CA" "/etc/docker/certs.d/$HARBOR_FQDN/ca.crt"
    install -m 0644 "$AIRGAP_CA" /usr/local/share/ca-certificates/airgap-ca.crt
    update-ca-certificates >/dev/null 2>&1 || true
    systemctl reload docker 2>/dev/null || systemctl restart docker
    echo "Harbor CA 신뢰 완료"
fi

if ! grep -qE "\s${HARBOR_FQDN}(\s|$)" /etc/hosts; then
    echo "$HARBOR_IP $HARBOR_FQDN" >> /etc/hosts
    echo "/etc/hosts: $HARBOR_IP $HARBOR_FQDN 추가"
fi
if ! grep -qE "\sgitea\.airgap\.local(\s|$)" /etc/hosts; then
    echo "127.0.0.1 gitea.airgap.local" >> /etc/hosts
    echo "/etc/hosts: 127.0.0.1 gitea.airgap.local 추가"
fi

# ─────────────────────────────────────────
# [3/6] compose 기동 (db + gitea)
# ─────────────────────────────────────────
echo ""
echo "[3/6] compose 기동 (db + gitea)"
echo "-----------------------------------------"
install -d -m 0755 "$DATA_DIR"
cp -f "$SCRIPT_DIR/docker-compose.yml" "$DATA_DIR/docker-compose.yml"
cp -f "$SCRIPT_DIR/runner-config.yaml" "$DATA_DIR/runner-config.yaml"
# runner.env을 미리 생성 (compose env_file 파싱 에러 방지). seed.sh가 실제 토큰으로 덮어씀.
touch "$DATA_DIR/runner.env"
chmod 600 "$DATA_DIR/runner.env"
cd "$DATA_DIR"

docker compose up -d db gitea
echo "Gitea 헬스 대기 중 (최대 2분)..."
for i in $(seq 1 120); do
    if docker inspect -f '{{.State.Health.Status}}' gitea 2>/dev/null | grep -q healthy; then
        echo "gitea healthy (${i}s)"
        break
    fi
    sleep 1
done
docker inspect -f '{{.State.Health.Status}}' gitea 2>/dev/null | grep -q healthy || {
    echo "오류: gitea가 healthy 상태가 아님"
    docker compose logs --tail 50 gitea
    exit 1
}

# ─────────────────────────────────────────
# [4/6] admin 계정 + PAT
# ─────────────────────────────────────────
echo ""
echo "[4/6] admin 계정 + PAT"
echo "-----------------------------------------"
if docker exec -u git gitea gitea admin user list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$ADMIN_USER"; then
    echo "$ADMIN_USER 이미 존재 — skip"
else
    docker exec -u git gitea gitea admin user create \
        --admin \
        --username "$ADMIN_USER" \
        --password "$ADMIN_PASS" \
        --email "$ADMIN_EMAIL" \
        --must-change-password=false
    echo "$ADMIN_USER 생성 완료"
fi

TOKEN_FILE="$DATA_DIR/admin.token"
if [ ! -s "$TOKEN_FILE" ]; then
    RAW=$(docker exec -u git gitea gitea admin user generate-access-token \
        --username "$ADMIN_USER" \
        --token-name bootstrap \
        --scopes write:admin,write:organization,write:repository,write:user)
    TOKEN=$(echo "$RAW" | awk -F': ' '/[Aa]ccess token.*created/ {print $NF}' | tr -d ' \r\n')
    if [ -z "$TOKEN" ]; then
        echo "오류: PAT 발급 실패"
        echo "$RAW"
        exit 1
    fi
    umask 077
    echo "$TOKEN" > "$TOKEN_FILE"
    echo "PAT 저장 → $TOKEN_FILE"
else
    echo "PAT 이미 존재 — 재사용"
fi

# ─────────────────────────────────────────
# [5/6] seed (org/repo) + runner 등록 토큰
# ─────────────────────────────────────────
echo ""
echo "[5/6] seed + runner 등록 토큰"
echo "-----------------------------------------"
bash "$SCRIPT_DIR/seed.sh"

# ─────────────────────────────────────────
# [6/6] runner 기동
# ─────────────────────────────────────────
echo ""
echo "[6/6] runner 기동"
echo "-----------------------------------------"
[ -s "$DATA_DIR/runner.env" ] || {
    echo "오류: $DATA_DIR/runner.env 없음 (seed.sh 실패)"
    exit 1
}
docker compose --profile runner up -d runner

echo "runner 등록 대기 (최대 30초)..."
for i in $(seq 1 30); do
    if docker logs gitea-runner 2>&1 | grep -qE 'Runner registered|Starting runner|Loaded runner'; then
        echo "runner 등록/로드 완료 (${i}s)"
        break
    fi
    sleep 1
done

echo ""
echo "========================================="
echo " Gitea 전체 설치 완료"
echo "========================================="
echo "  URL        : http://gitea.airgap.local:3000  (또는 http://<VM_IP>:3000)"
echo "  admin      : $ADMIN_USER / $ADMIN_PASS"
echo "  PAT        : $TOKEN_FILE"
echo "  runner.env : $DATA_DIR/runner.env"
echo "  org/repo   : clcoco/hello"
echo "========================================="
