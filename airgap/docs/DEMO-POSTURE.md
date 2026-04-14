# 시연 포스처 (Closed-Network Demo)

> 해커톤/고객 시연 시 "진짜 폐쇄망에서 동작한다"를 설득력 있게 보여주기 위한 접근 방식 정리. 구현은 시연 직전에 최소한으로 튜닝.

---

## 1. 3가지 선택지

| 방식 | 실현성 | "진짜 airgap" 설득력 | 구현 비용 |
|---|---|---|---|
| A) **호스트-키오스크** — 호스트 자체에 브라우저 띄우고 HDMI/모니터로 시연. 시연 중 WiFi/Tailscale **물리적으로 끄기** | ★★★ | ★★★ (인터넷 끊고도 동작하는 걸 눈앞에서 증명) | 호스트 DNS만 infra VM(10.10) 가리키게 + 브라우저 |
| B) **데모 랩톱이 libvirt 서브넷에 직결** — 유선 NIC을 `virbr-airgap`에 bridge-join | ★★ | ★★★ | 호스트 네트워크 재구성 필요 |
| C) **Tailscale subnet router** — 호스트 `tailscale up --advertise-routes=192.168.10.0/24` + 랩톱 `/etc/hosts` | ★★★ | ★ (SaaS 터널 경유라 narrative 깨짐) | 명령 1줄 |

**권장: A (호스트 키오스크)**. 해커톤 narrative에 제일 잘 맞음 — "지금 이 기계는 인터넷이 없습니다"를 **눈앞에서 증명** 가능.

---

## 2. 방식 A 구현 체크리스트

1. **호스트 DNS 리졸버 설정** — `.airgap.local` 도메인만 infra VM dnsmasq로 돌리기.
   ```ini
   # /etc/systemd/resolved.conf.d/airgap.conf
   [Resolve]
   DNS=192.168.10.10
   Domains=~airgap.local
   ```
   ```bash
   sudo systemctl restart systemd-resolved
   resolvectl query grafana.apps.airgap.local  # should return 192.168.10.21
   ```
   호스트는 `virbr-airgap` 브릿지의 owner이므로 `192.168.10.0/24` 로 직접 라우팅됨 → 포트포워딩 불필요.

2. **브라우저 설치** — `sudo apt install firefox-esr` (또는 chromium).

3. **시연 중 인터넷 물리 차단** — 심사위원 앞에서 해도 플랫폼 동작에 지장 없음:
   - `nmcli radio wifi off` (WiFi 꺼서 "외부 없음" 가시화)
   - `sudo tailscale down` (선택사항, 팀 원격 접근 포기 시에만)
   - k3s 클러스터는 libvirt 내부라 전혀 영향 없음

4. **사설 CA 신뢰 추가** — 시연용 호스트 브라우저가 `*.airgap.local` 서버 인증서 경고 안 띄우게:
   ```bash
   # infra VM의 원본 CA를 호스트 trust에 주입
   ssh airgap@192.168.10.10 'sudo cat /etc/airgap-ca/ca.crt' \
     | sudo tee /usr/local/share/ca-certificates/airgap-ca.crt >/dev/null
   sudo update-ca-certificates
   ```
   검증: `curl -sS -o /dev/null -w "%{http_code}\n" https://grafana.apps.airgap.local/api/health` → `200`.
   Firefox는 자체 NSS trust를 쓰므로 별도 import 필요 (Chromium/Chrome은 시스템 trust 공유).

---

## 3. 시연 중 "airgap 증명" 루틴

심사위원 앞에서 다음 순서로 보여주면 narrative 강해짐:

1. `ip addr show wlp15s0` → WiFi 살아있는 상태 확인
2. `sudo nmcli radio wifi off` → 무선 OFF, 랜선도 OFF
3. `ping 1.1.1.1` → 타임아웃, "지금 인터넷 없습니다"
4. 브라우저 `grafana.apps.airgap.local` → 센서 데이터 실시간 그래프 여전히 동작
5. `ssh airgap@192.168.10.20 'sudo kubectl get nodes'` → 3 Ready
6. (선택) `~/airgap/scripts/bootstrap-net.sh on <vm>` 은 **시연 중 절대 누르지 않기**. 누르는 순간 narrative 깨짐.

---

## 4. Tailscale은 언제 쓰나?

- **OFF in 시연**: 인터넷 없이 동작을 보여주는 시점
- **ON 평소 / 팀 개발**: 원격 팀원이 VM에 SSH / kubectl 쓸 때
- **ON 시연 시작 직전**: 백업 원격 접근 경로 확보용. 끈 다음에 "끊고도 동작" 시연.

---

## 5. 시연 구성이 고객 현장과 다른 점

| 항목 | 해커톤 시연 | 실제 고객 현장 |
|---|---|---|
| 호스트 | KVM on Ubuntu (PoC) | 베어메탈 3~6대 |
| 네트워크 | libvirt isolated | 고객 사내망 (실제 L2 airgap) |
| 원격 접근 | Tailscale SaaS | 없음 — 물리 접근만 |
| 사설 CA | 온-클러스터 etcd에 개인키 | Intermediate CA (Root는 USB/HSM 오프라인) |
| 이미지 레지스트리 | Harbor (단일) | Harbor (단일, Zarf 번들로 초기 로드) |

시연 narrative에서는 "PoC는 KVM, 실배포는 동일 플로우로 베어메탈에서 그대로" 로 연결해주면 됨.
