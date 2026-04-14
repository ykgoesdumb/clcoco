# Demo Runbook — 8분 시연 대본

전제: `demo/PREP.md` 완료, 모든 VM `demo-ready-*` 스냅샷 존재, `demo/verify.sh` PASS.

## 시연 3막 구조

| 막 | 분 | 증명할 것 |
|---|---|---|
| A. Airgap 컷오프 | 1' | 외부망 차단된 상태에서 나머지 전부 동작 |
| B. git push → 자동 배포 | 4' | 폐쇄망 내부에서 dev loop 가 닫힘 |
| C. Rust vs Python 비교 | 3' | 같은 MQTT 부하에서 런타임 특성 갈림 |

## 사전 창 배치 (시연 시작 30초 전)

브라우저 탭 4개를 **미리** 열어둔다 — 각 탭을 시연 중 즉시 전환:
1. Gitea — `https://gitea.airgap.local/clcoco/hello/actions` (Actions 페이지 고정)
2. Harbor — `https://harbor.airgap.local/harbor/projects/2/repositories/hello` (apps/hello 리포)
3. 앱 — `https://hello.apps.airgap.local/`
4. Grafana — `https://grafana.apps.airgap.local/d/bridge-comparison` (시간창 `now-5m` 으로)

터미널 3개:
1. `[host]` — airgap 토글 + burst 실행
2. `[dev]` — 코드 편집 + push (미리 clone 해둔 `~/demo-hello/` 에서 시작)
3. `[k3s-master]` — `watch -n1 kubectl -n apps get po,deploy/hello -o wide`

---

## A. Airgap 컷오프 (1분)

```bash
[host]$ nmcli radio wifi       # enabled
[host]$ ping -c 2 8.8.8.8      # 정상
[host]$ nmcli radio wifi off
[host]$ nmcli radio wifi       # disabled
[host]$ ping -c 2 -W 2 8.8.8.8 # 100% loss
```

내레이션: "여기서부터 고객사 폐쇄망과 동일한 조건. 다음 모든 동작은 인터넷 없이 일어납니다."

---

## B. git push → 자동 배포 (4분)

### B1. 코드 편집 + push
```bash
[dev]$ cd ~/demo-hello
[dev]$ sed -i 's/MESSAGE=".*"/MESSAGE="hello from hackathon — live demo"/' src/app.py
[dev]$ git diff src/app.py     # 한 줄 변경 보여주기
[dev]$ git commit -am 'demo: change greeting'
[dev]$ git push
```

### B2. 화면 전환 (각 15~30초)
1. **Gitea Actions 탭** — 새 workflow run 실행 중. `build → push → rollout` 3 step 초록색으로 바뀌는 과정 관전.
2. **Harbor 탭** 새로고침 — `apps/hello` 리포에 방금 git SHA 태그 **추가** 됨.
3. **k3s-master 터미널** — `deploy/hello` READY `1/2 → 2/2`, 새 ReplicaSet 활성.
4. **앱 탭** 새로고침 — 문구가 `hello from hackathon — live demo` 로 바뀜.

### B3. 핵심 증거 (원라이너)
```bash
[k3s-master]$ kubectl -n apps get deploy hello -o=jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
#            harbor.airgap.local/apps/hello:<방금 푸시한 SHA>
[dev]$ git log -1 --oneline
#      <같은 SHA> demo: change greeting
```

내레이션: "push 에서 배포까지 평균 90초. 인터넷 없이 Gitea Actions 러너가 Harbor 에서 베이스 이미지 당기고 빌드·푸시·롤아웃까지 전부 내부에서."

---

## C. Python vs Rust 런타임 비교 (3분)

### C1. 정상 트래픽 대시보드
**Grafana 탭**:
- 시간창 `now-5m`.
- 상단 스탯 패널: Python msg/sec ≈ Rust msg/sec (센서-sim 부하 동률이라 당연).
- **CPU/RSS 패널** 강조 — Python RSS ~40MB / Rust RSS ~5MB. 콘테이너 이미지 크기 주석: ~165MB vs ~12MB.

내레이션: "정상 부하에서는 둘 다 처리한다. 하지만 풋프린트가 다릅니다. 현장 박스에 20개 올리면 메모리 800MB vs 100MB."

### C2. 버스트 (클라이맥스)
```bash
[host]$ airgap/scripts/run-burst.sh   # 10K msg / 5s
```

**Grafana 대시보드** 계속 주시:
- **in-flight 패널** — Python 은 수백까지 튀고, Rust 는 한 자리 수 유지.
- **insert p99 latency** — Python 스파이크 100ms↑, Rust 평탄 유지.
- **msg/sec ok** — Rust 가 버스트 구간에서 Python 보다 먼저 끝내고 꼬리 없음.

내레이션: "PLC 이벤트 버스트가 들어오면 GC pause 유무가 latency 테일에서 갈립니다. 제어 루프 깨짐 vs 유지."

### C3. 마무리 원라이너
```bash
[k3s-master]$ kubectl -n edge-demo top po
#            bridge(py) CPU m단위 · mem MB 단위로 Rust 대비 8~10배 큰 것 확인
```

---

## 장애 복구 (시연 중 꼬였을 때)

### B 단계 Actions 실패
- Harbor robot pw 만료/오타 → `[gitea]$ sudo platform/gitea/install/register-secrets.sh` 재실행.
- 러너 Offline → `[gitea]$ cd /opt/gitea && docker compose restart runner`.

### C 단계 메트릭 미표시
- Grafana 빈 그래프 → `[k3s-master]$ kubectl -n monitoring get servicemonitor` 확인. `bridge-*` 있어야.
- 그래도 없으면 Prometheus UI `https://grafana.apps.airgap.local/explore` 에서 `bridge_messages_total` 찍어보기.

### 전면 리셋 (리허설 간)
```bash
[host]$ demo/reset.sh demo-ready-<DATE>
```
30초 내 4 VM 스냅샷 복귀.

---

## 체크포인트 (시연 성공 기준)

- [ ] WiFi off 상태에서 B·C 전부 수행됨.
- [ ] Gitea Actions job `Success`, Harbor 에 새 태그.
- [ ] `deploy/hello` 이미지 태그 = 방금 push 한 SHA.
- [ ] 브라우저에서 새 문구 렌더링.
- [ ] Grafana 버스트 구간에서 Python/Rust 가시적 격차 (p99 latency 또는 in-flight).
