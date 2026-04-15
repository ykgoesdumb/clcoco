# clcoco — Air-Gapped DevOps Hackathon

3일 해커톤 PoC. 폐쇄망(공장·방산·금융) 안에서 **Gitea(코드) + Harbor(이미지) + k3s(배포)** 를 돌리고, 그 위에 제조 엣지 데이터 파이프라인을 올려 "고객사 개발자가 인터넷 없이 push → 자동 빌드 → 롤링 배포" 루프가 닫히는 것을 증명한다.

> **납품(MVP) 구성**: 고객사 내부 LAN(격리) 상의 독립 서버/VM 7대 (infra · gitea · harbor · k3s × 3 · dev).
> **해커톤 재현**: 원격 협업을 위해 단일 호스트에 libvirt + Tailscale 로 동일 위상을 재현 — **Lab 전용이며 MVP 산출물에는 포함되지 않는다.** 아래 문서에서 `[Lab]` 표시가 붙은 단계가 이에 해당.

---

## 데모가 증명하는 3가지

1. **Airgap** — 외부 인터넷 경로가 전혀 없어도 전체 스택이 정상 동작 ([Lab] 에선 `nmcli radio wifi off` 로 증명).
2. **제조 엣지 런타임 비교** — 같은 MQTT 토픽에 Python 브릿지 + Rust edge-agent 동시 구독. 평상 트래픽에서 CPU·RSS 격차, 10K-burst에서 p99 latency·queue depth 격차가 Grafana 한 대시보드에 두 줄로 갈린다.
3. **Post-install dev loop** — 개발자가 `git push` → Gitea Actions 러너가 `cargo vendor`로 오프라인 재빌드 → Harbor에 이미지 업로드 → k3s 롤링 배포 → 브라우저 새로고침.

---

## 왜 이 시나리오 — 제조 엣지 × 폐쇄망

### 제조 엣지 런타임 제약
PLC·센서·비전 파이프라인에서 초당 수백~수천 포인트가 올라오는 엣지 박스는:
- **Predictable latency** (GC pause 있으면 제어 루프가 깨짐)
- **Low RSS** (MES·비전 모델이 메모리 대부분 먹음)
- **Single static binary** (현장 엔지니어가 `scp` 한 번으로 배포·롤백)
- **산업 프로토콜의 안전한 파싱** (Modbus/OPC-UA/MQTT 바이너리를 unsafe 언어로 파싱하면 malformed 한 패킷이 라인 전체를 멈춘다)

그래서 엣지 컴포넌트(`airgap/edge-agent`)는 **Rust**로 작성. Python 브릿지와 동일 데이터 경로(MQTT → TimescaleDB)를 공유해 Grafana에서 나란히 비교한다.

| 항목 | Python bridge | Rust edge-agent |
|---|---|---|
| 이미지 크기 | ~165 MB | ~12 MB (alpine + static bin) |
| RSS (idle) | ~40 MB | ~5 MB |
| 콜드 스타트 | initContainer pip install | 즉시 |
| GC pause | 있음 | 없음 |

### 폐쇄망 배포 제약
`crates.io` / `docker.io` / `pypi` / `github.com` 모두 닿지 않는 환경. 레지스트리·CI를 내부에 설치하고, 설치 이후에도 dev loop가 닫혀 있어야 한다.

산출물 두 개:
1. **인프라 레이어** (이 리포 — DNS + NTP + 사설 CA. [Lab] 부록으로 libvirt 격리망·iptables DNAT 재현 스크립트)
2. **오프라인 설치 번들** (`airgap/bundle/`) — k3s 바이너리, `docker save` tar, `cargo vendor` 의존성, 설치 스크립트를 하나의 `.tgz`에. 반입 후 고객사 Gitea 러너가 vendor 디렉토리로 재빌드까지. 자세한 절차: [`airgap/docs/RUST-OFFLINE-BUILD.md`](airgap/docs/RUST-OFFLINE-BUILD.md).

---

## 엣지 데모 파이프라인 — 무엇이 돌고 있나

`edge-demo` 네임스페이스 한 곳에 제조 라인 시뮬레이션을 집어넣고, 같은 MQTT 토픽을 **Python / Rust 두 브릿지가 동시 구독** 하도록 구성했다. 두 구현이 같은 데이터를 TimescaleDB 의 같은 테이블(`readings`) 에 `source='python'|'rust'` 로 구분해 저장 → Grafana 한 대시보드에서 나란히 비교가 가능하다.

