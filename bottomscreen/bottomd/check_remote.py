#!/usr/bin/env python3
"""Assert that a remote-world map frame is labelled, live, and non-blank."""
from __future__ import annotations

import sys

from check_frame import load_ppm, px


def main() -> None:
    width, height, data = load_ppm(sys.argv[1])
    assert (width, height) == (640, 480)
    warning_pixels = 0
    arrow_pixels = 0
    for y in range(120, 330):
        for x in range(80, 560):
            red, green, blue = px(data, width, x, y)
            if (red, green, blue) == (0xE0, 0x8A, 0x5E):
                warning_pixels += 1
            if abs(red - 0x5E) < 12 and abs(green - 0xE0) < 12 and abs(blue - 0x8A) < 12:
                arrow_pixels += 1
    assert warning_pixels > 20, "MAP UNAVAILABLE warning was not rendered"
    assert arrow_pixels > 4, "live player arrow missing from remote-world frame"
    print("remote frame OK: labelled unavailable, live position retained")


if __name__ == "__main__":
    main()
