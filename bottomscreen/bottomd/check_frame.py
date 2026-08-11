#!/usr/bin/env python3
"""Assert a bottomd PPM frame looks like the dual-screen companion shell:
- the player-arrow green appears near the paper-map center
- the persistent status header and bottom Minecraft-style tabs are drawn
Usage: check_frame.py frame.ppm
"""
import sys

def load_ppm(path):
    with open(path, "rb") as f:
        assert f.readline().strip() == b"P6"
        line = f.readline()
        while line.startswith(b"#"):
            line = f.readline()
        w, h = map(int, line.split())
        assert int(f.readline()) == 255
        data = f.read(w * h * 3)
    return w, h, data

def px(data, w, x, y):
    i = (y * w + x) * 3
    return data[i], data[i + 1], data[i + 2]

def main():
    w, h, data = load_ppm(sys.argv[1])
    assert (w, h) == (640, 480), f"unexpected size {w}x{h}"

    # arrow green 0x5ee08a within 20px of center
    found = any(
        abs(r - 0x5E) < 12 and abs(g - 0xE0) < 12 and abs(b - 0x8A) < 12
        for y in range(h // 2 - 20, h // 2 + 20)
        for x in range(w // 2 - 20, w // 2 + 20)
        for (r, g, b) in [px(data, w, x, y)]
    )
    assert found, "player arrow not found near center"

    # Persistent status header.
    r, g, b = px(data, w, 5, 5)
    assert (r, g, b) == (0x18, 0x14, 0x12), f"status header missing {r,g,b}"

    # Bottom tab strip remains below the five button cells.
    r, g, b = px(data, w, 5, h - 2)
    assert (r, g, b) == (0x10, 0x10, 0x10), f"tab strip missing {r,g,b}"

    print("frame OK: arrow centered, status HUD and tab strip drawn")

if __name__ == "__main__":
    main()
