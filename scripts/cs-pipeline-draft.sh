#!/usr/bin/env bash
# Generate canonical Achaean post.json drafts from one product repository.
# This intentionally never commits, pushes, calls Postiz, or publishes.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: scripts/cs-pipeline-draft.sh SOURCE_REPO CONTENT_REPO [CONFIG_PATH]

SOURCE_REPO   product repository whose latest commit should be summarized
CONTENT_REPO  checked-out Achaean content repository; receives posts/.../post.json
CONFIG_PATH   config relative to SOURCE_REPO (default: .github/cs-pipeline.toml)

Requires OPENROUTER_API_KEY in the environment. The command writes canonical
drafts only; it never commits, pushes, calls Postiz, or publishes.
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 2
fi

source_repo="$1"
content_repo="$2"
config_path="${3:-.github/cs-pipeline.toml}"
pipeline="$repo_root/cs-pipeline/scripts/syndicate.py"
venv_python="$repo_root/.venv-cs-pipeline/bin/python3"
python_bin="${CS_PIPELINE_PYTHON:-$venv_python}"

if [[ ! -d "$source_repo/.git" ]]; then
  echo "SOURCE_REPO must be a git checkout: $source_repo" >&2
  exit 2
fi
if [[ ! -d "$content_repo/.git" ]]; then
  echo "CONTENT_REPO must be a git checkout: $content_repo" >&2
  exit 2
fi
if [[ ! -f "$source_repo/$config_path" ]]; then
  echo "Config file not found: $source_repo/$config_path" >&2
  exit 2
fi
if [[ ! -f "$pipeline" ]]; then
  echo "CS Pipeline submodule is unavailable; run git submodule update --init --recursive" >&2
  exit 2
fi
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "OPENROUTER_API_KEY is required (supply it through your secret runner)." >&2
  exit 2
fi
if [[ ! -x "$python_bin" ]]; then
  python_bin="python3"
fi

cd "$source_repo"
exec "$python_bin" "$pipeline" --config "$config_path" --output-dir "$content_repo" --write
