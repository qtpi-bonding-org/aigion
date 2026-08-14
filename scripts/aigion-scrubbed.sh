#!/usr/bin/env bash
# Run one non-interactive command on Aigion with literal values from every
# encrypted Aigion inventory scrubbed from its combined output.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 'COMMAND'" >&2
  exit 2
fi

# Send the command over stdin rather than interpolating it into the remote SSH
# command. The remote bash process is itself inside the scrubber, so its output
# is captured and redacted before it returns here.
printf '%s\n' "$1" | ssh aigion '
  cd /home/cduser/aigion
  secret_args=()
  while IFS= read -r -d "" secret_file; do
    secret_args+=(--secrets "$secret_file")
  done < <(find "$HOME/.config/aigion" -type f \( -name "*.enc.yaml" -o -name "*.enc.yml" -o -name "*.enc.json" \) -print0 2>/dev/null | sort -z)
  if [ "${#secret_args[@]}" -gt 0 ]; then
    SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
    SOPS_BIN="$HOME/.local/bin/sops" \
    ./scripts/sops-redact-exec.sh "${secret_args[@]}" -- bash -s
  else
    bash -s
  fi
'
