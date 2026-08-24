#!/usr/bin/env python3
"""Write a PNG of the screen when a gamepad chord is held.

Runs alongside the game and reads the pad's evdev nodes directly, the same way
the client's own gamepad backend does, so it needs no compositor support and
works on the framebuffer path where no screenshot key exists.

The chord is MENU + L3 where the pad has an L3, and MENU + R2 where it does
not -- clamshell handhelds such as the RG34XX-SP report no BTN_THUMBL at all.
Override with MCPE_SCREENSHOT_COMBO, e.g. "mode+select".

Screenshots land in $MCPE_SCREENSHOT_DIR (default <gamedir>/screenshots) as
mcpe-YYYYmmdd-HHMMSS.png.
"""
from __future__ import annotations

import glob
import os
import select
import struct
import sys
import time
import zlib

# evdev
EV_KEY = 0x01
EVENT_FORMAT = "llHHi" if struct.calcsize("l") == 8 else "iiHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)

# A name maps to every code that can stand for it, because handhelds disagree
# about which one their MENU key sends.
BUTTONS = {
    "a": {0x130}, "b": {0x131}, "c": {0x132}, "x": {0x133}, "y": {0x134},
    "z": {0x135}, "l1": {0x136}, "r1": {0x137}, "l2": {0x138}, "r2": {0x139},
    "select": {0x13A}, "start": {0x13B},
    "menu": {0x13C, 0x162}, "mode": {0x13C, 0x162},
    "l3": {0x13D}, "r3": {0x13E},
}

# Some handhelds print labels that do not line up with the BTN_ names their
# driver sends, so a chord named after the labels has to be translated. Keyed
# by the device name in /proc/bus/input/devices. Measured by pressing each
# button and recording the codes (MCPE_SCREENSHOT_DEBUG=1 prints them).
LAYOUTS = {
    # RG34XX-SP: labels sit one place off the driver's names, and one press of
    # MENU emits two codes. Its stick clicks are not wired at all -- what the
    # shell calls L3/R3 are separate buttons.
    "Anbernic RG34XX-SP Controller": {
        "menu": {0x138, 0x162}, "mode": {0x138, 0x162},
        "l3": {0x139}, "r3": {0x13C}, "l2": {0x13A}, "r2": {0x13B},
    },
}
MENU = BUTTONS["menu"]


def log(message: str) -> None:
    sys.stdout.write("Screenshot: %s\n" % message)
    sys.stdout.flush()


def gamepads() -> list[tuple[str, set[int], str]]:
    """[(event node, button codes, device name)] for every pad-like device."""
    found = []
    try:
        blocks = open("/proc/bus/input/devices", encoding="utf-8",
                      errors="replace").read().split("\n\n")
    except OSError:
        return found
    for block in blocks:
        node = None
        name = ""
        codes: set[int] = set()
        for line in block.splitlines():
            if line.startswith('N: Name="'):
                name = line.split('"')[1]
            elif line.startswith("H: Handlers="):
                for handler in line.split("=", 1)[1].split():
                    if handler.startswith("event"):
                        node = "/dev/input/" + handler
            elif line.startswith("B: KEY="):
                words = [int(w, 16) for w in line.split("=", 1)[1].split()][::-1]
                for index, word in enumerate(words):
                    for bit in range(64):
                        if word >> bit & 1:
                            codes.add(index * 64 + bit)
        # A pad is anything reporting the south face button.
        if node and BUTTONS["a"] & codes:
            found.append((node, codes, name))
    return found


def button_table(names: list[str]) -> tuple[dict[str, set[int]], str]:
    """Button names for this hardware, corrected by a layout when one fits."""
    for device in names:
        if device in LAYOUTS:
            table = dict(BUTTONS)
            table.update(LAYOUTS[device])
            return table, device
    return dict(BUTTONS), ""


def pick_combo(codes: set[int], table: dict[str, set[int]] | None = None
               ) -> tuple[list[set[int]], str]:
    """Chord as a list of groups; each group needs one held code to match."""
    table = table or dict(BUTTONS)
    wanted = os.environ.get("MCPE_SCREENSHOT_COMBO", "").strip().lower()
    if wanted:
        parts = [part for part in wanted.replace("-", "+").split("+") if part]
        if parts and all(part in table for part in parts):
            return [table[part] for part in parts], "+".join(parts)
        log("ignoring unusable MCPE_SCREENSHOT_COMBO=%r" % wanted)
    if table["l3"] & codes:
        return [table["menu"], table["l3"]], "menu+L3"
    # Nothing reports an L3: some pads have no stick click wired at all. R2 is
    # the next chord that is awkward to press by accident.
    return [table["menu"], table["r2"]], "menu+R2 (this pad reports no L3)"


