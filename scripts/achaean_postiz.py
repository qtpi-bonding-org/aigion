#!/usr/bin/env python3
"""Limited secret-aware commands for the Achaean → Postiz bridge."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def fail(message: str) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--secrets", required=True, type=Path)
if "--" not in sys.argv:
    fail("expected -- before the command")
separator = sys.argv.index("--")
args = parser.parse_args(sys.argv[1:separator])
command = sys.argv[separator + 1 :]
if not command:
    fail("expected integrations or draft")

try:
    inventory = json.loads(args.secrets.read_text())
except (OSError, json.JSONDecodeError) as error:
    fail(f"could not read encrypted inventory: {error}")
if not isinstance(inventory, dict):
    fail("encrypted inventory must be a top-level mapping")

api_key = inventory.get("POSTIZ_API_KEY")
if not isinstance(api_key, str) or not api_key:
    fail("POSTIZ_API_KEY is missing from the encrypted inventory")
api_url = inventory.get("POSTIZ_API_URL", "https://postiz.qtpi.app/api/public/v1")
if not isinstance(api_url, str) or not api_url.startswith("https://"):
    fail("POSTIZ_API_URL must be an https URL")
api_url = api_url.rstrip("/")

if command[0] == "integrations" and len(command) == 1:
    request = urllib.request.Request(
        f"{api_url}/integrations", headers={"Authorization": api_key}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            integrations = json.loads(response.read())
    except urllib.error.HTTPError as error:
        # Response bodies can contain provider/account data, so expose only
        # transport metadata and JSON field names for diagnosis.
        try:
            body = json.loads(error.read())
            body_keys = ",".join(sorted(body.keys())) if isinstance(body, dict) else "non-object"
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            body_keys = "unreadable"
        server = error.headers.get("server", "unknown")
        content_type = error.headers.get("content-type", "unknown")
        fail(
            f"Postiz integrations request failed (HTTP {error.code}; "
            f"server={server}; content-type={content_type}; body-keys={body_keys})"
        )
    if not isinstance(integrations, list):
        fail("Postiz returned an unexpected integrations response")
    for integration in integrations:
        if not isinstance(integration, dict):
            continue
        # Deliberately allow-list public routing metadata only.
        identifier = integration.get("identifier", "?")
        profile = integration.get("profile") or integration.get("name") or "?"
        integration_id = integration.get("id", "?")
        disabled = " disabled" if integration.get("disabled") else ""
        print(f"{identifier}\t{profile}\t{integration_id}{disabled}")
    raise SystemExit(0)

if command[0] == "draft":
    publisher = Path(__file__).resolve().parents[1] / "syndication" / "syndicate.py"
    env = os.environ.copy()
    env["POSTIZ_API_KEY"] = api_key
    env["POSTIZ_API_URL"] = api_url
    os.execvpe("python3", ["python3", str(publisher), *command[1:], "--submit"], env)

fail("expected integrations or draft")
