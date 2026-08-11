#!/usr/bin/env python3
"""Generate the notices file shipped beside mcbedrock-get.exe.

Read from the build environment rather than hand-maintained, so the list cannot
drift from what PyInstaller actually bundles. Run by build.bat.
"""
from __future__ import annotations

import sys
from importlib.metadata import distributions
from pathlib import Path

# Build tooling: present in the venv, never bundled into the executable.
EXCLUDED = {
    "pip", "setuptools", "wheel", "pyinstaller", "pyinstaller-hooks-contrib",
    "altgraph", "packaging", "pefile", "pywin32-ctypes",
}

HEADER = """\
mcbedrock-get - notices and licences
====================================

mcbedrock-get is part of the Minecraft Bedrock handheld port and is licensed
under the GNU General Public License version 3. The complete corresponding
source is published in the same release as `minecraftbedrock-source-v<VERSION>.zip`
and at:

    https://github.com/DankMiimer/minecraft-bedrock-handheld-port

No Minecraft code, assets, worlds, or licence material is contained in this
executable or distributed with it. The tool is a Google Play client: it
downloads Minecraft from the Google account of the person running it, and only
if Google confirms that account owns it. It circumvents nothing and stores no
Minecraft content of its own.

NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG
OR MICROSOFT. Minecraft is owned by Mojang Studios and Microsoft.

This executable also embeds the CPython runtime, licensed under the Python
Software Foundation License.

Bundled components
------------------
"""


def licence_of(dist) -> str:
    meta = dist.metadata
    expression = meta.get("License-Expression")
    if expression:
        return expression.strip()
    declared = (meta.get("License") or "").strip().splitlines()
    if declared and len(declared[0]) < 60:
        return declared[0]
    classifiers = [
        line.split("::")[-1].strip()
        for line in (meta.get_all("Classifier") or [])
        if line.startswith("License")
    ]
    return "; ".join(classifiers) or "see bundled licence text"


def licence_texts(dist) -> list[tuple[str, str]]:
    """Licence files the wheel shipped inside its dist-info."""
    found = []
    for file in dist.files or []:
        name = Path(str(file)).name
        if not name.lower().startswith(("license", "licence", "copying", "notice")):
            continue
        # read_text() resolves against the dist-info directory, so the entries
        # in dist.files have to be located on disk instead.
        try:
            path = Path(file.locate())
            if path.is_file():
                found.append((name, path.read_text(encoding="utf-8", errors="replace")))
        except (OSError, ValueError):
            continue
    return [(name, text) for name, text in found if text.strip()]


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("dist/mcbedrock-get-NOTICES.txt")

    bundled = sorted(
        (d for d in distributions() if (d.metadata["Name"] or "").lower() not in EXCLUDED),
        key=lambda d: (d.metadata["Name"] or "").lower(),
    )

    lines = [HEADER]
    for dist in bundled:
        lines.append(f"  {dist.metadata['Name']:<22} {dist.version:<12} {licence_of(dist)}")

    lines.append("\n\nFull licence texts\n" + "-" * 18 + "\n")
    for dist in bundled:
        texts = licence_texts(dist)
        if not texts:
            lines.append(
                f"\n=== {dist.metadata['Name']} {dist.version} ===\n"
                f"Licence: {licence_of(dist)}\n"
                "(This wheel ships no licence text; see the project's own repository.)\n"
            )
            continue
        for name, text in texts:
            lines.append(f"\n=== {dist.metadata['Name']} {dist.version} - {name} ===\n{text.strip()}\n")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {out} covering {len(bundled)} components")
    return 0


if __name__ == "__main__":
    sys.exit(main())
