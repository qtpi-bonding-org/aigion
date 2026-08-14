#!/usr/bin/env python3
"""CS Pipeline — generate canonical Achaean drafts from git diffs via an LLM.

This program deliberately does not know about Postiz or social credentials.  It
writes reviewable ``posts/<date>-<slug>/post.json`` files into an Achaean
content checkout; Aigion's separate Achaean → Postiz bridge decides whether and
where an approved canonical post becomes a Postiz draft.
"""

import argparse
import datetime as dt
import fnmatch
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

import httpx


def read_config(path: str) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)


def get_commit_messages() -> str:
    result = subprocess.run(
        ["git", "log", "--format=%s", "HEAD~1..HEAD"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def get_diff_stat() -> list[str]:
    result = subprocess.run(
        ["git", "diff", "HEAD~1..HEAD", "--stat"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip().splitlines()


def get_diff_lines_changed(ignore_paths: list[str]) -> int:
    """Count changed lines only in files that survived the path filter."""
    result = subprocess.run(
        ["git", "diff", "HEAD~1..HEAD", "--numstat"],
        capture_output=True, text=True, check=True,
    )
    total = 0
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        additions, deletions, path = fields[0], fields[1], fields[-1]
        if any(fnmatch.fnmatch(path, pat) or path.startswith(pat.rstrip("*")) for pat in ignore_paths):
            continue
        # Git uses '-' for binary files. They are intentionally not enough on
        # their own to trigger an LLM-written shipping update.
        total += (int(additions) if additions.isdigit() else 0)
        total += (int(deletions) if deletions.isdigit() else 0)
    return total


def filter_diff_stat(lines: list[str], ignore_paths: list[str]) -> list[str]:
    filtered = []
    for line in lines:
        # diff --stat lines look like: " path/to/file | 5 ++-"
        # The summary line has no "|"
        if "|" not in line:
            filtered.append(line)
            continue
        file_path = line.split("|")[0].strip()
        if any(fnmatch.fnmatch(file_path, pat) or file_path.startswith(pat.rstrip("*")) for pat in ignore_paths):
            continue
        filtered.append(line)
    return filtered


def build_prompt(config: dict, commit_messages: str, diff_stat: str) -> str:
    project = config["project"]
    syndication = config.get("syndication", {})
    tone = syndication.get("tone", "shipping-update")
    max_posts = syndication.get("max_posts", 3)

    return f"""You are a social media writer for an indie dev project.

Project: {project["name"]}
Description: {project["description"]}
Audience: {project.get("audience", "developers")}
Tone: {tone}

Here's what just shipped (commit messages):
{commit_messages}

Changed files:
{diff_stat}

Write exactly {max_posts} social media posts about this update.
- Authentic indie dev voice, no corporate speak
- Each post should stand alone
- Keep posts concise (under 280 characters each)
- Do NOT include hashtags (they will be added automatically)

Respond with ONLY a JSON array of {max_posts} strings. No other text."""


def call_openrouter(prompt: str, config: dict) -> list[str]:
    api_key = os.environ["OPENROUTER_API_KEY"]
    model = config.get("llm", {}).get("model", "anthropic/claude-haiku-4-5")

    response = httpx.post(
        "https://openrouter.ai/api/v1/chat/completions",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        json={
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
        },
        timeout=60,
    )
    response.raise_for_status()
    content = response.json()["choices"][0]["message"]["content"]

    # Extract JSON array from response (handle markdown code blocks)
    text = content.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()

    return json.loads(text)


def social_texts(posts: list[object], config: dict) -> list[str]:
    """Validate model output and preserve the old final-post hashtag behavior."""
    if not isinstance(posts, list) or not all(isinstance(post, str) for post in posts):
        raise ValueError("LLM response must be a JSON array of strings")
    cleaned = [post.strip() for post in posts if post.strip()]
    if not cleaned:
        raise ValueError("LLM returned no usable post text")
    hashtags = config.get("syndication", {}).get("hashtags", [])
    if not isinstance(hashtags, list) or not all(isinstance(tag, str) for tag in hashtags):
        raise ValueError("syndication.hashtags must be an array of strings")
    if hashtags:
        cleaned[-1] = f"{cleaned[-1]} {' '.join(hashtags)}"
    return cleaned


def source_commit() -> str:
    """Use the CI SHA when present; otherwise identify the local source commit."""
    if os.environ.get("GITHUB_SHA"):
        return os.environ["GITHUB_SHA"]
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
    )
    return result.stdout.strip()


def draft_slug(text: str) -> str:
    words = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return (words[:56].rstrip("-") or "shipping-update")


def canonical_post(text: str, config: dict, timestamp: str, commit: str) -> dict:
    achaean = config.get("achaean", {})
    if not isinstance(achaean, dict):
        raise ValueError("achaean must be a TOML table")
    tags = achaean.get("tags", ["buildinpublic"])
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        raise ValueError("achaean.tags must be an array of strings")
    return {
        "content": {"text": text},
        "routing": {"poleis": [], "tags": tags, "mentions": []},
        "details": {"cs_pipeline": {"source_commit": commit}},
        "crosspost": {"postiz": {"strategy": "auto"}},
        "timestamp": timestamp,
        "signature": "",
    }


def unique_post_path(content_dir: Path, timestamp: dt.datetime, text: str) -> Path:
    prefix = f"{timestamp.date().isoformat()}-{draft_slug(text)}"
    candidate = content_dir / "posts" / prefix / "post.json"
    suffix = 2
    while candidate.exists():
        candidate = content_dir / "posts" / f"{prefix}-{suffix}" / "post.json"
        suffix += 1
    return candidate


def plan_achaean_drafts(posts: list[str], config: dict, output_dir: Path) -> list[tuple[Path, dict]]:
    timestamp = dt.datetime.now(dt.UTC).replace(microsecond=0)
    timestamp_text = timestamp.isoformat().replace("+00:00", "Z")
    commit = source_commit()
    planned: list[tuple[Path, dict]] = []
    reserved: set[Path] = set()
    for index, text in enumerate(posts, 1):
        path = unique_post_path(output_dir, timestamp, f"{text}-{index}")
        while path in reserved:
            path = path.parent.with_name(path.parent.name + "-draft") / "post.json"
        reserved.add(path)
        planned.append((path, canonical_post(text, config, timestamp_text, commit)))
    return planned


def write_achaean_drafts(planned: list[tuple[Path, dict]]) -> None:
    for path, post in planned:
        path.parent.mkdir(parents=True, exist_ok=False)
        path.write_text(json.dumps(post, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=os.environ.get("CONFIG_PATH", ".github/cs-pipeline.toml"))
    parser.add_argument(
        "--output-dir",
        help="A checked-out Achaean content repository; overrides achaean.content_dir",
    )
    parser.add_argument("--write", action="store_true", help="write planned canonical drafts (default: dry run)")
    args = parser.parse_args()
    config_path = args.config

    if not os.path.exists(config_path):
        print(f"Config not found at {config_path}. Exiting.")
        sys.exit(0)

    config = read_config(config_path)
    print(f"Config loaded: {config['project']['name']}")

    # Get git info
    commit_messages = get_commit_messages()
    diff_stat_lines = get_diff_stat()

    if not commit_messages:
        print("No commit messages found. Exiting.")
        sys.exit(0)

    # Filter ignored paths
    ignore_paths = config.get("filters", {}).get("ignore_paths", [])
    filtered_stat = filter_diff_stat(diff_stat_lines, ignore_paths)

    # Check minimum diff threshold
    min_diff = config.get("filters", {}).get("min_diff_lines", 5)
    lines_changed = get_diff_lines_changed(ignore_paths)
    print(f"Lines changed: {lines_changed} (minimum: {min_diff})")

    if lines_changed < min_diff:
        print("Change too small, skipping syndication.")
        sys.exit(0)

    # Build prompt and call LLM
    diff_stat_str = "\n".join(filtered_stat)
    prompt = build_prompt(config, commit_messages, diff_stat_str)
    print("Calling LLM for post generation...")

    posts = social_texts(call_openrouter(prompt, config), config)
    print(f"Generated {len(posts)} canonical draft(s):")
    for i, post in enumerate(posts, 1):
        print(f"  [{i}] {post}")

    achaean = config.get("achaean", {})
    default_output = achaean.get("content_dir", ".achaean-drafts") if isinstance(achaean, dict) else ".achaean-drafts"
    output_dir = Path(args.output_dir or default_output)
    try:
        planned = plan_achaean_drafts(posts, config, output_dir)
    except ValueError as error:
        print(f"Invalid Achaean configuration: {error}", file=sys.stderr)
        sys.exit(2)
    for path, _ in planned:
        print(f"  PLAN {path}")
    if not args.write:
        print("Dry run complete. Re-run with --write to create canonical Achaean drafts.")
        return
    write_achaean_drafts(planned)
    print(f"Created {len(planned)} canonical Achaean draft(s). No commit, Postiz call, or publication was made.")


if __name__ == "__main__":
    main()
