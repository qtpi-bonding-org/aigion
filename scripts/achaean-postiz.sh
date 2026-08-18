#!/usr/bin/env bash
# Safe entrypoint for the Achaean -> Postiz draft bridge.
# It reads only POSTIZ_API_KEY / POSTIZ_API_URL from the encrypted inventory.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secrets_file="${AIGION_POSTIZ_SECRETS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/aigion/postiz.enc.yaml}"
# Cron has a deliberately minimal PATH. Prefer the per-user installation used
# by the VPS secret helpers, while still allowing an explicit override.
sops_bin="${SOPS_BIN:-$HOME/.local/bin/sops}"
default_age_key="$HOME/.config/sops/age/keys.txt"

if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$default_age_key" ]]; then
  export SOPS_AGE_KEY_FILE="$default_age_key"
fi
if [[ $# -lt 1 ]]; then
  echo "usage: $0 integrations | draft [publisher arguments...]" >&2
  exit 2
fi
if [[ ! -f "$secrets_file" ]]; then
  echo "Missing encrypted secrets file: $secrets_file" >&2
  exit 1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
temporary_secrets="$temporary_dir/secrets.json"
umask 077
"$sops_bin" --output-type json -d "$secrets_file" > "$temporary_secrets"

python3 "$repo_root/scripts/achaean_postiz.py" \
  --secrets "$temporary_secrets" -- "$@"
