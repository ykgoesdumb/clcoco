# Airgap Install Bundle

> 인터넷이 전혀 없는 환경에서 Ubuntu 22.04 호스트 한 대 위에 k3s + 엣지 데모 스택을 올리기 위한 오프라인 번들.

## 구성

```
bundle/
├── install.sh                # 메인 설치 엔트리
├── uninstall.sh
├── lib/                      # 설치 스테이지 스크립트
│   ├── 10-k3s.sh
│   ├── 20-load-images.sh
│   └── 30-apply-manifests.sh
├── k3s/                      # k3s 바이너리 + 에어갭 이미지 + 설치 스크립트
│   ├── k3s
│   ├── install.sh
│   └── airgap-images.tar.zst
├── images/                   # 앱 컨테이너 이미지 (docker save)
│   ├── edge-agent.tar
│   ├── mosquitto.tar
│   ├── timescaledb.tar
│   └── grafana.tar
├── manifests/                # kubectl apply 대상
│   └── edge-demo/
├── src/                      # 고객사 재빌드용 소스 (Rust vendor 포함)
│   └── edge-agent/
└── docs/
    └── CUSTOMER-REBUILD.md   # 고객사가 소스 수정 후 재빌드하는 방법
```

## 설치 요구사항 (고객사 측)

- Ubuntu 22.04 LTS (amd64), 최소 4 vCPU / 8 GB RAM / 40 GB 디스크
- root 또는 sudo
- **인터넷 연결 불필요** — 번들 하나로 완결

## 설치

```bash
tar xzf clcoco-bundle-<version>.tgz
cd clcoco-bundle-<version>
sudo ./install.sh
```

설치 완료 후 출력되는 Grafana URL로 접속 — 센서 데이터 실시간 대시보드.

## 제거

```bash
sudo ./uninstall.sh
```

## 고객사가 소스 수정 후 재빌드하려면

`docs/CUSTOMER-REBUILD.md` 참조. 번들 안 `src/edge-agent/` 에 Rust 소스와 vendor 디렉토리가 포함되어 있어, 설치된 Gitea/Actions 런타임 위에서 인터넷 없이 재빌드 가능.
