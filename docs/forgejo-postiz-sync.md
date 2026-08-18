# Forgejo → Postiz sync

`scripts/forgejo-postiz-sync.sh` is the VPS-side publishing boundary. It pulls
the public Achaean content repository from Forgejo, walks canonical
`posts/*/post.json` files, and invokes the secret-aware Aigion bridge. The
bridge's encrypted state file makes repeated runs idempotent. It defaults to
Postiz drafts and never publishes unless the mode is explicitly changed.

Configure the non-secret mode for the VPS scheduler with:

```sh
AIGION_POSTIZ_MODE=draft       # draft (default), schedule, or now
AIGION_POSTIZ_DATE=2026-08-19T16:00:00.000Z  # required for schedule
```

`schedule` and `now` send Postiz's native `type` and `date` fields; Postiz
remains responsible for queueing and delivery. `now` publishes immediately.

The VPS scheduler runs it every five minutes. Social credentials remain on the
VPS and are never placed in Forgejo or a Forgejo Action.

Useful manual check:

```sh
bash scripts/forgejo-postiz-sync.sh
```

Set `AIGION_CONTENT_REPO`, `AIGION_CONTENT_REMOTE`, or `AIGION_CONTENT_BRANCH`
only when using a different checkout.
