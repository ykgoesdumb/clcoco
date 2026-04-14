# platform/gitea/

폐쇄망 안에서 돌 **사설 Git 서버 + CI(Gitea Actions)**. 팀 전체가 코드를 push 하고, push 하면 자동으로 빌드·배포가 굴러가는 곳.

---

## 역할 = 2가지

### 1. Gitea 서버 (Git 저장소)
Gitea를 gitea VM(`192.168.10.11`)에 docker-compose 로 설치. `git push`, `git clone` 되는 상태.

### 2. Gitea Actions Runner (자동 작업장) ← 데모의 메인 스토리
**"코드 push → 이미지 빌드 → Harbor에 업로드 → k3s에 배포"** 를 굴리는 놈. Runner가 안 돌면 데모 전체가 멈춘다.

---

## 전제 (인프라 제공)

| 항목 | 상태 |
|---|---|
| gitea VM (192.168.10.11) | 부팅됨 — `ssh -p 2201 airgap@100.123.217.17` |
| 사설 CA | `/opt/airgap-ca/ca.crt` 배포됨 |
| DNS | `gitea.airgap.local` → 192.168.10.11 |
| Docker + compose | Harbor VM과 동일 패턴으로 설치됨 (번들 `/opt/offline-bundle/docker/`) |
| Harbor | `harbor.airgap.local` 에서 `mirror/gitea/gitea:1.22`, `mirror/postgres:16-alpine`, `mirror/gitea/act_runner:0.3` 접근 가능 |
| 포트포워딩 | 호스트 `3000` → gitea:3000 (Tailscale 경유 웹 UI) |

---

## Part 1. 설치 (one-liner)

gitea VM에서:
```bash
cd /opt/offline-bundle/platform/gitea/install
sudo bash install-on-vm.sh
```

스크립트가 순서대로 해주는 일:
1. root/docker/compose 확인
2. Harbor CA 신뢰 + `/etc/hosts` 엔트리 (Harbor 이미지 pull 목적)
3. `docker compose up -d db gitea`
4. admin 계정 생성 + PAT 발급 (`gitea admin user create` / `generate-access-token`)
5. `seed.sh` — 조직 `clcoco` + 리포 `clcoco/hello` + 샘플 워크플로 push + runner 등록 토큰 발급
6. `docker compose --profile runner up -d runner` — act_runner 자동 등록

완료되면:
- UI: http://gitea.airgap.local:3000  (또는 Tailscale로 `http://100.123.217.17:3000`)
- admin: `gitea-admin` / `admin_pass_change_me`  (env `ADMIN_USER`/`ADMIN_PASS`로 변경)
- PAT: `/opt/gitea/admin.token`
- runner.env: `/opt/gitea/runner.env`

### 환경 변수 오버라이드
```bash
ADMIN_PASS=strong_pass HARBOR_IP=192.168.10.10 sudo -E bash install-on-vm.sh
```

### 재실행 (idempotent)
- admin 이미 있으면 skip, PAT 재사용, org/repo 존재하면 skip
- runner는 `/opt/gitea/runner` 아래 `.runner` 파일이 있으면 재등록 안 함

---

## Part 2. Runner 검증

```bash
# 등록 상태
docker logs gitea-runner --tail 30 | grep -E 'registered|connected|ready'

# gitea UI: Site Administration → Actions → Runners  → status online
```

샘플 워크플로가 기동되려면 Secret이 필요:

| Secret | 값 | 출처 |
|---|---|---|
| `HARBOR_USER` | `robot$gitea-runner` | Harbor 담당 |
| `HARBOR_PASS` | `<토큰>` | Harbor 담당 |
| `KUBECONFIG` | k3s kubeconfig (base64) | k3s 담당 |

Gitea UI → `clcoco` org → Settings → Actions → Secrets.

---

## Part 3. 데모 시나리오

1. 앱 담당이 `clcoco/hello` 리포에 코드 push
2. `.gitea/workflows/ci.yml` 이 자동 트리거 (seed.sh가 이미 push해둠, `runner/workflow-template.yml` 참고)
3. runner가 Harbor에 이미지 build + push
4. runner가 k3s에 rollout

실시간 확인:
```bash
# 액션 로그
gitea UI → clcoco/hello → Actions

# Harbor에 이미지
curl -u robot\$gitea-runner:<TOKEN> https://harbor.airgap.local/api/v2.0/projects/apps/repositories

# k3s rollout
kubectl --context=airgap -n apps rollout status deploy/hello
```

---

## 디렉토리

```
platform/gitea/
├── install/
│   ├── docker-compose.yml        db + gitea + runner (profile runner)
│   ├── runner-config.yaml        act_runner 설정
│   ├── install-on-vm.sh          한방 설치
│   └── seed.sh                   org/repo + runner 등록 토큰
├── runner/
│   └── workflow-template.yml     앱 담당용 샘플 워크플로
└── README.md                     (이 문서)
```

---

## 알려진 제한 / 추후

- **TLS 미적용** (HTTP :3000). 데모는 Tailscale 포워딩으로 접속하므로 충분. 필요해지면 `GITEA__server__PROTOCOL=https` + `CERT_FILE`/`KEY_FILE` 주입 + `/opt/airgap-ca/gitea.{crt,key}` 마운트.
- **Runner 이미지 확장**: 현재 기본 `gitea/act_runner:0.3` — docker-cli와 skopeo/kubectl 추가가 필요하면 커스텀 `Dockerfile.runner` 빌드 후 `harbor.airgap.local/apps/act_runner:custom` push.
- **번들 포함**: 현재는 Lab 용도. 번들 반영은 `airgap/bundle/build-bundle.sh` + `lib/25-platform.sh` 업데이트 필요 (Harbor과 동일 패턴).
