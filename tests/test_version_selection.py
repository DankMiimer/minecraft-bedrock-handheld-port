#!/usr/bin/env python3
"""Regression coverage for metadata-first installed-version selection."""
from __future__ import annotations

import json
import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SELECTOR = ROOT / "portmaster/minecraftbedrock/minecraftbedrock/version_env.py"


def make_version(root: Path, directory: str, version: str | None, code: int = 0) -> None:
    target = root / "versions" / directory
    library = target / "lib/arm64-v8a/libminecraftpe.so"
    library.parent.mkdir(parents=True)
    library.write_bytes(b"game")
    if version is not None:
        (target / "version.json").write_text(json.dumps({
            "schema": 1,
            "package": "com.mojang.minecraftpe",
            "version_name": version,
            "version_code": code,
            "abi": "arm64-v8a",
            "abi_label": "arm64",
            "game_library_sha256": hashlib.sha256(b"game").hexdigest(),
            "compatibility": {"status": "best_effort", "profile": "default"},
        }), encoding="utf-8")


def select(root: Path) -> str:
    return subprocess.check_output(
        ["python3", str(SELECTOR), str(root), "--select-latest"], text=True
    ).strip()


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / "compat").mkdir()
        shutil.copy2(ROOT / "portmaster/minecraftbedrock/minecraftbedrock/compat/compatibility.json",
                     root / "compat/compatibility.json")
        make_version(root, "1.16.221.01-971622101-arm64", "1.16.221.01", 971622101)
        make_version(root, "1.20.62.02-official-arm64", "1.20.62.02", 972006202)
        make_version(root, "1.21.51.01-972105101-arm64", "1.21.51.01", 972105101)
        make_version(root, "com.mojang.minecraftpe-config.arm64_v8a-XLZPri", None)
        assert select(root) == "1.16.221.01-971622101-arm64"

        result = subprocess.run(
            ["python3", str(SELECTOR), str(root),
             str(root / "versions/1.21.51.01-972105101-arm64")],
            text=True, capture_output=True, check=True,
        )
        assert "MCPE_RECOMMENDATION=not_recommended" in result.stdout
        assert "MCPE_RENDERER_PROFILE=unclassified_reupload" in result.stdout

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        make_version(root, "legacy-1.20.15", None)
        make_version(root, "legacy-1.21.1", None)
        assert select(root) == "legacy-1.21.1"

    print("version selection tests passed")


if __name__ == "__main__":
    main()
