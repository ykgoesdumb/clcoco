# platform/k3s/

k3s 노드를 **Harbor 와 묶는 통합 설정**. 클러스터 부트스트랩 자체는 `airgap/bundle/lib/10-k3s.sh` 에서 이미 처리됨 — 여기는 그 위에 올라가는 **레지스트리 통합·Secret·kubeconfig 발급** 을 다룸.

---

## 이 담당이 하는 일 = 3가지

### 1. containerd 에게 Harbor 를 알려준다 (= 노드가 `harbor.airgap.local` 에서 pull 하도록 배선)
하지 않으면 k3s 가 이미지를 못 당겨와 **모든 매니페스트 `ImagePullBackOff`**. 데모 정지 1호 원인.

### 2. 각 네임스페이스에 imagePullSecret 을 심는다
Harbor 의 `apps`/`edge` 프로젝트는 private 이라 robot 토큰 없이는 pull 불가. 네임스페이스마다 Secret 만들고 Deployment/Pod 가 참조하도록 함.

### 3. Gitea Runner 에게 k3s 를 제어할 kubeconfig 를 발급한다
Runner 가 `kubectl set image` 로 롤링 업데이트를 치는 구조라 **권한 축소한 ServiceAccount kubeconfig** 하나 발급해서 Gitea secret 으로 넘김.

---

## 전제 (다른 담당이 이미 제공)

| 항목 | 상태 |
|---|---|
| k3s-master (192.168.10.20) + worker1/2 (.21/.22) | 부팅 + k3s 클러스터 기동됨 |
| `/etc/rancher/k3s/k3s.yaml` | kubeconfig 존재 (root only) |
| 사설 CA (`/opt/airgap-ca/ca.crt`) | 전 k3s 노드에 배포·trust 등록됨 (`distribute-ca.sh` 수행 완료) |
| Harbor | `harbor.airgap.local:443` 에서 서빙 중, robot 계정 발급됨 |
| Robot 토큰 (`robot$k3s-puller`) | Harbor 담당에게 요청 |

---

## Part 1. containerd `hosts.toml` — Harbor 미러 배선

### 왜 필요한가
k3s 의 containerd 는 기본적으로 `docker.io` 등 외부 레지스트리로 나감. 폐쇄망에서는 다 막혀 있으므로 **모든 registry 요청을 `harbor.airgap.local/mirror/...` 로 리라이트** 하거나, 최소한 매니페스트에 박힌 `harbor.airgap.local` 도메인을 CA 신뢰 + TLS 로 올바르게 말 붙이게 해야 함.

### 옵션 비교 (하나 선택)

**옵션 A — Harbor 를 모든 public registry 의 미러로 (권장)**
매니페스트에서 `image: nginx:1.25` 같은 원본 주소를 그대로 써도 containerd 가 Harbor 로 우회. 팀이 매니페스트를 덜 고쳐도 됨.

**옵션 B — 매니페스트 주소를 전부 `harbor.airgap.local/...` 로 박음**
containerd 설정은 Harbor 엔드포인트 CA 신뢰만. 단순하지만 모든 매니페스트 수정 필요.

### 체크리스트 (옵션 A 기준)

- [ ] 전 노드(master + worker1 + worker2) 에 `/etc/rancher/k3s/registries.yaml` 배포
  ```yaml
  mirrors:
    "docker.io":
      endpoint:
        - "https://harbor.airgap.local/v2/mirror/docker.io"
    "quay.io":
      endpoint:
        - "https://harbor.airgap.local/v2/mirror/quay.io"
    "harbor.airgap.local":
      endpoint:
        - "https://harbor.airgap.local"
  configs:
    "harbor.airgap.local":
      tls:
        ca_file: /opt/airgap-ca/ca.crt
      auth:
        username: "robot$k3s-puller"
        password: "<HARBOR 담당에게서 받은 토큰>"
  ```
- [ ] `sudo systemctl restart k3s` (master) / `k3s-agent` (worker) — k3s 는 `registries.yaml` 을 읽어 containerd 에 전파
- [ ] 스모크 테스트 (전 노드)
  ```bash
  sudo crictl pull harbor.airgap.local/mirror/alpine:3.19
  sudo k3s crictl images | grep harbor.airgap.local
  ```

### 산출물
- `platform/k3s/registries.yaml.tmpl` — 위 YAML 템플릿
- `platform/k3s/install-registries.sh` — 3개 노드에 ssh 로 뿌리고 k3s 재시작

---

## Part 2. imagePullSecret — 네임스페이스별 주입

