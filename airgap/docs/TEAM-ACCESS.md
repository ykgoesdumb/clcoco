# 팀 접속 가이드 (Air-gapped DevOps Hackathon)

> Infra 엔지니어가 운영하는 KVM 기반 airgap 클러스터에 원격으로 접속하기 위한 안내.

---

## 0. 전제: Tailscale 합류

이 인프라는 호스트의 **Tailscale tunnel**을 통해서만 원격 접속 가능 (외부 포트 노출 없음, public IP 없음).

1. **Tailscale 클라이언트 설치** — https://tailscale.com/download (mac/Win/Linux 모두 무료)
2. **@kyle에게 tailnet 초대 요청** — 본인 이메일 알려주면 admin 콘솔에서 invite 발송. 받은 링크에서 SSO(Google/MS/GitHub 등)로 가입.
3. 클라이언트에서 로그인:
   ```bash
   sudo tailscale up   # Linux
   # 또는 macOS/Windows는 메뉴 앱에서 Log in
   ```
4. 본인 tailscale IP 확인:
   ```bash
   tailscale ip
   ```
5. 호스트 도달 확인 (이름/IP 둘 다 가능):
   ```bash
   tailscale ping ykgoesdumb-x670-aorus-elite-ax
   tailscale ping 100.123.217.17
   ```

호스트(`ykgoesdumb`) tailscale IP: **`100.123.217.17`** (호스트네임: `ykgoesdumb-x670-aorus-elite-ax`)

---

## 1. SSH 키 등록

각자의 SSH **public key**(`~/.ssh/id_ed25519.pub` 등)를 슬랙 DM으로 @kyle에게 전달.
→ 7개 VM 전체의 `airgap` 사용자 `authorized_keys`에 일괄 주입됩니다.

키 받은 직후 본인 노트북에서 바로 접속 가능 (비밀번호 인증은 비활성).

### 이미 등록된 키 (재전송 불필요)

- `chosk992@naver.com` (ed25519)
- `zhonire@google.com` (rsa 4096)
- 기타 팀원용 rsa 키 1개 (`teammate1`)

본인 커밋 이메일이 위 둘 중 하나라면 바로 접속 테스트 가능. 새로운 노트북/키를 추가할 때만 @kyle에게 요청.

---

## 2. 포트 매핑 (호스트 `100.123.217.17` 기준)

| 외부 포트 | 대상 VM         | 내부 IP           | 용도              |
|-----------|------------------|-------------------|-------------------|
| 2200      | infra            | 192.168.10.10:22  | SSH (DNS/NTP/CA)  |
| 2201      | gitea            | 192.168.10.11:22  | SSH               |
| 2202      | harbor           | 192.168.10.12:22  | SSH               |
| 2203      | k3s-master       | 192.168.10.20:22  | SSH               |
| 2204      | k3s-worker1      | 192.168.10.21:22  | SSH               |
| 2205      | k3s-worker2      | 192.168.10.22:22  | SSH               |
| 2206      | dev              | 192.168.10.100:22 | SSH (앱 개발)     |
| 3000      | gitea            | 192.168.10.11     | Gitea web UI      |
| 8443      | harbor           | 192.168.10.12:443 | Harbor web/API    |
| 30080     | k3s-worker1      | 192.168.10.21     | K8s NodePort      |
| 30443     | k3s-master       | 192.168.10.20:443 | Traefik websecure (grafana/argocd ingress) |

모든 VM은 사용자 `airgap`만 활성화되어 있습니다.

---

## 3. 역할별 진입 명령

```bash
# Registry (Harbor) 담당
ssh -p 2202 airgap@100.123.217.17

# Git / CI (Gitea) 담당
ssh -p 2201 airgap@100.123.217.17

# K8s 담당 — 클러스터 노드 3대
ssh -p 2203 airgap@100.123.217.17   # master
ssh -p 2204 airgap@100.123.217.17   # worker1
ssh -p 2205 airgap@100.123.217.17   # worker2

# 앱 개발 / 데모
ssh -p 2206 airgap@100.123.217.17
```

`~/.ssh/config`에 별칭 등록을 권장:

```
Host airgap-harbor
  HostName 100.123.217.17
  Port 2202
  User airgap

Host airgap-gitea
  HostName 100.123.217.17
  Port 2201
  User airgap
# ... 필요한 만큼 반복
```

