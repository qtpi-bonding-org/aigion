#!/usr/bin/env bash
# Backwards-compatible name for the redaction-only SOPS wrapper.
# For deliberate environment injection, use sops-exec-env.sh explicitly.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$repo_root/scripts/sops-redact-exec.sh" "$@"
