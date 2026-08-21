# Aigion server operations

This repository runs the Aigion VPS stack: Forgejo/Achaean content, Postiz,
the Forgejo→Postiz bridge, and the secret-handling helpers. Read
[`docs/agent-operations.md`](docs/agent-operations.md) before operating the
server.

## Non-negotiable rule

Use the filtered SSH entry point for every remote diagnostic command:

```sh
./scripts/aigion-scrubbed.sh 'COMMAND'
```

It decrypts all encrypted inventories only inside a temporary redaction
process, strips literal secret values from combined output, and does not pass
those values to `COMMAND`. Never use raw `ssh aigion '...'` for commands that
may print environment variables, container configuration, database rows,
logs, or credentials.

The filter is a guardrail, not a security boundary: it cannot recognize
transformed, encoded, hashed, or provider-derived values. Do not deliberately
print secrets, and never paste them into an agent conversation.

For the complete command reference and recovery notes, see
[`docs/agent-operations.md`](docs/agent-operations.md).