---

## 4. VM 안에서의 환경

VM 셸로 들어간 다음 사용 가능한 것들:

### 4.1 내부 DNS (`*.airgap.local`)

infra VM(192.168.10.10)에서 dnsmasq가 다음 이름들을 권위적으로 응답:

| 이름                       | IP             |
|----------------------------|----------------|
| infra.airgap.local         | 192.168.10.10  |
| gitea.airgap.local         | 192.168.10.11  |
| harbor.airgap.local        | 192.168.10.12  |
| k3s-master.airgap.local    | 192.168.10.20  |
| k3s-worker1.airgap.local   | 192.168.10.21  |
| k3s-worker2.airgap.local   | 192.168.10.22  |
| dev.airgap.local           | 192.168.10.100 |

테스트:
```bash
getent hosts harbor.airgap.local
dig +short @192.168.10.10 gitea.airgap.local
```

### 4.2 NTP

infra VM의 chrony가 stratum 10 권위 서버. 별도 설정 불필요.
확인: `chronyc -n sources`

### 4.3 사설 CA (TLS 신뢰)

CA 인증서 + 서버 인증서 위치:

| 파일                                 | 어디                                                                      |
|--------------------------------------|---------------------------------------------------------------------------|
| `/etc/airgap-ca/ca.crt` (+ `ca.key`) | **infra VM만** — CA 권위자. 원본 발급소                                   |
| `/opt/airgap-ca/ca.crt`              | infra 외 모든 VM (`distribute-ca.sh`가 복사, 시스템 trust에 이미 등록됨)  |
| `/etc/ssl/certs/ca-certificates.crt` | 모든 VM 시스템 trust 번들 (CA 포함됨)                                     |
| `/opt/airgap-ca/harbor.{crt,key}`    | **harbor VM에만**                                                         |
| `/opt/airgap-ca/gitea.{crt,key}`     | **gitea VM에만**                                                          |

검증:
```bash
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /opt/airgap-ca/ca.crt   # (non-infra VM)
# infra VM이면:  openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt /etc/airgap-ca/ca.crt
```

#### Harbor / Gitea 설정 시
- 본인 서비스의 TLS 설정에서 위 `*.crt`와 `*.key`를 마운트하여 사용.
- CN/SAN: `harbor.airgap.local` / `gitea.airgap.local` + 단축명 + IP.
- 825일 유효 (Apple/iOS 호환 한도).

#### Docker / containerd 클라이언트 신뢰 (참고)
시스템 trust에 CA가 이미 있으므로 일반적으로 추가 작업 불필요. 단 containerd 레지스트리 미러 설정 시 별도 hosts.toml 작성 필요할 수 있음 — k3s 담당자와 협의.

---

## 5. 외부 인터넷 접근 (중요)

**기본적으로 모든 VM은 airgap** — 외부망 접근 불가.

오프라인 번들이 부족해 패키지를 임시로 인터넷에서 받아야 한다면 인프라 엔지니어에게 요청:

```bash
# infra 엔지니어가 호스트에서 실행
~/airgap/scripts/bootstrap-net.sh on  <vm_name>   # 일시 개방
~/airgap/scripts/bootstrap-net.sh off <vm_name>   # 다시 차단
```

작업 후 반드시 `off`로 닫아야 airgap 무결성이 유지됩니다.

---

## 6. 트러블슈팅

| 증상                                  | 원인 / 조치                                                            |
|---------------------------------------|------------------------------------------------------------------------|
| `ssh ... Connection timed out`        | Tailscale 미실행 또는 tailnet 미합류 — `tailscale status` 확인         |
| `Permission denied (publickey)`       | 본인 pubkey 미등록 — @kyle에게 키 전달                                 |
| `harbor.airgap.local` 못 찾음 (호스트에서) | 의도된 동작. 해당 이름은 **VM 내부에서만** 해석됨                  |
| Harbor/Gitea가 self-signed 경고       | 클라이언트가 `/opt/airgap-ca/ca.crt`를 trust에 추가했는지 확인          |
| 시계 차이로 TLS/토큰 실패             | `chronyc tracking`으로 동기화 상태 확인                                |

---

## 7. 로컬 `kubectl`로 k3s 접근 (SSH 터널)

