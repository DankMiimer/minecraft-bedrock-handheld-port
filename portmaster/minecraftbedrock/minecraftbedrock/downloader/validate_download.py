#!/usr/bin/env python3
"""Validate one freshly downloaded Play split set before publishing it."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from apkmeta import (  # noqa: E402
    InstallError,
    choose_sources,
    inspect_apk,
    normalized_group,
    validate_signers,
)


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: validate_download.py STAGING VERSION_CODE arm64|armhf",
            file=sys.stderr,
        )
        return 2
    staging = Path(sys.argv[1]).resolve()
    try:
        expected = int(sys.argv[2])
        requested_abi = {"arm64": "arm64-v8a", "armhf": "armeabi-v7a"}.get(
            sys.argv[3]
        )
        if requested_abi is None:
            raise InstallError(f"unknown requested architecture: {sys.argv[3]}")
        paths = sorted(staging.glob("*.apk"))
        if not paths:
            raise InstallError("Google Play returned no APK files")
        infos = [inspect_apk(path) for path in paths]
        _, actual, _ = normalized_group(infos)
        if actual != expected:
            raise InstallError(f"Google Play returned version code {actual}, expected {expected}")
        validate_signers(infos)
        native, _, _ = choose_sources(infos)
        if requested_abi not in native:
            raise InstallError(f"download is missing the {requested_abi} native split")
        for path in paths:
            if any(character in path.name for character in "/\\\r\n\t|"):
                raise InstallError("download produced an unsafe APK filename")
            print(path.name)
    except (OSError, ValueError, InstallError) as error:
        print(f"download validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
