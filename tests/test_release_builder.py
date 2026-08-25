#!/usr/bin/env python3
from __future__ import annotations
import json, struct, subprocess, sys, tempfile, zipfile
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
    legacy = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts" / "build_release_zips.py"),
            "--staging",
            str(ROOT / "staging"),
            "--version",
            "9.9.9-test",
            "--out-dir",
            str(tmp / "legacy"),
        ],
        capture_output=True,
        text=True,
    )
    assert legacy.returncode == 2
    assert "archived v1.x staging builder" in legacy.stderr
    assert not (tmp / "legacy").exists()
    for name in ("client", "standard-arm64", "bottomd", "bedrockmap", "context-bridge"):
        fake_aarch64(artifacts / name)
    fake_armhf(artifacts / "standard-armhf")
    helper = artifacts / "mcbedrock-get-windows-v9.9.9-test.zip"
    with zipfile.ZipFile(helper, "w") as archive:
        archive.writestr("README.md", "No game files are included.\n")
    subprocess.run([
        sys.executable, str(ROOT / "scripts" / "build_releases.py"),
        "--version", "9.9.9-test", "--out-dir", str(out),
        "--rgds-client", str(artifacts / "client"),
        "--standard-arm64-client", str(artifacts / "standard-arm64"),
        "--standard-armhf-client", str(artifacts / "standard-armhf"),
        "--bottomd", str(artifacts / "bottomd"),
        "--bedrockmap", str(artifacts / "bedrockmap"),
        "--context-bridge", str(artifacts / "context-bridge"),
        "--extra-asset", str(helper),
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
    index = json.loads((out / "release-index.json").read_text(encoding="utf-8"))
    assert index["schema"] == 2
    assert {row["edition"] for row in index["releases"]} == {
        "minecraftbedrock.standard", "minecraftbedrock.rgds"
    }
    assert not any("mcbedrock-get" in row["asset"] for row in index["releases"])
    assert (out / helper.name).read_bytes() == helper.read_bytes()
    assert helper.name in (out / "SHA256SUMS.txt").read_text(encoding="utf-8")
    notes = (out / "RELEASE_NOTES.md").read_text(encoding="utf-8")
    # The point is that shipping the helper is announced, not the wording used
    # to announce it; pinning a phrase here just breaks when the notes improve.
    assert "Windows helper" in notes
    assert "No game files are included" in notes
    for name in ("release-index.json", "SHA256SUMS.txt", "RELEASE_NOTES.md"):
        assert b"\r" not in (out / name).read_bytes()
    # A stable release must also be offered to the testing channel, pointing at
    # the same asset. The device's channel lives in config/update_channel and
    # survives the code swap, so a shared asset cannot move anyone between
    # channels -- the channel stamped into the payload is never read back.
    base_index = tmp / "base-index.json"
    base_index.write_text(json.dumps({"schema": 2, "releases": [
        {"edition": "minecraftbedrock.standard", "channel": "testing",
         "version": "9.9.8-test", "asset": "old.zip", "url": "https://example/old.zip",
         "sha256": "0" * 64, "size": 1, "minimum_updater": 2},
        {"edition": "somethingelse", "channel": "testing", "version": "1.0",
         "asset": "keep.zip", "url": "https://example/keep.zip",
         "sha256": "1" * 64, "size": 2, "minimum_updater": 2},
    ]}), encoding="utf-8")
    mirrored = tmp / "mirrored"
    subprocess.run([
        sys.executable, str(ROOT / "scripts" / "build_releases.py"),
        "--version", "9.9.9-test", "--out-dir", str(mirrored),
        "--channel", "stable", "--mirror-channel", "testing",
        "--base-index", str(base_index),
        "--rgds-client", str(artifacts / "client"),
        "--standard-arm64-client", str(artifacts / "standard-arm64"),
        "--standard-armhf-client", str(artifacts / "standard-armhf"),
        "--bottomd", str(artifacts / "bottomd"),
        "--bedrockmap", str(artifacts / "bedrockmap"),
        "--context-bridge", str(artifacts / "context-bridge"),
    ], check=True)
    mirror_index = json.loads((mirrored / "release-index.json").read_text(encoding="utf-8"))
    rows = mirror_index["releases"]
    # Exactly one row per edition-and-channel pair: release_select.py rejects
    # anything else, so a duplicate here is a broken updater on every device.
    pairs = [(row["edition"], row["channel"]) for row in rows]
    assert len(pairs) == len(set(pairs)), pairs
    for edition in ("minecraftbedrock.standard", "minecraftbedrock.rgds"):
        pick = {row["channel"]: row for row in rows if row["edition"] == edition}
        assert set(pick) == {"stable", "testing"}, (edition, sorted(pick))
        assert pick["stable"]["version"] == "9.9.9-test"
        assert pick["testing"]["version"] == "9.9.9-test"
        # Same file, so the digests must agree; a mismatch means the updater
        # would reject the download it was just told to make.
        for field in ("asset", "url", "sha256", "size"):
            assert pick["stable"][field] == pick["testing"][field], (edition, field)
    # The superseded testing row is replaced, and another edition is untouched.
    assert not any(row["asset"] == "old.zip" for row in rows)
    assert any(row["asset"] == "keep.zip" for row in rows)
    notes = (mirrored / "RELEASE_NOTES.md").read_text(encoding="utf-8")
    assert "also published to the `testing` channel" in notes

# The index the repository tracks is the published one: update_port.sh fetches
# it from raw.githubusercontent.com/<repo>/main/release-index.json. A bad row
# here breaks Update port on every device at once, so it is checked directly
# rather than only as a build output.
tracked = json.loads((ROOT / "release-index.json").read_text(encoding="utf-8"))
assert tracked["schema"] == 2
seen = {}
for row in tracked["releases"]:
    key = (row["edition"], row["channel"])
    # release_select.py requires exactly one match for a device's edition and
    # channel, and reports "found N" rather than choosing between duplicates.
    assert key not in seen, f"duplicate release-index row for {key}"
    seen[key] = row
    assert row["channel"] in ("stable", "testing"), row
    assert len(row["sha256"]) == 64 and not set(row["sha256"]) - set("0123456789abcdef"), row
    assert row["size"] > 0, row
    assert row["minimum_updater"] >= 2, row
    assert row["url"].endswith("/" + row["asset"]), row
# Where one asset is offered on both channels, the two rows must describe it
# identically -- a device that downloads the file and checks it against the
# other row's digest would reject its own update.
for (edition, channel), row in seen.items():
    other = seen.get((edition, "testing" if channel == "stable" else "stable"))
    if other is not None and other["version"] == row["version"]:
        for field in ("asset", "url", "sha256", "size"):
            assert other[field] == row[field], (edition, field)

print("release builder tests passed")
