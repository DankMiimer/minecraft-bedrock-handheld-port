#!/usr/bin/env python3
"""Generate SDL-style gamecontrollerdb mapping lines for connected gamepads,
using the SAME button numbering as mcpelauncher's linux-gamepad backend
(buttons indexed ascending by evdev code starting at BTN_JOYSTICK=288,
wrapping to codes 0..287 afterwards; axes indexed ascending over non-hat ABS
codes; hats numbered over ABS_HAT pairs).

Reads /proc/bus/input/devices, prints one mapping line per gamepad-like
device. Optionally pass existing-GUIDs as arguments to skip known pads.
"""
import sys

BTN_JOYSTICK = 0x120  # 288
KEY_MAX_BITS = 768

# evdev key code -> SDL mapping element. Nintendo-style orientation to match
# the hand-tuned RG34XX-SP / RG DS lines (physical A = east = confirm).
BUTTON_NAMES = {
    0x130: "b",              # BTN_SOUTH
    0x131: "a",              # BTN_EAST
    0x133: "x",              # BTN_NORTH
    0x134: "y",              # BTN_WEST
    0x136: "leftshoulder",   # BTN_TL
    0x137: "rightshoulder",  # BTN_TR
    0x138: "lefttrigger",    # BTN_TL2
    0x139: "righttrigger",   # BTN_TR2
    0x13a: "back",           # BTN_SELECT
    0x13b: "start",          # BTN_START
    0x13c: "guide",          # BTN_MODE
    0x13d: "leftstick",      # BTN_THUMBL
    0x13e: "rightstick",     # BTN_THUMBR
    0x220: "dpup",           # BTN_DPAD_UP
    0x221: "dpdown",
    0x222: "dpleft",
    0x223: "dpright",
}
ABS_HAT0X, ABS_HAT3Y = 0x10, 0x17


def parse_bitmap(words):
    """'f00000000 0 0 7fdb...' (MSB word first) -> set of set bit indices."""
    bits = set()
    words = [int(w, 16) for w in words]
    words.reverse()  # now index 0 = lowest word
    for wi, w in enumerate(words):
        b = 0
        while w:
            if w & 1:
                bits.add(wi * 64 + b)
            w >>= 1
            b += 1
    return bits


def sdl_guid(bus, vendor, product, version):
    def le16(v):
        return f"{v & 0xff:02x}{(v >> 8) & 0xff:02x}"
    return f"{le16(bus)}0000{le16(vendor)}0000{le16(product)}0000{le16(version)}0000"


def gen_mapping(dev):
    keys = dev.get("KEY", set())
    absbits = dev.get("ABS", set())
    # linux-gamepad button numbering: i from BTN_JOYSTICK ascending, wrap.
    order = list(range(BTN_JOYSTICK, KEY_MAX_BITS)) + list(range(0, BTN_JOYSTICK))
    idx = 0
    parts = []
    for code in order:
        if code in keys:
            name = BUTTON_NAMES.get(code)
            if name:
                parts.append(f"{name}:b{idx}")
            idx += 1
    # Map only recognized evdev stick pairs. Arbitrarily assigning the first
    # four ABS codes turns triggers/accelerometers into sticks on unknown
    # controllers. Unusual GPIO layouts should contribute a device mapping
    # (and remain button/dpad-usable until then) rather than receive a wrong
    # synthetic mapping.
    nonhat = [c for c in sorted(absbits) if not ABS_HAT0X <= c <= ABS_HAT3Y]
    axis_index = {code: index for index, code in enumerate(nonhat)}
    pairs = []
    if 0x00 in axis_index and 0x01 in axis_index:  # ABS_X/ABS_Y
        pairs.append(("leftx", 0x00)); pairs.append(("lefty", 0x01))
    if 0x03 in axis_index and 0x04 in axis_index:  # ABS_RX/ABS_RY
        pairs.append(("rightx", 0x03)); pairs.append(("righty", 0x04))
    elif 0x02 in axis_index and 0x05 in axis_index:  # ABS_Z/ABS_RZ
        pairs.append(("rightx", 0x02)); pairs.append(("righty", 0x05))
    for name, code in pairs:
        parts.append(f"{name}:a{axis_index[code]}")
    # hat dpad (only if no button dpad present)
    if ABS_HAT0X in absbits and ABS_HAT0X + 1 in absbits and 0x220 not in keys:
        parts.append("dpup:h0.1"); parts.append("dpright:h0.2")
        parts.append("dpdown:h0.4"); parts.append("dpleft:h0.8")
    guid = sdl_guid(dev["bus"], dev["vendor"], dev["product"], dev["version"])
    return f'{guid},{dev["name"]},' + ",".join(parts) + ","


def main():
    skip_guids = {g.strip().lower() for g in sys.argv[1:] if g.strip()}
    devs, cur = [], {}
    for line in open("/proc/bus/input/devices"):
        line = line.rstrip("\n")
        if not line:
            if cur: devs.append(cur); cur = {}
        elif line.startswith("I:"):
            for kv in line[2:].split():
                k, _, v = kv.partition("=")
                cur[{"Bus": "bus", "Vendor": "vendor",
                     "Product": "product", "Version": "version"}.get(k, k)] = int(v, 16)
        elif line.startswith("N: Name="):
            cur["name"] = line.split("=", 1)[1].strip('"')
        elif line.startswith("B: KEY="):
            cur["KEY"] = parse_bitmap(line.split("=", 1)[1].split())
        elif line.startswith("B: ABS="):
            cur["ABS"] = parse_bitmap(line.split("=", 1)[1].split())
    if cur: devs.append(cur)

    for d in devs:
        keys = d.get("KEY", set())
        absbits = d.get("ABS", set())
        nonhat = [c for c in absbits if not ABS_HAT0X <= c <= ABS_HAT3Y]
        # gamepad-like: has BTN_GAMEPAD (BTN_SOUTH) plus axes or a hat
        if 0x130 not in keys or (not nonhat and ABS_HAT0X not in absbits):
            continue
        line = gen_mapping(d)
        if line.split(",", 1)[0].lower() in skip_guids:
            continue
        print(line)


if __name__ == "__main__":
    main()
