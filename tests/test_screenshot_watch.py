#!/usr/bin/env python3
"""Chord selection for the in-game screenshot shortcut.

Every pad fact asserted here was measured on the reference RG34XX-SP: its
driver registers BTN_MODE but never BTN_THUMBL/BTN_THUMBR, and the physical
MENU key emits 0x162 rather than BTN_MODE.
"""
from __future__ import annotations

import importlib.util
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE = (ROOT / "portmaster" / "minecraftbedrock" / "minecraftbedrock"
          / "screenshot_watch.py")

spec = importlib.util.spec_from_file_location("screenshot_watch", MODULE)
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)

FULL_PAD = {0x130, 0x131, 0x136, 0x137, 0x138, 0x139, 0x13A, 0x13B, 0x13C,
            0x13D, 0x13E}
RG34XXSP = {0x130, 0x131, 0x132, 0x133, 0x134, 0x135, 0x136, 0x137, 0x138,
            0x139, 0x13A, 0x13B, 0x13C, 0x162}

os.environ.pop("MCPE_SCREENSHOT_COMBO", None)

combo, label = watch.pick_combo(FULL_PAD)
assert combo == [watch.BUTTONS["menu"], {0x13D}], combo
assert "L3" in label, label

combo, label = watch.pick_combo(RG34XXSP)
assert combo == [watch.BUTTONS["menu"], {0x139}], combo
assert "R2" in label and "no L3" in label, label

# The RG34XX-SP prints labels one place off the names its driver sends, and one
# MENU press emits two codes. Measured on the device: L3 is 0x139, R3 0x13c,
# MENU 0x138 and 0x162, L2 0x13a, R2 0x13b. Without the layout the chord would
# silently watch for buttons this pad never sends.
table, layout = watch.button_table(["Anbernic RG34XX-SP Controller"])
assert layout == "Anbernic RG34XX-SP Controller", layout
assert table["l3"] == {0x139} and table["r3"] == {0x13C}, table["l3"]
assert table["menu"] == {0x138, 0x162}, table["menu"]
assert table["a"] == {0x130}, "layout dropped the untouched buttons"

combo, label = watch.pick_combo(RG34XXSP | table["l3"], table)
assert combo == [{0x138, 0x162}, {0x139}], combo
assert label == "menu+L3", label
for menu_code in (0x138, 0x162):
    assert all(group & {menu_code, 0x139} for group in combo), menu_code
assert not all(group & {0x139} for group in combo), "L3 alone fired the chord"
assert not all(group & {0x138} for group in combo), "menu alone fired the chord"

# An unknown pad keeps the kernel's own names.
table, layout = watch.button_table(["Some Other Pad"])
assert layout == "" and table == dict(watch.BUTTONS), layout

# Either MENU code satisfies the chord on pads that send BTN_MODE.
combo, _ = watch.pick_combo(RG34XXSP)
for menu_code in (0x13C, 0x162):
    assert all(group & {menu_code, 0x139} for group in combo), menu_code

os.environ["MCPE_SCREENSHOT_COMBO"] = "menu+select"
combo, label = watch.pick_combo(RG34XXSP)
assert combo == [watch.BUTTONS["menu"], {0x13A}], combo
assert label == "menu+select", label

# An override is expressed in the pad's own labels when a layout applies.
table, _ = watch.button_table(["Anbernic RG34XX-SP Controller"])
os.environ["MCPE_SCREENSHOT_COMBO"] = "menu+r3"
combo, label = watch.pick_combo(RG34XXSP, table)
assert combo == [{0x138, 0x162}, {0x13C}], combo

# An unusable override falls back rather than leaving no shortcut at all.
os.environ["MCPE_SCREENSHOT_COMBO"] = "menu+nosuchbutton"
combo, label = watch.pick_combo(RG34XXSP)
assert combo == [watch.BUTTONS["menu"], {0x139}], combo
os.environ.pop("MCPE_SCREENSHOT_COMBO")

# A pad-less system must not claim a shortcut exists.
assert watch.pick_combo(set())[0], "no chord was offered at all"

print("screenshot chord tests passed")
sys.exit(0)
