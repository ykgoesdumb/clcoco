#!/bin/bash
# Harbor 전체 설치 스크립트
# 실행 순서: Docker 설치 → Harbor 설치 → 프로젝트/로봇 계정 생성

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo " Harbor 전체 설치 시작"
echo "========================================="

# 1. Docker 설치
echo ""
echo "[1/3] Docker 설치"
echo "-----------------------------------------"
sudo bash "$SCRIPT_DIR/setup_docker.sh"

# 2. Harbor 설치
echo ""
echo "[2/3] Harbor 설치"
echo "-----------------------------------------"
sudo bash "$SCRIPT_DIR/setup_harbor.sh"

# 3. 프로젝트 + 로봇 계정 생성
echo ""
echo "[3/3] 프로젝트 + 로봇 계정 생성"
echo "-----------------------------------------"
bash "$SCRIPT_DIR/provision_harbor.sh"

echo ""
echo "========================================="
echo " Harbor 전체 설치 완료"
echo "========================================="
