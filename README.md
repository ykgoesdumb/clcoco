# clcoco — Air-Gapped DevOps Platform

> 제조 폐쇄망(공장·방산·금융)을 위한 올인원 DevOps 인프라 PoC. **USB 하나에 담긴 번들** + **고성능 Rust 엣지 에이전트** 로 외부 인터넷 의존성 ZERO 환경에서 `git push → 자동 빌드 → 롤링 배포` 루프를 닫고, 동시에 엣지 런타임의 메모리·GC 한계까지 푼다.

> **납품(MVP)**: 고객사 내부 LAN 의 독립 서버/VM 7대 (infra · gitea · harbor · k3s × 3 · dev).
> **해커톤 재현**: 단일 KVM 호스트 + libvirt + Tailscale 로 동일 위상을 재현 — Lab 한정. 본 문서에서 `[Lab]` 표시된 단계가 이에 해당하며 **MVP 산출물에는 포함되지 않는다.**

---

## 1. 문제 정의 — 제조 폐쇄망의 두 가지 제약

대상: **스마트팩토리 · 방산 · 금융** 등 폐쇄망 운영 제조 현장.

### 제약 ① — 엣지 런타임 한계
PLC·센서·비전 파이프라인에서 초당 수백~수천 데이터 포인트가 발생하는 엣지 박스는:
- **GC Pause** — Python/Java GC 의 밀리초 단위 지터가 제어 루프를 깨뜨림
- **메모리 경쟁 (Low RSS)** — MES·비전 모델이 RAM 대부분 점유
- **배포 복잡성** — 의존성 설치·런타임 버전 충돌
- **산업 프로토콜 안전성** — Modbus/OPC-UA/MQTT 바이너리를 unsafe 언어로 파싱하면 malformed 패킷 하나가 라인 전체를 멈춤

### 제약 ② — 폐쇄망 DevOps 부재
인터넷 완전 차단(`crates.io` / `docker.io` / `pypi` / `github.com` 모두 차단) 환경에서 CI/CD · 레지스트리 · 모니터링 모두 부재.

| | 현재 (BEFORE) | CLCOCO 도입 후 (AFTER) |
|---|---|---|
| 코드 반입 | USB 수동 반입 | 내부 Gitea 에 `git push` |
| 빌드 | 개발자 수동 빌드 | Gitea Actions Runner 자동 빌드 |
| 레지스트리 | 없음 | Harbor 사설 레지스트리 |
| 모니터링 | 없음 (장애 후 인지) | Prometheus + Grafana 실시간 |
| 배포 주기 | 2주 ~ 수개월 | 수분 이내 |

→ CLCOCO 는 이 두 가지 큰 제약을 해결하는 방향성을 제시하는 플랫폼.

---

## 2. 우리의 해결책 — 번들 + 엣지 에이전트

| 해결 A — 오프라인 설치 번들 | 해결 B — Rust 엣지 에이전트 |
|---|---|
| → 제약 ② 폐쇄망 DevOps 부재 해결 | → 제약 ① 엣지 런타임 한계 방향성 제시 |
| k3s 3-node 바이너리 | Zero GC — 예측 가능한 latency |
| Harbor 사설 레지스트리 | ~5 MB RSS — MES 에 메모리 양보 |
| Gitea + Actions Runner (CI/CD) | ~12 MB 이미지 — 경량 배포 |
| cert-manager + 자체서명 Root CA | Static binary — `scp` 한 번으로 배포 |
| dnsmasq (DNS) + chrony (NTP) | Memory-safe 프로토콜 파싱 |
| Prometheus + Grafana | MQTT → TimescaleDB 파이프라인 |
| ArgoCD *(번들 동봉, 본 PoC 파이프라인엔 미사용)* | `cargo vendor` 오프라인 재빌드 |

> **ArgoCD 표기 주의** — 매니페스트는 번들에 들어있지만, 본 PoC 의 dev loop 는 단순화를 위해 **Gitea Actions → `kubectl rollout`** 직접 라인으로 시연한다. 상용화 단계에서 ArgoCD GitOps 라인으로 전환 가능.

---

## 3. 오프라인 설치 번들 — USB 하나로 인프라 구축

