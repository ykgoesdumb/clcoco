# Airgap Install Bundle

> 인터넷이 전혀 없는 환경에서 Ubuntu 22.04 호스트 한 대 위에 k3s + 플랫폼 계층(cert-manager + ArgoCD) + 엣지 데모 스택까지 전부 올리기 위한 오프라인 번들. 설치 직후 HTTPS Ingress가 바로 떠 있음.

## 구성

```
bundle/
├── install.sh                # 메인 설치 엔트리 (k3s → 이미지 → 플랫폼 → 앱)
├── uninstall.sh
├── lib/                      # 설치 스테이지 스크립트
│   ├── 10-k3s.sh             # k3s airgap 설치 (traefik 포함)
│   ├── 20-load-images.sh     # 이미지 → containerd 로드
│   ├── 25-platform.sh        # CA 생성 → cert-manager → argocd + Ingress
│   └── 30-apply-manifests.sh # edge-demo 매니페스트 적용
├── k3s/                      # k3s 바이너리 + 에어갭 이미지 + 설치 스크립트
├── images/                   # k3s에 직접 load할 이미지 (edge-demo + cert-manager/argocd)
├── manifests/edge-demo/      # kubectl apply 대상 (앱)
├── platform/                 # 플랫폼 매니페스트 + harbor/gitea/k3s 스크립트
│   ├── cert-manager.yaml     # cert-manager 매니페스트 스냅샷
│   ├── clusterissuer.yaml    # airgap-ca ClusterIssuer
│   ├── argocd.yaml           # ArgoCD install.yaml 스냅샷
│   ├── argocd-ingress.yaml   # Traefik TLS Ingress + server.insecure ConfigMap
│   ├── harbor/               # install-on-vm.sh, harbor.yml, offline installer, mirror-images/, push-all.sh
│   ├── gitea/                # install-on-vm.sh, docker-compose.yml, seed.sh, register-secrets.sh
│   └── k3s/                  # registries.yaml.tmpl, install-registries.sh, rbac, gen-kubeconfig
├── src/                      # 고객사 재빌드용 소스 (Rust vendor 포함)
│   └── edge-agent/
└── docs/
    └── CUSTOMER-REBUILD.md
```

## 설치 요구사항 (고객사 측)

- Ubuntu 22.04 LTS (amd64), 최소 4 vCPU / 8 GB RAM / 40 GB 디스크
- root 또는 sudo
- **인터넷 연결 불필요** — 번들 하나로 완결 (k3s / cert-manager / ArgoCD / edge-demo 전부 포함)

## 설치

```bash
tar xzf clcoco-bundle-<version>.tgz
cd clcoco-bundle-<version>
sudo ./install.sh
```

설치 종료 시 출력에 다음 정보가 표시됨:

- 호스트 IP
- Grafana / ArgoCD URL (HTTPS, `*.apps.airgap.local`)
- ArgoCD 초기 admin 비밀번호
- `/etc/hosts` 추가 명령 (클라이언트가 호스트 이름 해석하려면)
- CA 파일 복사 경로 (클라이언트 브라우저가 초록자물쇠 보려면)

## 설치 이후 접근

설치 대상 호스트 **자체**에서는 `/etc/airgap-ca/ca.crt`가 이미 시스템 trust에 주입되므로 `curl https://grafana.apps.airgap.local/` 가 `-k` 없이 동작 (단 호스트가 `*.apps.airgap.local`을 자신의 IP로 해석해야 함 — install.sh가 `/etc/hosts`에 안내 추가).

**다른 클라이언트**에서 접근하려면:

```bash
# 1) 호스트네임 해석
echo "<NODE_IP>  grafana.apps.airgap.local  argocd.apps.airgap.local" | sudo tee -a /etc/hosts

# 2) CA trust (선택 — 초록자물쇠)
scp root@<NODE_IP>:/etc/airgap-ca/ca.crt /tmp/airgap-ca.crt
sudo install -m 0644 /tmp/airgap-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

## 제거

```bash
sudo ./uninstall.sh
```

k3s-uninstall.sh가 노드와 모든 리소스를 제거. CA(`/etc/airgap-ca`)와 host trust는 수동으로 지워야 완전 클린 상태:

```bash
sudo rm -rf /etc/airgap-ca
sudo rm -f /usr/local/share/ca-certificates/airgap-ca.crt
sudo update-ca-certificates --fresh
```

## 번들 빌드 (인터넷 있는 머신에서)

```bash
# 버전 오버라이드 가능: VERSION, K3S_VERSION, CERT_MANAGER_VERSION, ARGO_VERSION
./build-bundle.sh
```

`build-bundle.sh`는 10단계로:

1. 설치 스크립트 복사 (`install.sh`, `uninstall.sh`, `lib/*.sh`)
2. k3s 바이너리 + airgap 이미지 다운로드
3. Rust edge-agent 이미지 빌드 (`cargo vendor` → Containerfile build)
4. cert-manager / ArgoCD 매니페스트 다운로드 + 거기서 **참조된 이미지를 자동 추출**
5. 앱 + 플랫폼 이미지 일괄 pull/save (→ `images/`, k3s에 직접 로드용)
6. `platform/{harbor,gitea,k3s}/` 전체 스크립트 번들에 복사
7. Harbor offline installer tarball fetch (`platform/harbor/install/`)
8. `platform/harbor/images/IMAGES.txt` 기준 mirror 이미지 pull/save (→ `platform/harbor/mirror-images/`, Harbor push용)
9. edge-demo 매니페스트 + Rust 소스(vendor 포함) 스테이징
10. `dist/clcoco-bundle-<version>.tgz`로 묶음

5와 8의 차이 — edge-demo 이미지(mosquitto/timescaledb/grafana)는 **양쪽에 중복** 포함. 이유: edge-demo 가 Harbor 기동 전에 먼저 떠야 하므로 k3s 에 직접 load, 그리고 Harbor 미러 카탈로그 일원화를 위해 한 번 더.

## 고객사가 소스 수정 후 재빌드하려면

`docs/CUSTOMER-REBUILD.md` 참조. 번들 안 `src/edge-agent/`의 Rust 소스 + vendor 디렉터리가 포함되어 있어, 설치된 Gitea/Actions 런타임 위에서 인터넷 없이 재빌드 가능.

## 주의 — Lab 대 Bundle 차이

| 항목 | Lab (멀티 VM) | Bundle (싱글머신) |
|------|----------------|--------------------|
| CA 출처 | infra VM이 발급, distribute-ca.sh로 배포 | 설치 시점에 자체 생성 (`openssl req -x509` in `lib/25-platform.sh`) |
| CA 경로 | infra `/etc/airgap-ca`, 나머지 VM `/opt/airgap-ca` | 호스트 `/etc/airgap-ca` |
| DNS | infra dnsmasq (권위) | 호스트 `/etc/hosts` 수동 |
| Ingress | Traefik | Traefik (번들도 동일) |
| argocd / cert-manager | `bootstrap-net.sh on` → 인터넷에서 설치 | 번들에 이미지/매니페스트 포함, 완전 오프라인 |
