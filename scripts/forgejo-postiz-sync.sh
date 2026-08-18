#!/usr/bin/env bash
# Pull canonical Achaean posts from Forgejo and create Postiz drafts.
# This never publishes; the Aigion bridge remains the only secret-bearing step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
content_repo="${AIGION_CONTENT_REPO:-$HOME/content/pocketcoder-build-log}"
remote_name="${AIGION_CONTENT_REMOTE:-origin}"
branch="${AIGION_CONTENT_BRANCH:-main}"
lock_file="${AIGION_SYNC_LOCK:-$HOME/.cache/aigion/forgejo-postiz-sync.lock}"

mkdir -p "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || { echo "sync already running"; exit 0; }

if [[ ! -d "$content_repo/.git" ]]; then
  echo "missing Achaean content checkout: $content_repo" >&2
  exit 2
fi

git -C "$content_repo" fetch "$remote_name" "$branch"
git -C "$content_repo" merge --ff-only "$remote_name/$branch"

shopt -s nullglob
posts=("$content_repo"/posts/*/post.json)
if ((${#posts[@]} == 0)); then
  echo "no canonical posts found"
  exit 0
fi

failed=0
for post in "${posts[@]}"; do
  if ! (
    cd "$content_repo"
    bash "$repo_root/scripts/achaean-postiz.sh" draft --post "$post"
  ); then
    failed=1
  fi
done

exit "$failed"
