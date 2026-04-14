#!/usr/bin/env bash
# compare-bridges.sh — side-by-side Py(Python bridge) vs Rust(edge-agent) on edge-demo.
#
# Prints (1) kubectl top CPU/RSS for each bridge pod, (2) last-minute insert
# rate from TimescaleDB grouped by source column. Intended as a demo beat:
# same workload, same topic, same DB — single static Rust binary vs Python.
#
# Usage:
#   ./compare-bridges.sh                  # one-shot
#   WATCH=1 ./compare-bridges.sh          # refresh every 3s (Ctrl-C to quit)
set -euo pipefail

NS=edge-demo
CTX="${KUBECTL_CONTEXT:-airgap}"
KUBE() { kubectl --context="$CTX" -n "$NS" "$@"; }

print_once() {
  printf '\n===== %s =====\n' "$(date '+%H:%M:%S')"

  printf '\n[pod resources]\n'
  # -l app=bridge → Python; app=edge-agent → Rust
  { KUBE top pod -l app=bridge     --no-headers 2>/dev/null | awk '{printf "  python   %-38s cpu=%-6s rss=%s\n", $1, $2, $3}'
    KUBE top pod -l app=edge-agent --no-headers 2>/dev/null | awk '{printf "  rust     %-38s cpu=%-6s rss=%s\n", $1, $2, $3}'
  } || true

  printf '\n[inserts in last 60s by source]\n'
  KUBE exec statefulset/timescaledb -- psql -U edge -d sensors -At -F'|' -c \
    "SELECT source, COUNT(*) FROM readings WHERE ts > now() - INTERVAL '1 minute' GROUP BY source ORDER BY source;" \
    2>/dev/null | awk -F'|' '{printf "  %-8s rows=%s\n", $1, $2}'
}

if [[ "${WATCH:-}" == "1" ]]; then
  while true; do
    clear
    print_once
    sleep 3
  done
else
  print_once
fi
