#!/usr/bin/env bash
# Recreate Postiz with provider credentials injected from a host-only,
# SOPS-encrypted YAML file. Nothing here decrypts to disk or prints values.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secrets_file="${AIGION_POSTIZ_SECRETS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/aigion/postiz.enc.yaml}"
sops_bin="${SOPS_BIN:-sops}"
default_age_key="$HOME/.config/sops/age/keys.txt"

if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$default_age_key" ]]; then
  export SOPS_AGE_KEY_FILE="$default_age_key"
fi

if ! command -v "$sops_bin" >/dev/null 2>&1; then
  echo "error: sops is required but was not found: $sops_bin" >&2
  exit 1
fi

cd "$repo_root"
if [[ ! -f "$secrets_file" ]]; then
  echo "No encrypted provider file yet; recreating Postiz without provider overrides."
  exec docker compose up -d --force-recreate postiz
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
temporary_secrets="$temporary_dir/secrets.json"
umask 077
"$sops_bin" --output-type json -d "$secrets_file" > "$temporary_secrets"

echo "Recreating Postiz with configured provider credentials injected."
echo "Other encrypted inventory values stay out of the Postiz container."
python3 - "$temporary_secrets" <<'PY'
import json
import os
import sys

# The shared SOPS inventory can also hold account passwords or secrets for
# other services. Only these Postiz provider-configuration keys are allowed
# into the Postiz container environment.
postiz_keys = {
    "X_API_KEY", "X_API_SECRET", "X_URL", "DISABLE_X_ANALYTICS",
    "STRIP_LINKS_FROM_X_POSTS", "LINKEDIN_CLIENT_ID", "LINKEDIN_CLIENT_SECRET",
    "FACEBOOK_APP_ID", "FACEBOOK_APP_SECRET", "INSTAGRAM_APP_ID",
    "INSTAGRAM_APP_SECRET", "THREADS_APP_ID", "THREADS_APP_SECRET",
    "YOUTUBE_CLIENT_ID", "YOUTUBE_CLIENT_SECRET", "REDDIT_CLIENT_ID",
    "REDDIT_CLIENT_SECRET", "MASTODON_URL", "MASTODON_CLIENT_ID",
    "MASTODON_CLIENT_SECRET", "TIKTOK_CLIENT_ID", "TIKTOK_CLIENT_SECRET",
    "DISCORD_CLIENT_ID", "DISCORD_CLIENT_SECRET", "DISCORD_BOT_TOKEN_ID",
    "SLACK_ID", "SLACK_SECRET", "SLACK_SIGNING_SECRET", "PINTEREST_CLIENT_ID",
    "PINTEREST_CLIENT_SECRET", "GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET",
    "DRIBBBLE_CLIENT_ID", "DRIBBBLE_CLIENT_SECRET", "BEEHIIVE_API_KEY",
    "BEEHIIVE_PUBLICATION_ID", "LISTMONK_DOMAIN", "LISTMONK_USER",
    "LISTMONK_API_KEY", "LISTMONK_LIST_ID",
}
inventory = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(inventory, dict):
    raise SystemExit("Encrypted inventory must be a top-level mapping")
env = os.environ.copy()
env.update({key: value for key, value in inventory.items()
            if key in postiz_keys and isinstance(value, str)})
os.execvpe("docker", ["docker", "compose", "up", "-d", "--force-recreate", "postiz"], env)
PY
