# Tuwunel Chat Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Dex into Achaean, add Tuwunel Matrix homeserver, both behind a `chat` Docker Compose profile. Update Aigion to remove its Dex services and add Caddy routes.

**Architecture:** Dex and Tuwunel live in Achaean's docker-compose behind `profiles: [chat]`. The existing setup script is extended to also generate Tuwunel OIDC credentials and template its config. Aigion gets Dex/Tuwunel via `include:` and adds Caddy routes.

**Tech Stack:** Tuwunel (Rust Matrix homeserver), Dex (Go OIDC proxy), Docker Compose profiles, shell scripting

**Spec:** `specs/2026-03-31-tuwunel-chat-integration.md`

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `achaean/dex/setup.sh` | Create (moved + extended) | Auto-registration for Forgejo↔Dex↔Tuwunel |
| `achaean/dex/config.template.yaml` | Create (moved + extended) | Dex config template with Tuwunel static client |
| `achaean/tuwunel/tuwunel.template.toml` | Create | Tuwunel config template with OIDC placeholders |
| `achaean/dex/test-e2e.sh` | Create (moved + extended) | E2E test covering Dex + Tuwunel |
| `achaean/docker-compose.yml` | Modify | Add dex-setup, dex, tuwunel (profile: chat) |
| `achaean/.env.example` | Modify | Add Dex + Tuwunel env vars |
| `docker-compose.yml` | Modify | Remove dex-setup + dex services, update Caddy |
| `Caddyfile` | Modify | Add chat.DOMAIN route |
| `.env.example` | Modify | Move Dex vars out, add MATRIX_SERVER_NAME |
| `dex/` | Delete | Moved to achaean/dex/ |

---

### Task 1: Create Tuwunel config template in Achaean

**Files:**
- Create: `achaean/tuwunel/tuwunel.template.toml`

- [ ] **Step 1: Create tuwunel directory**

```bash
mkdir -p achaean/tuwunel
```

- [ ] **Step 2: Write config template**

Create `achaean/tuwunel/tuwunel.template.toml`:

```toml
[global]
server_name = "__MATRIX_SERVER_NAME__"
database_path = "/var/lib/tuwunel"
address = "0.0.0.0"
port = 8008
allow_registration = false
log = "warn,state_res=warn"

[global.well_known]
client = "__MATRIX_CLIENT_URL__"

[[global.identity_provider]]
brand = "Authelia"
client_id = "tuwunel"
client_secret = "__TUWUNEL_DEX_SECRET__"
issuer_url = "__DEX_ISSUER_URL__"
callback_url = "__TUWUNEL_CALLBACK_URL__"
name = "Sign in with Achaean"
discovery = true
default = true
```

- [ ] **Step 3: Commit**

```bash
git add achaean/tuwunel/tuwunel.template.toml
git commit -m "feat(tuwunel): add Tuwunel config template with OIDC placeholders"
```

---

### Task 2: Move and extend Dex config template in Achaean

**Files:**
- Create: `achaean/dex/config.template.yaml` (moved from `dex/config.template.yaml`, extended with Tuwunel static client)

- [ ] **Step 1: Create achaean dex directory**

```bash
mkdir -p achaean/dex
```

- [ ] **Step 2: Write extended config template**

Create `achaean/dex/config.template.yaml`:

```yaml
issuer: __ISSUER__

storage:
  type: memory

web:
  http: 0.0.0.0:5556

connectors:
  - type: gitea
    id: forgejo
    name: Forgejo
    config:
      clientID: __DEX_FORGEJO_CLIENT_ID__
      clientSecret: __DEX_FORGEJO_CLIENT_SECRET__
      redirectURI: __ISSUER__/callback
      baseURL: __FORGEJO_URL__
      useLoginAsID: true
      loadAllGroups: false

staticClients:
  - id: tuwunel
    name: Tuwunel
    secret: __TUWUNEL_DEX_SECRET__
    redirectURIs:
      - __TUWUNEL_CALLBACK_URL__

enablePasswordDB: false
```

- [ ] **Step 3: Commit**

```bash
git add achaean/dex/config.template.yaml
git commit -m "feat(dex): move Dex config template to Achaean, add Tuwunel static client"
```

