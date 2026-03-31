# Dex Identity Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Dex as an OIDC proxy between Forgejo and future consuming services, with fully automated Forgejo↔Dex registration.

**Architecture:** A one-shot setup container creates a Forgejo admin user + OAuth2 app via CLI and API, saves credentials, and templates the Dex config. Dex then starts with the generated config. All secrets auto-generated and persisted in the `forgejo_data` volume.

**Tech Stack:** Dex (Go OIDC proxy), Forgejo (git forge + identity), Docker Compose, shell scripting, Caddy (reverse proxy)

**Spec:** `specs/2026-03-31-dex-identity-layer.md`

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `dex/config.template.yaml` | Create | Dex config template with placeholders |
| `dex/setup.sh` | Create | Auto-registration script (init container entrypoint) |
| `docker-compose.yml` | Modify | Add dex-setup and dex services |
| `Caddyfile` | Modify | Add auth.DOMAIN route |
| `.env.example` | Modify | Add Dex/admin env vars |
| `.env` | Modify | Add Dex/admin env vars with real values |

---

### Task 1: Create Dex config template

**Files:**
- Create: `dex/config.template.yaml`

- [ ] **Step 1: Create dex directory**

```bash
mkdir -p dex
```

- [ ] **Step 2: Write config template**

Create `dex/config.template.yaml`:

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

staticClients: []

enablePasswordDB: false
```

- [ ] **Step 3: Commit**

```bash
git add dex/config.template.yaml
git commit -m "feat(dex): add Dex config template with Forgejo gitea connector"
```

---

### Task 2: Create setup script

**Files:**
- Create: `dex/setup.sh`

- [ ] **Step 1: Write the setup script**

Create `dex/setup.sh`:

```bash
#!/bin/sh
set -e

FORGEJO_URL="http://forgejo:3000"
CREDS_FILE="/data/dex-credentials.json"
CONFIG_OUT="/data/dex-config.yaml"

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
```

- [ ] **Step 2: Make script executable**

```bash
chmod +x dex/setup.sh
```

- [ ] **Step 3: Commit**

```bash
git add dex/setup.sh
git commit -m "feat(dex): add auto-registration setup script for Forgejo↔Dex"
```

---

### Task 3: Add Dex services to docker-compose

**Files:**
- Modify: `docker-compose.yml` (add dex-setup + dex services and volume references)

- [ ] **Step 1: Add dex-setup and dex services**

Add before the `volumes:` section in `docker-compose.yml`:

```yaml
  # --- Dex Setup (one-shot init) ---
  dex-setup:
    image: codeberg.org/forgejo/forgejo:14
    container_name: aigion-dex-setup
    depends_on:
      forgejo:
        condition: service_healthy
    volumes:
      - forgejo_data:/data
      - ./dex/setup.sh:/setup.sh:ro
      - ./dex/config.template.yaml:/config.template.yaml:ro
    environment:
      - FORGEJO_ADMIN_USER=${FORGEJO_ADMIN_USER:-aigion-admin}
      - FORGEJO_ADMIN_PASS=${FORGEJO_ADMIN_PASS}
      - FORGEJO_ADMIN_EMAIL=${FORGEJO_ADMIN_EMAIL:-admin@example.com}
      - DOMAIN=${DOMAIN}
    entrypoint: /bin/sh
    command: /setup.sh

  # --- Dex (OIDC Proxy) ---
  dex:
    image: dexidp/dex:v2.41.1
    container_name: aigion-dex
    restart: unless-stopped
    depends_on:
      dex-setup:
        condition: service_completed_successfully
    volumes:
      - forgejo_data:/data:ro
    command: dex serve /data/dex-config.yaml
    ports:
      - "${DEX_PORT:-5556}:5556"
```

- [ ] **Step 2: Commit**

```bash
git add docker-compose.yml
git commit -m "feat(dex): add dex-setup and dex services to docker-compose"
```

---

### Task 4: Update Caddyfile

**Files:**
- Modify: `Caddyfile`

- [ ] **Step 1: Add auth subdomain route**

Add to `Caddyfile`:

```
auth.{$DOMAIN} {
	reverse_proxy dex:5556
}
```

- [ ] **Step 2: Update Caddy depends_on in docker-compose**

In `docker-compose.yml`, add `dex` to Caddy's `depends_on`:

```yaml
    depends_on:
      - forgejo
      - synedrion
      - postiz
      - dex
```

- [ ] **Step 3: Commit**

```bash
git add Caddyfile docker-compose.yml
git commit -m "feat(dex): add auth.DOMAIN route to Caddyfile"
```

---

### Task 5: Update env files

**Files:**
- Modify: `.env.example`
- Modify: `.env`

- [ ] **Step 1: Add Dex env vars to .env.example**

Add to `.env.example` after the `# === Achaean Postgres ===` section:

```
# === Dex (OIDC Proxy) ===
DEX_PORT=5556
FORGEJO_ADMIN_USER=aigion-admin
FORGEJO_ADMIN_PASS=CHANGE_ME
FORGEJO_ADMIN_EMAIL=admin@example.com
```

- [ ] **Step 2: Add Dex env vars to .env**

Add to `.env` with real values (use a generated password for admin):

```
# === Dex (OIDC Proxy) ===
DEX_PORT=5556
FORGEJO_ADMIN_USER=aigion-admin
FORGEJO_ADMIN_PASS=<generate-a-password>
FORGEJO_ADMIN_EMAIL=admin@example.com
```

- [ ] **Step 3: Commit (.env.example only — .env is gitignored)**

```bash
git add .env.example
git commit -m "feat(dex): add Dex env vars to .env.example"
```

---

### Task 6: Test the full stack locally

- [ ] **Step 1: Start the stack**

```bash
cd /Users/aicoder/Documents/social-graph/aigion
docker compose up -d
```

Wait for all services to be healthy. Watch the dex-setup container logs:

```bash
docker compose logs -f dex-setup
```

Expected output:
```
[dex-setup] Creating Forgejo admin user: aigion-admin
[dex-setup] Creating API token...
[dex-setup] API token created.
[dex-setup] Creating OAuth2 application 'dex' in Forgejo...
[dex-setup] Credentials saved to /data/dex-credentials.json
[dex-setup] Generating Dex config...
[dex-setup] Dex config written to /data/dex-config.yaml
[dex-setup] Done.
```

- [ ] **Step 2: Verify Dex is running**

```bash
curl -s http://localhost:5556/.well-known/openid-configuration | python3 -m json.tool
```

Expected: JSON with `issuer`, `authorization_endpoint`, `token_endpoint`, etc.

- [ ] **Step 3: Verify credentials were persisted**

```bash
docker compose exec forgejo cat /data/dex-credentials.json
```

Expected: JSON with `client_id` and `client_secret`.

- [ ] **Step 4: Verify OAuth2 app exists in Forgejo**

```bash
curl -s -u "aigion-admin:<your-password>" http://localhost:3000/api/v1/user/applications/oauth2
```

Expected: JSON array containing an app with `"name": "dex"`.

- [ ] **Step 5: Verify idempotent restart**

```bash
docker compose down
docker compose up -d
docker compose logs dex-setup
```

Expected: `[dex-setup] Credentials already exist at /data/dex-credentials.json, skipping registration.`

- [ ] **Step 6: Commit if any fixes were needed**

```bash
git add -A
git commit -m "fix(dex): adjustments from local testing"
```
