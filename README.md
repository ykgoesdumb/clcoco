# clcoco — Air-Gapped DevOps Hackathon Infra

3일짜리 "폐쇄망 DevOps 챌린지" 해커톤을 위한 **인프라 레이어**. 같은 팀원이 Gitea / Harbor / k3s / 샘플 앱을 올릴 수 있도록 네트워크·DNS·NTP·사설 CA·원격 접근을 미리 깔아둔다.

실제 고객 납품은 베어메탈이지만, PoC는 단일 호스트에 **KVM/libvirt**로 7개 VM을 띄워 격리망을 재현한다.

---

## 왜 이 시나리오인가 — 제조 엣지 + 폐쇄망

우리가 타겟팅하는 고객은 **공장 / 방산 / 금융** — 모두 다음 두 가지 제약을 동시에 안고 있다:

### 1. 제조 엣지의 런타임 제약

PLC·센서·비전 파이프라인을 한 라인에 늘어놓으면 현장에서 올라오는 수치는 금세 **초당 수백~수천 포인트**가 된다. 이 데이터를 받아 쓰는 엣지 서버는 다음 조건을 모두 만족해야 한다:

- **Predictable latency** — GC pause로 수십~수백 ms가 튀면 제어 루프가 깨진다. Stop-the-world가 없어야 한다.
- **Low RSS** — 엣지 박스의 메인 리소스는 MES·비전 모델·OPC 서버가 먹는다. 브릿지/게이트웨이는 남는 자원만 써야 한다.
- **Single static binary** — 의존성 지옥 금지. 현장 엔지니어가 `scp` 하나로 배포/롤백할 수 있어야 한다.
- **산업용 프로토콜의 안전한 파싱** — Modbus / OPC-UA / MQTT 바이너리 프레임을 unsafe 언어로 처리하면 한 번의 malformed 패킷이 공정 전체를 멈춘다. 메모리 안전성은 선택이 아니다.

그래서 우리 엣지 컴포넌트(`airgap/edge-agent`)는 **Rust**로 짰다. Python 브릿지와 **동일한 데이터 경로(MQTT → TimescaleDB)**를 공유하고, 데모에서는 두 언어 버전을 같은 토픽에 붙여 **Grafana에 나란히 그래프를 그려 비교**한다 (`edge-demo/50-grafana.yaml`의 *Ingest rate by bridge* / *Rows by bridge* 패널).

기대 차이 (narrative):

| 항목 | Python bridge | Rust edge-agent |
|---|---|---|
| 이미지 크기 | ~150 MB | ~15 MB (alpine + static bin) |
| RSS (idle) | ~40 MB | ~5 MB |
| 콜드 스타트 | initContainer pip install | 즉시 |
| GC pause | 있음 | 없음 |

### 2. 폐쇄망(airgap) 배포 제약

위 엣지 컴포넌트는 공장 안에서 돌아야 한다. 공장 네트워크는 **밖으로 한 패킷도 나가지 않는 것을 전제**로 설계되어야 한다:

- `crates.io` / `docker.io` / `pypi` / `github.com` 모두 **닿지 않음**.
- 레지스트리도 CI도 내부에 **직접 설치**해야 한다 — Gitea + Harbor + Actions Runner.
- 하지만 고객사 개발자는 설치 이후에도 **계속 코드를 고치고 배포**할 수 있어야 한다. "한 번 떨구고 끝"이 아니라 post-install dev loop가 닫혀야 한다.

그래서 이 리포의 산출물은 두 개다:

1. **인프라 레이어 자체** (이 리포 — libvirt 격리망 + DNS + NTP + 사설 CA + 포트포워딩)
2. **오프라인 설치 번들** (`airgap/bundle/`) — k3s 바이너리, 전 이미지 `docker save` tar, `cargo vendor`된 Rust 의존성 트리, Gitea/Harbor 이미지, 설치 스크립트를 하나의 `.tgz`에 담아 고객사 airgap 내부로 반입. 반입 이후 customer의 Gitea Actions 러너가 vendor 디렉토리로 **오프라인 재빌드**까지 수행 가능 — 자세한 절차는 [`airgap/docs/RUST-OFFLINE-BUILD.md`](airgap/docs/RUST-OFFLINE-BUILD.md).

