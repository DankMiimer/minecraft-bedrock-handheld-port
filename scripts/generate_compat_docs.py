#!/usr/bin/env python3
from __future__ import annotations
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "portmaster/minecraftbedrock/minecraftbedrock/compat/compatibility.json"
OUTPUT = ROOT / "portmaster/minecraftbedrock/COMPATIBILITY.md"


def display_name(value: str) -> str:
    return value.replace("_", " ").title().replace("Renderdragon", "RenderDragon")


def render() -> str:
    data = json.loads(REGISTRY.read_text(encoding="utf-8"))
    lines = [
        "# Bedrock compatibility registry", "",
        "This file is generated from `minecraftbedrock/compat/compatibility.json`.", "",
        "| Bedrock | ABI | Status | Renderer | Recommendation | Guards / notes |",
        "|---|---|---|---|---|---|",
    ]
    for row in data["versions"]:
        notes = []
        notes.extend(row.get("patches", []))
        notes.extend("optional: " + item for item in row.get("optional_patches", []))
        if row.get("asset_layout"):
            notes.append("assets: " + row["asset_layout"])
        if row.get("game_library_sha256"):
            notes.append("library SHA-256: `" + row["game_library_sha256"][:12] + "…`")
        if row.get("warning"):
            notes.append("warning: " + row["warning"])
        limitations = row.get("known_limitations", [])
        if isinstance(limitations, str):
            limitations = [limitations]
        notes.extend("limitation: " + item for item in limitations)
        if row.get("reason"):
            notes.append(row["reason"])
        lines.append(
            f"| {row['version']} | {row['abi']} | {row['status'].replace('_', ' ').title()} "
            f"| {row.get('renderer_profile', 'unclassified')} "
            f"| {display_name(row.get('recommendation', '—'))} "
            f"| {'; '.join(notes) or '—'} |"
        )
    lines += ["", "## Labels", ""]
    for key, value in data["labels"].items():
        lines.append(f"- **{display_name(key)}** — {value}.")
    lines += ["", "## Recommendations", ""]
    for key, value in data.get("recommendations", {}).items():
        lines.append(f"- **{display_name(key)}** — {value}.")
    lines += ["", "## Default admission", ""]
    for row in data["defaults"]:
        suffix = f": {row['reason']}" if row.get("reason") else ""
        lines.append(f"- `{row['range']}`: **{row['status'].replace('_', ' ').title()}**{suffix}")
    return "\n".join(lines) + "\n"


def main() -> int:
    expected = render()
    import sys
    if "--check" in sys.argv:
        return 0 if OUTPUT.exists() and OUTPUT.read_text(encoding="utf-8") == expected else 1
    OUTPUT.write_bytes(expected.encode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