```
온라인 머신                     반입                  폐쇄망 서버
─────────────              ─────────              ──────────────────────
build-bundle.sh   →   clcoco-bundle.tgz   →   sudo install.sh
 k3s 바이너리            (USB)                   ├ lib/10-k3s.sh           k3s 3-node 부트스트랩
 docker save tar                                  ├ lib/20-load-images.sh   이미지 일괄 로드
 cargo vendor                                     ├ lib/25-platform.sh      cert-manager + Root CA + ArgoCD
 platform 매니페스트                              └ lib/30-apply-manifests  edge-demo 포함 전체
```

설치 후 자동 구성: **DNS+NTP+CA / Gitea+Actions / Harbor / k3s 3-node / Prometheus+Grafana / (ArgoCD)**. 모든 구성요소가 `install.sh` 한 줄로 자동 — 외부 인터넷 의존성 ZERO.

자세한 절차: [`airgap/bundle/README.md`](airgap/bundle/README.md), Rust 오프라인 빌드: [`airgap/docs/RUST-OFFLINE-BUILD.md`](airgap/docs/RUST-OFFLINE-BUILD.md).

---

## 4. CI/CD 파이프라인 — 폐쇄망 내부 완결

```
[1] git push          [2] Gitea Actions Runner       [3] Harbor push        [4] k3s rollout       [5] Live!
    ─────────   →     ──────────────────────  →    ──────────────  →    ─────────────  →    ─────────────
    개발자 코드        Docker build (cargo vendor)    tag = git SHA         kubectl rollout       브라우저 새로고침
```

- **전 과정 폐쇄망 내부 완결** — 외부 인터넷 의존성 ZERO. WiFi OFF 상태에서도 정상 동작.
- 본 PoC 는 단순한 push → kubectl 직선 한 줄로 "닫히는 루프" 자체 증명에 집중 (ArgoCD 의도적 제외).
- Runner 가 GitHub.com 없이 어떻게 체크아웃하는지 / self-signed Harbor 에 어떻게 push 하는지: [`apps/hello/.gitea/workflows/ci.yml`](apps/hello/.gitea/workflows/ci.yml) 주석.

---

## 5. Edge Demo — Python vs Rust 실증

`edge-demo` ns 한 곳에서 **같은 MQTT 토픽을 Python 브릿지와 Rust edge-agent 가 동시 구독** → TimescaleDB `readings` 테이블에 `source='python'|'rust'` 로 구분 적재 → Grafana 한 대시보드에 두 줄로 비교.

```
sensor-sim × 5  ──▶  mosquitto  ──┬─▶  mqtt-tsdb-bridge (Python)  ─┐
 (factory/line1/*)   (MQTT 1.6)   └─▶  edge-agent (Rust)           ├─▶ TimescaleDB ─▶ Grafana
                                                                   ┘
collect-pod-stats.sh  ──▶  pod_stats  (kubectl top, 2s 주기 — Prometheus 없이도 동작)
```

### 부하 시나리오

| 모드 | 설정 | MQTT 입력 | DB 인서트 (Python+Rust 각각 1회) |
|---|---|---|---|
| 지속 부하 (기본) | 5 pods × 50 ms 주기 | **100 msg/s** | 200 rows/s |
| 부하 상향 | `PUBLISH_INTERVAL_MS=10` | ~500 msg/s | ~1,000 rows/s |
| 순간 스파이크 | `run-burst.sh` (~13 s) | +**770 msg/s** 추가 | +1,540 rows/s |
| 최대 | sensor-sim 주기 한계 | ~2,500 msg/s | ~5,000 rows/s |

### 관측된 대조

| 지표 | Python bridge | Rust edge-agent | 격차 |
|---|---|---|---|
| 이미지 크기 | ~165 MB | ~12 MB (alpine + static) | **13.75×** ↓ |
| RSS (idle) | ~40 MB | ~5 MB | **8×** ↓ |
| RSS (지속 부하) | 19 MiB 고정 | < 1 MiB (측정 한계 미만) | **20×+** ↓ |
| 콜드 스타트 | pip install 필요 (수십초) | 즉시 (static binary) | — |
| GC pause | 있음 (밀리초 지터) | 없음 (zero-cost) | — |
| 10K-burst p99 latency | 스파이크 발생 | 평탄 유지 | — |
| 파싱 안전성 | unsafe (malformed → 크래시) | Memory-safe 보장 | — |

