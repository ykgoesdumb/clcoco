# platform/gitea/

폐쇄망 안에서 돌 **사설 Git 서버 + CI(Gitea Actions)**. 팀 전체가 코드를 push 하고, push 하면 자동으로 빌드·배포가 굴러가는 곳.

---

## 이 담당이 하는 일 = 2가지

### 1. Gitea 서버를 세운다 (= Git 저장소 오픈)
Gitea라는 프로그램을 gitea VM(`192.168.10.11`)에 설치. TLS·계정·리포까지 준비.
→ `git push`, `git clone` 되는 상태.

### 2. Gitea Actions Runner를 붙인다 (= 자동 작업장 가동) ← 핵심
그냥 Git만 돌면 의미 없음. **"코드 push → 이미지 빌드 → Harbor에 업로드 → k3s에 배포"**
이 자동 파이프라인이 우리 데모의 **메인 스토리**. 이걸 돌리는 게 Gitea Actions Runner.

> ⚠️ Runner가 안 돌면 데모 전체가 멈춤. 단순 Git 호스팅은 부록, Runner가 본진.

---

## 전제 (인프라가 이미 제공)

| 항목 | 상태 |
|---|---|
| gitea VM (192.168.10.11) | 부팅됨 — `ssh -p 2201 airgap@100.123.217.17` |
| 사설 CA 인증서 | `/opt/airgap-ca/gitea.{crt,key}` 이미 배포됨 |
| DNS | `gitea.airgap.local` → 192.168.10.11 자동 해석 |
| NTP | 동기화 완료 |
| 포트포워딩 | 호스트 `3000` → gitea:3000 (Tailscale 경유 웹 UI 접속) |
| Harbor 접근 | Harbor 담당이 `gitea-runner` robot 토큰 발급해 전달 예정 |

---

## Part 1. Gitea 서버 설치 (Git 저장소 오픈)

### 체크리스트
- [ ] Gitea 설치 방식 결정 — **binary + systemd** 또는 **docker-compose**. 간단한 쪽은 docker-compose.
- [ ] docker-compose 쓰면 필요한 이미지를 미리 준비 (`gitea/gitea`, `postgres`) — Harbor 담당에게 `IMAGES.txt`에 추가 요청
- [ ] 설정 파일 작성 (`app.ini` 핵심 항목)
  - `DOMAIN = gitea.airgap.local`
  - `ROOT_URL = https://gitea.airgap.local/`
  - `HTTP_PORT = 3000`
  - TLS: 리버스 프록시 쓸지 Gitea 자체 TLS 쓸지 결정. 자체 TLS면 `/opt/airgap-ca/gitea.{crt,key}` 지정
- [ ] 기동 후 브라우저에서 `http://100.123.217.17:3000` 접속 → **초기 admin 생성**
- [ ] admin 비번 팀 공유 (슬랙 DM)
- [ ] 조직(org) 생성: `clcoco`
- [ ] 데모용 리포 1개 생성: `clcoco/hello` (앱 담당이 여기에 코드 push)

### 설치 중 외부망 필요하면
인프라에게 요청:
```bash
~/airgap/scripts/bootstrap-net.sh on  gitea
~/airgap/scripts/bootstrap-net.sh off gitea   # 끝나면 반드시
```

---

## Part 2. Gitea Actions Runner (자동 작업장)

여기가 이 담당의 핵심. 3단계.

### Step 1. Actions 기능 활성화

Gitea 자체 설정에서 Actions를 켠다 — `app.ini`:
```ini
[actions]
ENABLED = true
DEFAULT_ACTIONS_URL = https://gitea.airgap.local
```

**주의**: 기본값은 `github.com`을 바라봄 → airgap에서 `uses: actions/checkout@v4` 같은 구문이 외부를 찾아 깨짐. 반드시 자기 자신으로 돌려야 함. `clcoco/actions` 같은 리포 만들어서 `checkout` 같은 공용 액션을 미러링해두는 게 권장.

### Step 2. Runner 이미지 준비

Runner는 **컨테이너로 빌드를 돌리는 놈**. 그래서 Runner 이미지 안에 빌드 도구가 다 들어 있어야 함 (airgap이라 런타임에 `apt install` 불가).

Runner 이미지에 들어가야 할 것들:
- Docker/Buildah (컨테이너 이미지 빌드용)
- `skopeo` (Harbor push용)
- `kubectl` (k3s에 배포용)
- 사설 CA (`/opt/airgap-ca/ca.crt`) 신뢰 등록
- (옵션) `cargo`, `go`, `node` — 언어별 빌드 필요하면

옵션 A: 공식 `gitea/act_runner` 이미지 + 필요 도구 추가로 커스텀 이미지 빌드
옵션 B: `docker-in-docker` 사이드카 사용

권장은 A — 커스텀 `Dockerfile.runner`로 한 번에 말아두기:

