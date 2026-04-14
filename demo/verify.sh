#!/usr/bin/env bash
# Pre-demo smoke check. Run from host BEFORE the demo (after PREP.md step 6).
# Fails fast on any red signal so you don't find out mid-demo.
#
# Usage:
#   demo/verify.sh                 # run all checks
#   VERBOSE=1 demo/verify.sh       # show full output on failures
#
# Port map (TEAM-ACCESS.md): 2200 infra, 2201 gitea, 2202 harbor, 2203 k3s-master

set -uo pipefail

HOST="${HOST:-localhost}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
VERBOSE="${VERBOSE:-0}"

PASS=0
FAIL=0
FAILURES=()

check() {
    local name="$1"; shift
    local out
    if out=$("$@" 2>&1); then
        printf '  \033[32mPASS\033[0m  %s\n' "$name"
        PASS=$((PASS+1))
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$name"
        FAIL=$((FAIL+1))
        FAILURES+=("$name")
        if [[ "$VERBOSE" = 1 ]]; then
            printf '        %s\n' "$out" | head -5
        fi
    fi
}

ssh_ok() {
    local port="$1"; shift
    ssh $SSH_OPTS -p "$port" "airgap@$HOST" "$@" >/dev/null 2>&1
}

echo "==> VM reachability"
check "infra SSH"       ssh_ok 2200 true
check "gitea SSH"       ssh_ok 2201 true
check "harbor SSH"      ssh_ok 2202 true
check "k3s-master SSH"  ssh_ok 2203 true

echo
echo "==> Harbor"
check "Harbor API up"                    ssh_ok 2202 "curl -skf -o /dev/null https://harbor.airgap.local/api/v2.0/systeminfo"
check "Harbor project apps/hello exists" ssh_ok 2202 "curl -sk -u admin:clcoco https://harbor.airgap.local/api/v2.0/projects/apps/repositories/hello | grep -q artifact_count"
check "Harbor has bootstrap tag"         ssh_ok 2202 "curl -sk -u admin:clcoco 'https://harbor.airgap.local/api/v2.0/projects/apps/repositories/hello/artifacts?page_size=20' | grep -q '\"name\":\"'"

echo
echo "==> Gitea"
check "Gitea HTTP up"                    ssh_ok 2201 "curl -sf -o /dev/null http://localhost:3000/api/v1/version"
check "clcoco/hello repo exists"         ssh_ok 2201 "curl -sf http://localhost:3000/api/v1/repos/clcoco/hello | grep -q '\"full_name\":\"clcoco/hello\"'"
check "Runner registered"                ssh_ok 2201 "cd /opt/gitea && docker compose ps runner 2>/dev/null | grep -q Up"

echo
echo "==> k3s + workloads"
check "k3s node Ready"                   ssh_ok 2203 "sudo kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
check "apps/hello deploy Ready"          ssh_ok 2203 "sudo kubectl -n apps get deploy hello -o jsonpath='{.status.readyReplicas}' | grep -qE '^[1-9]'"
check "edge-demo bridges Running"        ssh_ok 2203 "[ \$(sudo kubectl -n edge-demo get po -l app=bridge -o jsonpath='{.items[?(@.status.phase==\"Running\")].metadata.name}' | wc -w) -ge 1 ]"
check "edge-demo edge-agent Running"     ssh_ok 2203 "[ \$(sudo kubectl -n edge-demo get po -l app=edge-agent -o jsonpath='{.items[?(@.status.phase==\"Running\")].metadata.name}' | wc -w) -ge 1 ]"
check "kps prometheus Running"           ssh_ok 2203 "sudo kubectl -n monitoring get po -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "kps grafana Running"              ssh_ok 2203 "sudo kubectl -n monitoring get po -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.phase}' | grep -q Running"
check "ServiceMonitors present"          ssh_ok 2203 "[ \$(sudo kubectl -n edge-demo get servicemonitor -o name | wc -l) -ge 2 ]"

echo
echo "==> App endpoint"
check "hello.apps.airgap.local 200"      ssh_ok 2203 "curl -skf -o /dev/null -w '%{http_code}' --resolve hello.apps.airgap.local:443:\$(hostname -I|awk '{print \$1}') https://hello.apps.airgap.local/ | grep -q 200"

echo
echo "==> Grafana dashboard"
check "comparison dashboard provisioned" ssh_ok 2203 "sudo kubectl -n edge-demo get cm grafana-dashboard-bridge-comparison -o name >/dev/null"

echo
printf '==> %d pass / %d fail\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "실패 항목:"
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    echo "자세히 보려면: VERBOSE=1 $0"
    exit 1
fi
echo "데모 준비 완료."