```
sensor-sim × 5  ──publish──▶  mosquitto  ──subscribe──▶  mqtt-tsdb-bridge (Python)  ──▶┐
 (factory/line1/*)            (MQTT 1.6)                                                 │
                                           └─subscribe──▶  edge-agent (Rust)        ──▶  ├──▶  TimescaleDB
                                                                                          │     (readings: ts, source, sensor_id, …)
                                                            collect-pod-stats.sh     ──▶  ┘     (pod_stats: ts, app, cpu_m, mem_mi)
                                                                                                      │
                                                                                              Grafana (tsdb datasource)
```

| 컴포넌트 | 역할 | 매니페스트 |
|---|---|---|
| `sensor-sim` (StatefulSet × 5) | 5대 가상 센서 · awk sin 파동으로 temp/pressure/humidity 합성 → `factory/line1/<sid>` 에 MQTT 발행. 주기는 `PUBLISH_INTERVAL_MS` 로 조정 (기본 50ms = 20 Hz/pod = **100 msg/s 전체**) | `airgap/k8s/edge-demo/30-sensor-sim.yaml` |
| `mosquitto` | MQTT 브로커. 단일 Pod, 인증 없음, 라인 내부 전용 | `10-mosquitto.yaml` |
| `mqtt-tsdb-bridge` (Python) | paho-mqtt 로 `factory/#` 구독 → psycopg2 로 TimescaleDB 인서트. `source='python'` | `40-bridge.yaml` |
| `edge-agent` (Rust) | `rumqttc` + `tokio-postgres`. 같은 토픽 구독, `source='rust'` 로 같은 테이블 인서트. vendor 된 crate 로 오프라인 빌드 가능 | `41-edge-agent.yaml`, 소스 `airgap/edge-agent/` |
| `timescaledb` (StatefulSet) | 하이퍼테이블 `readings` + `pod_stats`. 2개의 Grafana 데이터소스 근원 | `20-timescaledb.yaml` |
| `burst` (Job, on-demand) | `mosquitto_pub` 파이썬 루프가 10K msg / ~13s 를 쏴 큐를 밀어넣는 "부하 스파이크" | `60-burst-job.yaml`, 런처 `airgap/scripts/run-burst.sh` |
| `collect-pod-stats.sh` (로컬) | 호스트에서 2초마다 `kubectl top po` → TimescaleDB `pod_stats` 로 기록. metrics-server 결과를 Grafana 가 볼 수 있게 중계 | `demo/collect-pod-stats.sh` |

### Grafana 대시보드 (현재)

데이터소스는 전부 `tsdb` (Postgres 플러그인 → TimescaleDB). Prometheus 없이도 동작 — `edge-demo` ns 내부 Grafana 하나로 제공.

| 대시보드 | UID | 용도 |
|---|---|---|
| **Factory Line 1 — Live Sensors** | `factory` | 센서별 temperature/pressure/humidity 실시간 라인. 데이터가 실제 들어오고 있음을 시각적으로 증명 |
| **Bridge Footprint — Python vs Rust** | `bridge-footprint` | `pod_stats` 기반. 메모리 RSS · CPU milli-core · 비율 스탯 · bargauge. Python 19 MiB vs Rust <1 MiB 대조가 헤드라인 |
| **Bridge Comparison: Python vs Rust** (Lab only) | `bridge-comparison` | kps 설치 후 사용. `bridge_*` Prometheus 메트릭으로 p99 latency / in-flight / msg/sec. 번들에 매니페스트는 실려 있고, kps 가 떠 있는 Lab 클러스터에서만 렌더 |

### 관측된 대조 (500 msg/s 지속 부하 기준)

| 지표 | Python bridge | Rust edge-agent | 격차 |
|---|---|---|---|
| 이미지 크기 | ~165 MB | ~12 MB (alpine + static) | 14× |
| RSS (정상 상태) | **19 MiB 고정** | **<1 MiB (측정 한계 미만)** | **20×+** |
| CPU avg | 22.6 m | 17.6 m | 1.3× |
| 10K-burst 흡수 | 전량 (drop 0) | 전량 (drop 0) | — |

