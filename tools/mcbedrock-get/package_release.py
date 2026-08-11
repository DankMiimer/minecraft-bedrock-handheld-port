#!/usr/bin/env python3
"""Create the deterministic, self-contained Windows helper release bundle."""
from __future__ import annotations

import argparse
import pathlib
import zipfile


TOOL_DIR = pathlib.Path(__file__).resolve().parent
ROOT = TOOL_DIR.parents[1]
FIXED_TIME = (2026, 1, 1, 0, 0, 0)


def add_file(archive: zipfile.ZipFile, source: pathlib.Path, name: str) -> None:
    if not source.is_file():
        raise SystemExit(f"required Windows bundle input is missing: {source}")
    info = zipfile.ZipInfo(name, FIXED_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    archive.writestr(info, source.read_bytes())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=(ROOT / "VERSION").read_text(encoding="utf-8").strip())
    parser.add_argument("--dist", type=pathlib.Path, default=TOOL_DIR / "dist")
    parser.add_argument("--out-dir", type=pathlib.Path)
    args = parser.parse_args()
    out_dir = args.out_dir or args.dist
    out_dir.mkdir(parents=True, exist_ok=True)
    output = out_dir / f"mcbedrock-get-windows-v{args.version}.zip"
    files = [
        (TOOL_DIR / "README.md", "README.md"),
        (args.dist / "mcbedrock-get.exe", "mcbedrock-get.exe"),
        (args.dist / "mcbedrock-get-NOTICES.txt", "mcbedrock-get-NOTICES.txt"),
        (TOOL_DIR / "Create desktop shortcut.cmd", "Create desktop shortcut.cmd"),
        (TOOL_DIR / "wsl-setup.sh", "wsl-setup.sh"),
    ]
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for source, name in files:
            add_file(archive, source, name)
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
