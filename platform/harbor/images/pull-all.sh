#!/bin/bash
# 인터넷 되는 노트북에서 실행
# IMAGES.txt를 읽어 이미지를 .tar 파일로 저장
#
# 사전 조건: skopeo 설치
#   macOS:  brew install skopeo
#   Ubuntu: apt install skopeo
#
# 사용법:
#   bash pull-all.sh
#   → out/*.tar 생성됨
#   → scp -P 2202 out/*.tar airgap@100.123.217.17:/tmp/images/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGES_FILE="$SCRIPT_DIR/IMAGES.txt"
OUT_DIR="$SCRIPT_DIR/out"

mkdir -p "$OUT_DIR"

if ! command -v skopeo &>/dev/null; then
    echo "오류: skopeo가 설치되지 않음"
    echo "  macOS:  brew install skopeo"
    echo "  Ubuntu: apt install skopeo"
    exit 1
fi

echo "===== 이미지 다운로드 시작 ====="
count=0

while IFS= read -r img; do
    # 주석·빈 줄 스킵
    [[ "$img" =~ ^#|^[[:space:]]*$ ]] && continue

    fname=$(echo "$img" | tr '/: ' '_').tar
    echo "→ $img"

    skopeo copy \
        --override-os linux \
        --override-arch amd64 \
        "docker://$img" \
        "docker-archive:$OUT_DIR/$fname:$img"

    count=$((count + 1))
done < "$IMAGES_FILE"

echo ""
echo "===== 완료: $count개 이미지 → $OUT_DIR/ ====="
echo "다음 단계: scp -P 2202 out/*.tar airgap@100.123.217.17:/tmp/images/"