CPU 는 Python/Rust 둘 다 가볍게 처리 — 브릿지가 단순해서 CPU-bound 가 아니다. **시연의 핵심 카드는 메모리 풋프린트**: 현장 박스에 브릿지 20개 올리면 Python 380 MiB vs Rust 20 MiB — MES·비전 모델이 메모리 대부분을 먹는 엣지 환경에서 결정적.

### 시연 중 조작

```bash
# 로컬 호스트에서 pod_stats 수집 시작 (Grafana 가 실시간으로 갱신)
./demo/collect-pod-stats.sh &

# 부하 상향 (기본 50ms → 10ms = 약 5배)
kubectl -n edge-demo set env sts/sensor-sim PUBLISH_INTERVAL_MS=10

# 버스트 (10K msg / 5s) — msg/sec 스파이크 보려면 Factory 대시보드, 풋프린트는 Bridge Footprint
airgap/scripts/run-burst.sh
```

---

## Topology

### MVP (납품) — 고객사 내부 LAN

```
                  고객사 격리 LAN (192.168.10.0/24)
                  외부 게이트웨이 없음 · DNS/NTP 전부 내부
  ┌──────────┬──────────┬──────────┬──────────┬──────────┐
  │          │          │          │          │          │
 infra    gitea     harbor   k3s-master  worker 1·2     dev
 .10      .11       .12      .20         .21 / .22     .100
 dnsmasq  Gitea     Harbor   k3s         k3s           개발자
 chrony   Actions   mirror   control     agents        워크스테이션
 Root CA  runner    projects cert-mgr
                             ArgoCD · kps
```

VM·베어메탈 어느 쪽이든 7대가 같은 L2 세그먼트에 놓이면 끝. 외부 NTP/DNS/레지스트리에 의존하지 않는다.

### [Lab] 해커톤 원격 재현

```
                  Tailscale (개발자 원격 접속 전용)
                          │
                  ┌───────┴───────┐
                  │  KVM 호스트    │  iptables DNAT + MASQUERADE
                  └───────┬───────┘
                          │ virbr-airgap (libvirt isolated, no outbound)
                          │
                 [infra][gitea][harbor][k3s × 3][dev]  ← MVP 와 동일 7대
```

`airgap-net` (192.168.10.0/24)은 `<forward>` 선언 없는 **libvirt isolated network**. Tailscale + 포트포워딩(`portfwd.sh`)은 해커톤 팀원이 원격에서 VM 에 붙기 위한 Lab 편의 장치이며, MVP 에는 둘 다 존재하지 않는다.

---

## 스택 한눈에

| 레이어 | 도구 | 위치 |
|---|---|---|
| 격리 네트워크 | 고객사 LAN (L2/VLAN) · MVP 엔 별도 SW 없음. [Lab] libvirt `airgap-net` + iptables DNAT 로 재현 | — |
| DNS / NTP / CA | dnsmasq, chrony, self-signed Root CA (10y) | infra |
| 코드 + CI | Gitea 1.22 + Actions runner | gitea VM |
| 레지스트리 | Harbor 2.10 | harbor VM |
| 배포 | k3s 3-node + cert-manager + `airgap-ca` ClusterIssuer | k3s VMs |
| GitOps | ArgoCD | k3s |
| 모니터링 | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) | k3s |
| 엣지 파이프라인 | Mosquitto + TimescaleDB + sensor-sim + Python 브릿지 + Rust edge-agent | k3s `edge-demo` ns |

---

## 설치 순서 (원라이너 중심)

> MVP 전제: 고객사 LAN 상에 Ubuntu 24.04 서버/VM 7대 (infra/gitea/harbor/k3s × 3/dev) 가 IP 할당된 상태. 각 노드에 공용 키 배포 완료.
> [Lab] 해커톤 재현 전제는 별도: Ubuntu 24.04 KVM 호스트 1대 + Tailscale 가입 + `~/.ssh/id_rsa.pub` — §1·§2 가 이에 해당.

### [Lab] 1. 호스트 준비 (해커톤 재현 전용)
```bash
airgap/scripts/install-host.sh
```
base 이미지 stage + `airgap-net` libvirt 네트워크 정의. **MVP 납품 시 스킵** — 실기기 7대가 곧 인프라.

