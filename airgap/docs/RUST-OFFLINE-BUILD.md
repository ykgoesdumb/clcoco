# Rust 오프라인 빌드 (airgap)

> `edge-agent` 를 인터넷 없는 환경에서 빌드하기 위한 절차.
> 독자: (1) 고객사 airgap 내부의 Gitea Actions 러너에서 edge-agent 를 재빌드해야 하는 고객사 개발자, (2) 랩 내 dev VM에서 직접 빌드 테스트하는 우리 팀원.
> 우리 팀의 릴리스 빌드는 GitHub Actions(인터넷 있음)에서 이미지로 만들어 번들에 넣으므로 이 절차가 필요 없다. 이 문서는 **번들이 배포된 이후 고객사 측에서 소스를 수정해 재빌드할 때** 쓴다.

## 배경

Cargo는 기본적으로 `crates.io`에서 의존성을 받는다. airgap VM은 외부망이 막혀 있어 그대로는 빌드 불가.
해결책: 온라인 머신에서 `cargo vendor`로 크레이트 트리를 한 번 떠낸 뒤, 번들을 airgap 안으로 옮겨 `.cargo/config.toml` 로 vendor 디렉토리를 바라보게 한다.

## 1회차: vendor 생성 (인터넷 있는 머신)

dev VM에서 일시 개방한 상태 또는 로컬 개발 머신에서:

```bash
cd airgap/edge-agent
cargo fetch                           # Cargo.lock 생성/고정
cargo vendor > .cargo/config.toml     # vendor/ 생성 + config 출력
tar czf edge-agent-vendor.tgz vendor/ .cargo/config.toml Cargo.lock
```

산출물: `edge-agent-vendor.tgz` (수백 MB 예상).

## 번들로 옮기기

호스트의 오프라인 번들 디렉토리에 적재:

```bash
scp edge-agent-vendor.tgz ykgoesdumb:/opt/offline-bundle/rust/
```

## 2회차: airgap 안에서 빌드

### 옵션 A — dev VM에서 직접 (바이너리만 필요할 때)

```bash
ssh -p 2206 airgap@100.123.217.17
cd ~/edge-agent   # 레포 clone 해둔 상태
tar xzf /opt/offline-bundle/rust/edge-agent-vendor.tgz
cargo build --release --offline
```

### 옵션 B — Gitea Actions에서 컨테이너 이미지로 (배포 경로)

Actions 러너는 본 레포를 체크아웃한 뒤 다음을 수행:

```bash
tar xzf /opt/offline-bundle/rust/edge-agent-vendor.tgz -C airgap/edge-agent/
podman build -t harbor.airgap.local/edge/edge-agent:$(git rev-parse --short HEAD) \
  -f airgap/edge-agent/Containerfile airgap/edge-agent/
podman push harbor.airgap.local/edge/edge-agent:...
```

`Containerfile`은 `cargo build --release --offline`만 호출하므로 네트워크 없이 완결된다.

## 의존성 추가 시

크레이트를 하나 추가할 때마다 vendor 전체를 다시 떠야 한다:

1. 로컬에서 `Cargo.toml` 편집 → `cargo fetch` → `cargo vendor > .cargo/config.toml`
2. `edge-agent-vendor.tgz` 재생성 → `/opt/offline-bundle/rust/` 로 복사
3. 커밋에는 `Cargo.toml` + `Cargo.lock` 만 포함. `vendor/` 와 `.cargo/config.toml` 은 `.gitignore` 처리됨.

번들 갱신 때문에 호스트에서 `bootstrap-net.sh on dev` 일시 개방이 필요할 수 있음. 끝나면 반드시 `off`.

## 시연용 수치 (narrative)

| 항목            | Python bridge (현재) | Rust edge-agent |
|-----------------|----------------------|-----------------|
| 이미지 크기     | ~150 MB (python:3.12-slim + pip)      | ~15 MB (alpine + static bin) |
| RSS (idle)      | ~40 MB               | ~5 MB           |
| 콜드 스타트     | initContainer pip install (수십 초)   | 즉시            |
| GC pause        | 있음                  | 없음            |

발표 영상에서 `kubectl top pod -n edge-demo` 캡처로 좌/우 비교.
