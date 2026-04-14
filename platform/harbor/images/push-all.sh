#!/bin/bash
# harbor VM 안에서 실행
# /tmp/images/*.tar 를 Harbor mirror 프로젝트에 업로드
#
# 사전 조건:
#   - Harbor 설치 완료 (install-on-vm.sh)
#   - /tmp/images/ 에 pull-all.sh 산출물(.tar 파일들) + IMAGES.txt 복사 완료
#
# 사용법:
#   bash push-all.sh
#
# 주의 (PoC): HARBOR_PASS 는 데모 기본값. 고객사 반입 전 외부화/교체 필수.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAR_DIR="${TAR_DIR:-/tmp/images}"
# IMAGES.txt 는 tar 들과 함께 /tmp/images/ 로 복사하거나, 리포 내 원본을 그대로 사용
IMAGES_FILE="${IMAGES_FILE:-$TAR_DIR/IMAGES.txt}"
[ -f "$IMAGES_FILE" ] || IMAGES_FILE="$SCRIPT_DIR/IMAGES.txt"

HARBOR_HOST="harbor.airgap.local"
HARBOR_PROJECT="mirror"
HARBOR_USER="admin"
HARBOR_PASS="clcoco"

if ! command -v skopeo &>/dev/null; then
    echo "오류: skopeo가 설치되지 않음 (apt install skopeo)"
    exit 1
fi

if [ ! -f "$IMAGES_FILE" ]; then
    echo "오류: IMAGES.txt 를 찾을 수 없음 ($IMAGES_FILE)"
    echo "  → pull-all.sh 와 함께 /tmp/images/ 로 IMAGES.txt 도 복사하세요"
    exit 1
fi

if [ ! -d "$TAR_DIR" ] || [ -z "$(ls $TAR_DIR/*.tar 2>/dev/null)" ]; then
    echo "오류: $TAR_DIR 에 .tar 파일 없음"
    echo "  → pull-all.sh 실행 후 tar 파일을 이 VM의 $TAR_DIR 로 복사"
    exit 1
fi

echo "===== Harbor 로그인 ====="
skopeo login "$HARBOR_HOST" \
    --username "$HARBOR_USER" \
    --password "$HARBOR_PASS"

echo ""
echo "===== 이미지 업로드 시작 ====="
count=0
skipped=0

# IMAGES.txt 를 단일 출처로 사용 — 파일명 역파싱 방식은 '_' 가 섞인 이미지
# (예: gitea/act_runner:0.2) 에서 잘못된 경로를 만들어내므로 쓰지 않음.
while IFS= read -r img || [ -n "$img" ]; do
    # 주석·빈 줄 스킵
    [[ "$img" =~ ^#|^[[:space:]]*$ ]] && continue

    # pull-all.sh 와 동일한 인코딩 — 양쪽이 깨지면 같이 깨져 일치 보장
    fname=$(echo "$img" | tr '/: ' '_').tar
    tar="$TAR_DIR/$fname"

    if [ ! -f "$tar" ]; then
        echo "→ SKIP: $img  ($tar 없음 — pull-all.sh 먼저 실행?)"
        skipped=$((skipped + 1))
        continue
    fi

    # IMAGES.txt 원문을 그대로 Harbor mirror/ 아래에 배치 — 원본 이름 완전 보존
    dest="docker://${HARBOR_HOST}/${HARBOR_PROJECT}/${img}"
    echo "→ $img  →  ${HARBOR_PROJECT}/${img}"

    skopeo copy "docker-archive:$tar" "$dest"
    count=$((count + 1))
done < "$IMAGES_FILE"

echo ""
echo "===== 완료: ${count}개 업로드, ${skipped}개 스킵 → Harbor ${HARBOR_PROJECT}/ ====="
