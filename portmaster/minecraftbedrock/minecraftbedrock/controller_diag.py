#!/usr/bin/env python3
"""Local, read-only evdev controller sampler for support diagnostics."""
from __future__ import annotations
import argparse
import os
import re
import select
import struct
import time
from pathlib import Path

EVENT = struct.Struct("@llHHi")


def devices() -> list[tuple[str, str]]:
    try:
        blocks = Path("/proc/bus/input/devices").read_text(errors="replace").split("\n\n")
    except OSError:
        return []
    found = []
    for block in blocks:
        if not re.search(r"\b(js\d+|gamepad|joystick)\b", block, re.I):
            continue
        event = re.search(r"\b(event\d+)\b", block)
        name = re.search(r'^N: Name="(.*)"$', block, re.M)
        if event:
            found.append(("/dev/input/" + event.group(1), name.group(1) if name else "unknown"))
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=8.0)
    args = parser.parse_args()
    found = devices()
    print(f"controller_count={len(found)}")
    handles = []
    for node, name in found:
        event = Path(node).name
        print(f"device={node} name={name}")
        for capability in ("key", "abs"):
            path = Path("/sys/class/input") / event / "device/capabilities" / capability
            try:
                print(f"cap_{capability}={path.read_text().strip()}")
            except OSError:
                pass
        try:
            handles.append(os.open(node, os.O_RDONLY | os.O_NONBLOCK))
        except OSError as exc:
            print(f"open_error={node}: {exc}")
    print(f"sampling_seconds={args.seconds:g}; press every button and move both sticks")
    seen: dict[tuple[int, int], tuple[int, int, int]] = {}
    deadline = time.monotonic() + max(0.0, args.seconds)
    while handles and time.monotonic() < deadline:
        ready, _, _ = select.select(handles, [], [], max(0.0, min(0.25, deadline - time.monotonic())))
        for handle in ready:
            try:
                data = os.read(handle, EVENT.size * 32)
            except BlockingIOError:
                continue
            for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _sec, _usec, event_type, code, value = EVENT.unpack_from(data, offset)
                if event_type not in (1, 3):
                    continue
                key = (event_type, code)
                low, high, count = seen.get(key, (value, value, 0))
                seen[key] = (min(low, value), max(high, value), count + 1)
    for handle in handles:
        os.close(handle)
    for (event_type, code), (low, high, count) in sorted(seen.items()):
        print(f"event type={event_type} code={code} min={low} max={high} samples={count}")
    print(f"unique_controls={len(seen)}")
    return 0 if found else 1


if __name__ == "__main__":
    raise SystemExit(main())
