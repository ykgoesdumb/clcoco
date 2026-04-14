# clcoco — Air-Gapped DevOps Hackathon

3일 해커톤 PoC. 폐쇄망(공장·방산·금융) 안에서 **Gitea(코드) + Harbor(이미지) + k3s(배포)** 를 돌리고, 그 위에 제조 엣지 데이터 파이프라인을 올려 "고객사 개발자가 인터넷 없이 push → 자동 빌드 → 롤링 배포" 루프가 닫히는 것을 증명한다. 단일 호스트에 libvirt VM 7개로 격리망을 재현한다.

---

## 데모가 증명하는 3가지

1. **Airgap** — 호스트 WiFi를 꺼도(`nmcli radio wifi off`) 전체 스택이 정상 동작.
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
1. **인프라 레이어** (이 리포 — libvirt 격리망 + DNS + NTP + 사설 CA + 포트포워딩)
2. **오프라인 설치 번들** (`airgap/bundle/`) — k3s 바이너리, `docker save` tar, `cargo vendor` 의존성, 설치 스크립트를 하나의 `.tgz`에. 반입 후 고객사 Gitea 러너가 vendor 디렉토리로 재빌드까지. 자세한 절차: [`airgap/docs/RUST-OFFLINE-BUILD.md`](airgap/docs/RUST-OFFLINE-BUILD.md).

---

## Topology

```
                 WiFi / Tailscale
                        │
                ┌───────┴───────┐
                │  host (KVM)   │  iptables DNAT + MASQUERADE
                └───┬───────┬───┘
                    │ virbr-airgap  (isolated, no outbound)
       ┌────────────┼────────────┬────────────┬──────────┐
       │            │            │            │          │
    infra        gitea        harbor       k3s × 3      dev
    .10.10       .10.11       .10.12       .10.20-22   .10.100
    dnsmasq      Gitea        Harbor       k3s cluster workstation
    chrony       Actions      projects     ArgoCD
    Root CA      runner                    kps stack
```

`airgap-net` (192.168.10.0/24)은 `<forward>` 선언 없는 **libvirt isolated network** — VM 외부 경로 없음. 필요할 때만 `bootstrap-net.sh on <vm>`으로 임시 개방.

---

## 스택 한눈에

| 레이어 | 도구 | 위치 |
|---|---|---|
| 격리망 | libvirt `airgap-net`, iptables DNAT | host |
| DNS / NTP / CA | dnsmasq, chrony, self-signed Root CA (10y) | infra VM |
| 코드 + CI | Gitea 1.22 + Actions runner | gitea VM |
| 레지스트리 | Harbor 2.10 | harbor VM |
| 배포 | k3s 3-node + cert-manager + `airgap-ca` ClusterIssuer | k3s VMs |
| GitOps | ArgoCD | k3s |
| 모니터링 | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) | k3s |
| 엣지 파이프라인 | Mosquitto + TimescaleDB + sensor-sim + Python 브릿지 + Rust edge-agent | k3s `edge-demo` ns |

---

## 설치 순서 (원라이너 중심)

> 전제: Ubuntu 24.04 호스트, Tailscale 가입, `~/.ssh/id_rsa.pub` 존재.

### 1. 호스트 준비
```bash
airgap/scripts/install-host.sh
```
base 이미지 stage + `airgap-net` libvirt 네트워크 정의.

### 2. VM 7개 생성 + 포트포워딩
```bash
airgap/scripts/create-all-vms.sh
airgap/scripts/wait-for-vms.sh
sudo airgap/scripts/portfwd.sh apply
sudo systemctl enable --now airgap-portfwd
```
포트 매핑: [`airgap/docs/TEAM-ACCESS.md`](airgap/docs/TEAM-ACCESS.md).

### 3. infra VM — DNS + NTP + Root CA
```bash
airgap/scripts/bootstrap-net.sh on infra      # 일시 egress
ssh -p 2200 airgap@<host> 'sudo ~/airgap/scripts/infra-services.sh'
ssh -p 2200 airgap@<host> 'sudo ~/airgap/scripts/infra-ca.sh'
airgap/scripts/distribute-ca.sh
airgap/scripts/bootstrap-net.sh off infra
```
이후 전 VM이 `*.airgap.local` 해석 + 사설 CA 신뢰 + NTP 동기화.

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

## 시연 순서 (End-to-End Demo)

"0에서 시작해 `git push` → 자동 배포까지" 정확히 무엇을 어떤 순서로 실행하는지. 각 단계 앞의 `[host]` / `[infra]` / `[harbor]` / `[k3s-master]` / `[gitea]` / `[dev]` 는 명령을 실행할 주체.

### 0. 사전 준비 (데모 시작 5분 전)
```bash
[host]$ git pull origin main                            # 최신 반영
[host]$ nmcli radio wifi on                             # 번들 빌드/수집 동안만 on
```

### 1. 인프라 부트스트랩 (이미 끝났다면 스킵)
```bash
[host]$ airgap/scripts/install-host.sh
[host]$ airgap/scripts/create-all-vms.sh && airgap/scripts/wait-for-vms.sh
[host]$ sudo airgap/scripts/portfwd.sh apply && sudo systemctl enable --now airgap-portfwd
[host]$ airgap/scripts/bootstrap-net.sh on infra
[infra]$ sudo ~/airgap/scripts/infra-services.sh && sudo ~/airgap/scripts/infra-ca.sh
[host]$ airgap/scripts/distribute-ca.sh
[host]$ airgap/scripts/bootstrap-net.sh off infra
```

