# Achaean → Postiz drafts

This is the product publishing bridge. Achaean `post.json` remains canonical;
the bridge creates Postiz **drafts**, never immediate publications.

## Routing

A canonical post opts in with:

```json
{
  "crosspost": { "postiz": { "strategy": "auto" } }
}
```

The local `postiz-routing.json` policy classifies rendered text by character
count. The example policy routes text at or below 280 characters to configured
microblog channels. Longer posts intentionally have no default destinations:
they need a deliberate summary/canonical-link policy, not an automatic
truncation or accidental full-text crosspost.

Per-channel integration IDs belong only in `postiz-routing.json`; copy the
example and do not commit the real file. List the public routing metadata with
`./scripts/achaean-postiz.sh integrations`; it prints only provider, public
profile/name, integration ID, and disabled state.

## First test

```sh
cp syndication/postiz-routing.example.json syndication/postiz-routing.json
python3 syndication/syndicate.py --post path/to/post.json
```

The first command is a dry run and prints its draft payload. After configuring
one integration ID and storing `POSTIZ_API_KEY` in the encrypted Aigion
inventory:

```sh
./scripts/achaean-postiz.sh draft --post path/to/post.json
```

`--submit` creates a Postiz draft only. Review and publish it in Postiz.

For this deployment, `POSTIZ_API_URL` is
`https://postiz.qtpi.app/api/public/v1`.
