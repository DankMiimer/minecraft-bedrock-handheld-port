#!/usr/bin/env python3
"""Save/restore Sway input assignments and output layout without jq."""
from __future__ import annotations
import argparse, json, subprocess
from pathlib import Path


def query(kind: str):
    return json.loads(subprocess.check_output(["swaymsg", "-r", "-t", kind], text=True))


def command(value: str) -> None:
    subprocess.run(["swaymsg", value], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


parser = argparse.ArgumentParser()
parser.add_argument("action", choices=("save", "restore"))
parser.add_argument("path", type=Path)
args = parser.parse_args()

if args.action == "save":
    state = {"schema": 2, "seats": [], "touch_outputs": [], "outputs": []}
    for seat in query("get_seats"):
        for device in seat.get("devices", []):
            state["seats"].append([seat["name"], device["identifier"]])
    for device in query("get_inputs"):
        if device.get("type") == "touch":
            state["touch_outputs"].append([device["identifier"], device.get("output") or ""])
    for output in query("get_outputs"):
        rect = output.get("rect") or {}
        mode = output.get("current_mode") or {}
        state["outputs"].append({
            "name": output["name"],
            "active": bool(output.get("active")),
            "power": bool(output.get("dpms", output.get("power", True))),
            "x": rect.get("x", 0), "y": rect.get("y", 0),
            "width": mode.get("width", 0), "height": mode.get("height", 0),
            "refresh": mode.get("refresh", 0),
            "scale": output.get("scale", 1.0),
            "transform": output.get("transform", output.get("current_transform", "normal")),
        })
    if not state["seats"]:
        raise SystemExit("refusing to save an empty Sway input state")
    args.path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
else:
    state = json.loads(args.path.read_text(encoding="utf-8"))
    if state.get("schema") not in (1, 2) or not state.get("seats"):
        raise SystemExit("invalid/empty Sway input state")
    for output in state.get("outputs", []):
        name = output["name"]
        if not output.get("active"):
            command(f'output "{name}" disable')
            continue
        command(f'output "{name}" enable')
        width, height, refresh = output.get("width", 0), output.get("height", 0), output.get("refresh", 0)
        if width and height:
            suffix = f'@{refresh / 1000:.3f}Hz' if refresh else ""
            command(f'output "{name}" mode {width}x{height}{suffix}')
        command(f'output "{name}" pos {output.get("x", 0)} {output.get("y", 0)}')
        command(f'output "{name}" scale {output.get("scale", 1.0)}')
        command(f'output "{name}" transform {output.get("transform", "normal")}')
        command(f'output "{name}" power {"on" if output.get("power", True) else "off"}')
    for seat, identifier in state["seats"]:
        command(f'seat "{seat}" attach "{identifier}"')
    for identifier, output in state.get("touch_outputs", []):
        if output:
            command(f'input "{identifier}" map_to_output "{output}"')