### 데모에서 증명하는 것

1. 호스트의 WiFi를 꺼도(`nmcli radio wifi off`) VM 클러스터는 정상 동작한다 → **airgap proof**.
2. 같은 클러스터에서 Python과 Rust 브릿지가 **동시에** 돌며 Grafana에 나란히 찍힌다 → **엣지 런타임 비교**.
3. 고객사 개발자가 Gitea에 push → Actions가 vendor로 오프라인 빌드 → Harbor에 이미지 업로드 → k3s 롤링 업데이트 → 브라우저 새로고침으로 버전 변경 확인 → **post-install dev loop가 닫혀 있다는 증명**.

---

## Role Scope

본 리포는 5인 팀의 **모노레포**다. top-level 디렉토리별로 담당이 나뉜다.

| 디렉토리 | 담당 | 범위 |
|---|---|---|
| `airgap/` | 인프라 | libvirt 격리망, VM 프로비저닝, 포트포워딩, 사설 CA, DNS(dnsmasq), NTP(chrony), k3s 위에 올라가는 엣지 데모(edge-demo + Rust edge-agent), 오프라인 설치 번들 조립 |
| `platform/` | 플랫폼 | Gitea + Harbor 설치/설정/매니페스트 (폐쇄망 내부 Git + 레지스트리) |
| `apps/` | 앱 | 데모 시나리오 샘플 앱 + Gitea Actions 파이프라인 (v1→v2 push 루프) |

각 디렉토리 하위 `README.md`에 세부 가이드.

---

## Topology

```
                 WiFi / Tailscale
                        │
                ┌───────┴───────┐
                │  host (KVM)   │  iptables DNAT + MASQUERADE
                └───┬───────┬───┘
                    │ virbr-airgap (isolated, no outbound)
       ┌────────────┼────────────┬────────────┐
       │            │            │            │
  infra        gitea        harbor       k3s × 3      dev
  .10.10       .10.11       .10.12       .10.20-22    .10.100
  dnsmasq      Gitea        Harbor       k3s cluster  workstation
  chrony
  Root CA
```

`airgap-net` (192.168.10.0/24)은 `<forward>` 선언이 없는 **libvirt isolated network** — VM은 외부로 나가는 기본 경로 자체가 없다. 필요할 때만 `bootstrap-net.sh on <vm>`으로 임시 개방.

---

## Directory Layout

```
clcoco/
├── airgap/      [인프라] 아래 상세
├── platform/    [플랫폼] Gitea / Harbor  — platform/README.md
└── apps/        [앱]     데모 샘플 앱    — apps/README.md
```

`airgap/` 내부:

```
airgap/
├── scripts/
│   ├── airgap-net.xml            libvirt 격리 네트워크 정의
│   ├── vm-spec.conf              7개 VM 인벤토리 (name:ip:cpu:mem:disk)
│   ├── install-host.sh           호스트 패키지 + base 이미지 + 네트워크 정의
│   ├── create-vm.sh              단일 VM 생성 (cloud-init, qcow2 오버레이)
│   ├── create-all-vms.sh         vm-spec.conf 기반 7개 일괄 생성
│   ├── destroy-vm.sh / wait-for-vms.sh   정리 / 부팅 대기
│   ├── portfwd.sh                호스트 iptables DNAT (wlp15s0 + tailscale0)
│   ├── airgap-portfwd.service    systemd unit (재부팅 시 자동 적용)
│   ├── bootstrap-net.sh          {on|off} <vm> 일시 인터넷 개방
│   ├── infra-services.sh         infra VM: dnsmasq + chrony 구성
│   ├── infra-ca.sh               infra VM: Root CA 생성 + 서버 인증서 발급
│   ├── distribute-ca.sh          CA 번들을 전 VM에 배포 + 시스템 trust 등록
│   └── import-edge-agent.sh      빌드한 edge-agent 이미지를 k3s 노드에 배포
├── k8s/edge-demo/                MQTT → TimescaleDB → Grafana 엣지 파이프라인
├── edge-agent/                   Rust MQTT→Timescale 브릿지 소스
├── bundle/                       오프라인 설치 번들 빌더 + 설치 스크립트
├── cloud-init-template/          (템플릿은 create-vm.sh 안에 인라인)
└── docs/
    ├── TEAM-ACCESS.md            팀원 원격 접속 가이드
    └── RUST-OFFLINE-BUILD.md     airgap 내부에서 Rust 재빌드 절차
```

