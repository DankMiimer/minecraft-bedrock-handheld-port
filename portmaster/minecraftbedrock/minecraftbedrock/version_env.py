#!/usr/bin/env python3
"""Emit validated launcher environment from installed-version metadata."""
from __future__ import annotations
import json
import re
import shlex
import sys
from pathlib import Path

from apkmeta import compatibility


ABI_NAME = {"arm64": "arm64-v8a", "armhf": "armeabi-v7a"}
RECOMMENDATION_RANK = {
    "not_recommended": 0,
    "optional_smoke": 1,
    "newest_tested_no_renderdragon": 2,
    "recommended": 3,
}


def emit(key: str, value: object) -> None:
    print(f"{key}={shlex.quote(str(value))}")


def natural_version_key(value: str) -> tuple[int, ...]:
    """Return a deterministic numeric key for Bedrock-style version names."""
    return tuple(int(part) for part in re.findall(r"\d+", value))


def select_latest(gamedir: Path) -> str:
    """Prefer the recommended build, then newer metadata-backed installs."""
    versions = gamedir / "versions"
    candidates: list[tuple[tuple[object, ...], str]] = []
    if not versions.is_dir():
        return ""
    for version_dir in versions.iterdir():
        if not version_dir.is_dir() or version_dir.name.startswith("."):
            continue
        has_arm64 = (version_dir / "lib/arm64-v8a/libminecraftpe.so").is_file()
        has_armhf = (version_dir / "lib/armeabi-v7a/libminecraftpe.so").is_file()
        if not (has_arm64 or has_armhf):
            continue
        trusted = 0
        recommendation_rank = 1
        version_name = version_dir.name
        version_code = 0
        try:
            metadata = json.loads((version_dir / "version.json").read_text(encoding="utf-8"))
            if metadata.get("package") != "com.mojang.minecraftpe":
                raise ValueError("unexpected package")
            version_name = str(metadata["version_name"])
            version_code = int(metadata["version_code"])
            abi = str(metadata["abi_label"])
            if abi == "arm64" and not has_arm64:
                raise ValueError("metadata ABI does not match files")
            if abi == "armhf" and not has_armhf:
                raise ValueError("metadata ABI does not match files")
            if abi not in {"arm64", "armhf"}:
                raise ValueError("invalid ABI")
            compat = compatibility(
                gamedir, version_name, ABI_NAME[abi], metadata.get("game_library_sha256")
            )
            recommendation = str(compat.get(
                "recommendation", metadata.get("compatibility", {}).get("recommendation", "")
            ))
            recommendation_rank = RECOMMENDATION_RANK.get(recommendation, 1)
            trusted = 1
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
            pass
        key = (trusted, recommendation_rank, natural_version_key(version_name), version_code, version_dir.name)
        candidates.append((key, version_dir.name))
    return max(candidates)[1] if candidates else ""


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: version_env.py GAMEDIR VERSION_DIR", file=sys.stderr)
        return 2
    gamedir = Path(sys.argv[1])
    if sys.argv[2] == "--select-latest":
        selected = select_latest(gamedir)
        if not selected:
            print("no launchable installed version", file=sys.stderr)
            return 1
        print(selected)
        return 0
    version_dir = Path(sys.argv[2])
    metadata_path = version_dir / "version.json"
    if not metadata_path.is_file():
        emit("MCPE_VERSION_METADATA", 0)
        emit("MCPE_COMPAT_STATUS", "best_effort")
        return 0
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        stored_compat = metadata["compatibility"]
        name = str(metadata["version_name"])
        code = int(metadata["version_code"])
        abi = str(metadata["abi_label"])
        if abi not in {"arm64", "armhf"}:
            raise ValueError("invalid ABI label")
        exact = compatibility(
            gamedir, name, ABI_NAME[abi], metadata.get("game_library_sha256")
        )
        if not exact:
            exact = {"status": stored_compat.get("status", "best_effort"),
                     "profile": stored_compat.get("profile", "default")}
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(f"invalid version metadata: {exc}", file=sys.stderr)
        return 1
    emit("MCPE_VERSION_METADATA", 1)
    emit("MCPE_BEDROCK_VERSION_NAME", name)
    emit("MCPE_BEDROCK_VERSION_CODE", code)
    emit("MCPE_BEDROCK_ABI_LABEL", abi)
    emit("MCPE_GAME_LIBRARY_SHA256", metadata.get("game_library_sha256", ""))
    emit("MCPE_COMPAT_STATUS", exact["status"])
    emit("MCPE_PROFILE_CLASS", exact.get("profile", "default"))
    emit("MCPE_RENDERER_PROFILE", exact.get("renderer_profile", "unclassified"))
    emit("MCPE_RECOMMENDATION", exact.get("recommendation", ""))
    emit("MCPE_COMPAT_WARNING", exact.get("warning", ""))
    patches = set(exact.get("patches", []))
    optional = set(exact.get("optional_patches", []))
    emit("MCPE_PATCH_EDUMODE", 1 if "edumode_guard" in patches else 0)
    emit("MCPE_PATCH_HTTP_RESOLVE", 1 if "http_resolver_guard" in patches else 0)
    emit("MCPE_COMPACTION_AVAILABLE", 1 if "auto_compaction" in optional else 0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