def panel_size() -> tuple[int, int]:
    """Visible framebuffer size, which the UI zoom setting can change."""
    # fbset reports "geometry <xres> <yres> <vxres> <vyres> <bpp>"; the virtual
    # buffer is usually two pages tall, so only the visible size is wanted.
    try:
        with os.popen("fbset 2>/dev/null") as pipe:
            for line in pipe:
                parts = line.split()
                if parts and parts[0] == "geometry" and len(parts) >= 3:
                    return int(parts[1]), int(parts[2])
    except (OSError, ValueError):
        pass
    try:
        with open("/sys/class/graphics/fb0/virtual_size", encoding="ascii") as f:
            width, _, height = f.read().strip().partition(",")
        return int(width), int(height)
    except (OSError, ValueError):
        return 0, 0


def write_png(path: str, raw: bytes, width: int, height: int) -> None:
    rows = bytearray()
    line_bytes = width * 4
    for y in range(height):
        line = raw[y * line_bytes:(y + 1) * line_bytes]
        row = bytearray(width * 3)
        row[0::3] = line[2::4]  # BGRA -> R
        row[1::3] = line[1::4]  # G
        row[2::3] = line[0::4]  # B
        rows += b"\x00" + row

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
           + chunk(b"IEND", b""))
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(png)
    os.replace(tmp, path)


def capture(directory: str) -> None:
    width, height = panel_size()
    if not width or not height:
        log("could not read the framebuffer geometry")
        return
    try:
        with open("/dev/fb0", "rb") as fb:
            raw = fb.read(width * height * 4)
    except OSError as exc:
        log("could not read /dev/fb0: %s" % exc)
        return
    if len(raw) < width * height * 4:
        log("short framebuffer read")
        return
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "mcpe-%s.png" % time.strftime("%Y%m%d-%H%M%S"))
    started = time.time()
    write_png(path, raw, width, height)
    log("%s (%dx%d, %.1fs)" % (path, width, height, time.time() - started))


def main() -> int:
    if os.environ.get("MCPE_SCREENSHOTS", "1") != "1":
        return 0
    directory = os.environ.get("MCPE_SCREENSHOT_DIR") or os.path.join(
        os.environ.get("GAMEDIR", "."), "screenshots")

    pads = gamepads()
    if not pads:
        log("no gamepad found; screenshot chord unavailable")
        return 0
    codes: set[int] = set()
    for _, pad_codes, _ in pads:
        codes |= pad_codes
    table, layout = button_table([name for _, _, name in pads])
    if layout:
        log("using the button layout for %s" % layout)
        # A layout names the buttons this pad really has, whatever its driver
        # calls them, so trust it over the capability bitmap.
        codes |= table["l3"]
    # The MENU key is a gpio-keys extra rather than a pad button on some
    # handhelds, so it is not always in the pad's own capability bitmap.
    codes |= table["menu"]
    combo, label = pick_combo(codes, table)

    # Read every input node, not just the pad: on these handhelds the MENU key
    # is a gpio-keys extra that can sit on a different device from the pad
    # buttons, and half a chord is no chord.
    nodes = sorted(set(glob.glob("/dev/input/event*")) | {n for n, _, _ in pads})
    files = {}
    for node in nodes:
        try:
            files[os.open(node, os.O_RDONLY | os.O_NONBLOCK)] = node
        except OSError as exc:
            log("cannot read %s: %s" % (node, exc))
    if not files:
        return 0
    log("%s writes a PNG to %s" % (label, directory))

    debug = os.environ.get("MCPE_SCREENSHOT_DEBUG") == "1"
    if debug:
        log("debug: reporting every button, chord needs %s"
            % " + ".join("/".join("0x%x" % c for c in sorted(g)) for g in combo))

    held: set[int] = set()
    armed = True
    while True:
        ready, _, _ = select.select(list(files), [], [], 30)
        for fd in ready:
            try:
                data = os.read(fd, EVENT_SIZE * 64)
            except OSError:
                continue
            for offset in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                _, _, etype, code, value = struct.unpack_from(
                    EVENT_FORMAT, data, offset)
                if etype != EV_KEY:
                    continue
                if value:
                    held.add(code)
                else:
                    held.discard(code)
                if debug:
                    log("debug: %s 0x%x %s -> held %s"
                        % (files[fd], code, "down" if value else "up",
                           sorted("0x%x" % c for c in held) or "none"))
        if all(group & held for group in combo):
            if armed:
                armed = False
                capture(directory)
        else:
            armed = True


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