```dockerfile
FROM gitea/act_runner:latest
RUN apk add --no-cache docker-cli skopeo curl ca-certificates
COPY ca.crt /usr/local/share/ca-certificates/airgap-ca.crt
RUN update-ca-certificates
# kubectl
RUN curl -LO https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl && \
    install kubectl /usr/local/bin/ && rm kubectl
```

### Step 3. Runner 등록 + 기동

```bash
# gitea UI → Site Administration → Actions → Runners → "Create new Runner"
# 발급된 토큰을 복사

docker run -d --name act_runner \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $PWD/runner-data:/data \
  -e GITEA_INSTANCE_URL=https://gitea.airgap.local \
  -e GITEA_RUNNER_REGISTRATION_TOKEN=<TOKEN> \
  harbor.airgap.local/apps/act_runner:custom
```

등록되면 UI에 `online` 상태로 뜸.

### Step 4. Secret 주입 (Runner가 Harbor/k3s에 접근하도록)

Gitea의 **Org 또는 리포 Settings → Actions → Secrets**:

| Secret 이름 | 값 | 출처 |
|---|---|---|
| `HARBOR_USER` | `robot$gitea-runner` | Harbor 담당이 전달 |
| `HARBOR_PASS` | `<토큰>` | Harbor 담당이 전달 |
| `KUBECONFIG` | k3s kubeconfig 내용 (base64) | k3s 담당이 전달 |

### Step 5. 샘플 워크플로

`apps/` 담당이 복붙해서 쓰도록 템플릿 제공 — `.gitea/workflows/ci.yml`:

```yaml
name: build-and-deploy
on: { push: { branches: [main] } }
jobs:
  build:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      - name: Login Harbor
        run: echo "$HARBOR_PASS" | skopeo login harbor.airgap.local -u "$HARBOR_USER" --password-stdin
      - name: Build + push
        run: |
          TAG=$(git rev-parse --short HEAD)
          docker build -t harbor.airgap.local/apps/hello:$TAG .
          docker push harbor.airgap.local/apps/hello:$TAG
      - name: Rollout
        env: { KUBECONFIG_DATA: ${{ secrets.KUBECONFIG }} }
        run: |
          echo "$KUBECONFIG_DATA" | base64 -d > /tmp/kc
          kubectl --kubeconfig=/tmp/kc -n apps set image deploy/hello hello=harbor.airgap.local/apps/hello:$TAG
```

---

## 검증 (끝났다고 말하기 전)

- [ ] 브라우저에서 `https://gitea.airgap.local` (VM 내부) — CA 경고 없이 열림
- [ ] Tailscale 경유 `http(s)://100.123.217.17:3000` — admin 로그인
- [ ] 로컬에서 `git clone https://gitea.airgap.local/clcoco/hello.git` 성공
- [ ] Runner UI 상태 `online`
- [ ] 테스트 push 하면 워크플로가 돌아가고 Harbor `apps/hello:<sha>` 이미지가 생김
- [ ] k3s에서 해당 이미지로 파드가 교체됨 (`kubectl rollout status deploy/hello`)

---

## 인접 담당과의 경계

- **Harbor 담당**: `gitea-runner` robot 토큰 수령 → 위 Secret 등록. Runner 커스텀 이미지도 Harbor `apps/act_runner`에 push 필요 → push 경로 열어달라고 요청.
- **k3s 담당**: kubeconfig 발급 받아서 Secret 등록. Runner에서 실제로 `kubectl` 되는지 스모크 테스트.
- **앱 담당**: 위 샘플 워크플로를 `apps/hello/.gitea/workflows/ci.yml`에 복사해 쓰기. 이미지 이름 규칙(`harbor.airgap.local/apps/<name>:<sha>`) 준수.
- **인프라**: Gitea가 써야 할 외부 이미지(gitea, postgres, act_runner base) → Harbor 담당의 `IMAGES.txt`에 포함 요청.

---

## 디렉토리 구조 (목표)

```
platform/gitea/
├── install/
│   ├── app.ini.template        설정 템플릿
│   ├── docker-compose.yml      (선택) compose 배포
│   └── install-on-vm.sh        래퍼
├── runner/
│   ├── Dockerfile.runner       커스텀 Runner 이미지
│   ├── register.sh             토큰 받아 등록하는 스크립트
│   └── workflow-template.yml   앱 담당용 샘플 워크플로
├── seed/
│   └── create-repos.sh         조직/리포 일괄 생성 (API)
└── README.md                   (이 문서)
```

---

## 최종 산출물이 번들에 들어가야 함

설치 스크립트 + Runner 커스텀 이미지 + app.ini 템플릿이 최종적으로 `airgap/bundle/`에 포함되어야 함. 경로는 `airgap/bundle/build-bundle.sh`에 등록 — 인프라 담당과 협의.
