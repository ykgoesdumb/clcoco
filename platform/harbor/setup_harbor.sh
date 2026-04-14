#!/bin/bash
# Harbor 설치 스크립트

set -e

# ─────────────────────────────────────────
# 경로 변수
# ─────────────────────────────────────────

# Harbor 설치 파일(.tgz)을 넣어둘 폴더
OFFLINE_BUNDLE="/opt/offline-bundle/harbor"

# 이 스크립트와 같은 폴더에 있는 harbor.yml을 절대 경로로 찾음
HARBOR_YML="$(cd "$(dirname "$0")" && pwd)/harbor.yml"

# 온라인 설치 시 다운받을 Harbor 버전
HARBOR_VERSION="v2.10.2"

echo "===== Harbor 설치 시작 ====="

# ─────────────────────────────────────────
# 온라인/오프라인 감지 (DNS 없이 IP로 직접 확인)
# ─────────────────────────────────────────
if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    echo "온라인 환경 감지 → 인터넷으로 설치"

    # 이전 실패 찌꺼기 정리 후 새로 시작
    INSTALL_DIR="/tmp/harbor-install"
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # 실패 시 찌꺼기 자동 정리
    cleanup() {
        echo "설치 실패 → 임시 파일 정리 중..."
        rm -rf "$INSTALL_DIR"
        echo "정리 완료."
    }
    trap cleanup ERR

    curl -fsSL "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz" \
        -o harbor-offline-installer.tgz

    tar xzf harbor-offline-installer.tgz

    trap - ERR

else
    echo "오프라인 환경 감지 → 번들로 설치"

    # 번들 존재 확인
    # 에어갭이라 인터넷에서 Harbor를 받을 수 없음
    # 번들 담당 팀원이 인터넷 되는 곳에서 미리 다운받아
    # /opt/offline-bundle/harbor/ 에 넣어둬야 함
    if [ ! -d "$OFFLINE_BUNDLE" ]; then
        echo "오류: $OFFLINE_BUNDLE 없음. 번들 마운트 확인."
        exit 1
    fi

    INSTALL_DIR="$OFFLINE_BUNDLE"
    cd "$INSTALL_DIR"

    tar xzf harbor-offline-installer-*.tgz
fi

# ─────────────────────────────────────────
# Harbor 설치
# 압축을 풀면 harbor/ 폴더가 나오고 그 안의 install.sh가 설치를 진행함
# install.sh는 내부적으로 Docker Compose로 Harbor 컨테이너들을 띄움
# harbor.yml에 적힌 인증서 경로(/opt/airgap-ca/harbor.crt)를
# Harbor가 컨테이너 안으로 자동으로 마운트함
# ─────────────────────────────────────────
echo "--- Harbor 설치 중 ---"
cd harbor

# Harbor 공식 install.sh는 같은 폴더의 harbor.yml을 읽으므로
# 우리가 작성한 설정 파일을 여기에 덮어씌움
cp "$HARBOR_YML" harbor.yml

# Harbor 설치 실행
./install.sh

echo "===== Harbor 설치 완료 ====="
