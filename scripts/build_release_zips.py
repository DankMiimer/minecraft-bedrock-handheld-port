#!/usr/bin/env python3
"""Build the release zip from the staging tree.

Produces, in --out-dir:
  minecraftbedrock-<version>.zip   one zip for every supported firmware
  SHA256SUMS.txt                   checksum

The zip is laid out so that extracting it at the SD card / share root
installs the port on any supported firmware, with no scripts or manual
file placement:

  README.md                     install instructions at the card root
  ports/minecraftbedrock/       the port payload (game dir), shipped once
  ports/<entry>.sh              launch entries for ROCKNIX-style layouts,
                                where scripts live inside ports/
  roms/ports/<entry>.sh         launch entries for muOS (ROMS/Ports —
                                FAT is case-insensitive) and Knulli
                                (roms/ports)

The launch entries locate the payload themselves: next to the script
first, then the ports/minecraftbedrock locations above. Docs and the GPL
source patches ride along under ports/minecraftbedrock/.

Then runs check_release_safety.py against the zip.

Usage:
  python scripts/build_release_zips.py --staging ../staging --version 1.5
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import subprocess
import sys
import zipfile

EXCLUDE_NAMES = {".DS_Store", "Thumbs.db", "log.txt", "setup_error.txt", "__pycache__"}
EXCLUDE_SUFFIXES = (".pyc", ".part")
EXCLUDE_PREFIXES = ("fps-trace",)

# The launch entries are duplicated at these zip prefixes so that every
# firmware's Ports menu sees them after a root extract.
SCRIPT_PREFIXES = ("ports/", "roms/ports/")


def iter_staging_files(staging: pathlib.Path):
    for path in sorted(staging.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(staging)
        parts = rel.parts
        if any(p in EXCLUDE_NAMES for p in parts):
            continue
        if rel.name.endswith(EXCLUDE_SUFFIXES) or rel.name.startswith(EXCLUDE_PREFIXES):
            continue
        yield path, rel


def add_entry(archive: zipfile.ZipFile, arcname: str, data: bytes) -> None:
    info = zipfile.ZipInfo(arcname)
    # Stable timestamps make rebuilt zips byte-comparable.
    info.date_time = (2026, 1, 1, 0, 0, 0)
    info.external_attr = (0o755 if arcname.endswith(".sh") or "/bin" in arcname else 0o644) << 16
    archive.writestr(info, data, zipfile.ZIP_DEFLATED)


def arcnames_for(rel: pathlib.Path) -> list[str]:
    rel_posix = rel.as_posix()
    if rel_posix.endswith(".sh") and len(rel.parts) == 1:
        return [prefix + rel_posix for prefix in SCRIPT_PREFIXES]
    if rel.parts[0] == "minecraftbedrock":
        return [f"ports/{rel_posix}"]
    if rel_posix == "README.md":
        # The install instructions stay visible at the card root (and the
        # safety checker requires a root README with the disclaimer).
        return [rel_posix]
    # Other docs and source_release ride along inside the payload.
    return [f"ports/minecraftbedrock/{rel_posix}"]


def build_zip(staging: pathlib.Path, out: pathlib.Path, version: str) -> None:
    with zipfile.ZipFile(out, "w") as archive:
        for src, rel in iter_staging_files(staging):
            if rel.as_posix() == "minecraftbedrock/PORT_VERSION":
                # Stamp the shipped version so the on-device updater can
                # compare against the latest release tag.
                data = (version + "\n").encode()
            else:
                data = src.read_bytes()
            for arcname in arcnames_for(rel):
                add_entry(archive, arcname, data)
    print(f"built {out} ({out.stat().st_size / 1024 / 1024:.1f} MB)")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging", type=pathlib.Path, required=True,
                        help="path to the staging tree (dist/staging)")
    parser.add_argument("--version", required=True, help="release version, e.g. 1.5")
    parser.add_argument("--out-dir", type=pathlib.Path, default=pathlib.Path("."),
                        help="output directory (default: cwd)")
    parser.add_argument("--skip-safety-check", action="store_true")
    args = parser.parse_args()

    staging = args.staging.resolve()
    if not (staging / "minecraftbedrock").is_dir():
        print(f"ERROR: {staging} has no minecraftbedrock/ payload dir", file=sys.stderr)
        return 1

    args.out_dir.mkdir(parents=True, exist_ok=True)
    out = args.out_dir / f"minecraftbedrock-{args.version}.zip"
    build_zip(staging, out, args.version)

    sums_path = args.out_dir / "SHA256SUMS.txt"
    sums_path.write_text(f"{sha256(out)}  {out.name}\n", encoding="utf-8")
    print(f"wrote {sums_path}")

    if not args.skip_safety_check:
        checker = pathlib.Path(__file__).with_name("check_release_safety.py")
        result = subprocess.run([sys.executable, str(checker), "--zip", str(out)])
        if result.returncode != 0:
            print(f"SAFETY CHECK FAILED: {out}", file=sys.stderr)
            return result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