> 핵심 카드는 **메모리 풋프린트**. 현장 박스에 브릿지 20 개 올리면 Python ~380 MiB vs Rust ~20 MiB — MES·비전 모델이 RAM 을 대부분 먹는 엣지 환경에서 결정적.

### Grafana 대시보드

| 대시보드 | 데이터 | 용도 |
|---|---|---|
| Factory Line 1 — Live Sensors | TimescaleDB `readings` | 센서별 실시간 라인. 데이터가 들어오는 시각적 증명 |
| Bridge Footprint — Python vs Rust | TimescaleDB `pod_stats` | 메모리·CPU 비교 (Prometheus 없이도 동작) |
| Bridge Comparison *(Lab only)* | kps Prometheus `bridge_*` | p99 latency / in-flight / msg/sec |

### 시연 중 조작

```bash
./demo/collect-pod-stats.sh &                                       # 풋프린트 수집기
kubectl -n edge-demo set env sts/sensor-sim PUBLISH_INTERVAL_MS=10  # 부하 5×
airgap/scripts/run-burst.sh                                         # 13s 스파이크
```

---

## 6. Topology

### 납품(MVP) — 고객사 내부 LAN

```
              고객사 격리 LAN (192.168.10.0/24) — 외부 게이트웨이 없음
  infra(.10)   gitea(.11)   harbor(.12)   k3s-master(.20)   worker(.21/.22)   dev(.100)
  dnsmasq      Gitea        Harbor         k3s control       k3s agents        개발자 WS
  chrony       Actions      mirror         cert-mgr · kps
  Root CA      runner       projects
```

VM·베어메탈 어느 쪽이든 7대가 같은 L2 세그먼트에 놓이면 끝. 외부 NTP/DNS/레지스트리 의존 없음.

### [Lab] 해커톤 원격 재현

```
Tailscale  →  KVM 호스트 (iptables DNAT)  →  virbr-airgap (libvirt isolated)
                                              └ MVP 와 동일 7대 VM
```

`airgap-net` (192.168.10.0/24) 은 `<forward>` 없는 libvirt isolated network. Tailscale + portfwd 는 팀원 원격 SSH 편의 장치이며 **MVP 산출물에는 둘 다 없음**. 포트 매핑: [`airgap/docs/TEAM-ACCESS.md`](airgap/docs/TEAM-ACCESS.md).

---

## 7. 설치 / 시연

> 본 README 는 개요만. 실제 명령 시퀀스는 각 하위 문서 참조.

| 작업 | 문서 |
|---|---|
| [Lab] 호스트 + VM 부트스트랩 | `airgap/scripts/install-host.sh` · `create-all-vms.sh` · `portfwd.sh` |
| infra (DNS+NTP+CA) | `airgap/scripts/infra-services.sh` · `infra-ca.sh` · `distribute-ca.sh` |
| 번들 빌드 + 분배 | [`airgap/bundle/README.md`](airgap/bundle/README.md), `distribute-bundle.sh` |
| Harbor 설치 + mirror push | [`platform/harbor/README.md`](platform/harbor/README.md) |
| k3s 설치 (`install.sh`) | [`airgap/bundle/README.md`](airgap/bundle/README.md) |
| Gitea + runner + secret 자동등록 | [`platform/gitea/README.md`](platform/gitea/README.md) |
| k3s ↔ Harbor 통합 | [`platform/k3s/README.md`](platform/k3s/README.md) |
| 시연 사전 준비 | [`demo/PREP.md`](demo/PREP.md) |
| 시연 대본 (8분 3막) | [`demo/RUNBOOK.md`](demo/RUNBOOK.md) |
| 사전 smoke / 리허설 리셋 | `demo/verify.sh` · `demo/reset.sh` |

### 시연이 증명하는 3가지

1. **Airgap** — 외부 인터넷 경로 없이 전체 스택 동작 ([Lab] 에선 `nmcli radio wifi off` 로 시각 증명).
2. **Post-install dev loop** — `git push` → Gitea Actions → Harbor → k3s 롤링 배포 → 브라우저 새로고침.
3. **엣지 런타임 비교** — 같은 MQTT 토픽 동시 구독, Grafana 한 화면에 Python vs Rust 두 줄.

### 체크포인트

