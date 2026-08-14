#!/usr/bin/env bash
# Generate canonical Achaean post.json drafts from one product repository.
# This intentionally never commits, pushes, calls Postiz, or publishes.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
usage: scripts/cs-pipeline-draft.sh REPOSITORY_URL CONTENT_REPO [CONFIG_PATH]

REPOSITORY_URL product repository to clone into Aigion's fixed CS Pipeline
               source checkout
CONTENT_REPO  checked-out Achaean content repository; receives posts/.../post.json
CONFIG_PATH   config relative to the fixed source checkout
               (default: .github/cs-pipeline.toml)

Requires OPENROUTER_API_KEY in the environment. The command writes canonical
drafts only; it never commits, pushes, calls Postiz, or publishes.

The fixed checkout defaults to ~/.local/share/aigion/cs-pipeline-target.
Set CS_PIPELINE_SOURCE_DIR only when intentionally using a different workspace.
EOF
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 2
fi

repository_url="$1"
content_repo="$2"
config_path="${3:-.github/cs-pipeline.toml}"
source_repo="${CS_PIPELINE_SOURCE_DIR:-$HOME/.local/share/aigion/cs-pipeline-target}"
shallow_since="${CS_PIPELINE_SHALLOW_SINCE:-7 days ago}"
pipeline="$repo_root/cs-pipeline/scripts/syndicate.py"
venv_python="$repo_root/.venv-cs-pipeline/bin/python3"
python_bin="${CS_PIPELINE_PYTHON:-$venv_python}"

if [[ ! -d "$source_repo/.git" ]]; then
  mkdir -p "$(dirname "$source_repo")"
  git clone --shallow-since="$shallow_since" "$repository_url" "$source_repo"
else
  origin_url="$(git -C "$source_repo" remote get-url origin)"
  if [[ "$origin_url" != "$repository_url" ]]; then
    echo "Fixed CS Pipeline checkout belongs to a different repository:" >&2
    echo "  $origin_url" >&2
    echo "Refusing to reuse it for: $repository_url" >&2
    exit 2
  fi
  if [[ -n "$(git -C "$source_repo" status --porcelain)" ]]; then
    echo "Fixed CS Pipeline checkout has local changes; refusing to update it." >&2
    exit 2
  fi
  git -C "$source_repo" fetch --shallow-since="$shallow_since" origin HEAD
  git -C "$source_repo" merge --ff-only FETCH_HEAD
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
