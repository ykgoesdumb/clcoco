# clcoco — Air-Gapped DevOps Hackathon Infra

3일짜리 "폐쇄망 DevOps 챌린지" 해커톤을 위한 **인프라 레이어**. 같은 팀원이 Gitea / Harbor / k3s / 샘플 앱을 올릴 수 있도록 네트워크·DNS·NTP·사설 CA·원격 접근을 미리 깔아둔다.

실제 고객 납품은 베어메탈이지만, PoC는 단일 호스트에 **KVM/libvirt**로 7개 VM을 띄워 격리망을 재현한다.

---

## Role Scope

본 리포지토리는 **인프라 엔지니어 담당 영역**만 포함한다.

| 레이어 | 담당 | 여기 포함? |
|---|---|---|
| libvirt 격리 네트워크, VM 프로비저닝 | 인프라 | ✅ |
| 호스트 포트포워딩 (WiFi + Tailscale) | 인프라 | ✅ |
| 사설 Root CA + 서버 인증서 발급/배포 | 인프라 | ✅ |
| *.airgap.local DNS (dnsmasq) | 인프라 | ✅ |
| NTP (chrony, stratum 10) | 인프라 | ✅ |
| Gitea / Harbor / k3s / 샘플 앱 | 다른 팀원 | ❌ |

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
│   └── distribute-ca.sh          CA 번들을 전 VM에 배포 + 시스템 trust 등록
├── cloud-init-template/          (템플릿은 create-vm.sh 안에 인라인)
└── docs/
    └── TEAM-ACCESS.md            팀원 원격 접속 가이드
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
