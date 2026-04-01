#!/bin/sh
# Seed the first Postiz user account.
# Requires: running Postiz container with no existing organizations.
#
# Usage: ./postiz-seed.sh
#
# Uses POSTIZ_ADMIN_EMAIL and POSTIZ_ADMIN_PASS from .env
# or prompts for them if not set.

set -e

# Load .env
if [ -f .env ]; then
  ADMIN_EMAIL=$(grep POSTIZ_ADMIN_EMAIL .env | cut -d= -f2)
  ADMIN_PASS=$(grep POSTIZ_ADMIN_PASS .env | cut -d= -f2)
  ADMIN_COMPANY=$(grep POSTIZ_ADMIN_COMPANY .env | cut -d= -f2)
fi

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@postiz.local}"
ADMIN_COMPANY="${ADMIN_COMPANY:-Qtpi Bonding}"

if [ -z "$ADMIN_PASS" ]; then
  echo "Set POSTIZ_ADMIN_PASS in .env first"
  exit 1
fi

POSTIZ_INTERNAL="http://postiz:5000"

echo "[postiz-seed] Creating first user: $ADMIN_EMAIL"

RESPONSE=$(docker compose exec -T postiz curl -sf -X POST "$POSTIZ_INTERNAL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{
    \"email\": \"$ADMIN_EMAIL\",
    \"password\": \"$ADMIN_PASS\",
    \"company\": \"$ADMIN_COMPANY\",
    \"provider\": \"LOCAL\"
  }" 2>&1)

if echo "$RESPONSE" | grep -q "error\|Error"; then
  echo "[postiz-seed] ERROR: $RESPONSE"
  exit 1
fi

echo "[postiz-seed] User created successfully."
echo "[postiz-seed] Login at your Postiz URL with: $ADMIN_EMAIL"
