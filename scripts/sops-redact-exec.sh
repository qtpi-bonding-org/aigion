#!/usr/bin/env bash
# Decrypt selected SOPS files only to provide literal values to redact-output.py.
# It never injects decrypted values into the wrapped command's environment.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sops_bin="${SOPS_BIN:-sops}"
default_age_key="$HOME/.config/sops/age/keys.txt"

if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$default_age_key" ]]; then
  export SOPS_AGE_KEY_FILE="$default_age_key"
fi

secrets_files=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
  if [[ "$1" != "--secrets" || $# -lt 2 ]]; then
    echo "usage: $0 --secrets FILE [--secrets FILE...] -- COMMAND [ARG...]" >&2
    exit 2
  fi
  secrets_files+=("$2")
  shift 2
done
if [[ ${#secrets_files[@]} -eq 0 || $# -lt 2 || "$1" != "--" ]]; then
  echo "usage: $0 --secrets FILE [--secrets FILE...] -- COMMAND [ARG...]" >&2
  exit 2
fi
shift

if [[ -t 0 || -t 1 || -t 2 ]]; then
  echo "This wrapper is for non-interactive commands only." >&2
  exit 2
fi
if ! command -v "$sops_bin" >/dev/null 2>&1; then
  echo "sops is not available; set SOPS_BIN if needed." >&2
  exit 1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
umask 077
temporary_files=()
for index in "${!secrets_files[@]}"; do
  secrets_file="${secrets_files[$index]}"
  if [[ ! -f "$secrets_file" ]]; then
    echo "Missing encrypted secrets file: $secrets_file" >&2
    exit 1
  fi
  temporary_file="$temporary_dir/secrets-$index.json"
  "$sops_bin" --output-type json -d "$secrets_file" > "$temporary_file"
  temporary_files+=("$temporary_file")
done

exec python3 "$repo_root/scripts/redact-output.py" "${temporary_files[@]}" -- "$@"
