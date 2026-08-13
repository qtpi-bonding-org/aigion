#!/usr/bin/env python3
"""Create safe Postiz drafts from canonical Achaean post.json files.

The script never publishes by default.  Routing is defined outside the
canonical post in a local policy file, while a post may opt in with
``crosspost.postiz: {"strategy": "auto"}``.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = ROOT / "postiz-routing.json"


def fail(message: str) -> "NoReturn":
    raise ValueError(message)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError:
        fail(f"missing file: {path}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{path} must contain a JSON object")
    return value


def changed_posts() -> list[Path]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "HEAD~1..HEAD", "--", "posts/**/post.json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode not in (0, 128):
        fail(result.stderr.strip() or "could not read changed posts")
    return [Path(line) for line in result.stdout.splitlines() if line.strip()]


def text_for_social(post: dict[str, Any]) -> str:
    content = post.get("content")
    if not isinstance(content, dict) or not isinstance(content.get("text"), str):
        fail("post.content.text must be a string")
    parts: list[str] = []
    title = content.get("title")
    if isinstance(title, str) and title.strip():
        parts.append(title.strip())
    parts.append(content["text"].strip())
    url = content.get("url")
    if isinstance(url, str) and url.strip():
        parts.append(url.strip())
    return "\n\n".join(part for part in parts if part)


def route_for(post: dict[str, Any], config: dict[str, Any], social_text: str) -> str:
    crosspost = post.get("crosspost", {})
    postiz = crosspost.get("postiz", {}) if isinstance(crosspost, dict) else {}
    if not isinstance(postiz, dict):
        fail("crosspost.postiz must be an object")
    strategy = postiz.get("strategy")
    if strategy != "auto":
        fail("post does not opt into auto routing (set crosspost.postiz.strategy to 'auto')")

    routing = config.get("routing")
    if not isinstance(routing, dict):
        fail("config.routing must be an object")
    short = routing.get("short")
    long = routing.get("long")
    if not isinstance(short, dict) or not isinstance(long, dict):
        fail("config.routing must define short and long routes")
    limit = short.get("max_characters", 280)
    if not isinstance(limit, int) or limit < 1:
        fail("routing.short.max_characters must be a positive integer")
    return "short" if len(social_text) <= limit else "long"


def channel_entries(
    config: dict[str, Any], route_name: str, social_text: str
) -> tuple[list[dict[str, Any]], list[str]]:
    routes = config["routing"]
    selected = routes[route_name].get("channels", [])
    channels = config.get("channels", {})
    if not isinstance(selected, list) or not isinstance(channels, dict):
        fail("routing channels and config.channels must be configured")

    posts: list[dict[str, Any]] = []
    skipped: list[str] = []
    for name in selected:
        channel = channels.get(name)
        if not isinstance(name, str) or not isinstance(channel, dict):
            skipped.append(str(name))
            continue
        integration_id = channel.get("integration_id")
        provider = channel.get("provider")
        if not isinstance(integration_id, str) or not integration_id:
            skipped.append(name)
            continue
        if not isinstance(provider, str) or not provider:
            fail(f"channel '{name}' needs a Postiz provider name")
        settings = channel.get("settings", {})
        if not isinstance(settings, dict):
            fail(f"channel '{name}'.settings must be an object")
        posts.append(
            {
                "integration": {"id": integration_id},
                "value": [{"content": social_text, "image": []}],
                "settings": {"__type": provider, **settings},
            }
        )
    return posts, skipped


def postiz_payload(post: dict[str, Any], config: dict[str, Any]) -> tuple[str, dict[str, Any], list[str]]:
    social_text = text_for_social(post)
    route_name = route_for(post, config, social_text)
    entries, skipped = channel_entries(config, route_name, social_text)
    tags = post.get("routing", {}).get("tags", []) if isinstance(post.get("routing"), dict) else []
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        fail("post.routing.tags must be a list of strings")
    timestamp = post.get("timestamp")
    if not isinstance(timestamp, str) or not timestamp:
        timestamp = dt.datetime.now(dt.UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    payload = {
        "type": "draft",
        "date": timestamp,
        "shortLink": False,
        "tags": [{"value": tag, "label": tag} for tag in tags],
        "posts": entries,
    }
    return route_name, payload, skipped


def submit(payload: dict[str, Any]) -> Any:
    api_url = os.environ.get("POSTIZ_API_URL", "").rstrip("/")
    api_key = os.environ.get("POSTIZ_API_KEY", "")
    if not api_url or not api_key:
        fail("POSTIZ_API_URL and POSTIZ_API_KEY are required for --submit")
    request = urllib.request.Request(
        f"{api_url}/posts",
        data=json.dumps(payload).encode(),
        headers={"Authorization": api_key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        # Do not print a provider response: it can include content or account data.
        fail(f"Postiz rejected the draft (HTTP {error.code})")


def process(path: Path, config: dict[str, Any], submit_draft: bool) -> bool:
    post = load_json(path)
    try:
        route_name, payload, skipped = postiz_payload(post, config)
    except ValueError as error:
        print(f"SKIP {path}: {error}")
        return False
    print(f"PLAN {path}: route={route_name}, draft targets={len(payload['posts'])}")
    if skipped:
        print("  unconfigured channels: " + ", ".join(skipped))
    if not payload["posts"]:
        print("  no configured targets; nothing submitted")
        return True
    if not submit_draft:
        print(json.dumps(payload, indent=2))
        return True
    submit(payload)
    print("  Postiz draft created")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--post", action="append", type=Path, help="canonical post.json to process")
    parser.add_argument("--changed", action="store_true", help="process post.json files changed in HEAD")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--submit", action="store_true", help="create Postiz drafts (never publishes)")
    args = parser.parse_args()
    if bool(args.post) == args.changed:
        parser.error("provide one or more --post paths, or --changed")
    try:
        config = load_json(args.config)
        paths = args.post or changed_posts()
        if not paths:
            print("No changed canonical posts.")
            return 0
        processed = [process(path, config, args.submit) for path in paths]
        return 0 if any(processed) else 1
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
