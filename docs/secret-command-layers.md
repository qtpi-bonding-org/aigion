# Secret command layers

These are three separate capabilities. Keep them separate when writing future
automation.

1. `scripts/redact-output.py` is a dumb, non-interactive output filter. Given
   temporary decoded JSON files, it replaces every literal string value with a
   labeled `[REDACTED:key.path]` marker. It does not decrypt files or modify a
   command environment.
2. `scripts/sops-redact-exec.sh` decrypts one or more selected SOPS files into
   a private temporary directory, invokes the redacter, and removes the
   temporary directory afterwards. It does **not** inject any decrypted value
   into the command.
3. `scripts/sops-exec-env.sh` deliberately injects the top-level values from
   one selected SOPS file into one command. Use it only for a named service
   helper that actually needs those variables.

`scripts/aigion-scrubbed.sh 'COMMAND'` is the normal remote diagnostic entry
point. It finds every `*.enc.yaml`, `*.enc.yml`, and `*.enc.json` file under
`~/.config/aigion`, then uses them all for redaction only. A command run there
does not receive those secrets as environment variables.

`scripts/postiz-scrubbed-exec.sh` is the intentional exception: it injects the
Postiz inventory only, while also redacting its literal values. The dedicated
`achaean-postiz.sh` and `postiz-with-secrets.sh` helpers remain the preferred
ways to give Postiz exactly the values it needs.

Redaction is a guardrail, not a security boundary. It cannot hide transformed,
hashed, encoded, or provider-derived values. Do not use raw container inspect,
database dumps, or interactive shells around live credentials.
