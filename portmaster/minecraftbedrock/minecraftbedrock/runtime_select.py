#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, shlex, sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("index", type=Path)
parser.add_argument("module")
args = parser.parse_args()
try:
    doc = json.loads(args.index.read_text(encoding="utf-8"))
    matches = [m for m in doc.get("modules", []) if m.get("id") == args.module]
    if len(matches) != 1:
        raise ValueError(f"expected one runtime {args.module}, found {len(matches)}")
    for key in ("id", "filename", "url", "sha256", "size", "api"):
        if key not in matches[0]: raise ValueError(f"runtime missing {key}")
        print(f"RUNTIME_{key.upper()}={shlex.quote(str(matches[0][key]))}")
except (OSError, ValueError, json.JSONDecodeError) as exc:
    print(f"runtime index error: {exc}", file=sys.stderr)
    raise SystemExit(1)
