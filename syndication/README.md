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

The local `postiz-routing.json` policy is a filter and routing layer:

- only posts with `crosspost.postiz.strategy: "auto"` opt in;
- replies, tiny posts, and `test`, `private`, `wip`, or `do-not-publish` tagged
  posts are held;
- an identical canonical post is submitted only once;
- each channel has a limit/eligibility check, so a post that fits Threads but
  not X produces only the valid draft targets;
- Instagram and YouTube wait for canonical-media uploading, while Reddit and
  Lemmy wait for an explicitly configured community.

The example routes short text to configured microblog channels. Longer posts
intentionally have no default destinations: they need a deliberate
summary/canonical-link policy, not automatic truncation or an accidental
full-text crosspost.

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

## Generate canonical drafts from product changes

CS Pipeline is included as an Aigion submodule. It clones the requested
product repository into the fixed checkout
`~/.local/share/aigion/cs-pipeline-target`, verifies its `origin` on every
run, and writes canonical Achaean drafts into a separate checked-out content
repository. It has no Postiz credential or publishing step:

```sh
OPENROUTER_API_KEY=... \
  ./scripts/cs-pipeline-draft.sh \
    https://github.com/qtpi-bonding-org/pocketcoder.git \
    /path/to/content-repo
```

Add `--dry-run` before the repository URL to inspect the generated text
without creating a `post.json` file.

The product repository supplies `.github/cs-pipeline.toml`. The runner keeps
seven days of shallow history by default, which supports a daily aggregation
window while avoiding a full clone. The result is one or more
`posts/<date>-<slug>/post.json` files with
`crosspost.postiz.strategy: "auto"`. Review and commit them to the content
repository, then run this bridge to create Postiz drafts. The runner itself
does not commit, push, call Postiz, or publish.

Initialize a fresh Aigion checkout, including CS Pipeline and Achaean, with:

```sh
git clone --recurse-submodules <aigion-repo>
```

On the VPS, the helper defaults to Postiz's private loopback API endpoint.
This intentionally avoids routing API credentials through Cloudflare. Only set
`POSTIZ_API_URL` when using a different self-hosted topology.
