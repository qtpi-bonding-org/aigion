#!/usr/bin/env bash
# Explicitly inject one SOPS inventory into one non-interactive command.
# Use sops-redact-exec.sh around it when its output also needs redaction.
set -euo pipefail

sops_bin="${SOPS_BIN:-sops}"
default_age_key="$HOME/.config/sops/age/keys.txt"
if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$default_age_key" ]]; then
  export SOPS_AGE_KEY_FILE="$default_age_key"
fi

if [[ $# -lt 4 || "$1" != "--secrets" || "$3" != "--" ]]; then
  echo "usage: $0 --secrets ENCRYPTED_FILE -- COMMAND [ARG...]" >&2
  exit 2
fi
secrets_file="$2"
shift 3
if [[ ! -f "$secrets_file" ]]; then
  echo "Missing encrypted secrets file: $secrets_file" >&2
  exit 1
fi
exec "$sops_bin" exec-env "$secrets_file" -- "$@"
