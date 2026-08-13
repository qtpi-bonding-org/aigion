#!/usr/bin/env bash
# Recreate Postiz with provider credentials injected from a host-only,
# SOPS-encrypted YAML file. Nothing here decrypts to disk or prints values.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secrets_file="${AIGION_POSTIZ_SECRETS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/aigion/postiz.enc.yaml}"
sops_bin="${SOPS_BIN:-sops}"
default_age_key="$HOME/.config/sops/age/keys.txt"

if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$default_age_key" ]]; then
  export SOPS_AGE_KEY_FILE="$default_age_key"
fi

if ! command -v "$sops_bin" >/dev/null 2>&1; then
  echo "error: sops is required but was not found: $sops_bin" >&2
  exit 1
fi

if [[ ! -f "$secrets_file" ]]; then
  echo "error: encrypted Postiz credentials not found at $secrets_file" >&2
  echo "See secrets/README.md. This script will not create or print secrets." >&2
  exit 1
fi

echo "Recreating Postiz with encrypted provider credentials injected."
echo "No credential values will be printed."

cd "$repo_root"
if "$sops_bin" --output-type json -d "$secrets_file" | \
  python3 -c 'import json, sys; sys.exit(0 if not json.load(sys.stdin) else 1)'; then
  echo "Encrypted provider file is empty; recreating Postiz without provider overrides."
  exec docker compose up -d --force-recreate postiz
fi

exec "$sops_bin" exec-env "$secrets_file" -- \
  docker compose up -d --force-recreate postiz