k3s API 서버(`:6443`)는 airgap 내부에만 떠 있으므로 SSH 터널로 로컬에 포워딩하는 방식을 사용합니다. 호스트나 API에 포트를 직접 뚫지 않으므로 airgap 무결성이 유지됩니다.

### 7.1 전제
- §1에서 안내한 SSH pubkey가 등록되어 있어 `ssh -p 2203 airgap@100.123.217.17` 가 비밀번호 없이 붙어야 함
- 로컬에 `kubectl` 설치 (`brew install kubectl` / `apt install kubectl`)

### 7.2 일회성 설정 (최초 1회) — macOS / Linux

```bash
# 1) kubeconfig 받아오기 (k3s-master에서 읽어와 로컬로)
mkdir -p ~/.kube
ssh -p 2203 airgap@100.123.217.17 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/airgap-config
chmod 600 ~/.kube/airgap-config

# 2) server URL을 127.0.0.1로 (터널 엔드포인트)
#    macOS
sed -i '' 's|https://127.0.0.1:6443|https://127.0.0.1:6443|' ~/.kube/airgap-config
#    Linux
# sed -i 's|https://127.0.0.1:6443|https://127.0.0.1:6443|' ~/.kube/airgap-config

# 3) context 이름 충돌 방지 (default → airgap)
sed -i.bak 's/name: default$/name: airgap/g; s/cluster: default$/cluster: airgap/; s/user: default$/user: airgap/; s/current-context: default/current-context: airgap/' ~/.kube/airgap-config && rm ~/.kube/airgap-config.bak

# 4) 기존 ~/.kube/config에 병합 (선택 — 격리하려면 이 단계 생략하고 매번 KUBECONFIG=~/.kube/airgap-config 사용)
cp ~/.kube/config ~/.kube/config.bak-$(date +%Y%m%d)
KUBECONFIG=~/.kube/config:~/.kube/airgap-config kubectl config view --flatten > /tmp/merged-kube
mv /tmp/merged-kube ~/.kube/config
chmod 600 ~/.kube/config
```

검증: `kubectl config get-contexts`에 `airgap` context가 보이면 성공.

### 7.3 `~/.ssh/config` — SSH 붙을 때 터널 자동 개방

```
Host airgap-host
  HostName 100.123.217.17
  Port 2203
  User airgap
  LocalForward 6443 127.0.0.1:6443
  ExitOnForwardFailure yes
  ServerAliveInterval 30
```

- `LocalForward 6443 127.0.0.1:6443` — 로컬 6443 → k3s-master VM 내부의 6443으로 포워드 (VM 안에서 보면 k3s API는 `127.0.0.1:6443`에 바인딩됨)
- 로컬 6443이 이미 사용 중이면 `LocalForward 16443 127.0.0.1:6443`으로 바꾸고, kubeconfig의 `:6443`도 `:16443`으로 수정

### 7.4 사용

```bash
# 터미널 A — 터널 세션 유지 (이 창 닫으면 kubectl 끊김)
ssh -N airgap-host

# 터미널 B
kubectl config use-context airgap
kubectl get nodes
```

백그라운드로 돌리고 싶으면:
```bash
ssh -fN airgap-host     # -f: fork, -N: 명령 실행 안 함
pgrep -fl 'ssh.*airgap-host'   # 확인
pkill -f 'ssh.*-N airgap-host' # 종료
```

### 7.5 Windows (PowerShell)

Windows 10/11 내장 OpenSSH 클라이언트 + `kubectl` 기준. OpenSSH가 없으면 `설정 → 앱 → 선택적 기능 → OpenSSH 클라이언트` 설치. `kubectl`은 `winget install -e --id Kubernetes.kubectl` 또는 `choco install kubernetes-cli`.

**1) kubeconfig 받아오기 + 편집** (PowerShell):

```powershell
New-Item -ItemType Directory -Force -Path "$HOME\.kube" | Out-Null

# k3s-master에서 kubeconfig 덤프 (raw 모드로 받아야 CR/LF 변환 안 됨)
ssh -p 2203 airgap@100.123.217.17 "sudo cat /etc/rancher/k3s/k3s.yaml" |
  Set-Content -NoNewline "$HOME\.kube\airgap-config"

# server URL을 127.0.0.1로, context명을 airgap으로
(Get-Content "$HOME\.kube\airgap-config") `
  -replace 'https://127.0.0.1:6443', 'https://127.0.0.1:6443' `
  -replace 'name: default$', 'name: airgap' `
  -replace 'cluster: default$', 'cluster: airgap' `
  -replace 'user: default$', 'user: airgap' `
  -replace 'current-context: default', 'current-context: airgap' |
  Set-Content "$HOME\.kube\airgap-config"

