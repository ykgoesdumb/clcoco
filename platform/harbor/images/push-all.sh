#!/bin/bash
# harbor VM 안에서 실행
# /tmp/images/*.tar를 Harbor mirror 프로젝트에 업로드
#
# 사전 조건:
#   - Harbor 설치 완료 (install-on-vm.sh 실행 후)
#   - /tmp/images/ 에 pull-all.sh로 만든 .tar 파일들 복사 완료
#
# 사용법:
#   bash push-all.sh

set -e

HARBOR_HOST="harbor.airgap.local"
HARBOR_PROJECT="mirror"
HARBOR_USER="admin"
HARBOR_PASS="clcoco"
TAR_DIR="/tmp/images"

if ! command -v skopeo &>/dev/null; then
    echo "오류: skopeo가 설치되지 않음 (apt install skopeo)"
    exit 1
fi

if [ ! -d "$TAR_DIR" ] || [ -z "$(ls $TAR_DIR/*.tar 2>/dev/null)" ]; then
    echo "오류: $TAR_DIR 에 .tar 파일 없음"
    echo "pull-all.sh 실행 후 tar 파일을 이 VM의 /tmp/images/ 로 복사하세요"
    exit 1
fi

echo "===== Harbor 로그인 ====="
skopeo login "$HARBOR_HOST" \
    --username "$HARBOR_USER" \
    --password "$HARBOR_PASS"

echo ""
echo "===== 이미지 업로드 시작 ====="
count=0

for tar in "$TAR_DIR"/*.tar; do
    # 파일명(_.tar) → 이미지 경로 복원
    # 예: gitea_gitea_1.22.tar → gitea/gitea:1.22
    basename=$(basename "$tar" .tar)
    # 마지막 _ 를 : 으로 (태그 구분)
    img_path=$(echo "$basename" | sed 's/_\([^_]*\)$/_\1/' | tr '_' '/')
    tag=$(echo "$basename" | rev | cut -d_ -f1 | rev)
    name=$(echo "$basename" | rev | cut -d_ -f2- | rev | tr '_' '/')

    dest="docker://${HARBOR_HOST}/${HARBOR_PROJECT}/${name}:${tag}"
    echo "→ $(basename $tar) → ${HARBOR_PROJECT}/${name}:${tag}"

    skopeo copy "docker-archive:$tar" "$dest"
    count=$((count + 1))
done

echo ""
echo "===== 완료: ${count}개 이미지 → Harbor ${HARBOR_PROJECT}/ ====="
