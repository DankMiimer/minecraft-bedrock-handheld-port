#!/usr/bin/env python3
"""Backfill legacy metadata and refresh native-library fingerprints.

Legacy 1.x ports named extraction directories by hand and stored no manifest
metadata. Runtime patch decisions must never inspect those names, so migration
records the inferred version and detected ABI in version.json. Existing records
are upgraded atomically when the fingerprint schema changes. Every patch is
still guarded by the launcher's symbol/signature checks.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

from apkmeta import compatibility, file_sha256


VERSION_PATTERN = re.compile(r"(?<!\d)(1\.\d+\.\d+(?:\.\d+)?)(?!\d)")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: migrate_version_metadata.py GAMEDIR", file=sys.stderr)
        return 2
    gamedir = Path(sys.argv[1]).resolve()
    versions = gamedir / "versions"
    if not versions.is_dir():
        return 0

    for version_dir in sorted(path for path in versions.iterdir() if path.is_dir()):
        detected = []
        if (version_dir / "lib/arm64-v8a/libminecraftpe.so").is_file():
            detected.append(("arm64-v8a", "arm64"))
        if (version_dir / "lib/armeabi-v7a/libminecraftpe.so").is_file():
            detected.append(("armeabi-v7a", "armhf"))
        if not detected:
            print(f"metadata backfill skipped (no supported game library): {version_dir.name}",
                  file=sys.stderr)
            continue
        target = version_dir / "version.json"
        existing = target.is_file()
        if existing:
            try:
                metadata = json.loads(target.read_text(encoding="utf-8"))
                version = str(metadata["version_name"])
                abi = str(metadata["abi"])
                abi_label = str(metadata["abi_label"])
                if (abi, abi_label) not in detected:
                    raise ValueError("metadata ABI does not match the extracted library")
            except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
                print(f"metadata fingerprint skipped ({version_dir.name}): {exc}", file=sys.stderr)
                continue
        else:
            match = VERSION_PATTERN.search(version_dir.name)
            if not match:
                print(f"metadata backfill skipped (no trustworthy version in name): {version_dir.name}",
                      file=sys.stderr)
                continue
            version = match.group(1)
            abi, abi_label = detected[0]
            metadata = {
                "package": "com.mojang.minecraftpe",
                "version_name": version,
                "version_code": 0,
                "abi": abi,
                "abi_label": abi_label,
                "detected_abis": [item[1] for item in detected],
                "signer": "legacy_unknown",
                "signer_status": "legacy_not_revalidated",
                "sources": [],
                "metadata_origin": "legacy_directory_migration",
                "source_directory": version_dir.name,
            }
        game_library = version_dir / "lib" / abi / "libminecraftpe.so"
        library_sha256 = file_sha256(game_library)
        updated = dict(metadata)
        updated["schema"] = 2
        updated["game_library_sha256"] = library_sha256
        updated["compatibility"] = compatibility(gamedir, version, abi, library_sha256)
        if existing and updated == metadata:
            continue
        temporary = version_dir / f".version.json.{os.getpid()}.part"
        try:
            temporary.write_text(json.dumps(updated, indent=2) + "\n", encoding="utf-8")
            os.replace(temporary, target)
            action = "fingerprinted" if existing else "backfilled"
            print(f"metadata {action}: {version_dir.name} -> {version}/{abi_label}")
        finally:
            temporary.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