### 대상 네임스페이스
| NS | 용도 | 생성 주체 |
|---|---|---|
| `apps` | 앱 담당의 데모 앱 | k3s 담당 |
| `edge-demo` | 기존 엣지 파이프라인 (이미 존재) | k3s 담당 |
| `default` | 임시 테스트용 | 선택 |

### 체크리스트

- [ ] `platform/harbor/manifests/create-imagepullsecret.sh` 이미 있음 — 재사용
- [ ] 각 ns 에 생성:
  ```bash
  bash platform/harbor/manifests/create-imagepullsecret.sh '<TOKEN>' apps
  bash platform/harbor/manifests/create-imagepullsecret.sh '<TOKEN>' edge-demo
  ```
- [ ] 기존 edge-demo 매니페스트(`airgap/k8s/edge-demo/*.yaml`) 의 Pod/Deployment 에 `imagePullSecrets: [{name: harbor-pull-secret}]` 추가 (인프라 담당과 분담)
- [ ] 검증:
  ```bash
  kubectl -n apps run pulltest --image=harbor.airgap.local/apps/hello:v1 --restart=Never
  kubectl -n apps describe pod pulltest | grep -i pull
  kubectl -n apps delete pod pulltest
  ```

### 산출물
- `platform/k3s/apply-imagepullsecrets.sh` — 대상 ns 목록 돌면서 위 헬퍼 호출

---

## Part 3. Gitea Runner 용 kubeconfig 발급

### 왜 필요한가
Gitea Runner 가 빌드 후 `kubectl set image deploy/hello hello=harbor.airgap.local/apps/hello:$SHA` 치려면 k3s 접근 kubeconfig 가 필요. **admin kubeconfig 를 그대로 주면 보안상 과도** — Runner 는 `apps` ns 의 deploy 에 update 만 할 수 있으면 됨.

### 체크리스트

- [ ] ServiceAccount + Role + RoleBinding 만들기
  ```yaml
  # platform/k3s/gitea-runner-rbac.yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata: { name: gitea-runner, namespace: apps }
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: Role
  metadata: { name: gitea-runner, namespace: apps }
  rules:
    - apiGroups: ["apps"]
      resources: ["deployments"]
      verbs: ["get","list","patch","update"]
    - apiGroups: [""]
      resources: ["pods"]
      verbs: ["get","list"]
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata: { name: gitea-runner, namespace: apps }
  roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: gitea-runner }
  subjects:
    - { kind: ServiceAccount, name: gitea-runner, namespace: apps }
  ```
- [ ] SA 토큰으로 kubeconfig 조립 → `gen-runner-kubeconfig.sh` 스크립트
- [ ] 출력 kubeconfig 를 base64 로 인코딩 → Gitea 담당에게 넘겨서 `KUBECONFIG` secret 으로 등록

### 산출물
- `platform/k3s/gitea-runner-rbac.yaml`
- `platform/k3s/gen-runner-kubeconfig.sh`

---

## 검증 (끝났다고 말하기 전)

- [ ] 전 노드에서 `crictl pull harbor.airgap.local/mirror/alpine:3.19` 성공
- [ ] `apps` ns 에서 `harbor.airgap.local/apps/*` 이미지로 Pod 띄워지면 pull 성공
- [ ] Gitea Runner 가 kubeconfig 로 `kubectl -n apps get deploy` 성공 (deploy 만)
- [ ] Gitea Runner 가 `kubectl -n kube-system get pods` 는 **실패** 해야 (권한 축소 확인)

---

## 디렉토리 구조 (목표)

```
platform/k3s/
├── registries.yaml.tmpl            containerd 미러 설정 템플릿
├── install-registries.sh           3개 노드에 배포 + k3s 재시작
├── apply-imagepullsecrets.sh       ns 목록 돌며 Harbor pull-secret 생성
├── gitea-runner-rbac.yaml          Runner 용 축소 권한 RBAC
├── gen-runner-kubeconfig.sh        kubeconfig 발급 + base64 출력
└── README.md                       (이 문서)
```

---

## 인접 담당과의 경계

- **Harbor 담당**: `robot$k3s-puller` 토큰 + `robot$gitea-runner` 토큰 전달
- **Gitea 담당**: 발급된 kubeconfig(base64) 를 `KUBECONFIG` secret 으로 Gitea 에 등록
- **앱 담당**: 매니페스트에 `imagePullSecrets: [{name: harbor-pull-secret}]` + `namespace: apps` 명시
- **인프라**: 기존 `airgap/k8s/edge-demo/*.yaml` 매니페스트에 pull-secret 적용하는 PR (k3s 담당이 `edge-demo` ns 에 Secret 심은 뒤)
