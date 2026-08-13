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