---

## Bootstrap Order

1. **Host 준비** (Ubuntu 24.04 + libvirt)
   ```bash
   airgap/scripts/install-host.sh
   ```
   base 이미지 stage + `airgap-net` 정의.

2. **VM 일괄 생성**
   ```bash
   airgap/scripts/create-all-vms.sh
   airgap/scripts/wait-for-vms.sh
   ```
   `airgap` 사용자 + 호스트 `id_rsa.pub` + 정적 IP로 부팅.

3. **포트포워딩**
   ```bash
   sudo airgap/scripts/portfwd.sh apply
   sudo systemctl enable --now airgap-portfwd
   ```
   WiFi와 Tailscale 양쪽에서 들어오는 트래픽을 DNAT. 포트 매핑은 [TEAM-ACCESS.md](airgap/docs/TEAM-ACCESS.md) 참조.

4. **infra VM 서비스 + CA**
   ```bash
   # on infra VM (one-time egress 켜고 패키지 설치 후)
   sudo ~/airgap/scripts/infra-services.sh
   sudo ~/airgap/scripts/infra-ca.sh
   # back on host
   airgap/scripts/distribute-ca.sh
   ```
   이후 전 VM이 `*.airgap.local` 해석 + 사설 CA 신뢰 + NTP 동기화.

---

## Remote Access (팀원용)

원격 접속은 **Tailscale SaaS 전용**. 호스트에 public IP / 포트 개방 없음.

- Tailnet 합류 후 `ssh -p 22XX airgap@<host-tailscale-ip>` 로 VM별 진입.
- 세부 절차 + 포트 매핑: [`airgap/docs/TEAM-ACCESS.md`](airgap/docs/TEAM-ACCESS.md).

---

## 주요 설계 결정

- **libvirt isolated network + iptables `-I FORWARD 1`** — libvirt의 `LIBVIRT_FWI` REJECT 체인보다 앞에 ACCEPT 룰을 꽂아야 포트포워딩이 동작.
- **cloud-init 인증 이중화** — `airgap` 사용자는 호스트 SSH pubkey + 비밀번호(`airgap`) 둘 다 받도록 구성. 팀원 pubkey는 부팅 후 `authorized_keys`에 주입.
- **dnsmasq + systemd-resolved 공존** — infra VM에서 `DNSStubListener=no`로 :53을 dnsmasq에 넘김. 다른 VM은 systemd-resolved가 infra(10.10)를 upstream으로 사용.
- **Root CA 3650일 / 서버 인증서 825일** — Apple/iOS 825-day 한도 준수.
- **Tailscale SaaS로 이전** — 애초 headscale로 시작했으나 원격 팀원 접근 경로 확보 위해 전환. 호스트는 outbound만으로 controlplane에 붙는다.

---

## 재해 복구

전 VM은 설치 시작 전 깨끗한 상태로 qcow2 스냅샷되어 있다:

```bash
sudo virsh snapshot-list <vm-name>
sudo virsh snapshot-revert <vm-name> clean-baseline-YYYYMMDD-HHMM
```

팀원이 Gitea/Harbor/k3s 설치 중 망가뜨려도 30초 롤백.

---

## License & Status

해커톤 PoC. 내부용.
