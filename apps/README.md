# apps/

데모 시나리오용 **샘플 애플리케이션**.

핵심 데모 스토리:

> 고객사 개발자가 `apps/<name>/` 의 코드를 수정 → 자기네 Gitea에 push → Gitea Actions가 **오프라인 빌드** → Harbor에 이미지 업로드 → k3s에 롤링 업데이트 → 브라우저 새로고침으로 버전 변경 확인.

## 레이아웃 제안

```
apps/
└── <app-name>/
    ├── src/                      앱 소스
    ├── Containerfile / Dockerfile
    ├── k8s/                      Deployment + Service + Ingress
    └── .gitea/workflows/         Gitea Actions 파이프라인 (빌드→푸시→배포)
```

## 설계 제약

- **오프라인 빌드가 가능해야 한다** — 의존성을 pre-vendor 하거나(Rust `cargo vendor`, Go `go mod vendor`, Node `npm ci --offline`) base 이미지에 미리 내장.
- **이미지 푸시 대상은 `harbor.apps.airgap.local`** — airgap-ca로 서명된 TLS. Actions Runner는 이미 CA 신뢰 등록됨.
- **k3s 배포 대상은 `edge-demo` 외 별도 네임스페이스** 권장 — `edge-demo`는 센서 파이프라인 전용으로 보존.
- 매니페스트의 이미지 태그는 **커밋 SHA** 기준으로 찍을 것 (GitOps 데모 편의).

## 예시 시나리오

웹 앱 `hello` v1.0.0 → v2.0.0 한 줄 수정이 기본. 욕심을 낸다면 Grafana 대시보드 앱처럼 실제 데이터와 연결된 것도 가능.