### [Lab] 2. VM 7개 생성 + 포트포워딩 (해커톤 재현 전용)
```bash
airgap/scripts/create-all-vms.sh
airgap/scripts/wait-for-vms.sh
sudo airgap/scripts/portfwd.sh apply
sudo systemctl enable --now airgap-portfwd
```
포트 매핑은 팀 원격 SSH 편의용: [`airgap/docs/TEAM-ACCESS.md`](airgap/docs/TEAM-ACCESS.md). **MVP 에는 DNAT/포트포워딩 없음** — 각 서버에 LAN IP 로 직접 접속.

### 3. infra 서버 — DNS + NTP + Root CA
```bash
# MVP: infra 서버에 ssh 로 붙어서 번들을 올린 뒤 실행
ssh airgap@192.168.10.10 'sudo /opt/offline-bundle/airgap/scripts/infra-services.sh'
ssh airgap@192.168.10.10 'sudo /opt/offline-bundle/airgap/scripts/infra-ca.sh'
airgap/scripts/distribute-ca.sh
# [Lab] 격리망이 libvirt 라면 번들 업로드용으로 bootstrap-net.sh on/off 로 일시 egress 토글.
```
이후 전 노드가 `*.airgap.local` 해석 + 사설 CA 신뢰 + NTP 동기화.

### 4. 오프라인 번들 빌드 + 분배
```bash
# 호스트 (온라인 머신)에서 1회
airgap/bundle/build-bundle.sh
# → airgap/bundle/dist/clcoco-bundle-<ver>.tgz
```
번들에 포함: k3s 바이너리, 앱/플랫폼 이미지 tar, cert-manager/ArgoCD 매니페스트, edge-demo 매니페스트, `platform/{harbor,gitea,k3s}/` 전체, Harbor offline installer, IMAGES.txt 기준 mirror 이미지 tar, cargo vendor 된 Rust 소스.

단 **install 단계는 VM별로 따로** 돌아야 한다. 호스트(VM 소유 머신)에서 한 방에 분배:
```bash
airgap/scripts/distribute-bundle.sh                 # 최신 dist/*.tgz 자동 선택
# 또는 특정 tgz
airgap/scripts/distribute-bundle.sh path/to/bundle.tgz
```
결과: harbor/gitea/k3s-master/infra VM 의 `/opt/offline-bundle/` 에 동일 내용 배포. TARGETS 환경변수로 대상 커스터마이즈.

### 5. k3s-master — k3s + 플랫폼 + edge-demo (번들 install.sh)
```bash
ssh -p 2203 airgap@<host>
sudo /opt/offline-bundle/install.sh
```
`install.sh` 가 차례대로:
- k3s 3-node 부트스트랩 (`lib/10-k3s.sh`)
- 이미지 일괄 로드 (`lib/20-load-images.sh`)
- cert-manager + Root CA Secret + `airgap-ca` ClusterIssuer + ArgoCD (`lib/25-platform.sh`)
- 번들 매니페스트 apply — edge-demo 포함 (`lib/30-apply-manifests.sh`)

결과: ArgoCD `https://argocd.apps.airgap.local/`, edge-demo 가동.

### 6. Harbor VM — 레지스트리 + 미러 push
```bash
ssh -p 2202 airgap@<host>
sudo /opt/offline-bundle/platform/harbor/install/install-on-vm.sh
# 이어서 mirror/ 프로젝트 이미지 push (Gitea 설치 전에 반드시 선행)
sudo /opt/offline-bundle/platform/harbor/images/push-all.sh
```
Docker 확인 → Harbor offline installer → `platform/harbor/manifests/` projects/robots 생성 → `push-all.sh` 로 IMAGES.txt 전체를 `harbor.airgap.local/mirror/` 에 업로드.

> Docker deb 준비: 오프라인이면 번들의 `/opt/offline-bundle/docker/*.deb` 자동 사용. 번들에 deb 를 넣으려면 **호스트에서** `platform/harbor/install/fetch-docker-debs.sh` 를 먼저 실행(선택).

### 7. Gitea VM — 코드 + Actions runner
```bash
ssh -p 2201 airgap@<host>
sudo /opt/offline-bundle/platform/gitea/install/install-on-vm.sh
```
**선결**: 6번이 끝나 Harbor `mirror/` 에 `postgres:16-alpine / gitea/gitea:1.22 / gitea/act_runner:0.3` 가 존재해야 함 — 설치 스크립트가 preflight 로 검증하고 없으면 fail-fast.