# 파일 권한 (kubectl 경고 방지)
icacls "$HOME\.kube\airgap-config" /inheritance:r /grant:r "${env:USERNAME}:F" | Out-Null
```

**2) 기본 config에 병합** (선택):

```powershell
Copy-Item "$HOME\.kube\config" "$HOME\.kube\config.bak-$(Get-Date -Format yyyyMMdd)"
$env:KUBECONFIG = "$HOME\.kube\config;$HOME\.kube\airgap-config"   # Windows는 세미콜론
kubectl config view --flatten | Set-Content "$HOME\.kube\config.new"
Move-Item -Force "$HOME\.kube\config.new" "$HOME\.kube\config"
Remove-Item Env:KUBECONFIG
```

**3) `~\.ssh\config`** (`%USERPROFILE%\.ssh\config` — 없으면 만들기. 메모장 또는 `notepad $HOME\.ssh\config`):

```
Host airgap-host
  HostName 100.123.217.17
  Port 2203
  User airgap
  IdentityFile ~/.ssh/id_ed25519
  LocalForward 6443 127.0.0.1:6443
  ExitOnForwardFailure yes
  ServerAliveInterval 30
```

**4) 사용**:

```powershell
# 포그라운드 (창 닫으면 터널 종료)
ssh -N airgap-host

# 백그라운드 (별도 창에서)
Start-Process ssh -ArgumentList "-N airgap-host" -WindowStyle Hidden

kubectl config use-context airgap
kubectl get nodes

# 터널 종료 (백그라운드 ssh 찾아서 kill)
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
  Where-Object { $_.CommandLine -like '*airgap-host*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId }
```

**WSL 사용자**: WSL 안에서는 §7.2 (Linux) 절차 그대로. `~/.ssh/config`, `~/.kube/config`는 WSL 배포판 내부 경로. Windows 본체의 `kubectl`과는 별도로 관리됨.

---

### 7.6 context 전환

```bash
kubectl config use-context airgap           # airgap k3s
kubectl config use-context <기존 context>    # 원래 클러스터로 복귀
kubectl config get-contexts                  # 목록
```

### 7.7 트러블슈팅

| 증상 | 원인 / 조치 |
|------|-------------|
| `Unable to connect to the server: dial tcp 127.0.0.1:6443` | 터널 미기동 — `ssh -fN airgap-host` (Windows는 §7.5 참조) |
| `bind: Address already in use` / `Only one usage of each socket address` | 로컬 6443 점유됨 — macOS/Linux `lsof -i :6443`, Windows `Get-NetTCPConnection -LocalPort 6443`. `LocalForward`를 `16443`으로 바꾸고 kubeconfig의 `:6443`도 `:16443`으로 수정 |
| `x509: certificate signed by unknown authority` | kubeconfig의 `certificate-authority-data`가 k3s-master 것이 아님 — §7.2 / §7.5 1)부터 다시 |
| `Permission denied (publickey)` SSH 시점 | pubkey 미등록 — @kyle에게 §1대로 요청 |
| `kubectl`은 되는데 이상한 클러스터에 붙음 | `kubectl config current-context` 확인, `use-context airgap` |
| Windows `sudo: command not found` | `ssh -p 2203 airgap@... "sudo cat ..."` — Windows가 아닌 **원격 VM**에서 sudo 실행. 정상. SSH 쪽 문제일 경우 §7.5 전제 재확인 |

---

## 8. 연락 / 운영 링크

- Infra 엔지니어: @kyle (호스트 `ykgoesdumb` 관리, 네트워크/CA/DNS/NTP)
- 인프라 변경 요청 / VM 재기동 / 추가 키 등록은 슬랙 DM

운영자용:
- Tailscale admin 콘솔 (초대·auth key·ACL): https://login.tailscale.com/admin
- 호스트 헤드네임: `ykgoesdumb-x670-aorus-elite-ax` (IP `100.123.217.17`)
