#!/usr/bin/env bash
# Observe Postiz OAuth state lifecycle events without disclosing Redis keys,
# values, OAuth request tokens, or OAuth token secrets.
set -euo pipefail

duration_seconds="${1:-120}"

if ! [[ "$duration_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [duration-seconds]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Watching Postiz OAuth Redis lifecycle for ${duration_seconds}s."
echo "Keys, values, and tokens are intentionally not shown."

# `redis-cli MONITOR` includes credentials and OAuth request secrets in its raw
# output.  Keep it inside this pipeline and emit only fixed lifecycle labels.
set +e
timeout "$duration_seconds" \
  docker compose -f "$repo_root/docker-compose.yml" exec -T postiz-redis redis-cli MONITOR |
  awk '
    function emit(message) { print message; fflush() }
    /"SET" "login:/          { emit("OAuth state stored"); next }
    /"GET" "login:/          { emit("OAuth state looked up"); next }
    /"DEL" "login:/          { emit("OAuth state consumed"); next }
    /"SET" "organization:/   { emit("OAuth organization stored"); next }
    /"GET" "organization:/   { emit("OAuth organization looked up"); next }
    /"DEL" "organization:/   { emit("OAuth organization consumed"); next }
  '
monitor_status=${PIPESTATUS[0]}
set -e

if [[ "$monitor_status" -eq 124 ]]; then
  echo "Watch complete."
  exit 0
fi

exit "$monitor_status"
