#!/usr/bin/env python3
"""Safely extract an exact runtime ELF from a pinned Debian package."""
from __future__ import annotations

import io
import os
import sys
import tarfile
from pathlib import Path

AR_MAGIC = b"!<arch>\n"
PLUGIN_SUFFIX = "/qt6/plugins/platforminputcontexts/libqtvirtualkeyboardplugin.so"


def ar_members(blob: bytes):
    if not blob.startswith(AR_MAGIC):
        raise ValueError("not a Debian ar archive")
    offset = len(AR_MAGIC)
    while offset < len(blob):
        header = blob[offset : offset + 60]
        if len(header) != 60 or header[58:60] != b"`\n":
            raise ValueError("invalid ar member header")
        name = header[:16].decode("ascii", "strict").strip().rstrip("/")
        size = int(header[48:58].decode("ascii", "strict").strip())
        offset += 60
        data = blob[offset : offset + size]
        if len(data) != size:
            raise ValueError("truncated ar member")
        yield name, data
        offset += size + (size & 1)


def extract_elf(package: Path, member_suffix: str, destination: Path, label: str) -> None:
    data_tar = next(
        (data for name, data in ar_members(package.read_bytes()) if name.startswith("data.tar")),
        None,
    )
    if data_tar is None:
        raise ValueError("Debian package has no data archive")
    with tarfile.open(fileobj=io.BytesIO(data_tar), mode="r:*") as archive:
        matches = [
            member
            for member in archive.getmembers()
            if member.isfile()
            and ("/" + member.name.lstrip("/")).endswith(member_suffix)
        ]
        if len(matches) != 1:
            raise ValueError(f"expected one {label}, found {len(matches)}")
        source = archive.extractfile(matches[0])
        if source is None:
            raise ValueError(f"could not read {label}")
        payload = source.read()
    if not 4096 <= len(payload) <= 64 * 1024 * 1024 or payload[:4] != b"\x7fELF":
        raise ValueError(f"{label} is not a plausible ELF binary")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".new")
    with temporary.open("wb") as output:
        output.write(payload)
    os.chmod(temporary, 0o755)
    os.replace(temporary, destination)


def extract_plugin(package: Path, destination: Path) -> None:
    extract_elf(package, PLUGIN_SUFFIX, destination, "virtual-keyboard plugin")


def main() -> int:
    if len(sys.argv) == 3:
        package, suffix, destination, label = (
            Path(sys.argv[1]),
            PLUGIN_SUFFIX,
            Path(sys.argv[2]),
            "virtual-keyboard plugin",
        )
    elif len(sys.argv) == 5 and sys.argv[1] == "--elf":
        package, suffix, destination, label = (
            Path(sys.argv[2]),
            sys.argv[3],
            Path(sys.argv[4]),
            "runtime library",
        )
        if not suffix.startswith("/") or ".." in Path(suffix).parts:
            print("unsafe Debian member suffix", file=sys.stderr)
            return 2
    else:
        print(
            f"usage: {Path(sys.argv[0]).name} PACKAGE.deb DESTINATION | "
            "--elf PACKAGE.deb /MEMBER/SUFFIX DESTINATION",
            file=sys.stderr,
        )
        return 2
    try:
        extract_elf(package, suffix, destination, label)
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f"Debian runtime extraction failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