---

### Task 3: Move and extend setup script in Achaean

**Files:**
- Create: `achaean/dex/setup.sh` (moved from `dex/setup.sh`, extended for Tuwunel)

- [ ] **Step 1: Write extended setup script**

Create `achaean/dex/setup.sh`:

```bash
#!/bin/sh
set -e

FORGEJO_URL="http://forgejo:3000"
DEX_DIR="/data/gitea/dex"
TUWUNEL_DIR="/data/gitea/tuwunel"
CREDS_FILE="$DEX_DIR/credentials.json"
CONFIG_OUT="$DEX_DIR/config.yaml"
TUWUNEL_CONFIG_OUT="$TUWUNEL_DIR/config.toml"

mkdir -p "$DEX_DIR" "$TUWUNEL_DIR"

# ── Idempotent: skip if credentials already exist ──
if [ -f "$CREDS_FILE" ]; then
  echo "[dex-setup] Credentials already exist at $CREDS_FILE, skipping registration."
  CLIENT_ID=$(cat "$CREDS_FILE" | grep -o '"client_id":"[^"]*"' | cut -d'"' -f4)
  CLIENT_SECRET=$(cat "$CREDS_FILE" | grep -o '"client_secret":"[^"]*"' | cut -d'"' -f4)
  TUWUNEL_SECRET=$(cat "$CREDS_FILE" | grep -o '"tuwunel_secret":"[^"]*"' | cut -d'"' -f4)
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

  # ── Step 5: Generate Tuwunel client secret ──
  TUWUNEL_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  echo "[dex-setup] Generated Tuwunel client secret."

  # ── Step 6: Save all credentials ──
  echo "{\"client_id\":\"$CLIENT_ID\",\"client_secret\":\"$CLIENT_SECRET\",\"tuwunel_secret\":\"$TUWUNEL_SECRET\"}" > "$CREDS_FILE"
  echo "[dex-setup] Credentials saved to $CREDS_FILE"
fi

# ── Step 7: Determine URLs based on environment ──
echo "[dex-setup] Generating configs..."

if [ "$DOMAIN" = "localhost" ] || [ "$DOMAIN" = "example.com" ] || [ -z "$DOMAIN" ]; then
  ISSUER="http://localhost:5556"
  FORGEJO_BASE_URL="http://forgejo:3000"
  TUWUNEL_CALLBACK="http://localhost:8008/_matrix/client/unstable/login/sso/callback/tuwunel"
  MATRIX_CLIENT_URL="http://localhost:8008"
else
  ISSUER="https://auth.$DOMAIN"
  FORGEJO_BASE_URL="https://git.$DOMAIN"
  TUWUNEL_CALLBACK="https://chat.$DOMAIN/_matrix/client/unstable/login/sso/callback/tuwunel"
  MATRIX_CLIENT_URL="https://chat.$DOMAIN"
fi

# ── Step 8: Template Dex config ──
sed \
  -e "s|__ISSUER__|$ISSUER|g" \
  -e "s|__DEX_FORGEJO_CLIENT_ID__|$CLIENT_ID|g" \
  -e "s|__DEX_FORGEJO_CLIENT_SECRET__|$CLIENT_SECRET|g" \
  -e "s|__FORGEJO_URL__|$FORGEJO_BASE_URL|g" \
  -e "s|__TUWUNEL_DEX_SECRET__|$TUWUNEL_SECRET|g" \
  -e "s|__TUWUNEL_CALLBACK_URL__|$TUWUNEL_CALLBACK|g" \
  /config.template.yaml > "$CONFIG_OUT"

echo "[dex-setup] Dex config written to $CONFIG_OUT"

# ── Step 9: Template Tuwunel config ──
sed \
  -e "s|__MATRIX_SERVER_NAME__|$MATRIX_SERVER_NAME|g" \
  -e "s|__MATRIX_CLIENT_URL__|$MATRIX_CLIENT_URL|g" \
  -e "s|__TUWUNEL_DEX_SECRET__|$TUWUNEL_SECRET|g" \
  -e "s|__DEX_ISSUER_URL__|$ISSUER|g" \
  -e "s|__TUWUNEL_CALLBACK_URL__|$TUWUNEL_CALLBACK|g" \
  /tuwunel.template.toml > "$TUWUNEL_CONFIG_OUT"

echo "[dex-setup] Tuwunel config written to $TUWUNEL_CONFIG_OUT"
echo "[dex-setup] Done."
```

