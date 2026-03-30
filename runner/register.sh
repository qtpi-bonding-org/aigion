#!/bin/sh
set -e

echo "Waiting for Forgejo to be ready..."
until wget -qO- "$FORGEJO_URL/api/v1/version" > /dev/null 2>&1; do
  sleep 2
done

echo "Registering runner with Forgejo..."
forgejo-runner create-runner-file \
  --instance "$FORGEJO_URL" \
  --secret "$RUNNER_SECRET" \
  --name aigion-runner

echo "Runner registered."
