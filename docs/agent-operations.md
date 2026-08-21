# Agent operations on Aigion

This is the handoff guide for an agent maintaining the Aigion VPS. It assumes
the local SSH alias `aigion` is already configured and that this checkout is
the source of truth for the deployed scripts.

## Secret-safe SSH

From the local machine, wrap remote commands with the all-inventory scrubber:

```sh
./scripts/aigion-scrubbed.sh 'hostname; date; docker compose ps'
./scripts/aigion-scrubbed.sh 'docker logs --since 10m aigion-postiz'
./scripts/aigion-scrubbed.sh 'cd ~/aigion && git status --short'
```

The command is sent to the VPS over SSH, but output is filtered through every
encrypted SOPS inventory under `~/.config/aigion` before it returns. The
scrubber redacts literal values and labels them by their secret path. It does
not inject secrets into the command.

Do not replace this with raw SSH for convenience. Do not run `env`, `printenv`,
`docker inspect`, database dumps, or broad log commands outside the scrubber.
Do not use `sops -d` in an agent-visible command. Redaction does not hide values
that have been transformed, encoded, hashed, truncated, or returned by a
provider, so keep queries narrow even when scrubbed.

## Command layers

Use the smallest layer that fits the task:

| Need | Use |
| --- | --- |
| Inspect a remote service | `scripts/aigion-scrubbed.sh 'COMMAND'` |
| Redact selected SOPS files around a local/non-SSH command | `scripts/sops-redact-exec.sh --secrets FILE -- COMMAND` |
| Inject named values into a command that truly needs them | `scripts/sops-exec-env.sh --secrets FILE -- COMMAND` |
| Start Postiz with only its allowlisted provider settings | `scripts/postiz-with-secrets.sh` |
| Submit an Achaean post through the Postiz boundary | `scripts/achaean-postiz.sh draft|schedule|now ...` |

The generic environment injector is not a replacement for the Postiz helper.
Prefer the named helper because it allowlists the variables Postiz receives.

## Safe diagnostics

```sh
# Host and Compose health
./scripts/aigion-scrubbed.sh 'hostname; date; docker compose ps'

# Recent service logs (keep the window narrow)
./scripts/aigion-scrubbed.sh 'docker logs --since 10m aigion-postiz'
./scripts/aigion-scrubbed.sh 'docker logs --since 10m aigion-temporal'

# Content checkout and recent canonical posts
./scripts/aigion-scrubbed.sh 'git -C ~/content/pocketcoder-build-log status --short'
./scripts/aigion-scrubbed.sh 'git -C ~/content/pocketcoder-build-log log -5 --oneline'

# Scheduler configuration (non-secret)
./scripts/aigion-scrubbed.sh 'crontab -l'

# Run the Forgejo→Postiz bridge in its default draft mode
./scripts/aigion-scrubbed.sh 'cd ~/aigion && bash scripts/forgejo-postiz-sync.sh'
```

The daily schedule is normally:

```text
09:45 America/Los_Angeles  CS Pipeline analyzes the previous 24 hours
every 5 minutes             Forgejo→Postiz sync checks for new canonical posts
10:00 America/Los_Angeles  Postiz publishes the scheduled post
```

CS Pipeline creates and pushes canonical Achaean content; it does not know
Postiz credentials. Aigion pulls that public content and is the secret-bearing
publishing boundary. The bridge is idempotent and records submitted canonical
content in `syndication/.postiz-draft-state.json`.

## Publishing modes

The bridge supports three explicit modes:

```sh
# Reviewable Postiz drafts (default)
./scripts/aigion-scrubbed.sh 'cd ~/aigion && bash scripts/forgejo-postiz-sync.sh'

# Queue for Postiz to publish at the configured local-time slot
./scripts/aigion-scrubbed.sh 'cd ~/aigion && AIGION_POSTIZ_MODE=schedule AIGION_POSTIZ_SCHEDULE_TIME=10:00 AIGION_POSTIZ_TIMEZONE=America/Los_Angeles bash scripts/forgejo-postiz-sync.sh'

# Immediate publishing; use only when explicitly requested
./scripts/aigion-scrubbed.sh 'cd ~/aigion && AIGION_POSTIZ_MODE=now bash scripts/forgejo-postiz-sync.sh'
```

`schedule` means the bridge sends Postiz a timestamp; Postiz owns queueing and
delivery. If a Postiz record remains in `QUEUE` after its timestamp, inspect
Temporal and the Postiz worker before resubmitting. Do not create duplicates.

## Postiz/Temporal recovery

Postiz can start before Temporal is ready and leave its worker disconnected.
Symptoms include Temporal `postWorkflowV107` workflows stuck with a pending task
on the `main` queue and Postiz rows remaining in `QUEUE` after their publish
time.

First inspect without exposing payloads:

```sh
./scripts/aigion-scrubbed.sh 'docker compose ps'
./scripts/aigion-scrubbed.sh 'docker logs --since 15m aigion-postiz'
./scripts/aigion-scrubbed.sh 'docker logs --since 15m aigion-temporal'
```

If Temporal is healthy and the worker is missing, restart only Postiz so it
reconnects:

```sh
./scripts/aigion-scrubbed.sh 'cd ~/aigion && docker compose restart postiz'
```

Then verify the workflow/task state with a narrow metadata query. Never dump
Postiz content or integration credentials. A restart is recoverable; do not
remove volumes as part of ordinary scheduling troubleshooting.

## Updating the VPS checkout

Pull the reviewed Aigion commit, then inspect status:

```sh
./scripts/aigion-scrubbed.sh 'cd ~/aigion && git pull --ff-only && git status --short'
```

Do not use `git reset --hard`, delete volumes, rotate credentials, or recreate
the stack unless the operator explicitly requests that recovery action. Keep
the encrypted SOPS inventories and age key on the VPS; they do not belong in
Forgejo or in command output.
