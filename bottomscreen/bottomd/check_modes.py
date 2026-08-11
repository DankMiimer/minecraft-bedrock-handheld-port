#!/usr/bin/env python3
"""check_modes.py — regression guard for the bottomd mode state machine.

Guards the two failure modes that motivated the state machine
(DUALSCREEN_RESEARCH_DB.md §3.2):

  blank   a frame that is essentially all black — the "bottom screen went
          black when I opened the inventory" symptom. Only BLANK and
          MIRROR may look like this, and neither is reachable by default.
  usable  a frame carrying real map content (many distinct colours, some
          brightness) — what MINIMAP and STALE must always produce.

Usage: check_modes.py blank|usable FRAME.ppm [FRAME.ppm ...]
Exits non-zero with a diagnosis if any frame fails the assertion.
"""
import sys


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    # P6 header: magic, width, height, maxval — whitespace separated
    fields, pos = [], 0
    while len(fields) < 4:
        while pos < len(data) and data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            while pos < len(data) and data[pos] != 0x0A:
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos : pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    pos += 1
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos : pos + w * h * 3]


def stats(path):
    w, h, px = read_ppm(path)
    n = w * h
    total = 0
    colors = set()
    dark = 0
    magenta = 0
    for i in range(0, n * 3, 3):
        r, g, b = px[i], px[i + 1], px[i + 2]
        lum = r + g + b
        total += lum
        if lum < 24:
            dark += 1
        if r > 200 and g < 60 and b > 200:
            magenta += 1
        if len(colors) < 4096:
            colors.add((r, g, b))
    return {
        "mean_lum": total / (n * 3),
        "dark_frac": dark / n,
        "colors": len(colors),
        "magenta_frac": magenta / n,
    }


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    want, paths = sys.argv[1], sys.argv[2:]
    bad = 0
    for p in paths:
        s = stats(p)
        desc = (
            f"mean_lum={s['mean_lum']:.1f} dark_frac={s['dark_frac']:.3f} "
            f"colors={s['colors']}"
        )
        if want == "usable":
            # real map content: not overwhelmingly black, and varied
            ok = s["dark_frac"] < 0.90 and s["colors"] >= 8
        elif want == "blank":
            ok = s["dark_frac"] > 0.90
        elif want == "mirror":
            # test_mirror publishes magenta; nothing bottomd draws itself
            # is anywhere near it, so this proves the blit actually ran
            ok = s["magenta_frac"] > 0.50
            desc += f" magenta_frac={s['magenta_frac']:.3f}"
        elif want == "notmirror":
            ok = s["magenta_frac"] < 0.05
            desc += f" magenta_frac={s['magenta_frac']:.3f}"
        else:
            print(f"unknown assertion '{want}'")
            return 2
        print(f"{'OK  ' if ok else 'FAIL'} {want:6} {p}  {desc}")
        if not ok:
            bad += 1
    if bad:
        print(f"\n{bad} frame(s) failed '{want}'.")
        if want == "usable":
            print(
                "A near-black frame here means a mode blanked the panel. "
                "Check the 'bottomd: mode X -> Y' lines for which one."
            )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