한 방에: Harbor CA 신뢰 + `/etc/hosts` → 이미지 preflight → compose 기동 → admin 생성 → PAT 발급 → org `clcoco` + repo `hello` + 샘플 워크플로 push → runner 자동 등록. 자세한 건 [`platform/gitea/README.md`](platform/gitea/README.md).

### 7a. k3s ↔ Harbor 통합 (Runner 의 rollout 권한)
```bash
# k3s-master 에서
ssh -p 2203 airgap@<host>
sudo /opt/offline-bundle/platform/k3s/install-registries.sh           # 전 노드 registries.yaml
HARBOR_TOKEN='<k3s-puller pw>' bash /opt/offline-bundle/platform/k3s/apply-imagepullsecrets.sh
kubectl apply -f /opt/offline-bundle/platform/k3s/gitea-runner-rbac.yaml
/opt/offline-bundle/platform/k3s/gen-runner-kubeconfig.sh > /tmp/kc.b64
# /tmp/kc.b64 를 gitea VM 에 복사
```

### 7b. Gitea Actions Secret 자동 등록 (gitea VM 에서)
```bash
# /tmp/kc.b64 복사 후
sudo HARBOR_TOKEN_FILE=~/harbor-robot-tokens.txt \
     KUBECONFIG_FILE=/tmp/kc.b64 \
     /opt/offline-bundle/platform/gitea/install/register-secrets.sh
```
`robots.sh` 가 만든 토큰 파일 + `gen-runner-kubeconfig.sh` 의 출력만으로 org `clcoco` 에 HARBOR_USER/HARBOR_PASS/KUBECONFIG 3 개 secret 을 Gitea API 로 등록. UI 붙여넣기 불필요.

### 8. (Lab only) kube-prometheus-stack + 엣지 데모 Grafana
번들 기본은 standalone Grafana 하나. Lab 에서 더 정교한 Python/Rust 비교 대시보드를 쓰려면:
```bash
airgap/k8s/platform/kube-prometheus-stack/install.sh   # kps via HelmChart CRD
airgap/k8s/edge-demo/deploy.sh                          # comparison dashboard + ServiceMonitor
airgap/scripts/run-burst.sh                             # 10K msg/5s 버스트 (데모 클라이맥스)
```
Grafana: `https://grafana.apps.airgap.local/` → "Bridge Comparison: Python vs Rust".

---

## 시연 (Demo)

시연에서는 **설치를 보여주지 않는다**. 이미 준비된 환경에서 airgap 컷오프 → `git push` 루프 → Rust/Python 런타임 비교 3막을 8분 안에.

- **사전 준비 (1회)**: [`demo/PREP.md`](demo/PREP.md) — install 스크립트 실행·부트스트랩 push·스냅샷.
- **시연 대본**: [`demo/RUNBOOK.md`](demo/RUNBOOK.md) — 창 배치·내레이션·체크포인트.
- **사전 smoke test**: `demo/verify.sh` — 4 VM 도달성·Harbor/Gitea/k3s 상태·앱 200·Grafana 대시보드 ConfigMap 존재 검증.
- **리허설 간 리셋**: `demo/reset.sh [snapshot]` — `demo-ready-*` qcow2 스냅샷으로 30초 복귀 후 `verify.sh` 재실행.
- **풋프린트 수집기**: `demo/collect-pod-stats.sh &` — 시연 직전 백그라운드로 띄워 Grafana `bridge-footprint` 대시보드에 Python vs Rust 메모리/CPU 실시간 반영 (kps 없어도 동작).

아래 `[host]` / `[infra]` / `[harbor]` / `[k3s-master]` / `[gitea]` / `[dev]` 는 명령을 실행할 주체. **아래 시연 절차는 [Lab] 해커톤 재현 환경 기준** — `nmcli radio wifi off` 가 "airgap 이 실제로 지켜지고 있다"는 시각적 증거로 쓰이고, `ssh -p 22XX airgap@<host>` 는 libvirt + portfwd 를 전제한 원격 접속. MVP 고객사에서는 해당 노드 IP 로 직접 SSH 하면 되며 WiFi on/off 개념 자체가 없다.

### 0. 사전 준비 (데모 시작 5분 전)
```bash
[host]$ git pull origin main                            # 최신 반영
[host]$ nmcli radio wifi on                             # 번들 빌드/수집 동안만 on
```

