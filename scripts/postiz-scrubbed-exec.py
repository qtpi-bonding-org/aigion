#!/usr/bin/env python3
"""Run a command with SOPS secrets and redact their literal values from output.

This is a convenience guardrail for non-interactive administrative commands. It
does not make a command safe to run against secrets: a command can still encode,
hash, or send them elsewhere. Do not use it for interactive commands.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


def labeled_string_values(value: object, path: str = "") -> list[tuple[str, str]]:
    if isinstance(value, str):
        return [(value, path)]
    if isinstance(value, dict):
        return [
            item
            for key, child in value.items()
            for item in labeled_string_values(child, f"{path}.{key}" if path else key)
        ]
    if isinstance(value, list):
        return [
            item
            for index, child in enumerate(value)
            for item in labeled_string_values(child, f"{path}[{index}]")
        ]
    return []


def redact(data: bytes, values: list[tuple[bytes, bytes]]) -> bytes:
    for value, label in values:
        data = data.replace(value, b"[REDACTED:" + label + b"]")
    return data


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        print("usage: postiz-scrubbed-exec.py SECRETS_JSON -- COMMAND...", file=sys.stderr)
        return 2

    decoded = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if not isinstance(decoded, dict):
        print("SOPS document must decode to a top-level mapping", file=sys.stderr)
        return 2
    values_by_value = {
        value.encode("utf-8"): label.encode("utf-8")
        for value, label in labeled_string_values(decoded)
        if value
    }
    values = sorted(values_by_value.items(), key=lambda item: len(item[0]), reverse=True)
    env = os.environ.copy()
    # Top-level scalar values are convenient environment variables for service
    # commands. Nested values are still scrubbed but are not coerced into env.
    env.update({key: value for key, value in decoded.items() if isinstance(value, str)})
    completed = subprocess.run(
        sys.argv[3:], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    sys.stdout.buffer.write(redact(completed.stdout, values))
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
