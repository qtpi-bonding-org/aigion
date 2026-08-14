#!/usr/bin/env bash
# Convenience wrapper: inject Postiz only, then redact Postiz values from output.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secrets_file="${AIGION_POSTIZ_SECRETS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/aigion/postiz.enc.yaml}"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 COMMAND [ARG...]" >&2
  exit 2
fi
exec "$repo_root/scripts/sops-exec-env.sh" --secrets "$secrets_file" -- \
  "$repo_root/scripts/sops-redact-exec.sh" --secrets "$secrets_file" -- "$@"