### 1. 인프라 부트스트랩 (이미 끝났다면 스킵)
```bash
# MVP: 실기기 7대가 이미 LAN 에 있다면 아래 3줄만 (infra 서버에서)
[infra]$ sudo ~/airgap/scripts/infra-services.sh && sudo ~/airgap/scripts/infra-ca.sh
[admin]$ airgap/scripts/distribute-ca.sh

# [Lab] 해커톤 재현 — 단일 KVM 호스트에 VM 7개 올리는 경우
[host]$ airgap/scripts/install-host.sh
[host]$ airgap/scripts/create-all-vms.sh && airgap/scripts/wait-for-vms.sh
[host]$ sudo airgap/scripts/portfwd.sh apply && sudo systemctl enable --now airgap-portfwd
[host]$ airgap/scripts/bootstrap-net.sh on infra    # Lab 한정 — 번들 업로드용 일시 egress
[infra]$ sudo ~/airgap/scripts/infra-services.sh && sudo ~/airgap/scripts/infra-ca.sh
[host]$ airgap/scripts/distribute-ca.sh
[host]$ airgap/scripts/bootstrap-net.sh off infra
```

### 2. 번들 생성 + 분배
```bash
[host]$ platform/harbor/install/fetch-docker-debs.sh    # (선택) Harbor용 docker .deb 수집
[host]$ airgap/bundle/build-bundle.sh                   # → dist/clcoco-bundle-0.1.1.tgz
[host]$ airgap/scripts/distribute-bundle.sh             # 4 VM 동시 배포 (/opt/offline-bundle/)
```

### 3. Airgap 컷오프 — "여기서부터 외부망 차단"
```bash
[host]$ nmcli radio wifi off                            # 데모 증거: WiFi off 상태로 아래 전부 수행
```

### 4. Harbor — 레지스트리 + mirror push
```bash
[harbor]$ ssh -p 2202 airgap@<host>
[harbor]$ sudo /opt/offline-bundle/platform/harbor/install/install-on-vm.sh
[harbor]$ sudo /opt/offline-bundle/platform/harbor/images/push-all.sh
[harbor]$ sudo /opt/offline-bundle/platform/harbor/manifests/projects.sh
[harbor]$ sudo /opt/offline-bundle/platform/harbor/manifests/robots.sh
#         ← robot$gitea-runner / robot$k3s-puller 비밀번호가 ~/harbor-robot-tokens.txt 에 기록됨
```

### 5. k3s 클러스터 + 플랫폼
```bash
[k3s-master]$ ssh -p 2203 airgap@<host>
[k3s-master]$ sudo /opt/offline-bundle/install.sh       # k3s + cert-manager + ArgoCD + edge-demo
```

### 6. k3s ↔ Harbor 통합
```bash
[k3s-master]$ sudo /opt/offline-bundle/platform/k3s/install-registries.sh
[k3s-master]$ HARBOR_TOKEN='<k3s-puller pw>' \
              bash /opt/offline-bundle/platform/k3s/apply-imagepullsecrets.sh
[k3s-master]$ kubectl apply -f /opt/offline-bundle/platform/k3s/gitea-runner-rbac.yaml
[k3s-master]$ /opt/offline-bundle/platform/k3s/gen-runner-kubeconfig.sh > /tmp/kc.b64
[k3s-master]$ scp -P 2201 /tmp/kc.b64 airgap@<host>:/tmp/kc.b64
```

### 7. Gitea — 코드·러너 + Secret 자동 등록
```bash
[gitea]$ ssh -p 2201 airgap@<host>
[gitea]$ sudo /opt/offline-bundle/platform/gitea/install/install-on-vm.sh
[gitea]$ sudo HARBOR_TOKEN_FILE=~/harbor-robot-tokens.txt \
              KUBECONFIG_FILE=/tmp/kc.b64 \
              /opt/offline-bundle/platform/gitea/install/register-secrets.sh
#        ← Gitea UI 의 org `clcoco` / repo `hello` / Actions runner `Idle` 상태 확인
```

### 8. apps/hello 최초 부트스트랩 (1회)
```bash
[k3s-master]$ kubectl apply -f /opt/offline-bundle/apps/hello/k8s/
#             ← 아직 이미지 없어 ImagePullBackOff — 정상. 다음 push 에서 해소.
```

