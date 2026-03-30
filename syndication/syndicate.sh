#!/bin/sh
# Syndicate Achaean posts to social media via Postiz.
# Reads crosspost.postiz from post.json, maps to Postiz API, and publishes.
#
# Required env vars:
#   POSTIZ_KEY  — Postiz API key (Authorization header)
#   POSTIZ_URL  — Postiz instance URL (e.g. https://post.example.com)
#
# Optional env vars:
#   FORGEJO_URL — Forgejo instance URL (for media downloads)
#   FORGEJO_TOKEN — Forgejo API token (for media downloads)

set -e

POSTIZ_URL="${POSTIZ_URL%/}"

# Find new/changed post.json files in the latest push
changed_posts() {
  git diff --name-only HEAD~1..HEAD -- 'posts/*/post.json' 'posts/*/*/post.json' 2>/dev/null || true
}

# Upload a media file to Postiz, return the media object JSON
upload_media() {
  local file_url="$1"
  local tmp_file
  tmp_file=$(mktemp)

  # Download from Forgejo
  if [ -n "$FORGEJO_TOKEN" ]; then
    curl -sf -H "Authorization: token $FORGEJO_TOKEN" "$file_url" -o "$tmp_file"
  else
    curl -sf "$file_url" -o "$tmp_file"
  fi

  # Upload to Postiz
  curl -sf -X POST "$POSTIZ_URL/public/v1/upload" \
    -H "Authorization: $POSTIZ_KEY" \
    -F "file=@$tmp_file" | jq -c '.'

  rm -f "$tmp_file"
}

# Build Postiz API payload from a post.json file
build_payload() {
  local post_file="$1"
  local post_dir
  post_dir=$(dirname "$post_file")

  # Read the post
  local post_json
  post_json=$(cat "$post_file")

  # Check if crosspost.postiz exists
  local has_postiz
  has_postiz=$(echo "$post_json" | jq -r '.crosspost.postiz // empty')
  if [ -z "$has_postiz" ]; then
    echo "No crosspost.postiz in $post_file — skipping"
    return 1
  fi

  # Extract tags from routing
  local tags
  tags=$(echo "$post_json" | jq -c '[(.routing.tags // [])[] | {value: ., label: .}]')

  # Extract timestamp
  local timestamp
  timestamp=$(echo "$post_json" | jq -r '.timestamp // empty')
  if [ -z "$timestamp" ]; then
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
  fi

  # Build posts array — one entry per platform in crosspost.postiz
  local posts_array="[]"
  local platforms
  platforms=$(echo "$post_json" | jq -r '.crosspost.postiz | keys[]')

  for platform in $platforms; do
    local integration_id
    integration_id=$(echo "$post_json" | jq -r ".crosspost.postiz.\"$platform\".integration_id")

    if [ -z "$integration_id" ] || [ "$integration_id" = "null" ]; then
      echo "Warning: No integration_id for platform '$platform' — skipping"
      continue
    fi

    # Build value array (thread posts)
    local value_array="[]"
    local post_texts
    post_texts=$(echo "$post_json" | jq -c ".crosspost.postiz.\"$platform\".posts[]")

    while IFS= read -r text; do
      # Strip outer quotes from jq output and wrap in <p> tags
      local content
      content=$(echo "$text" | jq -r '.')
      content="<p>$content</p>"

      local value_entry
      value_entry=$(jq -nc --arg c "$content" '{content: $c, image: []}')
      value_array=$(echo "$value_array" | jq -c --argjson v "$value_entry" '. + [$v]')
    done <<EOF
$post_texts
EOF

    # Build the platform post entry
    local post_entry
    post_entry=$(jq -nc \
      --arg iid "$integration_id" \
      --argjson val "$value_array" \
      '{integration: {id: $iid}, value: $val}')

    posts_array=$(echo "$posts_array" | jq -c --argjson p "$post_entry" '. + [$p]')
  done

  # Assemble final Postiz payload
  jq -nc \
    --arg type "now" \
    --arg date "$timestamp" \
    --argjson tags "$tags" \
    --argjson posts "$posts_array" \
    '{type: $type, shortLink: false, date: $date, tags: $tags, posts: $posts}'
}

# Send payload to Postiz
publish() {
  local payload="$1"
  local post_file="$2"

  local response
  response=$(curl -sf -X POST "$POSTIZ_URL/public/v1/posts" \
    -H "Authorization: $POSTIZ_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -w "\n%{http_code}" 2>&1) || true

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] 2>/dev/null; then
    echo "Published $post_file → Postiz (HTTP $http_code)"
  else
    echo "Failed to publish $post_file → Postiz (HTTP $http_code)"
    echo "Response: $body"
    return 1
  fi
}

# --- Main ---

if [ -z "$POSTIZ_KEY" ] || [ -z "$POSTIZ_URL" ]; then
  echo "Error: POSTIZ_KEY and POSTIZ_URL must be set"
  exit 1
fi

posts=$(changed_posts)
if [ -z "$posts" ]; then
  echo "No post.json changes detected. Nothing to syndicate."
  exit 0
fi

echo "Found changed posts:"
echo "$posts"
echo ""

failed=0
while IFS= read -r post_file; do
  echo "Processing: $post_file"

  payload=$(build_payload "$post_file") || continue

  echo "Payload:"
  echo "$payload" | jq .
  echo ""

  publish "$payload" "$post_file" || failed=1
  echo ""
done <<EOF
$posts
EOF

if [ "$failed" -ne 0 ]; then
  echo "Some posts failed to syndicate."
  exit 1
fi

echo "Syndication complete."
