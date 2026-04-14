#!/bin/bash
# Harbor imagePullSecret 생성 헬퍼 — k3s 담당자가 각 네임스페이스에서 실행
# robots.sh 가 발급한 k3s-puller 비밀번호를 받아 Secret 생성.
#
# 사용법:
#   ./create-imagepullsecret.sh <k3s-puller-password> [namespace]
#
# 예:
#   ./create-imagepullsecret.sh 'xxxxxxxx...' apps
#   ./create-imagepullsecret.sh 'xxxxxxxx...' edge-demo
#
# 환경변수로 이름 변경 가능:
#   SECRET_NAME=harbor-pull ./create-imagepullsecret.sh '...' apps

set -e

TOKEN="${1:-}"
NS="${2:-default}"
SECRET_NAME="${SECRET_NAME:-harbor-pull-secret}"
HARBOR_HOST="${HARBOR_HOST:-harbor.airgap.local}"
ROBOT_USER="${ROBOT_USER:-robot\$k3s-puller}"

if [ -z "$TOKEN" ]; then
    sed -n '2,14p' "$0"
    exit 2
fi

if ! command -v kubectl &>/dev/null; then
    echo "오류: kubectl 이 없음"
    exit 1
fi

# 멱등성 — 이미 있으면 덮어씀 (dry-run YAML → apply)
kubectl create secret docker-registry "$SECRET_NAME" \
    --docker-server="$HARBOR_HOST" \
    --docker-username="$ROBOT_USER" \
    --docker-password="$TOKEN" \
    --namespace="$NS" \
    --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "== Secret '$SECRET_NAME' ready in namespace '$NS' =="
echo ""
echo "Deployment 사용 예:"
cat <<YAML
  spec:
    template:
      spec:
        imagePullSecrets:
          - name: $SECRET_NAME
        containers:
          - name: app
            image: $HARBOR_HOST/apps/hello:v1
YAML
