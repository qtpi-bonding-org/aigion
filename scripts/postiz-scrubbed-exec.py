#!/usr/bin/env python3
"""Run a command with Postiz secrets and redact their literal values from output.

This is a convenience guardrail for non-interactive administrative commands. It
does not make a command safe to run against secrets: a command can still encode,
hash, or send them elsewhere. Do not use it for interactive commands.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def dotenv_entries(path: Path) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line or raw_line.startswith("#") or "=" not in raw_line:
            continue
        name, value = raw_line.split("=", 1)
        # The host-only secret file intentionally uses simple scalar values.
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        entries.append((name, value))
    return entries


def redact(data: bytes, values: list[bytes]) -> bytes:
    for value in values:
        data = data.replace(value, b"[REDACTED]")
    return data


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        print("usage: postiz-scrubbed-exec.py SECRETS_DOTENV -- COMMAND...", file=sys.stderr)
        return 2

    entries = dotenv_entries(Path(sys.argv[1]))
    values = sorted({value.encode("utf-8") for _, value in entries if value}, key=len, reverse=True)
    env = os.environ.copy()
    env.update(entries)
    completed = subprocess.run(
        sys.argv[3:], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    sys.stdout.buffer.write(redact(completed.stdout, values))
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
