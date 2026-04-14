# platform/

폐쇄망 안에서 돌아갈 **내부 플랫폼 서비스** (Gitea + Harbor 등)의 설치/설정/매니페스트.

## 레이아웃

```
platform/
├── gitea/      Gitea 설치 (VM 또는 k3s), Actions Runner, Runner용 이미지 사전 빌드
└── harbor/     Harbor 설치, 프로젝트/로봇 계정 프로비저닝, TLS (airgap-ca 발급)
```

## 인프라 레이어와의 경계

- DNS(`*.airgap.local`), NTP, 사설 CA는 이미 `airgap/`에서 제공됨 — 별도로 띄우지 말 것.
- 사용할 호스트네임: `gitea.airgap.local`, `harbor.airgap.local` (사설 CA가 이미 이 SAN으로 서버 인증서 발급해둠 — `airgap/scripts/infra-ca.sh`).
- TLS 인증서는 cert-manager + `airgap-ca` ClusterIssuer(이미 `airgap/k8s/`에 설치됨)에서 발급받는다.
- VM 레벨로 띄우는 경우 대상 VM은 `gitea` / `harbor` (`airgap/scripts/vm-spec.conf` 참조).

## 번들 포함

최종 오프라인 설치 번들(`airgap/bundle/`)이 이 디렉토리의 산출물(이미지 tar + k8s 매니페스트 or VM 설치 스크립트)을 포함하도록 `airgap/bundle/build-bundle.sh`에 경로를 추가해야 한다.
