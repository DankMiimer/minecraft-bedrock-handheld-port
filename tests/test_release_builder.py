#!/usr/bin/env python3
from __future__ import annotations
import struct, subprocess, sys, tempfile, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def fake_aarch64(path: Path):
    data = bytearray(64)
    data[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<H", data, 18, 183)
    path.write_bytes(data)


def fake_armhf(path: Path):
    data = bytearray(64)
    data[:6] = b"\x7fELF\x01\x01"
    struct.pack_into("<H", data, 18, 40)
    path.write_bytes(data)


with tempfile.TemporaryDirectory(prefix="release-test-") as tmpstr:
    tmp = Path(tmpstr); artifacts = tmp / "artifacts"; out = tmp / "out"
    artifacts.mkdir()
    for name in ("client", "standard-arm64", "bottomd", "bedrockmap", "context-bridge"):
        fake_aarch64(artifacts / name)
    fake_armhf(artifacts / "standard-armhf")
    subprocess.run([
        sys.executable, str(ROOT / "scripts" / "build_releases.py"),
        "--version", "9.9.9-test", "--out-dir", str(out),
        "--rgds-client", str(artifacts / "client"),
        "--standard-arm64-client", str(artifacts / "standard-arm64"),
        "--standard-armhf-client", str(artifacts / "standard-armhf"),
        "--bottomd", str(artifacts / "bottomd"),
        "--bedrockmap", str(artifacts / "bedrockmap"),
        "--context-bridge", str(artifacts / "context-bridge"),
    ], check=True)
    standard = out / "minecraftbedrock-standard-v9.9.9-test.zip"
    rgds = out / "minecraftbedrock-rgds-v9.9.9-test.zip"
    source = out / "minecraftbedrock-source-v9.9.9-test.zip"
    with zipfile.ZipFile(standard) as archive:
        names = archive.namelist()
        assert "ports/minecraftbedrock/edition.json" in names
        assert "COMPATIBILITY.md" in names
        assert "ports/minecraftbedrock/bin/crusty-context-v1.so" in names
        client_info = archive.getinfo("ports/minecraftbedrock/bin/mcpelauncher-client")
        assert client_info.create_system == 3
        assert (client_info.external_attr >> 16) & 0o777 == 0o755
        assert not any(name.startswith("ports/minecraftbedrock/apk/") for name in names)
        assert not any("bottomd" in name or "rgds/" in name for name in names)
    with zipfile.ZipFile(rgds) as archive:
        names = archive.namelist()
        assert "ports/minecraftbedrock-rgds/rgds/bottomd" in names
        assert "COMPATIBILITY.md" in names
        assert "ports/minecraftbedrock-rgds/bin/crusty-context-v1.so" in names
        assert "ports/Minecraft Bedrock RGDS.sh" in names
        bottomd_info = archive.getinfo("ports/minecraftbedrock-rgds/rgds/bottomd")
        assert bottomd_info.create_system == 3
        assert (bottomd_info.external_attr >> 16) & 0o777 == 0o755
        assert not any(name.startswith("ports/minecraftbedrock-rgds/apk/") for name in names)
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        assert "VERSION" in names
        assert ".gitattributes" in names
        assert "build/clients/Dockerfile" in names
        assert "scripts/build_releases.py" in names
    assert (out / "release-index.json").is_file()
    for name in ("release-index.json", "SHA256SUMS.txt", "RELEASE_NOTES.md"):
        assert b"\r" not in (out / name).read_bytes()
print("release builder tests passed")
