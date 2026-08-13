#!/usr/bin/env bash
# Stream the intentionally redacted Postiz Redis OAuth watcher from Aigion.
# This is deliberately not the generic scrubbed executor: it accepts only an
# integer duration and the remote watcher itself never prints Redis keys,
# values, or OAuth tokens.
set -euo pipefail

duration_seconds="${1:-120}"

if ! [[ "$duration_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [duration-seconds]" >&2
  exit 2
fi

exec ssh aigion "cd ~/aigion && ./scripts/postiz-redis-watch.sh $duration_seconds"