### 2. 번들 생성 + 분배
```bash
[host]$ platform/harbor/install/fetch-docker-debs.sh    # (선택) Harbor용 docker .deb 수집
[host]$ airgap/bundle/build-bundle.sh                   # → dist/clcoco-bundle-0.2.0.tgz
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
| `airgap/` | 인프라 | libvirt + k3s 번들 + edge-demo | [airgap/bundle/README.md](airgap/bundle/README.md), [airgap/edge-agent/README.md](airgap/edge-agent/README.md) |
| `platform/harbor/` | Harbor | [platform/harbor/README.md](platform/harbor/README.md) |
| `platform/gitea/` | Gitea | [platform/gitea/README.md](platform/gitea/README.md) |
| `platform/k3s/` | k3s ↔ Harbor 통합 | [platform/k3s/README.md](platform/k3s/README.md) |
| `apps/` | 앱 + CI 파이프라인 | [apps/README.md](apps/README.md) |

---

## Directory Layout

```
clcoco/
├── airgap/              [인프라]
│   ├── scripts/         libvirt/DNAT/CA 등 호스트 쪽 자동화
│   ├── bundle/          오프라인 설치 번들 빌더 + install.sh
│   │   └── lib/         10-k3s / 20-images / 25-platform / 30-apply
│   ├── edge-agent/      Rust MQTT→Timescale 브릿지 (+ Containerfile.dev: Lab 온라인 빌드)
│   ├── k8s/
│   │   ├── edge-demo/   MQTT+TSDB+sensor-sim+brigdes+dashboards+ServiceMonitor+burst Job
│   │   └── platform/kube-prometheus-stack/   (Lab) kps HelmChart + install.sh
│   └── docs/            TEAM-ACCESS.md, RUST-OFFLINE-BUILD.md, …
├── platform/
│   ├── harbor/          Harbor VM 설치 스크립트 + 매니페스트 (projects, robots)
│   ├── gitea/           Gitea VM 설치 스크립트 (feat/gitea) + runner + workflow 템플릿
│   └── k3s/             k3s ↔ Harbor 통합(pull secret 등) 가이드
└── apps/                demo 앱 + .gitea/workflows/
```

핵심 스크립트만:
```
airgap/scripts/
├── install-host.sh          호스트 패키지 + base 이미지 + airgap-net
├── create-all-vms.sh        vm-spec.conf 기반 일괄 생성
├── portfwd.sh               iptables DNAT (wlp* + tailscale0)
├── bootstrap-net.sh         {on|off} <vm>  임시 egress 토글
├── infra-services.sh        infra VM: dnsmasq + chrony
├── infra-ca.sh              infra VM: Root CA + 서버 인증서
├── distribute-ca.sh         CA 번들 전 VM 배포
├── build-edge-agent.sh      (Lab) 원격 docker 빌드 → k3s 노드 ctr import
├── import-edge-agent.sh     위 스크립트가 ssh pipe로 호출
└── run-burst.sh             edge-demo 10K msg burst Job 트리거
```

---

## 주요 설계 결정

- **libvirt isolated network + `iptables -I FORWARD 1`** — libvirt `LIBVIRT_FWI` REJECT 체인보다 앞으로 ACCEPT 삽입해야 DNAT 동작.
- **cloud-init 인증 이중화** — `airgap` 사용자는 호스트 pubkey + 비밀번호(`airgap`) 둘 다.
- **dnsmasq + systemd-resolved 공존** — infra VM에서 `DNSStubListener=no` 로 :53을 dnsmasq에 넘김.
- **Root CA 3650일 / 서버 인증서 825일** — Apple/iOS 825-day 한도 준수.
- **k3s HelmChart CRD로 kps 설치** — helm 바이너리 없이 클러스터 내부 Job이 helm install. 번들에 helm 추가 불필요.
- **Prometheus-driven edge 비교** — Python/Rust 양쪽에 `bridge_*` 메트릭 (messages total, insert/parse duration histogram, in-flight gauge). ServiceMonitor → kps Prometheus. Grafana에서 `source` 라벨로 나뉜 두 줄 + burst Job으로 p99 격차 가시화.
- **Rust vendor 번들링** — `cargo vendor` 된 의존성 트리를 번들에 포함, 고객사 airgap에서 재빌드 가능.
- **Gitea 부트스트랩 한 번에** — admin 생성 / PAT 발급 / org+repo / runner registration token 모두 `install-on-vm.sh` 한 스크립트. 팀원 수작업 제로.
- **Tailscale SaaS** — 호스트 outbound-only로 controlplane 접속. 초창기 headscale에서 전환.

---

## Remote Access

Tailscale 전용. Tailnet 합류 후 `ssh -p 22XX airgap@<host-tailscale-ip>` 로 VM별 진입.
포트 매핑 + 접속 절차: [`airgap/docs/TEAM-ACCESS.md`](airgap/docs/TEAM-ACCESS.md).

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
