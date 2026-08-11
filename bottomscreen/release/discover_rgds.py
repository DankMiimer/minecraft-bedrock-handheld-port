#!/usr/bin/env python3
"""Resolve RGDS outputs, touch identifiers, region, and gamepad dynamically."""
from __future__ import annotations
import json, os, re, subprocess, sys
from pathlib import Path


def sway_json(kind: str):
    return json.loads(subprocess.check_output(["swaymsg", "-r", "-t", kind], text=True))


def sway_command(command: str) -> None:
    subprocess.run(["swaymsg", command], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)


def quote(value: object) -> str:
    text = str(value)
    return "'" + text.replace("'", "'\\''") + "'"


def gamepad_event() -> str:
    try:
        blocks = open("/proc/bus/input/devices", encoding="utf-8", errors="replace").read().split("\n\n")
    except OSError:
        return ""
    for block in blocks:
        if "Handlers=" not in block or "KEY=" not in block:
            continue
        if not re.search(r"\b(js\d+|gamepad|joystick)\b", block, re.I):
            continue
        match = re.search(r"\b(event\d+)\b", block)
        if match:
            return "/dev/input/" + match.group(1)
    return ""


def touch_events() -> tuple[str, str]:
    """Return (top,bottom) from libinput calibration, not event numbers."""
    top = bottom = ""
    for event in sorted(Path("/sys/class/input").glob("event*")):
        try:
            name = (event / "device" / "name").read_text(errors="replace").strip()
        except OSError:
            continue
        if "touch" not in name.lower() and "goodix" not in name.lower():
            continue
        devnode = "/dev/input/" + event.name
        result = subprocess.run(
            ["udevadm", "info", "--query=property", "--name", devnode],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        matrix = next((line.split("=", 1)[1] for line in result.stdout.splitlines()
                       if line.startswith("LIBINPUT_CALIBRATION_MATRIX=")), "")
        try:
            values = [float(value) for value in matrix.split()]
        except ValueError:
            values = []
        if len(values) >= 3 and abs(values[0] - 0.5) < 0.01:
            if abs(values[2] - 0.5) < 0.01: bottom = devnode
            elif abs(values[2]) < 0.01: top = devnode
    return top, bottom


try:
    all_outputs = sway_json("get_outputs")
    if len(all_outputs) < 2:
        raise RuntimeError(f"need two connected Sway outputs, found {len(all_outputs)}")
    by_name = {o["name"]: o for o in all_outputs}
    top = os.getenv("MCPE_RGDS_TOP_OUTPUT", "")
    bottom = os.getenv("MCPE_RGDS_BOTTOM_OUTPUT", "")
    if not top or not bottom:
        if "DSI-1" in by_name and "DSI-2" in by_name:
            top, bottom = "DSI-2", "DSI-1"
        else:
            ordered = sorted(all_outputs, key=lambda o: (
                not o.get("active"), o.get("rect", {}).get("x", 0),
                o.get("rect", {}).get("y", 0), o["name"]))
            focused = [o for o in ordered if o.get("focused")]
            top_obj = focused[0] if focused else ordered[0]
            bottom_obj = next(o for o in ordered if o["name"] != top_obj["name"])
            top, bottom = top_obj["name"], bottom_obj["name"]
    if top == bottom or top not in by_name or bottom not in by_name:
        raise RuntimeError(f"invalid top/bottom outputs: {top!r}/{bottom!r}")
    if not all(re.fullmatch(r"[A-Za-z0-9_.:-]+", name) for name in (top, bottom)):
        raise RuntimeError("output names contain unsupported command characters")

    # RGDS frontends commonly leave the companion panel disabled. Enable only
    # the selected outputs, then re-query their real compositor geometry.
    for name in (top, bottom):
        if not by_name[name].get("active"):
            sway_command(f'output "{name}" enable')
            sway_command(f'output "{name}" power on')
    all_outputs = sway_json("get_outputs")
    by_name = {o["name"]: o for o in all_outputs}
    if not all(by_name.get(name, {}).get("active") for name in (top, bottom)):
        raise RuntimeError("selected RGDS outputs could not be activated")

    selected = [by_name[top], by_name[bottom]]
    xs = [o["rect"]["x"] for o in selected]
    ys = [o["rect"]["y"] for o in selected]
    rights = [o["rect"]["x"] + o["rect"]["width"] for o in selected]
    bottoms = [o["rect"]["y"] + o["rect"]["height"] for o in selected]
    region = (min(xs), min(ys), max(rights) - min(xs), max(bottoms) - min(ys))
    touches = [i["identifier"] for i in sway_json("get_inputs") if i.get("type") == "touch"]
    if len(touches) < 2:
        raise RuntimeError(f"need two Sway touch devices, found {len(touches)}")

    detected_top_touch, detected_bottom_touch = touch_events()
    top_touch = os.getenv("MCPE_RGDS_TOP_TOUCH_EVENT", detected_top_touch)
    bottom_touch = os.getenv("MCPE_RGDS_BOTTOM_TOUCH_EVENT", detected_bottom_touch)
    for label, value in (("top", top_touch), ("bottom", bottom_touch)):
        if value and not re.fullmatch(r"/dev/input/event[0-9]+", value):
            raise RuntimeError(f"invalid {label} touch event override: {value!r}")
    values = {
        "RGDS_TOP_OUTPUT": top,
        "RGDS_BOTTOM_OUTPUT": bottom,
        "RGDS_TOP_WIDTH": by_name[top]["rect"]["width"],
        "RGDS_TOP_HEIGHT": by_name[top]["rect"]["height"],
        "RGDS_BOTTOM_WIDTH": by_name[bottom]["rect"]["width"],
        "RGDS_BOTTOM_HEIGHT": by_name[bottom]["rect"]["height"],
        "RGDS_REGION_X": region[0], "RGDS_REGION_Y": region[1],
        "RGDS_REGION_W": region[2], "RGDS_REGION_H": region[3],
        "RGDS_GAMEPAD_EVENT": gamepad_event(),
        "RGDS_TOUCH_COUNT": len(touches),
        "RGDS_TOUCH_IDENTIFIERS": "\n".join(touches),
        "RGDS_TOP_TOUCH_EVENT": top_touch,
        "RGDS_BOTTOM_TOUCH_EVENT": bottom_touch,
    }
    for key, value in values.items():
        print(f"{key}={quote(value)}")
except (OSError, subprocess.CalledProcessError, ValueError, KeyError, RuntimeError) as exc:
    print(f"RGDS discovery failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
