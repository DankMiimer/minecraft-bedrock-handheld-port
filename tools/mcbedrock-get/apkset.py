"""What a complete Minecraft download looks like, and how to publish it.

Shared by both backends. gplaydl is driven very differently on Windows (through
WSL) and on Linux (directly), but what it must produce, and the rule that a
half-finished download never replaces a good one, are the same either way.
"""
from __future__ import annotations

import zipfile
from pathlib import Path
from typing import Callable

# The app's ABI names -> (device profile filename, Android ABI, split marker).
ABI_PROFILES = {
    "arm64": ("device-arm64.conf", "arm64-v8a", "arm64_v8a"),
    "armhf": ("device-armhf.conf", "armeabi-v7a", "armeabi_v7a"),
}


class DownloadError(RuntimeError):
    """A failure the user can act on."""


def abi_profile(abi: str) -> tuple[str, str, str]:
    try:
        return ABI_PROFILES[abi]
    except KeyError as error:
        choices = ", ".join(ABI_PROFILES)
        raise DownloadError(f"Unknown APK architecture {abi!r}; use {choices}.") from error


def has_native_lib(apk: Path, native_platform: str) -> bool:
    """True if a monolithic APK carries lib/<abi>/ itself.

    Old builds predate split APKs, so the ABI check cannot rely on a
    config.<abi>.apk filename and has to look inside the archive instead.
    """
    prefix = f"lib/{native_platform}/"
    try:
        with zipfile.ZipFile(apk) as archive:
            return any(name.startswith(prefix) for name in archive.namelist())
    except (zipfile.BadZipFile, OSError):
        return False


def check_complete(
    base: Path,
    written: list[Path],
    abi: str,
    returncode: int,
    tail: list[str],
    on_line: Callable[[str], None] | None,
) -> None:
    """Refuse anything that would not run on the device.

    Judged by what landed in the isolated staging directory, never by gplaydl's
    unreliable exit code and never by files left behind by an earlier download.
    """
    _, native_platform, split_marker = abi_profile(abi)
    if not base.is_file():
        raise DownloadError(
            f"The download produced no base APK (gplaydl exit {returncode}).\n\n"
            + "\n".join(tail[-12:])
        )
    if any(split_marker in path.name for path in written):
        return

    # Pre-App-Bundle builds (roughly 1.12 and older) ship as ONE monolithic APK
    # carrying lib/<abi>/ inside it -- there are no config.* split parts to look
    # for, and demanding one rejects every old version outright. Accept the base
    # APK, but only after proving the native library for this ABI is really in it.
    if not has_native_lib(base, native_platform):
        names = ", ".join(path.name for path in written)
        raise DownloadError(
            f"Play did not return the {native_platform} part for this build, so it "
            f"will not run on the device. Got: {names}"
        )
    if on_line is not None:
        on_line(
            f"No split parts (pre-bundle build); base APK carries "
            f"lib/{native_platform}/ itself."
        )


def publish(staging: Path, target: Path, prefix: str) -> list[Path]:
    """Move a validated set into place, restoring the old one if that fails."""
    backup = staging / "previous"
    backup.mkdir()
    previous = sorted(target.glob(f"{prefix}*.apk"))
    written = sorted(staging.glob(f"{prefix}*.apk"))
    moved: list[Path] = []
    try:
        for old in previous:
            old.replace(backup / old.name)
        for source in written:
            destination = target / source.name
            source.replace(destination)
            moved.append(destination)
    except OSError:
        for destination in moved:
            destination.unlink(missing_ok=True)
        for old in backup.glob("*.apk"):
            old.replace(target / old.name)
        raise
    return moved