### 9. 🎬 데모 루프 — `git push → 자동 배포`
```bash
[dev]$ git clone https://gitea.airgap.local/clcoco/hello.git && cd hello
[dev]$ $EDITOR apps/hello/src/app.py
#      → MESSAGE = "hello from hackathon v2" 로 변경
[dev]$ git commit -am 'bump greeting' && git push
```

**스크린 동선** (4분 권장):
1. Gitea → Actions 탭: 워크플로 `build → push → rollout` 3 step 녹색으로 통과.
2. Harbor → project `apps/hello`: 새 태그 (git SHA) 도착.
3. k3s: `kubectl -n apps rollout status deploy/hello` 완료.
4. 브라우저 `https://hello.apps.airgap.local` 새로고침 → 새 문구 표시.

### 10. (Lab 클라이맥스) kps + Python vs Rust burst
```bash
[host]$ nmcli radio wifi on                             # kps 헬름차트 당기는 동안만
[k3s-master]$ bash /opt/offline-bundle/airgap/k8s/platform/kube-prometheus-stack/install.sh
[k3s-master]$ kubectl apply -f /opt/offline-bundle/airgap/k8s/edge-demo/
[host]$ nmcli radio wifi off
[host]$ airgap/scripts/run-burst.sh                     # 10K msg/5s
```
Grafana `https://grafana.apps.airgap.local/` → "Bridge Comparison: Python vs Rust" — burst 구간에서 Python p99 latency 스파이크, Rust 평탄.

### 체크포인트 — "데모가 진짜 됐다"는 증거
- [ ] `nmcli radio wifi` 결과가 전 구간 `disabled` (§3 이후).
- [ ] Gitea Actions job 이 `Success`, Harbor `apps/hello:<sha>` 존재.
- [ ] `kubectl -n apps get deploy hello -o=jsonpath='{.spec.template.spec.containers[0].image}'` 가 방금 누른 SHA 태그.
- [ ] `curl https://hello.apps.airgap.local/` 가 편집한 문구 반환.
- [ ] (Lab) Grafana 대시보드에서 Python/Rust 두 줄이 burst 시점에 벌어짐.

---

## 담당 구조 (모노레포)

| 디렉토리 | 담당 | README |
|---|---|---|
| `airgap/` | 인프라 | CA·DNS·NTP + k3s 번들 + edge-demo ([Lab] libvirt 재현 스크립트 포함) | [airgap/bundle/README.md](airgap/bundle/README.md), [airgap/edge-agent/README.md](airgap/edge-agent/README.md) |
| `platform/harbor/` | Harbor | [platform/harbor/README.md](platform/harbor/README.md) |
| `platform/gitea/` | Gitea | [platform/gitea/README.md](platform/gitea/README.md) |
| `platform/k3s/` | k3s ↔ Harbor 통합 | [platform/k3s/README.md](platform/k3s/README.md) |
| `apps/` | 앱 + CI 파이프라인 | [apps/README.md](apps/README.md) |

---

## Directory Layout

```
clcoco/
├── airgap/              [인프라]
│   ├── scripts/         CA/DNS/NTP 부트스트랩 + 번들 분배  ([Lab] libvirt·DNAT 재현)
│   ├── bundle/          오프라인 설치 번들 빌더 + install.sh
│   │   └── lib/         10-k3s / 20-images / 25-platform / 30-apply
│   ├── edge-agent/      Rust MQTT→Timescale 브릿지 (+ Containerfile.dev: Lab 온라인 빌드)
│   ├── k8s/
│   │   ├── edge-demo/   MQTT+TSDB+sensor-sim+brigdes+dashboards+ServiceMonitor+burst Job
│   │   └── platform/kube-prometheus-stack/   kps HelmChart + install.sh
│   └── docs/            TEAM-ACCESS.md ([Lab]), RUST-OFFLINE-BUILD.md, …
├── platform/
│   ├── harbor/          Harbor VM 설치 스크립트 + 매니페스트 (projects, robots)
│   ├── gitea/           Gitea VM 설치 스크립트 (feat/gitea) + runner + workflow 템플릿
│   └── k3s/             k3s ↔ Harbor 통합(pull secret 등) 가이드
└── apps/                demo 앱 + .gitea/workflows/
```