- [ ] **Step 2: Make script executable**

```bash
chmod +x achaean/dex/setup.sh
```

- [ ] **Step 3: Commit**

```bash
git add achaean/dex/setup.sh
git commit -m "feat(dex): move setup script to Achaean, extend for Tuwunel credentials"
```

---

### Task 4: Add services to Achaean docker-compose

**Files:**
- Modify: `achaean/docker-compose.yml`

- [ ] **Step 1: Add dex-setup, dex, and tuwunel services with chat profile**

Add before the `volumes:` section in `achaean/docker-compose.yml`:

```yaml
  # --- Dex Setup (one-shot init, chat profile) ---
  dex-setup:
    image: codeberg.org/forgejo/forgejo:14
    container_name: achaean-dex-setup
    user: "1000:1000"
    profiles: [chat]
    depends_on:
      forgejo:
        condition: service_healthy
    volumes:
      - forgejo_data:/data
      - ./dex/setup.sh:/setup.sh:ro
      - ./dex/config.template.yaml:/config.template.yaml:ro
      - ./tuwunel/tuwunel.template.toml:/tuwunel.template.toml:ro
    environment:
      - FORGEJO_ADMIN_USER=${FORGEJO_ADMIN_USER:-aigion-admin}
      - FORGEJO_ADMIN_PASS=${FORGEJO_ADMIN_PASS}
      - FORGEJO_ADMIN_EMAIL=${FORGEJO_ADMIN_EMAIL:-admin@example.com}
      - DOMAIN=${DOMAIN}
      - MATRIX_SERVER_NAME=${MATRIX_SERVER_NAME:-localhost}
    entrypoint: /bin/sh
    command: /setup.sh

  # --- Dex (OIDC Proxy, chat profile) ---
  dex:
    image: dexidp/dex:v2.41.1
    container_name: achaean-dex
    restart: unless-stopped
    profiles: [chat]
    depends_on:
      dex-setup:
        condition: service_completed_successfully
    volumes:
      - forgejo_data:/data:ro
    command: dex serve /data/gitea/dex/config.yaml
    ports:
      - "${DEX_PORT:-5556}:5556"

  # --- Tuwunel (Matrix homeserver, chat profile) ---
  tuwunel:
    image: ghcr.io/matrix-construct/tuwunel:latest
    container_name: achaean-tuwunel
    restart: unless-stopped
    profiles: [chat]
    depends_on:
      dex-setup:
        condition: service_completed_successfully
    volumes:
      - forgejo_data:/data:ro
      - tuwunel_data:/var/lib/tuwunel
    environment:
      - TUWUNEL_CONFIG=/data/gitea/tuwunel/config.toml
    ports:
      - "${TUWUNEL_PORT:-8008}:8008"
```

Also add `tuwunel_data:` to the `volumes:` section at the bottom.

- [ ] **Step 2: Update .env.example**

Add to `achaean/.env.example`:

```
# === Dex (OIDC Proxy) — active with --profile chat ===
DEX_PORT=5556
FORGEJO_ADMIN_USER=aigion-admin
FORGEJO_ADMIN_PASS=CHANGE_ME
FORGEJO_ADMIN_EMAIL=admin@example.com

# === Tuwunel (Matrix) — active with --profile chat ===
TUWUNEL_PORT=8008
MATRIX_SERVER_NAME=localhost
```

- [ ] **Step 3: Commit**

```bash
git add achaean/docker-compose.yml achaean/.env.example
git commit -m "feat(achaean): add Dex + Tuwunel services behind chat profile"
```

---

### Task 5: Remove Dex from Aigion, add Caddy chat route

**Files:**
- Modify: `docker-compose.yml` (remove dex-setup + dex services, update Caddy depends_on)
- Modify: `Caddyfile` (add chat.DOMAIN route)
- Modify: `.env.example` (remove Dex vars, add MATRIX_SERVER_NAME)
- Delete: `dex/` folder

