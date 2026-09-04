#!/usr/bin/env python3
"""Opt-in, version-gated Handheld UI pack activation. No world files are changed."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

PACK_ID = "0b69cb5c-22cd-45c7-9992-a94e90f0e4ad"
PACK_VERSION = [0, 1, 0]
TARGET_VERSION = "1.21.51.01-972105101-arm64"
TARGET_SHA256 = "45382be72491ec2cbe5dd4d1262989ad894b8fc611e5cbc16141d04171510927"


def read_json(path: Path, default):
    return json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else default


def atomic_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def sync(gamedir: Path, profile: Path, version: str, library_sha256: str,
         request: bool | None = None, abi: str = "arm64",
         strict: bool = True) -> dict:
    profile = profile.resolve()
    preference = profile / "handheld-ui.json"
    config = read_json(preference, {"enabled": False})
    if not isinstance(config, dict) or not isinstance(config.get("enabled"), bool):
        raise ValueError("Invalid handheld-ui.json; refusing to replace it")
    requested = config["enabled"] if request is None else request
    compatible = (version == TARGET_VERSION and library_sha256 == TARGET_SHA256
                  and abi == "arm64")
    # Asking for the pack on a build it was not measured against is an error
    # when a person types it, and merely a no-op when the launcher replays a
    # saved menu setting: switching to another version must not fail the launch.
    # The preference is still recorded either way, so going back to the tested
    # build restores the pack without the player touching the setting again.
    if request is True and not compatible and strict:
        raise ValueError("Handheld UI requires the tested 1.21.51.01 arm64 library")

    mojang = profile / "mcpelauncher/games/com.mojang"
    if (request is None and not preference.exists() and not requested
            and not (mojang / "resource_packs/handheld-ui/manifest.json").exists()):
        # An unused optional feature must not make unrelated pack state a new
        # launch requirement. Managed installations still get the version gate.
        return {"requested": False, "enabled": False, "compatible": compatible,
                "profile": str(profile)}
    activation = mojang / "minecraftpe/global_resource_packs.json"
    previous = read_json(activation, [])
    if not isinstance(previous, list) or any(not isinstance(x, dict) for x in previous):
        raise ValueError("Invalid global_resource_packs.json; refusing to replace it")
    retained = [entry for entry in previous if entry.get("pack_id") != PACK_ID]
    enabled = requested and compatible
    if enabled:
        source = gamedir / "packs/handheld-ui"
        manifest = read_json(source / "manifest.json", {})
        if (manifest.get("header", {}).get("uuid") != PACK_ID
                or manifest["header"].get("version") != PACK_VERSION):
            raise ValueError("Handheld UI source manifest does not match this manager")
        destination = mojang / "resource_packs/handheld-ui"
        if destination.exists():
            installed = read_json(destination / "manifest.json", {})
            if installed.get("header", {}).get("uuid") != PACK_ID:
                raise ValueError("resource_packs/handheld-ui belongs to a different pack")
        # Only our shipped files are updated; other installed packs are untouched.
        for item in source.rglob("*"):
            if item.is_file():
                target = destination / item.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(item, target)
        retained.insert(0, {"pack_id": PACK_ID, "version": PACK_VERSION})
    if retained != previous:
        backup = profile / "handheld-ui-backups" / str(time.time_ns())
        backup.mkdir(parents=True)
        if activation.exists():
            shutil.copy2(activation, backup / activation.name)
        else:
            (backup / "global_resource_packs.was-absent").touch()
        atomic_json(activation, retained)
    if request is not None:
        atomic_json(preference, {**config, "enabled": requested})
    return {"requested": requested, "enabled": enabled, "compatible": compatible,
            "profile": str(profile)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("on", "off", "sync", "status"))
    parser.add_argument("--gamedir", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--library-sha256")
    parser.add_argument("--abi", default="arm64")
    # The launcher replays the menu's saved toggle through this rather than
    # through `on`/`off`, so an incompatible version disables the pack instead
    # of failing the launch.
    parser.add_argument("--request", choices=("on", "off"))
    args = parser.parse_args()
    profile = args.profile or args.gamedir / "profiles/default"
    if args.action == "status":
        config = read_json(profile / "handheld-ui.json", {"enabled": False})
        packs = read_json(profile / "mcpelauncher/games/com.mojang/minecraftpe/global_resource_packs.json", [])
        print(json.dumps({"preference": config, "active": any(x.get("pack_id") == PACK_ID for x in packs)}))
        return 0
    version = args.version
    if version is None:
        settings = args.gamedir / "config/settings.cfg"
        for line in settings.read_text().splitlines() if settings.exists() else []:
            if line.startswith("version="):
                version = line.partition("=")[2]
                break
    library_hash = args.library_sha256 or ""
    wants_pack = (args.action == "on" or args.request == "on"
                  or read_json(profile / "handheld-ui.json", {}).get("enabled", False))
    if version == TARGET_VERSION and not library_hash and args.action != "off" and wants_pack:
        library = args.gamedir / "versions" / version / "lib/arm64-v8a/libminecraftpe.so"
        digest = hashlib.sha256()
        with library.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        library_hash = digest.hexdigest()
    request = {"on": True, "off": False}.get(args.action)
    strict = True
    if request is None and args.request:
        request = args.request == "on"
        strict = False
    result = sync(args.gamedir, profile, version or "", library_hash, request,
                  args.abi, strict)
    print("Handheld UI: " + json.dumps(result))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit("Handheld UI: " + str(error))
