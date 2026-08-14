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
import hashlib
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


def post_tags(post: dict[str, Any]) -> list[str]:
    routing = post.get("routing", {})
    tags = routing.get("tags", []) if isinstance(routing, dict) else []
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        fail("post.routing.tags must be a list of strings")
    return tags


def filter_reasons(post: dict[str, Any], config: dict[str, Any], social_text: str) -> list[str]:
    """Return policy reasons to hold a canonical post out of syndication."""
    filters = config.get("filters", {})
    if not isinstance(filters, dict):
        fail("config.filters must be an object")
    reasons: list[str] = []
    if filters.get("skip_replies", True) and post.get("parent"):
        reasons.append("reply posts stay native to their original conversation")
    min_characters = filters.get("min_characters", 24)
    if not isinstance(min_characters, int) or min_characters < 1:
        fail("filters.min_characters must be a positive integer")
    if len(social_text.strip()) < min_characters:
        reasons.append(f"content is shorter than {min_characters} characters")
    blocked_tags = filters.get("blocked_tags", ["test", "private", "wip", "do-not-publish"])
    if not isinstance(blocked_tags, list) or not all(isinstance(tag, str) for tag in blocked_tags):
        fail("filters.blocked_tags must be a list of strings")
    blocked = {tag.casefold() for tag in blocked_tags}
    matching_tags = sorted({tag for tag in post_tags(post) if tag.casefold() in blocked})
    if matching_tags:
        reasons.append("blocked tag: " + ", ".join(matching_tags))
    return reasons


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
    config: dict[str, Any], route_name: str, social_text: str, post: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[str]]:
    routes = config["routing"]
    selected = routes[route_name].get("channels", [])
    channels = config.get("channels", {})
    if not isinstance(selected, list) or not isinstance(channels, dict):
        fail("routing channels and config.channels must be configured")

    posts: list[dict[str, Any]] = []
    skipped: list[str] = []
    content = post.get("content", {})
    media = content.get("media", []) if isinstance(content, dict) else []
    has_media = isinstance(media, list) and bool(media)
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
        max_characters = channel.get("max_characters")
        if max_characters is not None:
            if not isinstance(max_characters, int) or max_characters < 1:
                fail(f"channel '{name}'.max_characters must be a positive integer")
            if len(social_text) > max_characters:
                skipped.append(f"{name} (over {max_characters} characters)")
                continue
        if channel.get("requires_media", False) and not has_media:
            skipped.append(f"{name} (requires canonical media)")
            continue
        if channel.get("requires_community", False):
            skipped.append(f"{name} (community not configured)")
            continue
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
    entries, skipped = channel_entries(config, route_name, social_text, post)
    tags = post_tags(post)
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


def submission_key(path: Path, post: dict[str, Any]) -> str:
    canonical = json.dumps(post, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(str(path).encode() + b"\0" + canonical).hexdigest()


def load_state(config: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    state_path = Path(config.get("state_file", ROOT / ".postiz-draft-state.json"))
    if not state_path.is_absolute():
        state_path = ROOT / state_path
    if not state_path.exists():
        return state_path, {"submitted": {}}
    value = load_json(state_path)
    if not isinstance(value.get("submitted", {}), dict):
        fail("state file submitted field must be an object")
    return state_path, value


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.replace(path)


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


def process(path: Path, config: dict[str, Any], submit_draft: bool, state: dict[str, Any], state_path: Path) -> bool:
    post = load_json(path)
    social_text = text_for_social(post)
    reasons = filter_reasons(post, config, social_text)
    if reasons:
        print(f"HOLD {path}: " + "; ".join(reasons))
        return True
    key = submission_key(path, post)
    submitted = state["submitted"]
    if submit_draft and key in submitted:
        print(f"HOLD {path}: identical canonical content already submitted as a draft")
        return True
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
    submitted[key] = {
        "path": str(path),
        "submitted_at": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "route": route_name,
    }
    save_state(state_path, state)
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
        state_path, state = load_state(config)
        paths = args.post or changed_posts()
        if not paths:
            print("No changed canonical posts.")
            return 0
        processed = [process(path, config, args.submit, state, state_path) for path in paths]
        return 0 if any(processed) else 1
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