- [ ] **Step 1: Remove dex-setup and dex services from Aigion docker-compose**

Remove the entire `# --- Dex Setup (one-shot init) ---` and `# --- Dex (OIDC Proxy) ---` service blocks (lines 192-224) from `docker-compose.yml`.

Update Caddy's `depends_on` — replace `dex` with `tuwunel`:

```yaml
    depends_on:
      - forgejo
      - synedrion
      - postiz
      - tuwunel
```

- [ ] **Step 2: Add chat route to Caddyfile**

Add to `Caddyfile`:

```
chat.{$DOMAIN} {
	reverse_proxy tuwunel:8008
}
```

- [ ] **Step 3: Update .env.example**

Remove the `# === Dex (OIDC Proxy) ===` section from `.env.example` (those vars now live in Achaean's .env.example).

Add:

```
# === Tuwunel (Matrix) ===
MATRIX_SERVER_NAME=chat.example.com
```

- [ ] **Step 4: Delete Aigion's dex/ folder**

```bash
rm -rf dex/
```

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml Caddyfile .env.example
git rm -r dex/
git commit -m "refactor: move Dex to Achaean, add Tuwunel Caddy route, remove Aigion dex/"
```

---

### Task 6: Create e2e test for chat profile

**Files:**
- Create: `achaean/dex/test-e2e.sh`

- [ ] **Step 1: Write e2e test**

Create `achaean/dex/test-e2e.sh`:

```bash
#!/bin/bash
# End-to-end test for Dex + Tuwunel (chat profile).
# Requires: docker compose --profile chat up -d
#
# Usage: ./dex/test-e2e.sh

set -e

FORGEJO_URL="http://localhost:3000"
DEX_URL="http://localhost:5556"
TUWUNEL_URL="http://localhost:8008"
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
  for f in .env ../.env; do
    if [ -f "$f" ]; then
      ADMIN_PASS=$(grep FORGEJO_ADMIN_PASS "$f" | cut -d= -f2)
      break
    fi
  done
fi
[ -z "$ADMIN_PASS" ] && fail "FORGEJO_ADMIN_PASS not set and .env not found"

# --- Preflight ---
info "Checking stack is running..."
docker compose ps --format "{{.Name}}" | grep -q "achaean-forgejo" || fail "Forgejo not running"
docker compose ps --format "{{.Name}}" | grep -q "achaean-dex" || fail "Dex not running (did you use --profile chat?)"
docker compose ps --format "{{.Name}}" | grep -q "achaean-tuwunel" || fail "Tuwunel not running (did you use --profile chat?)"
pass "Stack is running (Forgejo + Dex + Tuwunel)"

# --- Test 1: Dex OIDC discovery ---
info "Checking Dex OIDC discovery endpoint..."
ISSUER=$(curl -sf "$DEX_URL/.well-known/openid-configuration" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])" 2>/dev/null)
[ -z "$ISSUER" ] && fail "Dex not responding or invalid OIDC discovery"
pass "Dex OIDC discovery works (issuer: $ISSUER)"

# --- Test 2: Credentials persisted (including tuwunel_secret) ---
info "Checking credentials were saved..."
CREDS=$(docker compose exec forgejo cat /data/gitea/dex/credentials.json 2>/dev/null)
echo "$CREDS" | grep -q "client_id" || fail "credentials.json missing client_id"
echo "$CREDS" | grep -q "client_secret" || fail "credentials.json missing client_secret"
echo "$CREDS" | grep -q "tuwunel_secret" || fail "credentials.json missing tuwunel_secret"
pass "All credentials persisted (Dex + Tuwunel)"

# --- Test 3: OAuth2 app in Forgejo ---
info "Checking OAuth2 app exists in Forgejo..."
OAUTH_APPS=$(curl -sf "$FORGEJO_URL/api/v1/user/applications/oauth2" \
  -u "$ADMIN_USER:$ADMIN_PASS" 2>/dev/null)
echo "$OAUTH_APPS" | grep -q '"name":"dex"' || fail "OAuth2 app 'dex' not found in Forgejo"
pass "OAuth2 app 'dex' registered in Forgejo"

