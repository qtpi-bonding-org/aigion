#!/usr/bin/env bash
# Run one non-interactive command on Aigion with Postiz secrets available and
# literal secret values scrubbed from its combined output.
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
  if [ -f "$HOME/.config/aigion/postiz.enc.yaml" ]; then
    SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
    SOPS_BIN="$HOME/.local/bin/sops" \
    ./scripts/postiz-scrubbed-exec.sh bash -s
  else
    bash -s
  fi
'
