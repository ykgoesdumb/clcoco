#!/bin/bash
# Harbor 전체 설치 스크립트
# 실행 순서: Docker 설치 → Harbor 설치 → 프로젝트/로봇 계정 생성

set -e

# root 권한 확인
[[ $(id -u) -eq 0 ]] || { echo "오류: root 권한 필요. sudo bash install-on-vm.sh 로 실행하세요."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OFFLINE_DOCKER="/opt/offline-bundle/docker"
OFFLINE_HARBOR="/opt/offline-bundle/harbor"
HARBOR_YML="$SCRIPT_DIR/harbor.yml"
HARBOR_VERSION="v2.10.2"

echo "========================================="
echo " Harbor 전체 설치 시작"
echo "========================================="

# ─────────────────────────────────────────
# [1/4] Docker 설치
# ─────────────────────────────────────────
echo ""
echo "[1/4] Docker 설치"
echo "-----------------------------------------"

if command -v docker &>/dev/null; then
    echo "Docker 이미 설치됨. 스킵."
else
    if ping -c1 -W2 8.8.8.8 &>/dev/null; then
        echo "온라인 환경 감지 → 인터넷으로 설치"

        apt-get update
        apt-get install -y ca-certificates curl gnupg

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        echo \
            "deb [arch=$(dpkg --print-architecture) \
            signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    else
        echo "오프라인 환경 감지 → 번들로 설치"

        if [ ! -d "$OFFLINE_DOCKER" ]; then
            echo "오류: $OFFLINE_DOCKER 없음. 번들 마운트 확인."
            exit 1
        fi

        dpkg -i $OFFLINE_DOCKER/containerd.io_*.deb
        dpkg -i $OFFLINE_DOCKER/docker-ce-cli_*.deb
        dpkg -i $OFFLINE_DOCKER/docker-ce_*.deb
        dpkg -i $OFFLINE_DOCKER/docker-compose-plugin_*.deb
    fi

    systemctl start docker
    systemctl enable docker
    usermod -aG docker airgap

    docker --version
    echo "Docker 설치 완료"
    echo "※ docker 그룹 적용은 재로그인 또는 'newgrp docker' 실행 필요"
fi

# ─────────────────────────────────────────
# [2/4] Harbor 설치
# ─────────────────────────────────────────
echo ""
echo "[2/4] Harbor 설치"
echo "-----------------------------------------"

if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    echo "온라인 환경 감지 → 인터넷으로 설치"

    INSTALL_DIR="/tmp/harbor-install"
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    cleanup() {
        echo "설치 실패 → 임시 파일 정리 중..."
        rm -rf "$INSTALL_DIR"
        echo "정리 완료."
    }
    trap cleanup ERR

    curl -fsSL "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz" \
        -o harbor-offline-installer.tgz

    tar xzf harbor-offline-installer.tgz

else
    echo "오프라인 환경 감지 → 번들로 설치"

    if [ ! -d "$OFFLINE_HARBOR" ]; then
        echo "오류: $OFFLINE_HARBOR 없음. 번들 마운트 확인."
        exit 1
    fi

    INSTALL_DIR="$OFFLINE_HARBOR"
    cd "$INSTALL_DIR"

    tar xzf harbor-offline-installer-*.tgz
fi

cd harbor
cp "$HARBOR_YML" harbor.yml
./install.sh

trap - ERR

echo "Harbor 설치 완료"

# ─────────────────────────────────────────
# [3/4] 프로젝트 생성
# ─────────────────────────────────────────
echo ""
echo "[3/4] 프로젝트 생성"
echo "-----------------------------------------"
bash "$SCRIPT_DIR/../manifests/projects.sh"

# ─────────────────────────────────────────
# [4/4] 로봇 계정 생성
# ─────────────────────────────────────────
echo ""
echo "[4/4] 로봇 계정 생성"
echo "-----------------------------------------"
bash "$SCRIPT_DIR/../manifests/robots.sh"

echo ""
echo "========================================="
echo " Harbor 전체 설치 완료"
echo "========================================="
