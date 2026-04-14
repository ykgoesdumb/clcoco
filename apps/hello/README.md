# apps/hello/

"git push → 자동 배포" 데모의 주인공. `apps/hello/src/app.py` 한 줄 바꿔 커밋·푸시하면 Gitea Actions 가 빌드→Harbor→k3s 로 롤아웃.

## 파일

| 경로 | 역할 |
|---|---|
| `src/app.py` | Python stdlib HTTP 서버, `GET /` 가 `APP_VERSION` 반환 |
| `Dockerfile` | `FROM python:3.12-slim` (Harbor 미러에 있음) |
| `k8s/deployment.yaml` | apps ns Deployment (초기 이미지 `:bootstrap`) |
| `k8s/service.yaml` | ClusterIP :80 → Pod :8080 |
| `k8s/ingress.yaml` | `https://hello.apps.airgap.local` (cert-manager + airgap-ca) |
| `.gitea/workflows/ci.yml` | push 시 build/push/rollout |

## 최초 부트스트랩 (한 번만)

Runner 의 `kubectl set image` 는 **기존 Deployment 가 있어야** 성공. 다음 순서로:

```bash
# 1. apps ns + harbor-pull-secret (k3s 담당 이미 했다면 스킵)
kubectl create ns apps --dry-run=client -o yaml | kubectl apply -f -
HARBOR_TOKEN='<k3s-puller pw>' bash platform/k3s/apply-imagepullsecrets.sh

# 2. 부트스트랩 이미지 수동 빌드+푸시 (한 번만)
docker build --build-arg APP_VERSION=bootstrap -t harbor.airgap.local/apps/hello:bootstrap apps/hello/
docker push harbor.airgap.local/apps/hello:bootstrap

# 3. Deployment / Service / Ingress apply
kubectl apply -f apps/hello/k8s/
kubectl -n apps rollout status deploy/hello
```

## 데모 루프

1. `apps/hello/src/app.py` 의 `MESSAGE` 문자열을 수정
2. `git commit -am 'demo: bump message' && git push origin main`
3. Gitea UI → Actions 탭에서 파이프라인 진행 관찰
4. `curl https://hello.apps.airgap.local` 응답이 새 sha 로 바뀌어 있음

## Secret 요구사항 (Gitea Org/Repo Settings → Actions → Secrets)

| 이름 | 출처 |
|---|---|
| `HARBOR_USER` | `robot$gitea-runner` (Harbor 담당) |
| `HARBOR_PASS` | 위 robot 토큰 |
| `KUBECONFIG` | `platform/k3s/gen-runner-kubeconfig.sh` 출력 (base64) |
