#!/bin/bash
# Seed custom-field integrations into Postiz from .env
# Requires: running Postiz with a registered user.
#
# Usage: ./postiz-seed-integrations.sh
#
# Reads credentials from .env and connects any platform that has values set.
# Platforms using OAuth (X, LinkedIn, etc.) are connected via the Postiz UI.

set -e

POSTIZ_URL="http://127.0.0.1:${POSTIZ_PORT:-4007}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${YELLOW}→ $1${NC}"; }
skip() { echo -e "${YELLOW}  - $1 (not configured, skipping)${NC}"; }

# Load .env
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

[ -z "$POSTIZ_ADMIN_EMAIL" ] && fail "POSTIZ_ADMIN_EMAIL not set"
[ -z "$POSTIZ_ADMIN_PASS" ] && fail "POSTIZ_ADMIN_PASS not set"

# --- Login to get auth cookie ---
info "Logging into Postiz..."
COOKIE_JAR=$(mktemp)
curl -sf -X POST "$POSTIZ_URL/auth/login" \
  -H "Content-Type: application/json" \
  -c "$COOKIE_JAR" \
  -d "{
    \"email\": \"$POSTIZ_ADMIN_EMAIL\",
    \"password\": \"$POSTIZ_ADMIN_PASS\",
    \"provider\": \"LOCAL\"
  }" > /dev/null 2>&1

# Check we got cookies
if [ ! -s "$COOKIE_JAR" ]; then
  fail "Could not authenticate with Postiz"
fi
pass "Logged into Postiz"

# --- Helper: connect a custom-field integration ---
connect() {
  local provider="$1"
  local display_name="$2"
  local json="$3"

  info "Connecting $display_name..."
  CREDS=$(echo -n "$json" | base64)

  RESPONSE=$(curl -sf -X POST "$POSTIZ_URL/integrations/social/$provider/connect" \
    -H "Content-Type: application/json" \
    -b "$COOKIE_JAR" \
    -d "{\"code\":\"$CREDS\",\"state\":\"seed\",\"timezone\":0}" 2>&1) || true

  if echo "$RESPONSE" | grep -qi "error\|invalid\|unauthorized"; then
    echo -e "${RED}  ✗ Failed: $RESPONSE${NC}"
  else
    pass "$display_name connected"
  fi
}

echo ""
info "Seeding custom-field integrations..."
echo ""

# --- Bluesky ---
if [ -n "$BLUESKY_IDENTIFIER" ] && [ -n "$BLUESKY_PASSWORD" ]; then
  connect "bluesky" "Bluesky ($BLUESKY_IDENTIFIER)" \
    "{\"service\":\"${BLUESKY_SERVICE:-https://bsky.social}\",\"identifier\":\"$BLUESKY_IDENTIFIER\",\"password\":\"$BLUESKY_PASSWORD\"}"
else
  skip "Bluesky"
fi

# --- Lemmy ---
if [ -n "$LEMMY_IDENTIFIER" ] && [ -n "$LEMMY_PASSWORD" ] && [ -n "$LEMMY_SERVICE" ]; then
  connect "lemmy" "Lemmy ($LEMMY_IDENTIFIER@$LEMMY_SERVICE)" \
    "{\"service\":\"$LEMMY_SERVICE\",\"identifier\":\"$LEMMY_IDENTIFIER\",\"password\":\"$LEMMY_PASSWORD\"}"
else
  skip "Lemmy"
fi

# --- Nostr ---
if [ -n "$NOSTR_PRIVATE_KEY" ]; then
  connect "nostr" "Nostr" \
    "{\"password\":\"$NOSTR_PRIVATE_KEY\"}"
else
  skip "Nostr"
fi

# --- Dev.to ---
if [ -n "$DEVTO_API_KEY" ]; then
  connect "devto" "Dev.to" \
    "{\"apiKey\":\"$DEVTO_API_KEY\"}"
else
  skip "Dev.to"
fi

# --- Hashnode ---
if [ -n "$HASHNODE_API_KEY" ]; then
  connect "hashnode" "Hashnode" \
    "{\"apiKey\":\"$HASHNODE_API_KEY\"}"
else
  skip "Hashnode"
fi

# --- Medium ---
if [ -n "$MEDIUM_API_KEY" ]; then
  connect "medium" "Medium" \
    "{\"apiKey\":\"$MEDIUM_API_KEY\"}"
else
  skip "Medium"
fi

# --- WordPress ---
if [ -n "$WORDPRESS_DOMAIN" ] && [ -n "$WORDPRESS_USERNAME" ] && [ -n "$WORDPRESS_PASSWORD" ]; then
  connect "wordpress" "WordPress ($WORDPRESS_DOMAIN)" \
    "{\"domain\":\"$WORDPRESS_DOMAIN\",\"username\":\"$WORDPRESS_USERNAME\",\"password\":\"$WORDPRESS_PASSWORD\"}"
else
  skip "WordPress"
fi

# --- Listmonk ---
if [ -n "$LISTMONK_SEED_URL" ] && [ -n "$LISTMONK_SEED_USER" ] && [ -n "$LISTMONK_SEED_PASS" ]; then
  connect "listmonk" "Listmonk ($LISTMONK_SEED_URL)" \
    "{\"url\":\"$LISTMONK_SEED_URL\",\"username\":\"$LISTMONK_SEED_USER\",\"password\":\"$LISTMONK_SEED_PASS\"}"
else
  skip "Listmonk"
fi

rm -f "$COOKIE_JAR"

echo ""
echo -e "${GREEN}Integration seeding complete.${NC}"
echo "OAuth platforms (X, LinkedIn, Facebook, etc.) must be connected via the Postiz UI."
