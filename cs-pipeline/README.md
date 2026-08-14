# CS Pipeline — Continuous Syndication

CS stands for **Continuous Syndication** — like CI/CD, but for social media.
Every push to `main` can generate canonical [Achaean](https://github.com/qtpi-bonding-org/achaean) `post.json` drafts summarizing what you shipped. It has no Postiz access and cannot publish anything.

It's built as a GitHub reusable workflow, so any repo can plug in with ~10 lines of YAML and a small config file. An LLM (via [OpenRouter](https://openrouter.ai)) reads your git diff and writes the posts for you — authentic indie dev voice, no corporate speak.

## How It Works

1. You push to `main`
2. The workflow grabs the commit messages and diff stat
3. Ignored paths and trivial changes are filtered out
4. An LLM generates draft updates based on your config (tone, audience, project context)
5. CS Pipeline writes Achaean `posts/<date>-<slug>/post.json` files for review
6. The separate Aigion bridge filters and routes opted-in canonical posts into **Postiz drafts**
7. You review and publish in Postiz

## Setup

### 1. Add secrets to your repo

Go to **Settings > Secrets and variables > Actions** and add:

| Secret | Description |
|---|---|
| `OPENROUTER_API_KEY` | Your OpenRouter API key |

### 2. Add a config file

Create `.github/cs-pipeline.toml` in your repo:

```toml
[project]
name = "MyProject"
description = "Short description of your project"
audience = "developers"

[llm]
model = "anthropic/claude-haiku-4-5"  # any OpenRouter model slug

[syndication]
tone = "shipping-update" # shipping-update | announcement | changelog
hashtags = ["#myproject", "#indiedev"]
max_posts = 3

[achaean]
# Local path to a checked-out Achaean content repository. For GitHub Actions,
# the default output is uploaded as an artifact instead.
content_dir = ".achaean-drafts"
tags = ["buildinpublic"]

[filters]
ignore_paths = ["docs/", ".github/", "*.md", "*.lock"]
min_diff_lines = 5
```

### 3. Add the caller workflow

Create `.github/workflows/cs-pipeline.yml` in your repo:

```yaml
name: Continuous Syndication
on:
  push:
    branches: [main]
jobs:
  syndicate:
    uses: qtpi-bonding-org/cs-pipeline/.github/workflows/syndicate.yml@main
    secrets:
      openrouter_api_key: ${{ secrets.OPENROUTER_API_KEY }}
```

That's it. Push to `main` and check the Actions tab.

## Config Reference

### `[project]`

| Key | Description |
|---|---|
| `name` | Your project name — used in the LLM prompt |
| `description` | One-liner about your project |
| `audience` | Who the posts are for (e.g. `"developers"`, `"designers"`, `"founders"`) |

### `[llm]`

| Key | Default | Description |
|---|---|---|
| `model` | `anthropic/claude-haiku-4-5` | Any [OpenRouter model slug](https://openrouter.ai/models) |

### `[syndication]`

| Key | Default | Description |
|---|---|---|
| `tone` | `shipping-update` | Post style: `shipping-update`, `announcement`, or `changelog` |
| `hashtags` | `[]` | Appended to the last generated canonical draft |
| `max_posts` | `3` | Number of posts generated per push |

### `[achaean]`

| Key | Default | Description |
|---|---|---|
| `content_dir` | `.achaean-drafts` | A local checked-out content repo in which to create `posts/` drafts |
| `tags` | `["buildinpublic"]` | Canonical Achaean routing tags on each generated post |

### `[filters]`

| Key | Default | Description |
|---|---|---|
| `ignore_paths` | `[]` | Glob patterns for paths to skip (e.g. `"docs/"`, `"*.lock"`) |
| `min_diff_lines` | `5` | Pushes with fewer changed lines are skipped entirely |

## Smart Filtering

Not every push deserves a post. CS Pipeline skips syndication when:

- The only changed files match your `ignore_paths` patterns
- The total lines changed is below `min_diff_lines`
- No commit messages are found

This means doc-only updates, lockfile changes, and CI tweaks won't spam your followers.

## Output and handoff

The script is dry-run by default:

```sh
python scripts/syndicate.py --config .github/cs-pipeline.toml
```

Write drafts into a checked-out Achaean/Forgejo content repo only when ready:

```sh
python scripts/syndicate.py \
  --config .github/cs-pipeline.toml \
  --output-dir /path/to/your/content-repo \
  --write
```

That creates files only. It does not commit, push, call Postiz, or publish.
Commit the reviewed canonical files to the content repo, then use Aigion's
`achaean-postiz.sh draft --changed` bridge to create reviewable Postiz drafts.
The reusable GitHub workflow uploads its output as the `achaean-drafts`
artifact instead of attempting to commit to another repository.

## Custom Config Path

If you want to put the config somewhere else, pass `config_path`:

```yaml
jobs:
  syndicate:
    uses: qtpi-bonding-org/cs-pipeline/.github/workflows/syndicate.yml@main
    with:
      config_path: ".github/syndication.toml"
    secrets:
      openrouter_api_key: ${{ secrets.OPENROUTER_API_KEY }}
```
