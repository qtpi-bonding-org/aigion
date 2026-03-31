#!/bin/sh
set -e

FORGEJO_URL="http://forgejo:3000"
DEX_DIR="/data/gitea/dex"
CREDS_FILE="$DEX_DIR/credentials.json"
CONFIG_OUT="$DEX_DIR/config.yaml"

mkdir -p "$DEX_DIR"

# ── Idempotent: skip if credentials already exist ──
if [ -f "$CREDS_FILE" ]; then
  echo "[dex-setup] Credentials already exist at $CREDS_FILE, skipping registration."
  # Still regenerate config in case template changed
  CLIENT_ID=$(cat "$CREDS_FILE" | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)
  CLIENT_SECRET=$(cat "$CREDS_FILE" | grep -o '"client_secret":"[^"]*"' | cut -d'"' -f4)
else
  # ── Step 1: Create Forgejo admin user (idempotent) ──
  echo "[dex-setup] Creating Forgejo admin user: $FORGEJO_ADMIN_USER"
  forgejo admin user create \
    --admin \
    --username "$FORGEJO_ADMIN_USER" \
    --password "$FORGEJO_ADMIN_PASS" \
    --email "$FORGEJO_ADMIN_EMAIL" \
    --must-change-password=false 2>/dev/null || echo "[dex-setup] Admin user already exists (OK)"

  # ── Step 2: Create API token ──
  echo "[dex-setup] Creating API token..."
  TOKEN_RESPONSE=$(curl -sf -X POST "$FORGEJO_URL/api/v1/users/$FORGEJO_ADMIN_USER/tokens" \
    -u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASS" \
    -H "Content-Type: application/json" \
    -d '{"name":"dex-setup-'"$(date +%s)"'","scopes":["all"]}')

  TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"sha1":"[^"]*"' | cut -d'"' -f4)
  if [ -z "$TOKEN" ]; then
    echo "[dex-setup] ERROR: Failed to create API token"
    echo "$TOKEN_RESPONSE"
    exit 1
  fi
  echo "[dex-setup] API token created."

  # ── Step 3: Determine redirect URIs ──
  if [ "$DOMAIN" = "localhost" ] || [ "$DOMAIN" = "example.com" ] || [ -z "$DOMAIN" ]; then
    REDIRECT_URIS='["http://localhost:5556/callback"]'
  else
    REDIRECT_URIS='["https://auth.'"$DOMAIN"'/callback","http://localhost:5556/callback"]'
  fi

  # ── Step 4: Create OAuth2 app ──
  echo "[dex-setup] Creating OAuth2 application 'dex' in Forgejo..."
  OAUTH_RESPONSE=$(curl -sf -X POST "$FORGEJO_URL/api/v1/user/applications/oauth2" \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "dex",
      "redirect_uris": '"$REDIRECT_URIS"',
      "confidential_client": true
    }')

  CLIENT_ID=$(echo "$OAUTH_RESPONSE" | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)
  CLIENT_SECRET=$(echo "$OAUTH_RESPONSE" | grep -o '"client_secret":"[^"]*"' | cut -d'"' -f4)

  if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    echo "[dex-setup] ERROR: Failed to create OAuth2 app"
    echo "$OAUTH_RESPONSE"
    exit 1
  fi

  # ── Step 5: Save credentials ──
  echo "{\"client_id\":\"$CLIENT_ID\",\"client_secret\":\"$CLIENT_SECRET\"}" > "$CREDS_FILE"
  echo "[dex-setup] Credentials saved to $CREDS_FILE"
fi

# ── Step 6: Template Dex config ──
echo "[dex-setup] Generating Dex config..."

if [ "$DOMAIN" = "localhost" ] || [ "$DOMAIN" = "example.com" ] || [ -z "$DOMAIN" ]; then
  ISSUER="http://localhost:5556"
  FORGEJO_BASE_URL="http://forgejo:3000"
else
  ISSUER="https://auth.$DOMAIN"
  FORGEJO_BASE_URL="https://git.$DOMAIN"
fi

sed \
  -e "s|__ISSUER__|$ISSUER|g" \
  -e "s|__DEX_FORGEJO_CLIENT_ID__|$CLIENT_ID|g" \
  -e "s|__DEX_FORGEJO_CLIENT_SECRET__|$CLIENT_SECRET|g" \
  -e "s|__FORGEJO_URL__|$FORGEJO_BASE_URL|g" \
  /config.template.yaml > "$CONFIG_OUT"

echo "[dex-setup] Dex config written to $CONFIG_OUT"
echo "[dex-setup] Done."
