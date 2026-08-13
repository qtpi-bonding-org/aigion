# Postiz credentials on Aigion

The Aigion repository is public. Never put real credentials in this checkout,
in Compose files, in Git, or in chat.

Postiz needs provider application credentials at *container creation* time.
The supported path is a flat, SOPS-encrypted YAML file on the VPS, decrypted
only while Docker Compose recreates the `postiz` service.

## Host-only secret file

Create this file directly on the VPS, outside the Aigion checkout:

```text
/home/cduser/.config/aigion/postiz.enc.yaml
```

Its values must be top-level scalar environment variables matching the names
already referenced by `docker-compose.yml`, for example:

```yaml
X_API_KEY: replace-me
X_API_SECRET: replace-me
THREADS_APP_ID: replace-me
THREADS_APP_SECRET: replace-me
```

Encrypt/edit it only in a trusted interactive SSH session:

```sh
mkdir -p ~/.config/aigion
chmod 700 ~/.config/aigion
sops ~/.config/aigion/postiz.enc.yaml
chmod 600 ~/.config/aigion/postiz.enc.yaml
```

Do not paste values into an agent chat or run a command that prints the
decrypted file. SOPS/age installation and its private age key are host
operational state and must stay outside this repository.

## First-time age and SOPS setup

On the VPS, create a host-local age identity:

```sh
mkdir -p ~/.config/sops/age ~/.config/aigion
chmod 700 ~/.config/sops ~/.config/sops/age ~/.config/aigion
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt
```

Put the final `age1...` public recipient in
`~/.config/aigion/.sops.yaml`:

```yaml
creation_rules:
  - path_regex: postiz\.enc\.yaml$
    age: age1REPLACE_WITH_THE_HOST_PUBLIC_RECIPIENT
```

On Aigion, `sops` is installed at `~/.local/bin/sops`. For an interactive SSH
session, use:

```sh
export PATH="$HOME/.local/bin:$PATH"
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
cd ~/.config/aigion
sops postiz.enc.yaml
```

The Aigion launch and scrubber scripts automatically use
`~/.config/sops/age/keys.txt` when `SOPS_AGE_KEY_FILE` is not already set.

Before adding real credentials, test redaction using a unique disposable
value:

```yaml
TEST_PASSWORD: replace-with-a-disposable-test-value
```

From a local Aigion checkout, this must return `[REDACTED]`, never the value:

```sh
./scripts/aigion-scrubbed.sh 'printf "%s\n" "$TEST_PASSWORD"'
```

Delete `TEST_PASSWORD` afterwards and save again with `sops`. An empty
encrypted mapping is valid: the Postiz launcher detects it and recreates
Postiz without provider overrides until you add real keys.

## Launch Postiz with credentials

From the Aigion checkout on the VPS:

```sh
./scripts/postiz-with-secrets.sh
```

The script runs `docker compose up -d --force-recreate postiz` through
`sops exec-env`. Compose gives shell environment variables precedence over
the values in `.env`, so only the provider variables in the encrypted file
are injected into the newly created Postiz container. The decrypted values
are not written to the checkout or printed by the script.

The container retains its configured environment until it is recreated. Run
the script again after adding or rotating provider application credentials.

## Scrubbed operational commands

For any SOPS-encrypted file, use `scripts/sops-scrubbed-exec.sh`. It decrypts
the file into a temporary private file, passes top-level scalar values only to
the child process, and replaces literal secret values (including nested values)
in combined stdout/stderr before returning output. For example:

```bash
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
SOPS_BIN="$HOME/.local/bin/sops" \
./scripts/sops-scrubbed-exec.sh --secrets ~/.config/aigion/postiz.enc.yaml -- \
  docker inspect aigion-postiz
```

`scripts/postiz-scrubbed-exec.sh` is a convenience wrapper for that same
command using `~/.config/aigion/postiz.enc.yaml`.

From a local Aigion checkout, the usual short form is:

```bash
./scripts/aigion-scrubbed.sh 'docker inspect aigion-postiz'
```

It sends one command to the VPS through the `aigion` SSH alias, with the
Postiz secret file and scrubber selected remotely. The command is passed over
stdin instead of interpolated into the SSH command. This default is for
Postiz-related diagnostics; use `sops-scrubbed-exec.sh --secrets ...` directly
on the VPS for another encrypted file.

This is an accidental-output guardrail, not an isolation boundary. It cannot
prevent a command from transforming or transmitting a secret, and must not be
used for interactive commands or as permission to inspect credentials.

## Trust model and operational policy

This protects against accidental source-control and terminal-output leaks; it
does **not** isolate secrets from a VPS administrator. A Docker administrator
can inspect a running container or modify its deployment.

The agreed operating policy is:

- administrators do not read, print, transform, or deliberately inspect
  secrets;
- avoid `docker inspect`, `docker exec ... env`, database dumps, and
  unbounded logs for secret-bearing services;
- rotate a credential if it is accidentally exposed;
- provider OAuth account tokens stored by Postiz are also sensitive.

## AI agent operating rules

An agent with Aigion SSH access may administer the VPS and use the scrubbed
wrapper for a necessary, non-interactive operation. It must:

- never ask for, read, print, copy, summarize, encode, transform, or
  deliberately inspect decrypted credential values;
- prefer ordinary commands when no secret is needed;
- use `./scripts/aigion-scrubbed.sh 'COMMAND'` from a local checkout for a
  Postiz-related diagnostic that needs secret context; and
- use `scripts/sops-scrubbed-exec.sh --secrets FILE -- COMMAND` on the VPS for
  another SOPS file.

Treat redaction as an accidental-output guardrail, not a permission system or
an isolation boundary. Avoid `docker inspect`, `docker exec ... env`, database
dumps, and broad Postiz logs unless genuinely needed. When one is needed, use
the scrubbed wrapper and report only the non-secret result. A secret may still
be exposed by a transformed representation or an untrusted command; rotate it
if that happens.