핵심 스크립트만:
```
airgap/scripts/
├── infra-services.sh        infra: dnsmasq + chrony         (MVP)
├── infra-ca.sh              infra: Root CA + 서버 인증서     (MVP)
├── distribute-ca.sh         CA 번들 전 노드 배포              (MVP)
├── distribute-bundle.sh     오프라인 번들 전 노드 배포         (MVP)
├── run-burst.sh             edge-demo 10K msg burst Job 트리거 (MVP)
├── install-host.sh          호스트 패키지 + base 이미지 + airgap-net   [Lab]
├── create-all-vms.sh        vm-spec.conf 기반 일괄 생성                [Lab]
├── portfwd.sh               iptables DNAT (wlp* + tailscale0)         [Lab]
├── bootstrap-net.sh         {on|off} <vm>  임시 egress 토글            [Lab]
├── build-edge-agent.sh      원격 docker 빌드 → k3s 노드 ctr import     [Lab]
└── import-edge-agent.sh     위 스크립트가 ssh pipe 로 호출              [Lab]
```

---

## 주요 설계 결정

- **dnsmasq + systemd-resolved 공존** — infra 에서 `DNSStubListener=no` 로 :53을 dnsmasq 에 넘김.
- **Root CA 3650일 / 서버 인증서 825일** — Apple/iOS 825-day 한도 준수.
- **k3s HelmChart CRD 로 kps 설치** — helm 바이너리 없이 클러스터 내부 Job 이 helm install. 번들에 helm 추가 불필요.
- **Prometheus-driven edge 비교** — Python/Rust 양쪽에 `bridge_*` 메트릭 (messages total, insert/parse duration histogram, in-flight gauge). ServiceMonitor → kps Prometheus. Grafana 에서 `source` 라벨로 나뉜 두 줄 + burst Job 으로 p99 격차 가시화.
- **Rust vendor 번들링** — `cargo vendor` 된 의존성 트리를 번들에 포함, 고객사 airgap 에서 재빌드 가능.
- **Gitea 부트스트랩 한 번에** — admin 생성 / PAT 발급 / org+repo / runner registration token 모두 `install-on-vm.sh` 한 스크립트. 팀원 수작업 제로.
- **cloud-init 인증 이중화** — `airgap` 사용자는 호스트 pubkey + 비밀번호(`airgap`) 둘 다. [Lab]
- **libvirt isolated network + `iptables -I FORWARD 1`** — libvirt `LIBVIRT_FWI` REJECT 체인보다 앞으로 ACCEPT 삽입해야 DNAT 동작. [Lab]
- **Tailscale SaaS** — 호스트 outbound-only 로 controlplane 접속. 초창기 headscale 에서 전환. [Lab]

---

## Remote Access

**MVP**: 별도 원격 접근 경로 없음 — 고객사 LAN 내부에서 각 서버 IP 로 직접 SSH.

**[Lab]** 해커톤 원격 재현 전용으로 Tailscale + 포트포워딩(DNAT) 사용. Tailnet 합류 후 `ssh -p 22XX airgap@<host-tailscale-ip>`. 포트 매핑 + 접속 절차: [`airgap/docs/TEAM-ACCESS.md`](airgap/docs/TEAM-ACCESS.md). **납품 산출물에서는 모두 제거된다.**

---

## 알려진 갭 (추후 보완)

- **Harbor docker deb 선택적** — `platform/harbor/install/fetch-docker-debs.sh` 로 사전 수집하면 번들에 담김. 미실행 시 Harbor 설치 시점에 온라인(bootstrap-net) 경로로 폴백.
- **End-to-end 검증 미완** — 개별 스크립트(install-on-vm.sh · push-all.sh · register-secrets.sh · distribute-bundle.sh) 는 구성 완료, 실제 4-VM 엔드투엔드 런은 담당자 검증 대기.
- **edge-demo 번들 매니페스트 vs Lab** — 번들 `manifests/edge-demo/` 는 kps 대시보드·burst Job 포함 (51/52/55/60). kps 자체는 번들 설치 시 `bootstrap-net on` 경유로 설치되도록 설계 (`airgap/k8s/platform/kube-prometheus-stack/install.sh`).

---

## 재해 복구

전 VM은 설치 시작 전 qcow2 스냅샷이 있다:
```bash
sudo virsh snapshot-list <vm-name>
sudo virsh snapshot-revert <vm-name> clean-baseline-YYYYMMDD-HHMM
```
30초 롤백.

---

## License

해커톤 PoC. 내부용.
