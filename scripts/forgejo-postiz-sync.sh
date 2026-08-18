#!/usr/bin/env bash
# Pull canonical Achaean posts from Forgejo and create Postiz drafts.
# This never publishes; the Aigion bridge remains the only secret-bearing step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
content_repo="${AIGION_CONTENT_REPO:-$HOME/content/pocketcoder-build-log}"
remote_name="${AIGION_CONTENT_REMOTE:-origin}"
branch="${AIGION_CONTENT_BRANCH:-main}"
lock_file="${AIGION_SYNC_LOCK:-$HOME/.cache/aigion/forgejo-postiz-sync.lock}"
postiz_mode="${AIGION_POSTIZ_MODE:-draft}"
postiz_date="${AIGION_POSTIZ_DATE:-}"

case "$postiz_mode" in
  draft|now) ;;
  schedule)
    [[ -n "$postiz_date" ]] || { echo "AIGION_POSTIZ_DATE is required when AIGION_POSTIZ_MODE=schedule" >&2; exit 2; }
    ;;
  *) echo "AIGION_POSTIZ_MODE must be draft, schedule, or now" >&2; exit 2 ;;
esac

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
    args=("$postiz_mode" --post "$post")
    if [[ "$postiz_mode" == schedule ]]; then
      args+=(--date "$postiz_date")
    fi
    bash "$repo_root/scripts/achaean-postiz.sh" "${args[@]}"
  ); then
    failed=1
  fi
done

exit "$failed"
