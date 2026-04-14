# platform/harbor/

폐쇄망 안에서 돌 **사설 컨테이너 레지스트리(Harbor)**. 팀 전체가 쓰는 이미지의 단일 저장소.

---

## 이 담당이 하는 일 = 2가지

### 1. Harbor 서버를 세운다 (= 빈 창고 짓기)
Harbor라는 프로그램을 harbor VM(`192.168.10.12`)에 설치하고, TLS·계정·프로젝트까지 준비.

### 2. Harbor 안에 이미지를 채워 넣는다 (= 창고에 물건 입고)
우리 폐쇄망은 `docker.io` 같은 외부 레지스트리에 **못 닿음**. 그래서 팀이 쓸 이미지 전부를 Harbor에 **미리 복사**해둬야 k3s가 배포할 때 가져다 쓸 수 있음.

> ⚠️ 설치만 하고 끝내면 **빈 창고**. 아무도 못 씀. 2번이 진짜 핵심 업무.

---

## 전제 (인프라가 이미 제공)

| 항목 | 상태 |
|---|---|
| harbor VM (192.168.10.12) | 부팅됨 — `ssh -p 2202 airgap@100.123.217.17` |
| 사설 CA 인증서 | `/opt/airgap-ca/harbor.{crt,key}` 이미 배포됨 |
| DNS | `harbor.airgap.local` → 192.168.10.12 자동 해석 |
| NTP | 동기화 완료 |
| 포트포워딩 | 호스트 `8443` → harbor:8443 (Tailscale 경유 접속 가능) |

---

## Part 1. Harbor 서버 설치 (창고 짓기)

### 체크리스트
- [ ] Harbor offline installer tarball 다운로드 (자기 노트북, 인터넷 있는 곳에서)
  - 공식: `harbor-offline-installer-vX.Y.Z.tgz` (goharbor/harbor releases)
- [ ] tarball을 harbor VM으로 복사
  ```bash
  scp -P 2202 harbor-offline-installer-*.tgz airgap@100.123.217.17:~
  ```
- [ ] harbor VM에서 `harbor.yml` 작성 (핵심 항목)
  - `hostname: harbor.airgap.local`
  - `https.certificate: /opt/airgap-ca/harbor.crt`
  - `https.private_key: /opt/airgap-ca/harbor.key`
  - `harbor_admin_password: <정해서 팀 공유>`
- [ ] `sudo ./install.sh` 실행
- [ ] 브라우저에서 `https://100.123.217.17:8443` 접속 → admin 로그인 확인
- [ ] 프로젝트 생성
  - `mirror` (public) — 외부 이미지 미러용
  - `apps` (private) — 자체 빌드 앱 이미지용
  - `edge` (private) — edge-demo 자체 이미지용
- [ ] Robot account 2개 발급
  - `gitea-runner` — push+pull, `apps`/`edge` 대상 (Gitea Actions용)
  - `k3s-puller` — pull-only, 전 프로젝트 (k3s imagePullSecret용)
  - 토큰은 슬랙 DM으로 Gitea 담당/k3s 담당에 전달

### 설치 중 외부망 필요하면
harbor VM은 기본 airgap. 인프라에게 요청:
```bash
# 호스트에서 (인프라가 실행)
~/airgap/scripts/bootstrap-net.sh on  harbor
# 설치 끝난 뒤
~/airgap/scripts/bootstrap-net.sh off harbor
```

---

## Part 2. 이미지 채워 넣기 (입고 작업)

이게 업무의 절반 이상. 3단계.

### Step 1. 팀원들한테 이미지 목록 받기

각 담당자한테 "너 뭐 쓸 거야?" 물어서 `images/IMAGES.txt` 한 파일로 모음.

담당별로 필요한 것들 (예시):

| 담당 | 대표 이미지 |
|---|---|
| Harbor 자기 자신 | `goharbor/*` (installer에 이미 포함 — 별도 처리 불필요) |
| Gitea | `gitea/gitea`, `gitea/act_runner`, `postgres` |
| k3s | `rancher/mirrored-*`, `traefik`, `coredns`, `local-path-provisioner` |
| cert-manager | `quay.io/jetstack/cert-manager-*` |
| Edge demo (인프라) | `eclipse-mosquitto`, `timescale/timescaledb`, `grafana/grafana` |
| 앱 빌드 base (Gitea Runner가 씀) | `rust:1.80-alpine`, `python:3.12`, `alpine`, `distroless/*` |
| 데모 앱 초기 빌드 | `apps/hello:v1` (앱 담당이 직접 빌드·push) |

파일 형식:
```
# IMAGES.txt
gitea/gitea:1.22
gitea/act_runner:0.2
postgres:16
traefik:v3.0
rust:1.80-alpine
...
```

### Step 2. 외부망에서 이미지를 파일로 뽑기

본인 노트북(인터넷 됨)에서:

