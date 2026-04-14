# Demo Prep — 시연 전 1회만

시연에서는 설치를 보여주지 않는다. **준비된 상태**에서 airgap 컷오프 → git push 루프 → 런타임 비교 3막만 보여준다.
이 문서는 그 "준비된 상태"를 **한 번** 만드는 체크리스트.

## 출력물

모든 단계 완료 시:
- 4 VM (infra/harbor/gitea/k3s-master) 기동 + 서비스 Ready
- Harbor `apps/hello:bootstrap`, `apps/hello:<git-sha>` 존재
- `https://hello.apps.airgap.local/` 가 200 반환
- `https://gitea.airgap.local/clcoco/hello` repo + Actions runner Idle
- `https://grafana.apps.airgap.local/` "Bridge Comparison: Python vs Rust" 대시보드 접근
- 각 VM `demo-ready-<date>` qcow2 스냅샷 존재 (reset.sh 의존)

## 1. 인프라 + 번들 분배

루트 README §1~§4 그대로.
```bash
[host]$ airgap/scripts/install-host.sh
[host]$ airgap/scripts/create-all-vms.sh && airgap/scripts/wait-for-vms.sh
[host]$ sudo airgap/scripts/portfwd.sh apply && sudo systemctl enable --now airgap-portfwd
[host]$ airgap/scripts/bootstrap-net.sh on infra
[infra]$ sudo ~/airgap/scripts/infra-services.sh && sudo ~/airgap/scripts/infra-ca.sh
[host]$ airgap/scripts/distribute-ca.sh
[host]$ airgap/scripts/bootstrap-net.sh off infra
[host]$ platform/harbor/install/fetch-docker-debs.sh   # 선택
[host]$ airgap/bundle/build-bundle.sh
[host]$ airgap/scripts/distribute-bundle.sh
```

## 2. Harbor

```bash
[harbor]$ sudo /opt/offline-bundle/platform/harbor/install/install-on-vm.sh
[harbor]$ sudo /opt/offline-bundle/platform/harbor/images/push-all.sh
[harbor]$ sudo /opt/offline-bundle/platform/harbor/manifests/projects.sh
[harbor]$ sudo /opt/offline-bundle/platform/harbor/manifests/robots.sh
#         → ~/harbor-robot-tokens.txt 에 robot$gitea-runner / robot$k3s-puller 기록
```

## 3. k3s + 통합

```bash
[k3s-master]$ sudo /opt/offline-bundle/install.sh
[k3s-master]$ sudo /opt/offline-bundle/platform/k3s/install-registries.sh
[k3s-master]$ HARBOR_TOKEN='<k3s-puller pw>' \
              bash /opt/offline-bundle/platform/k3s/apply-imagepullsecrets.sh
[k3s-master]$ kubectl apply -f /opt/offline-bundle/platform/k3s/gitea-runner-rbac.yaml
[k3s-master]$ /opt/offline-bundle/platform/k3s/gen-runner-kubeconfig.sh > /tmp/kc.b64
[k3s-master]$ scp -P 2201 /tmp/kc.b64 airgap@<host>:/tmp/kc.b64
```

## 4. Gitea + Secrets

```bash
[gitea]$ sudo /opt/offline-bundle/platform/gitea/install/install-on-vm.sh
[gitea]$ sudo HARBOR_TOKEN_FILE=~/harbor-robot-tokens.txt \
              KUBECONFIG_FILE=/tmp/kc.b64 \
              /opt/offline-bundle/platform/gitea/install/register-secrets.sh
```

## 5. apps/hello 부트스트랩 push

시연에서 "push 하자마자 Actions 가 돈다" 를 보여주려면 bootstrap push 를 **미리** 한 번 해둬야 함 (최초 빌드 5~7분 소요 — 시연 타이밍에 끼이면 안 됨).

```bash
[dev]$ git clone https://gitea.airgap.local/clcoco/hello.git /tmp/hello-boot
[dev]$ cp -r <repo>/apps/hello/{src,Dockerfile,k8s,.gitea,README.md} /tmp/hello-boot/
[dev]$ cd /tmp/hello-boot
[dev]$ git add . && git commit -m 'bootstrap' && git push
#      → Gitea Actions 완료까지 대기. Harbor 에 apps/hello:<sha> 생성 확인.
[k3s-master]$ kubectl apply -f /opt/offline-bundle/apps/hello/k8s/
[k3s-master]$ kubectl -n apps rollout status deploy/hello
[k3s-master]$ curl -k https://hello.apps.airgap.local/   # 200 확인
```

## 6. kps + edge-demo (비교 대시보드)

```bash
[host]$ airgap/scripts/bootstrap-net.sh on k3s-master
[k3s-master]$ bash /opt/offline-bundle/airgap/k8s/platform/kube-prometheus-stack/install.sh
[k3s-master]$ kubectl apply -f /opt/offline-bundle/airgap/k8s/edge-demo/
[host]$ airgap/scripts/bootstrap-net.sh off k3s-master
[k3s-master]$ kubectl -n monitoring get po    # prometheus/grafana Running
[k3s-master]$ kubectl -n edge-demo get po     # bridge/edge-agent Running
```

브라우저: `https://grafana.apps.airgap.local/` → "Bridge Comparison: Python vs Rust" 가 뜨는지 확인.

## 7. 검증

```bash
[host]$ demo/verify.sh
```
전 체크 PASS 확인.

## 8. 스냅샷 (리허설 간 복구용)

```bash
[host]$ DATE=$(date +%Y%m%d)
[host]$ for vm in airgap-infra airgap-gitea airgap-harbor airgap-k3s-master; do
          sudo virsh snapshot-create-as --domain $vm --name demo-ready-$DATE --atomic
        done
```

리허설 중 상태가 오염되면:
```bash
[host]$ demo/reset.sh demo-ready-<DATE>
```
