#!/usr/bin/env bash
# Run CS Pipeline for PocketCoder, then commit/push only newly generated posts.
# The caller must provide OPENROUTER_API_KEY through the SOPS env wrapper.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
product_url="${CS_PIPELINE_PRODUCT_URL:-https://github.com/qtpi-bonding-org/pocketcoder.git}"
content_repo="${AIGION_CONTENT_REPO:-$HOME/content/pocketcoder-build-log}"
config_path="${CS_PIPELINE_CONFIG_PATH:-.github/cs-pipeline.toml}"
dry_run="${CS_PIPELINE_DAILY_DRY_RUN:-false}"

if [[ ! -d "$content_repo/.git" ]]; then
  echo "missing Achaean content checkout: $content_repo" >&2
  exit 2
fi

before="$(git -C "$content_repo" status --porcelain -- posts)"
if [[ "$dry_run" == "true" ]]; then
  exec bash "$repo_root/scripts/cs-pipeline-draft.sh" --dry-run "$product_url" "$content_repo" "$config_path"
fi
"$repo_root/scripts/cs-pipeline-draft.sh" "$product_url" "$content_repo" "$config_path"
after="$(git -C "$content_repo" status --porcelain -- posts)"

if [[ "$before" == "$after" ]]; then
  echo "CS Pipeline produced no new canonical post"
  exit 0
fi

git -C "$content_repo" add posts
if git -C "$content_repo" diff --cached --quiet; then
  echo "No staged canonical changes"
  exit 0
fi
git -C "$content_repo" commit -m "Add daily PocketCoder build update"
git -C "$content_repo" push origin main
echo "Pushed new canonical post; Postiz sync will schedule it on the next run"
