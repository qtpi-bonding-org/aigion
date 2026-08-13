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

cd "$repo_root"
if [[ ! -f "$secrets_file" ]]; then
  echo "No encrypted provider file yet; recreating Postiz without provider overrides."
  exec docker compose up -d --force-recreate postiz
fi

echo "Recreating Postiz with encrypted provider credentials injected."
echo "No credential values will be printed."
exec "$sops_bin" exec-env "$secrets_file" -- \
  docker compose up -d --force-recreate postiz
