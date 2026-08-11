#!/usr/bin/env python3
"""Build a tiny index over textures already installed with Minecraft.

The index contains paths and metadata only.  It deliberately never copies
Mojang artwork into the port or its release archive.  bottomd opens PNG files
through these roots at runtime, so removing the user-supplied game also makes
the artwork unavailable.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import tempfile
from typing import Any


def version_key(name: str) -> tuple[int, ...]:
    match = re.fullmatch(r"vanilla_(\d+(?:\.\d+)*)", name)
    if not match:
        return ()
    return tuple(int(part) for part in match.group(1).split("."))


def pack_roots(version_dir: pathlib.Path) -> list[pathlib.Path]:
    parent = version_dir / "assets" / "assets" / "resource_packs"
    if not parent.is_dir():
        return []
    base = [parent / "vanilla_base", parent / "vanilla"]
    overlays = sorted(
        (path for path in parent.iterdir() if path.is_dir() and version_key(path.name)),
        key=lambda path: version_key(path.name),
    )
    # Bedrock overlays are cumulative.  Resolve newest first, then vanilla,
    # then vanilla_base, while merge_json() consumes the reverse order.
    return list(reversed(overlays)) + [path for path in reversed(base) if path.is_dir()]


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def texture_variants(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        textures = value.get("textures")
        if isinstance(textures, str):
            return [textures]
        if isinstance(textures, list):
            return [item for item in textures if isinstance(item, str)]
    return []


def merge_atlas(roots_high_first: list[pathlib.Path], filename: str) -> dict[str, list[str]]:
    merged: dict[str, list[str]] = {}
    for root in reversed(roots_high_first):
        atlas = load_json(root / "textures" / filename)
        data = atlas.get("texture_data")
        if not isinstance(data, dict):
            continue
        for identifier, value in data.items():
            if isinstance(identifier, str):
                variants = texture_variants(value)
                if variants:
                    merged[identifier] = variants
    return merged


def path_aliases(relative: str) -> set[str]:
    """Return canonical-looking aliases without copying the texture.

    Bedrock's legacy item atlas groups families under keys such as ``helmet``
    and ``axe`` even though native inventory identifiers are
    ``chainmail_helmet`` and ``iron_axe``.  The leaf filenames retain those
    canonical names.  Terrain textures also commonly retain the words in the
    opposite order (``log_oak`` versus ``oak_log``).
    """
    leaf = pathlib.PurePosixPath(relative).name
    aliases = {leaf}
    for prefix, suffix in (
        ("log_", "_log"),
        ("planks_", "_planks"),
        ("leaves_", "_leaves"),
        ("sapling_", "_sapling"),
        ("door_", "_door"),
        ("trapdoor_", "_trapdoor"),
    ):
        if leaf.startswith(prefix) and len(leaf) > len(prefix):
            aliases.add(leaf[len(prefix):] + suffix)
    return aliases


def indexed_rows(roots: list[pathlib.Path]) -> list[tuple[str, int, str]]:
    rows: dict[tuple[str, int], str] = {}
    item_atlas = merge_atlas(roots, "item_texture.json")
    for identifier, variants in item_atlas.items():
        for variant, relative in enumerate(variants):
            rows[(identifier, variant)] = relative
            for alias in path_aliases(relative):
                rows.setdefault((alias, 0), relative)

    # BlockItems do not necessarily have an item-atlas entry.  Index their
    # user-installed terrain PNG paths as aliases so the independent UI can
    # still show a real Bedrock texture rather than bundled replacement art.
    for variants in merge_atlas(roots, "terrain_texture.json").values():
        for relative in variants:
            for alias in path_aliases(relative):
                rows.setdefault((alias, 0), relative)
    return [(identifier, variant, relative)
            for (identifier, variant), relative in sorted(rows.items())]


def atomic_text(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def build(version_dir: pathlib.Path, output: pathlib.Path) -> int:
    roots = pack_roots(version_dir.resolve())
    if not roots:
        raise SystemExit(f"no installed Bedrock resource packs under {version_dir}")

    atomic_text(output / "resource-paths.txt", "".join(f"{root.resolve()}\n" for root in roots))
    rows = ["# identifier\tvariant\ttexture-relative-path\n"]
    rows.extend(f"{identifier}\t{variant}\t{relative}\n"
                for identifier, variant, relative in indexed_rows(roots))
    atomic_text(output / "item-textures.tsv", "".join(rows))

    metadata = {
        "schema": 1,
        "version_directory": version_dir.resolve().name,
        "resource_roots": len(roots),
        "item_identifiers": len({row.split("\t", 1)[0] for row in rows[1:]}),
    }
    atomic_text(output / "index.json", json.dumps(metadata, sort_keys=True, indent=2) + "\n")
    print(f"indexed {metadata['item_identifiers']} item identifiers across {len(roots)} installed packs")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("version_dir", type=pathlib.Path)
    parser.add_argument("output_dir", type=pathlib.Path)
    args = parser.parse_args()
    return build(args.version_dir, args.output_dir)


if __name__ == "__main__":
    raise SystemExit(main())