- [ ] (Lab) `nmcli radio wifi` 결과 `disabled`
- [ ] Gitea Actions job `Success`, Harbor 에 `apps/hello:<sha>` 존재
- [ ] `kubectl -n apps get deploy/hello` 의 이미지 태그 = 방금 push 한 SHA
- [ ] `curl https://hello.apps.airgap.local/` 가 편집한 문구 반환
- [ ] Grafana Bridge Footprint 에서 Python vs Rust 라인 분리

---

## 8. SWOT & 사업 확장성

| Strengths | Weaknesses |
|---|---|
| 완전 오프라인 동작 실증 (WiFi OFF) | PoC 수준 — End-to-end 자동 테스트 미완 |
| USB 번들 1 개로 전체 인프라 구축 | HA 구성 미적용 (단일 마스터) |
| Rust 엣지 에이전트 13.75× 경량화 | 웹 기반 관리 콘솔 부재 |
| `install.sh` 원커맨드 자동화 | |

| Opportunities | Threats |
|---|---|
| 망분리 의무 대상 확대 (ISMS-P) | 대기업 솔루션 (삼성 SDS, LG CNS) |
| 스마트팩토리 정부 투자 누적 10조+ | GitLab Self-Hosted 등 기존 도구 |
| 방산 SW 공장 자동화 수요 급증 | 폐쇄망 보안 인증 절차 장벽 |
| 엣지 컴퓨팅 시장 연 25% 성장 | Rust 인력 수급 어려움 |

### 시장 (KR)

- 엣지 컴퓨팅 시장 연성장률 **25%**
- 국내 폐쇄망 운영 기업 **2,000+**
- 스마트팩토리 정부 투자 누적 **10조+**

### 로드맵

| 단계 | 시점 | 목표 |
|---|---|---|
| Phase 1 | 2026 Q3 | MVP 완성 — HA 클러스터 · 웹 관리 콘솔 · 자동 테스트 · 문서화 |
| Phase 2 | 2027 Q1 | 파일럿 — 제조사 1~2 곳 / 피드백 / 보안 인증 |
| Phase 3 | 2027 Q2 | 상용화 — SaaS 형 관리 포털 · 방산/금융 확장 |
| Phase 4 | 2027 Q4 ~ | 플랫폼 확장 — AI/ML 엣지 추론 · 멀티 클러스터 관리 |

---

## 9. 모노레포 구조

| 디렉토리 | 담당 | README |
|---|---|---|
| `airgap/` | 인프라 — CA·DNS·NTP + 번들 + edge-demo ([Lab] libvirt 재현 포함) | [`bundle/`](airgap/bundle/README.md), [`edge-agent/`](airgap/edge-agent/README.md) |
| `platform/harbor/` | Harbor 사설 레지스트리 | [link](platform/harbor/README.md) |
| `platform/gitea/` | Gitea + Actions runner | [link](platform/gitea/README.md) |
| `platform/k3s/` | k3s ↔ Harbor 통합 | [link](platform/k3s/README.md) |
| `apps/` | 데모 앱 + CI 워크플로 | [link](apps/README.md) |
| `demo/` | 시연 PREP/RUNBOOK/verify/reset/collect-pod-stats | — |

---

## 10. 트러블슈팅 / 설계 결정 (요약)

- **dnsmasq + systemd-resolved 충돌** → infra 에서 `DNSStubListener=no` 로 :53 양보
- **Harbor 오프라인 Docker 설치** → 번들에 `.deb` 동봉 (`fetch-docker-debs.sh`)
- **Rust 의존성 오프라인 빌드** → `cargo vendor` → 번들 포함 → 폐쇄망 재빌드
- **k3s `registries.yaml` 자동 배포** → `install-registries.sh` 전 노드 일괄 적용
- **k3s HelmChart CRD 로 kps 설치** — 별도 helm 바이너리 없이 클러스터 내부 Job 이 helm install
- **Gitea `actions/checkout@v4` 차단** → 내부 Gitea shell-clone 으로 대체 ([CI 주석](apps/hello/.gitea/workflows/ci.yml))
- **Root CA 3650 일 / 서버 인증서 825 일** — Apple/iOS 825-day 한도 준수

[Lab 한정] libvirt isolated network + `iptables -I FORWARD 1` (LIBVIRT_FWI REJECT 앞에 ACCEPT 삽입), Tailscale outbound-only — 자세한 사항은 [`airgap/docs/TEAM-ACCESS.md`](airgap/docs/TEAM-ACCESS.md).

---

## License

해커톤 PoC. 내부용.
