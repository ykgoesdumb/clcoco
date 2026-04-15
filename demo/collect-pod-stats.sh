#!/usr/bin/env bash
# Local-host collector. Samples `kubectl top po` every INTERVAL seconds
# and writes (ts, pod, app, cpu_m, mem_mi) rows into TimescaleDB.
#
# Drives the "Bridge Footprint" Grafana dashboard (same TimescaleDB datasource
# as the Factory dashboard — no Prometheus needed).
#
# Usage:
#   demo/collect-pod-stats.sh                     # run forever
#   INTERVAL=1 demo/collect-pod-stats.sh          # 1s cadence
#   CTX=airgap NS=edge-demo demo/collect-pod-stats.sh
#
# Stop with Ctrl-C.

set -uo pipefail

CTX="${CTX:-airgap}"
NS="${NS:-edge-demo}"
INTERVAL="${INTERVAL:-2}"
TSDB_POD="${TSDB_POD:-timescaledb-0}"

# Map pod-name prefix → app label. Case stmt keeps this bash 3.2-compatible (macOS default).
pod_to_app() {
    case "$1" in
        mqtt-tsdb-bridge*) echo python ;;
        edge-agent*)       echo rust ;;
        *)                 echo "" ;;
    esac
}

echo "collector → ctx=$CTX ns=$NS interval=${INTERVAL}s"

# Convert "237m" → 237 ; "2" → 2000 ; "0" → 0
parse_cpu() {
    local v="$1"
    if [[ "$v" == *m ]]; then echo "${v%m}"; else echo "$((${v%%[^0-9]*} * 1000))"; fi
}
# Convert "19Mi" → 19 ; "1Gi" → 1024 ; "500Ki" → 0 (rounded)
parse_mem() {
    local v="$1"
    case "$v" in
        *Gi) echo "$(( ${v%Gi} * 1024 ))" ;;
        *Mi) echo "${v%Mi}" ;;
        *Ki) echo "$(( ${v%Ki} / 1024 ))" ;;
        *)   echo 0 ;;
    esac
}

while true; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sql=""
    while read -r name cpu mem _; do
        [[ -z "$name" || "$name" == "NAME" ]] && continue
        app="$(pod_to_app "$name")"
        [[ -z "$app" ]] && continue
        cpu_m=$(parse_cpu "$cpu")
        mem_mi=$(parse_mem "$mem")
        sql+="INSERT INTO pod_stats(ts,pod,app,cpu_m,mem_mi) VALUES ('$ts','$name','$app',$cpu_m,$mem_mi);"$'\n'
    done < <(kubectl --context "$CTX" -n "$NS" top po --no-headers 2>/dev/null)

    if [[ -n "$sql" ]]; then
        # Pipe the whole tick's inserts through a single psql invocation.
        printf '%s' "$sql" | kubectl --context "$CTX" -n "$NS" exec -i "$TSDB_POD" -- \
            psql -U edge -d sensors -q >/dev/null 2>&1 || echo "write failed @ $ts" >&2
    fi
    sleep "$INTERVAL"
done
