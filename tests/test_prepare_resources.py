#!/usr/bin/env python3
import importlib.util
import json
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "bottomscreen" / "release" / "prepare_resources.py"
spec = importlib.util.spec_from_file_location("prepare_resources", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)


def atlas(path: Path, entries: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"texture_data": entries}), encoding="utf-8")


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    version = root / "1.21.51.01-test"
    packs = version / "assets" / "assets" / "resource_packs"
    atlas(packs / "vanilla_base" / "textures" / "item_texture.json", {
        "apple": {"textures": "textures/items/apple_old"},
        "axe": {"textures": ["textures/items/axe_0", "textures/items/axe_1"]},
    })
    atlas(packs / "vanilla" / "textures" / "item_texture.json", {
        "apple": {"textures": "textures/items/apple"},
        "helmet": {"textures": ["textures/items/leather_helmet",
                                  "textures/items/chainmail_helmet"]},
    })
    atlas(packs / "vanilla" / "textures" / "terrain_texture.json", {
        "log": {"textures": ["textures/blocks/log_oak"]},
    })
    atlas(packs / "vanilla_1.21.40" / "textures" / "item_texture.json", {
        "bundle": {"textures": "textures/items/bundle_old"},
    })
    atlas(packs / "vanilla_1.21.51" / "textures" / "item_texture.json", {
        "bundle": {"textures": "textures/items/bundle"},
    })
    output = root / "cache"
    assert module.build(version, output) == 0

    paths = (output / "resource-paths.txt").read_text().splitlines()
    assert paths[0].endswith("vanilla_1.21.51")
    assert paths[-1].endswith("vanilla_base")
    items = (output / "item-textures.tsv").read_text()
    assert "apple\t0\ttextures/items/apple\n" in items
    assert "apple_old" not in items
    assert "axe\t1\ttextures/items/axe_1\n" in items
    assert "bundle\t0\ttextures/items/bundle\n" in items
    assert "chainmail_helmet\t0\ttextures/items/chainmail_helmet\n" in items
    assert "oak_log\t0\ttextures/blocks/log_oak\n" in items
    metadata = json.loads((output / "index.json").read_text())
    assert metadata["item_identifiers"] >= 5

print("resource index tests passed")
