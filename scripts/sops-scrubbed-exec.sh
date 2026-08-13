#!/usr/bin/env bash
# Run a non-interactive command with a SOPS file and redact literal secret
# values from combined output. This is a guardrail, not a security boundary.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sops_bin="${SOPS_BIN:-sops}"

if [[ $# -lt 4 || "$1" != "--secrets" || "$3" != "--" ]]; then
  echo "usage: $0 --secrets ENCRYPTED_FILE -- COMMAND [ARG...]" >&2
  exit 2
fi
secrets_file="$2"
shift 3

if [[ -t 0 || -t 1 || -t 2 ]]; then
  echo "This wrapper is for non-interactive commands only." >&2
  exit 2
fi
if ! command -v "$sops_bin" >/dev/null 2>&1; then
  echo "sops is not available; set SOPS_BIN if needed." >&2
  exit 1
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
python3 "$repo_root/scripts/postiz-scrubbed-exec.py" "$temporary_secrets" -- "$@"
