#!/usr/bin/env python3
"""Run a command and redact literal values supplied in temporary JSON files.

This tool does not decrypt, load, or inject secrets into the command environment.
It is a deliberately dumb output filter. The caller is responsible for creating
the temporary JSON source files and deleting them afterwards.
"""

from __future__ import annotations

import json
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
    if "--" not in sys.argv[1:]:
        print("usage: redact-output.py SECRETS_JSON [SECRETS_JSON...] -- COMMAND...", file=sys.stderr)
        return 2
    separator = sys.argv.index("--")
    command = sys.argv[separator + 1 :]
    secret_paths = [Path(path) for path in sys.argv[1:separator]]
    if not secret_paths or not command:
        print("usage: redact-output.py SECRETS_JSON [SECRETS_JSON...] -- COMMAND...", file=sys.stderr)
        return 2

    documents: dict[Path, dict[str, object]] = {}
    for path in secret_paths:
        decoded = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(decoded, dict):
            print(f"SOPS document must decode to a top-level mapping: {path.name}", file=sys.stderr)
            return 2
        documents[path] = decoded
    values_by_value = {
        value.encode("utf-8"): label.encode("utf-8")
        for decoded in documents.values()
        for value, label in labeled_string_values(decoded)
        if value
    }
    values = sorted(values_by_value.items(), key=lambda item: len(item[0]), reverse=True)
    completed = subprocess.run(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    sys.stdout.buffer.write(redact(completed.stdout, values))
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
