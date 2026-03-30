#!/bin/bash
# End-to-end test for the Achaean → Postiz syndication pipeline.
# Requires: running aigion stack (docker compose up -d)
#
# Usage: ./syndication/test-e2e.sh
#
# What it does:
#   1. Ensures admin user and runner are registered
#   2. Creates a test koinon repo with Actions enabled
#   3. Pushes the syndication workflow
#   4. Pushes a test post.json with crosspost.postiz
#   5. Waits for the Forgejo Action to run
#   6. Checks the runner logs for success/failure
#   7. Cleans up the test repo

set -e

FORGEJO_URL="http://localhost:3000"
ADMIN_USER="achaean"
ADMIN_PASS="achaean123"
ADMIN_EMAIL="admin@achaean.local"
REPO_NAME="syndication-test-$$"
RUNNER_SECRET="${FORGEJO_RUNNER_SECRET:-63bac6909f8380e21b61349f4e4a46741736f99a}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

cleanup() {
  info "Cleaning up test repo $REPO_NAME..."
  curl -s -X DELETE "$FORGEJO_URL/api/v1/repos/$ADMIN_USER/$REPO_NAME" \
    -u "$ADMIN_USER:$ADMIN_PASS" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# --- Preflight checks ---
info "Checking stack is running..."
docker compose ps --format "{{.Name}}" | grep -q "achaean-forgejo" || { fail "Forgejo not running"; exit 1; }
docker compose ps --format "{{.Name}}" | grep -q "aigion-forgejo-runner" || { fail "Runner not running"; exit 1; }
docker compose ps --format "{{.Name}}" | grep -q "aigion-postiz" || { fail "Postiz not running"; exit 1; }
pass "Stack is running"

curl -sf "$FORGEJO_URL/api/v1/version" > /dev/null || { fail "Forgejo not responding"; exit 1; }
pass "Forgejo is responding"

# --- Ensure admin user ---
info "Ensuring admin user..."
docker exec --user 1000 achaean-forgejo forgejo admin user create \
  --admin --username "$ADMIN_USER" --password "$ADMIN_PASS" \
  --email "$ADMIN_EMAIL" --must-change-password=false 2>&1 | grep -q "already exists" \
  && pass "Admin user exists" \
  || pass "Admin user created"

# --- Register runner on Forgejo side ---
info "Registering runner on Forgejo side..."
docker exec --user 1000 achaean-forgejo forgejo forgejo-cli actions register \
  --name aigion-runner --secret "$RUNNER_SECRET" > /dev/null 2>&1 || true
pass "Runner registered on Forgejo"

# Restart runner so it picks up the registration
info "Restarting runner to pick up registration..."
docker restart aigion-forgejo-runner > /dev/null 2>&1

# Wait for runner to declare successfully
info "Waiting for runner to connect (up to 30s)..."
RUNNER_WAIT=0
while [ "$RUNNER_WAIT" -lt 30 ]; do
  sleep 3
  RUNNER_WAIT=$((RUNNER_WAIT + 3))
  if docker logs aigion-forgejo-runner 2>&1 | tail -3 | grep -q "declared successfully"; then
    break
  fi
  echo -n "."
done
echo ""

docker logs aigion-forgejo-runner 2>&1 | tail -5 | grep -q "declared successfully" \
  || { fail "Runner not declared — check runner logs"; exit 1; }
pass "Runner is declared and polling"

# --- Create test repo ---
info "Creating test repo: $REPO_NAME"
curl -sf -X POST "$FORGEJO_URL/api/v1/user/repos" \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$REPO_NAME\", \"auto_init\": true}" > /dev/null
pass "Repo created"

# Enable Actions
curl -sf -X PATCH "$FORGEJO_URL/api/v1/repos/$ADMIN_USER/$REPO_NAME" \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  -H "Content-Type: application/json" \
  -d '{"has_actions": true}' > /dev/null
pass "Actions enabled"

# --- Push syndication workflow ---
info "Pushing syndication workflow..."
WORKFLOW_CONTENT=$(base64 < "$(dirname "$0")/test-workflow.yml")
curl -sf -X POST "$FORGEJO_URL/api/v1/repos/$ADMIN_USER/$REPO_NAME/contents/.forgejo/workflows/syndicate.yml" \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  -H "Content-Type: application/json" \
  -d "{\"content\": \"$WORKFLOW_CONTENT\", \"message\": \"add syndication workflow\"}" > /dev/null
pass "Workflow pushed"

# --- Push test post ---
info "Pushing test post.json with crosspost.postiz..."
POST_JSON=$(cat <<'JSON'
{
  "content": {
    "text": "Automated e2e test of the Achaean syndication pipeline.",
    "title": "E2E Test Post"
  },
  "routing": {
    "poleis": [],
    "tags": ["test", "e2e"]
  },
  "crosspost": {
    "postiz": {
      "x": {
        "integration_id": "test-integration-x",
        "posts": ["Achaean e2e test — syndication pipeline working!"]
      },
      "bluesky": {
        "integration_id": "test-integration-bsky",
        "posts": ["Achaean e2e test — this post was written in git and routed through Postiz."]
      }
    }
  },
  "timestamp": "2026-03-30T00:00:00Z",
  "signature": "test-signature"
}
JSON
)

POST_CONTENT=$(echo "$POST_JSON" | base64)
curl -sf -X POST "$FORGEJO_URL/api/v1/repos/$ADMIN_USER/$REPO_NAME/contents/posts/e2e-test/post.json" \
  -u "$ADMIN_USER:$ADMIN_PASS" \
  -H "Content-Type: application/json" \
  -d "{\"content\": \"$POST_CONTENT\", \"message\": \"add e2e test post\"}" > /dev/null
pass "Test post pushed"

# --- Wait for the action to run ---
info "Waiting for Forgejo Action to execute (up to 120s)..."
MAX_WAIT=120
ELAPSED=0
INTERVAL=5
RUN_STATUS=""

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))

  # Get the latest run for this repo
  RUN_STATUS=$(curl -sf "$FORGEJO_URL/api/v1/repos/$ADMIN_USER/$REPO_NAME/actions/runs" \
    -u "$ADMIN_USER:$ADMIN_PASS" | jq -r '.workflow_runs[-1].status // "pending"')

  if [ "$RUN_STATUS" = "success" ] || [ "$RUN_STATUS" = "failure" ]; then
    break
  fi

  echo -n "."
