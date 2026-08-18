# Forgejo → Postiz draft sync

`scripts/forgejo-postiz-sync.sh` is the VPS-side publishing boundary. It pulls
the public Achaean content repository from Forgejo, walks canonical
`posts/*/post.json` files, and invokes the secret-aware Aigion bridge. The
bridge's encrypted state file makes repeated runs idempotent. It creates
Postiz drafts only; it never publishes.

The VPS scheduler runs it every five minutes. Social credentials remain on the
VPS and are never placed in Forgejo or a Forgejo Action.

Useful manual check:

```sh
bash scripts/forgejo-postiz-sync.sh
```

Set `AIGION_CONTENT_REPO`, `AIGION_CONTENT_REMOTE`, or `AIGION_CONTENT_BRANCH`
only when using a different checkout.
