#!/usr/bin/env python3
"""Select one exact edition/channel entry from a release index."""
from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("index", type=Path)
    parser.add_argument("edition")
    parser.add_argument("channel", choices=("stable", "testing"))
    args = parser.parse_args()
    try:
        doc = json.loads(args.index.read_text(encoding="utf-8"))
        if doc.get("schema") != 2:
            raise ValueError(f"unsupported release-index schema {doc.get('schema')!r}")
        matches = [
            item for item in doc.get("releases", [])
            if item.get("edition") == args.edition and item.get("channel") == args.channel
        ]
        if len(matches) != 1:
            raise ValueError(f"expected one {args.edition}/{args.channel} release, found {len(matches)}")
        item = matches[0]
        required = ("version", "asset", "url", "sha256", "size", "minimum_updater")
        missing = [key for key in required if key not in item]
        if missing:
            raise ValueError("release entry missing: " + ", ".join(missing))
        for key in required:
            value = str(item[key])
            print(f"RELEASE_{key.upper()}={shlex.quote(value)}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"release index error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