done
echo ""

if [ "$RUN_STATUS" = "success" ]; then
  pass "Forgejo Action completed successfully"
elif [ "$RUN_STATUS" = "failure" ]; then
  fail "Forgejo Action failed"
else
  fail "Forgejo Action did not complete within ${MAX_WAIT}s (status: $RUN_STATUS)"
fi

# --- Check runner logs for syndication output ---
info "Checking runner logs for syndication output..."
RUNNER_LOGS=$(docker logs aigion-forgejo-runner 2>&1)

if echo "$RUNNER_LOGS" | grep -q "Processing: posts/e2e-test/post.json"; then
  pass "Runner processed the test post"
else
  fail "Runner did not process the test post"
fi

if echo "$RUNNER_LOGS" | grep -q "Payload:"; then
  pass "Payload was built from crosspost.postiz"
else
  fail "Payload was not built"
fi

if echo "$RUNNER_LOGS" | grep -q "Sending to Postiz"; then
  pass "Postiz API was called"
else
  fail "Postiz API was not called"
fi

if echo "$RUNNER_LOGS" | grep -q "Syndication complete"; then
  pass "Syndication completed"
else
  fail "Syndication did not complete"
fi

# --- Summary ---
echo ""
if [ "$RUN_STATUS" = "success" ]; then
  echo -e "${GREEN}═══ E2E TEST PASSED ═══${NC}"
  echo "Pipeline: push → Forgejo Action → parse post.json → call Postiz API"
  echo "Note: Postiz API call used placeholder keys. With real keys, posts would be distributed."
else
  echo -e "${RED}═══ E2E TEST FAILED ═══${NC}"
  echo "Check runner logs: docker logs aigion-forgejo-runner 2>&1 | tail -30"
  exit 1
fi
