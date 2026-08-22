#!/usr/bin/env python3
"""Create the deterministic, self-contained Windows helper release bundle."""
from __future__ import annotations

import argparse
import pathlib
import zipfile


TOOL_DIR = pathlib.Path(__file__).resolve().parent
ROOT = TOOL_DIR.parents[1]
FIXED_TIME = (2026, 1, 1, 0, 0, 0)


def project_version() -> str:
    """The version this bundle is named after.

    Read when it is needed rather than when the parser is built: as an argparse
    default it was read on every run, so the tool could not be packaged from a
    checkout of its own repository -- where the port's VERSION file two levels
    up does not exist -- even when --version was supplied.
    """
    for candidate in (TOOL_DIR / "VERSION", ROOT / "VERSION"):
        try:
            return candidate.read_text(encoding="utf-8").strip()
        except OSError:
            continue
    raise SystemExit("no VERSION file beside the tool or at the repository root")


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
    parser.add_argument("--version", default=None)
    parser.add_argument("--dist", type=pathlib.Path, default=TOOL_DIR / "dist")
    parser.add_argument("--out-dir", type=pathlib.Path)
    args = parser.parse_args()
    version = args.version or project_version()
    out_dir = args.out_dir or args.dist
    out_dir.mkdir(parents=True, exist_ok=True)
    output = out_dir / f"mcbedrock-get-windows-v{version}.zip"
    files = [
        (TOOL_DIR / "README.md", "README.md"),
        (args.dist / "mcbedrock-get.exe", "mcbedrock-get.exe"),
        (args.dist / "mcbedrock-get-NOTICES.txt", "mcbedrock-get-NOTICES.txt"),
        (TOOL_DIR / "Create desktop shortcut.cmd", "Create desktop shortcut.cmd"),
        (TOOL_DIR / "setup-downloader.sh", "setup-downloader.sh"),
        # The provenance claim travels with the executable it describes: what
        # the helper builds from source, from which pinned revision, which
        # files hold account data, and every host it may contact.
        (TOOL_DIR / "PROVENANCE.json", "PROVENANCE.json"),
    ]
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for source, name in files:
            add_file(archive, source, name)
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
