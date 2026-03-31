#!/bin/bash
# End-to-end test for the Dex identity layer.
# Requires: running aigion stack (docker compose up -d)
#
# Usage: ./dex/test-e2e.sh
#
# What it does:
#   1. Verifies dex-setup completed successfully
#   2. Verifies Dex is running and serving OIDC discovery
#   3. Verifies credentials were persisted
#   4. Verifies OAuth2 app exists in Forgejo
#   5. Verifies Dex config was templated correctly
#   6. Verifies idempotent restart (re-run dex-setup, check skip)

set -e

FORGEJO_URL="http://localhost:3000"
DEX_URL="http://localhost:5556"
ADMIN_USER="${FORGEJO_ADMIN_USER:-aigion-admin}"
ADMIN_PASS="${FORGEJO_ADMIN_PASS}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

# Load .env if ADMIN_PASS not set
if [ -z "$ADMIN_PASS" ]; then
  if [ -f .env ]; then
    ADMIN_PASS=$(grep FORGEJO_ADMIN_PASS .env | cut -d= -f2)
  fi
fi
[ -z "$ADMIN_PASS" ] && fail "FORGEJO_ADMIN_PASS not set and .env not found"

# --- Preflight ---
info "Checking stack is running..."
docker compose ps --format "{{.Name}}" | grep -q "achaean-forgejo" || fail "Forgejo not running"
docker compose ps --format "{{.Name}}" | grep -q "aigion-dex" || fail "Dex not running"
pass "Stack is running"

# --- Test 1: Dex is running (implies dex-setup succeeded) ---
info "Checking Dex container is running..."
DEX_STATE=$(docker compose ps dex --format "{{.State}}" 2>/dev/null)
echo "$DEX_STATE" | grep -qi "running" || fail "Dex not running (state: $DEX_STATE)"
pass "Dex container is running"

# --- Test 2: Dex OIDC discovery ---
info "Checking Dex OIDC discovery endpoint..."
ISSUER=$(curl -sf "$DEX_URL/.well-known/openid-configuration" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])" 2>/dev/null)
[ -z "$ISSUER" ] && fail "Dex not responding or invalid OIDC discovery"
pass "Dex OIDC discovery works (issuer: $ISSUER)"

# --- Test 3: Credentials persisted ---
info "Checking credentials were saved..."
CREDS=$(docker compose exec forgejo cat /data/gitea/dex/credentials.json 2>/dev/null)
echo "$CREDS" | grep -q "client_id" || fail "credentials.json missing or invalid"
echo "$CREDS" | grep -q "client_secret" || fail "credentials.json missing client_secret"
pass "Credentials persisted in forgejo_data volume"

# --- Test 4: OAuth2 app in Forgejo ---
info "Checking OAuth2 app exists in Forgejo..."
OAUTH_APPS=$(curl -sf "$FORGEJO_URL/api/v1/user/applications/oauth2" \
  -u "$ADMIN_USER:$ADMIN_PASS" 2>/dev/null)
echo "$OAUTH_APPS" | grep -q '"name":"dex"' || fail "OAuth2 app 'dex' not found in Forgejo"
pass "OAuth2 app 'dex' registered in Forgejo"

# --- Test 5: Dex config templated correctly ---
info "Checking Dex config was templated..."
CONFIG=$(docker compose exec forgejo cat /data/gitea/dex/config.yaml 2>/dev/null)
echo "$CONFIG" | grep -q "type: gitea" || fail "Dex config missing gitea connector"
echo "$CONFIG" | grep -q "clientID:" || fail "Dex config missing clientID"
# Verify no un-templated placeholders remain
echo "$CONFIG" | grep -q "__" && fail "Dex config has un-templated placeholders"
pass "Dex config templated correctly"

# --- Test 6: Idempotent restart ---
info "Testing idempotent restart..."
docker compose rm -f dex-setup > /dev/null 2>&1
docker compose up -d dex-setup > /dev/null 2>&1
sleep 5
LOGS=$(docker compose logs dex-setup 2>&1)
echo "$LOGS" | grep -q "skipping registration" || fail "Idempotent restart did not skip registration"
pass "Idempotent restart works (skipped registration)"

echo ""
echo -e "${GREEN}All Dex e2e tests passed!${NC}"
