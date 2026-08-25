#!/usr/bin/env python3
"""Guard the public and packaged installation guides against release drift."""
from __future__ import annotations

import pathlib
import re


ROOT = pathlib.Path(__file__).resolve().parents[1]
PUBLIC = (ROOT / "README.md").read_text(encoding="utf-8")
PACKAGED = (ROOT / "portmaster" / "minecraftbedrock" / "README.md").read_text(encoding="utf-8")
APK_GUIDE = (ROOT / "GETTING-BEDROCK-APKS.md").read_text(encoding="utf-8")
MAINTAINER = (ROOT / "README.txt").read_text(encoding="utf-8")
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()

for label, text in (("README.md", PUBLIC), ("packaged README", PACKAGED), ("APK guide", APK_GUIDE)):
    assert "No game files are included" in text, f"{label}: missing no-game-files statement"
    assert "NOT AN OFFICIAL MINECRAFT PRODUCT" in text, f"{label}: missing disclaimer"
    assert "ports/minecraftbedrock-data/apk/" in text, f"{label}: stale APK destination"
    assert "1.16.221.01" in text, f"{label}: missing recommended version"
    assert "1.21.51.01" in text, f"{label}: missing newest tested alternative"
    assert "arm64-v8a" in text, f"{label}: missing ABI guidance"

assert f"v{VERSION}" in PUBLIC, "public README does not name the current release"
assert f"mcbedrock-get-windows-v{VERSION}.zip" in PUBLIC, "public README lacks Windows bundle"
for asset in (
    f"minecraftbedrock-standard-v{VERSION}.zip",
    f"minecraftbedrock-rgds-v{VERSION}.zip",
    f"minecraftbedrock-source-v{VERSION}.zip",
    f"minecraftbedrock-standard-v{VERSION}.spdx.json",
    f"minecraftbedrock-rgds-v{VERSION}.spdx.json",
    f"mcbedrock-get-windows-v{VERSION}.zip",
    "RELEASE_NOTES.md",
    "SHA256SUMS.txt",
):
    assert asset in PUBLIC, f"public README lacks release asset {asset}"
# 2.0.0 is stable, but not uniformly: the armhf/R36S matrix has no device and
# the RGDS companion is experimental. Both READMEs must keep saying so, and
# must not have quietly become a blanket claim.
for label, text in (("README.md", PUBLIC), ("packaged README", PACKAGED)):
    assert "R36S" in text and "RGDS" in text and "pending" in text, label
    assert "experimental" in text.lower(), f"{label}: RGDS caveat lost"
for label, text in (("README.md", PUBLIC), ("README.txt", MAINTAINER)):
    assert "ArkOS" in text, f"{label}: the unsupported firmware family is unnamed"
assert "cannot download from Google Play" not in (PUBLIC + PACKAGED + APK_GUIDE)
assert "unfinished Windows downloader" not in (PUBLIC + PACKAGED + APK_GUIDE)

for match in re.finditer(r"\[[^]]+\]\(([^)]+)\)", PUBLIC):
    target = match.group(1).split("#", 1)[0]
    if not target or "://" in target or target.startswith("#"):
        continue
    assert (ROOT / target).exists(), f"README.md: broken local link {target}"

print("documentation consistency tests passed")
