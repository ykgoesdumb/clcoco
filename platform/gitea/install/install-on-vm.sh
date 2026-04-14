#!/bin/bash
# Gitea 설치 자동화 스크립트 (install-on-vm.sh)

echo ">>> [STEP 1] 설정 파일 준비"
# 템플릿을 실제 설정 파일로 복사합니다.
if [ ! -f "app.ini" ]; then
    sudo cp app.ini.template app.ini
    echo "app.ini 파일이 생성되었습니다."
fi

echo ">>> [STEP 2] Gitea 서비스 기동"
# 도커 컴포즈 실행
sudo docker-compose up -d

echo ">>> [STEP 3] 상태 확인"
sudo docker ps | grep gitea

echo "===================================================="
echo "Gitea 설치 프로세스가 시작되었습니다."
echo "브라우저에서 http://100.123.217.17:3000 에 접속하세요."
echo "===================================================="
