#!/bin/bash
# Docker 설치 스크립트

set -e

OFFLINE_BUNDLE="/opt/offline-bundle/docker"

echo "===== Docker 설치 시작 ====="

# 이미 설치됐으면 스킵
if command -v docker &>/dev/null; then
    echo "Docker 이미 설치됨. 스킵."
    exit 0
fi

# 온라인/오프라인 감지 (DNS 없이 IP로 직접 확인)
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
    apt-get install -y docker-ce docker-ce-cli containerd.io

else
    echo "오프라인 환경 감지 → 번들로 설치"

    if [ ! -d "$OFFLINE_BUNDLE" ]; then
        echo "오류: $OFFLINE_BUNDLE 없음. USB 마운트 확인."
        exit 1
    fi

    # 실패 시 설치된 패키지 롤백
    cleanup() {
        echo "설치 실패 → 롤백 중..."
        apt-get purge -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
        echo "롤백 완료."
    }
    trap cleanup ERR

    dpkg -i $OFFLINE_BUNDLE/containerd.io_*.deb
    dpkg -i $OFFLINE_BUNDLE/docker-ce-cli_*.deb
    dpkg -i $OFFLINE_BUNDLE/docker-ce_*.deb

    trap - ERR
fi

# Docker 실행
systemctl start docker
systemctl enable docker

# airgap 유저를 docker 그룹에 추가 (sudo 없이 docker 사용 가능)
usermod -aG docker airgap

# 확인
docker --version
echo "===== Docker 설치 완료 ====="
echo "※ docker 그룹 적용은 재로그인 또는 'newgrp docker' 실행 필요"