```bash
# skopeo 설치 필요 (brew install skopeo 또는 apt install skopeo)
mkdir -p out
while read -r img; do
  [[ "$img" =~ ^#|^$ ]] && continue
  fname=$(echo "$img" | tr '/:' '__').tar
  skopeo copy --override-os linux --override-arch amd64 \
    docker://$img docker-archive:out/$fname:$img
done < IMAGES.txt
```

→ `out/*.tar` 파일들이 생김. 이게 "물건 박스".

스크립트로 박아두세요 → `images/pull-all.sh`.

### Step 3. harbor VM으로 옮겨서 Harbor에 push

tar들을 harbor VM으로 복사:
```bash
scp -P 2202 out/*.tar airgap@100.123.217.17:/tmp/images/
```

harbor VM에서 Harbor에 밀어넣기:
```bash
# images/push-all.sh
skopeo login harbor.airgap.local --username admin --password <PASSWORD>
for tar in /tmp/images/*.tar; do
  # tar 안의 원본 태그를 읽어 mirror/<source>/<name>:<tag>로 push
  skopeo copy docker-archive:$tar docker://harbor.airgap.local/mirror/$(basename $tar .tar | tr '__' '/')
done
```

확인:
```bash
# harbor UI → mirror 프로젝트에 이미지 올라와 있는지
# 또는 k3s 노드에서
sudo crictl pull harbor.airgap.local/mirror/gitea/gitea:1.22
```

---

## 이미지 이름 규칙 (팀 전체 합의 필요)

매니페스트에서 이미지 참조를 **전부 Harbor 주소로 바꿔야 함**:

| 종류 | 포맷 | 예시 |
|---|---|---|
| 외부 이미지 미러 | `harbor.airgap.local/mirror/<source>/<name>:<tag>` | `harbor.airgap.local/mirror/gitea/gitea:1.22` |
| 자체 빌드 앱 | `harbor.airgap.local/apps/<name>:<git-sha>` | `harbor.airgap.local/apps/hello:a1b2c3d` |
| edge-demo 자체 | `harbor.airgap.local/edge/<name>:<tag>` | `harbor.airgap.local/edge/edge-agent:0.1.1` |

이미 다른 담당이 써둔 매니페스트(`airgap/k8s/edge-demo/*.yaml` 등)도 이 규칙에 맞춰 수정 PR 필요.

---

## 인접 담당과의 경계

- **Gitea 담당**: Runner가 Harbor에 push/pull 하려면 위 `gitea-runner` robot 토큰을 Gitea secret에 등록해야 함 → 토큰 받으면 바로 등록.
- **k3s 담당**: 각 네임스페이스에 `k3s-puller` 기반 imagePullSecret 생성 + containerd `hosts.toml`로 사설 CA 신뢰. 매니페스트 샘플은 `manifests/imagepullsecret.yaml`로 제공 예정.
- **인프라**: edge-demo 매니페스트 이미지 주소 치환 — `IMAGES.txt` 제출 후 인프라가 PR 침.
- **앱 담당**: `apps/hello` 초기 v1 이미지는 앱 담당이 직접 빌드해서 Harbor `apps/` 프로젝트에 push.

---

## 디렉토리 구조 (목표)

```
platform/harbor/
├── install/
│   ├── harbor.yml              설정 템플릿
│   └── install-on-vm.sh        래퍼 (tarball 풀고 ./install.sh 까지)
├── manifests/
│   ├── projects.sh             mirror/apps/edge 프로젝트 생성 (Harbor API)
│   ├── robots.sh               robot 계정 발급
│   └── imagepullsecret.yaml    k3s용 샘플
├── images/
│   ├── IMAGES.txt              인제스천 대상 단일 출처
│   ├── pull-all.sh             외부망 실행 → tar 생성
│   └── push-all.sh             airgap 내부 실행 → Harbor에 push
└── README.md                   (이 문서)
```

---

## 최종 산출물이 번들에 들어가야 함

모든 설치물은 최종적으로 `airgap/bundle/`에 포함되어 고객사 airgap 내부로 반입됨. 위 결과물(설치 스크립트 + 이미지 tar들)이 `airgap/bundle/build-bundle.sh`에 경로 등록되어야 함 — 인프라 담당과 협의.

---

## 검증 (끝났다고 말하기 전)

- [ ] `https://harbor.airgap.local` (VM 내부) — 브라우저 경고 없이 열림 (CA 신뢰)
- [ ] `https://100.123.217.17:8443` (Tailscale 경유) — admin 로그인
- [ ] `mirror/gitea/gitea:1.22` 같은 미러 이미지 UI에서 보임
- [ ] k3s-master에서 `sudo crictl pull harbor.airgap.local/mirror/...` 성공
- [ ] Gitea Runner가 robot 토큰으로 `docker login harbor.airgap.local` 성공