# --- Test 4: Dex config has Tuwunel static client ---
info "Checking Dex config has Tuwunel static client..."
DEX_CONFIG=$(docker compose exec forgejo cat /data/gitea/dex/config.yaml 2>/dev/null)
echo "$DEX_CONFIG" | grep -q "id: tuwunel" || fail "Dex config missing Tuwunel static client"
echo "$DEX_CONFIG" | grep -q "__" && fail "Dex config has un-templated placeholders"
pass "Dex config has Tuwunel static client, no placeholders"

# --- Test 5: Tuwunel config templated ---
info "Checking Tuwunel config was templated..."
TUW_CONFIG=$(docker compose exec forgejo cat /data/gitea/tuwunel/config.toml 2>/dev/null)
echo "$TUW_CONFIG" | grep -q "server_name" || fail "Tuwunel config missing server_name"
echo "$TUW_CONFIG" | grep -q "client_id = \"tuwunel\"" || fail "Tuwunel config missing OIDC client_id"
echo "$TUW_CONFIG" | grep -q "__" && fail "Tuwunel config has un-templated placeholders"
pass "Tuwunel config templated correctly"

# --- Test 6: Tuwunel Matrix API responds ---
info "Checking Tuwunel Matrix API..."
VERSIONS=$(curl -sf "$TUWUNEL_URL/_matrix/client/versions" 2>/dev/null)
echo "$VERSIONS" | grep -q "versions" || fail "Tuwunel not responding on /_matrix/client/versions"
pass "Tuwunel Matrix API responds"

# --- Test 7: Idempotent restart ---
info "Testing idempotent restart..."
docker compose --profile chat rm -f dex-setup > /dev/null 2>&1
docker compose --profile chat up -d dex-setup > /dev/null 2>&1
sleep 5
LOGS=$(docker compose logs dex-setup 2>&1)
echo "$LOGS" | grep -q "skipping registration" || fail "Idempotent restart did not skip registration"
pass "Idempotent restart works (skipped registration)"

echo ""
echo -e "${GREEN}All Dex + Tuwunel e2e tests passed!${NC}"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x achaean/dex/test-e2e.sh
```

- [ ] **Step 3: Commit**

```bash
git add achaean/dex/test-e2e.sh
git commit -m "test: add e2e test for Dex + Tuwunel chat profile"
```

---

### Task 7: Test full stack locally

- [ ] **Step 1: Tear down existing stack**

```bash
cd /Users/aicoder/Documents/social-graph/aigion
docker compose down -v
```

- [ ] **Step 2: Start core stack (no chat profile)**

```bash
docker compose up -d
```

Verify Dex and Tuwunel are NOT running:

```bash
docker compose ps --format "{{.Name}}" | grep -E "dex|tuwunel" && echo "FAIL: chat services should not be running" || echo "OK: chat services not running"
```

- [ ] **Step 3: Start with chat profile**

```bash
docker compose --profile chat up -d
```

Wait for all services. Check dex-setup logs:

```bash
docker compose logs dex-setup
```

Expected output includes:
```
[dex-setup] Creating Forgejo admin user: aigion-admin
[dex-setup] API token created.
[dex-setup] Creating OAuth2 application 'dex' in Forgejo...
[dex-setup] Generated Tuwunel client secret.
[dex-setup] Credentials saved to /data/gitea/dex/credentials.json
[dex-setup] Dex config written to /data/gitea/dex/config.yaml
[dex-setup] Tuwunel config written to /data/gitea/tuwunel/config.toml
[dex-setup] Done.
```

- [ ] **Step 4: Verify Dex**

```bash
curl -s http://localhost:5556/.well-known/openid-configuration | python3 -m json.tool
```

Expected: JSON with issuer, endpoints.

- [ ] **Step 5: Verify Tuwunel**

```bash
curl -s http://localhost:8008/_matrix/client/versions | python3 -m json.tool
```

Expected: JSON with `versions` array.

- [ ] **Step 6: Run e2e test from Achaean directory**

```bash
cd achaean && ./dex/test-e2e.sh
```

Expected: All tests pass.

- [ ] **Step 7: Commit any fixes**

```bash
git add -A
git commit -m "fix: adjustments from local testing"
```
