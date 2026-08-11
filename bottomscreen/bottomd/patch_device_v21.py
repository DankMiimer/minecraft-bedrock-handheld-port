#!/usr/bin/env python3
"""v2.1 device patch (run ON the RG DS): fixes the two issues found in
live testing 2026-07-11:
- ES powers off/disables the bottom panel (DSI-1) when launching a
  game -> re-enable it before starting bottomd, and re-assert a few
  seconds later in case ES acts after us.
- stale bottomd from unclean exits -> pkill before starting.
Idempotent."""
from pathlib import Path

p = Path("/storage/roms/ports/minecraftbedrock/run_bedrock.sh")
t = p.read_text()

if "output DSI-1 enable" in t:
    print("run_bedrock.sh: already v2.1")
else:
    anchor = ("    swaymsg 'for_window [app_id=\"bottomd\"] move container"
              " to output DSI-1, fullscreen enable' >/dev/null 2>&1\n")
    assert anchor in t, "v2 block anchor not found"
    add = (anchor +
           "    # ES disables the bottom panel for normal games —"
           " take it back\n"
           "    swaymsg \"output DSI-1 enable\" >/dev/null 2>&1\n"
           "    swaymsg \"output DSI-1 power on\" >/dev/null 2>&1\n"
           "    # no duplicate daemons from unclean exits\n"
           "    pkill -f \"bottomscreen/bottomd --backend\" 2>/dev/null\n")
    t = t.replace(anchor, add, 1)

    anchor2 = "    BOTTOMD_PID=$!\n"
    assert anchor2 in t, "pid anchor not found"
    add2 = (anchor2 +
            "    # re-assert placement in case ES touches outputs after"
            " us\n"
            "    ( sleep 4; swaymsg \"output DSI-1 enable\" >/dev/null"
            " 2>&1; swaymsg \"output DSI-1 power on\" >/dev/null 2>&1;"
            " swaymsg '[app_id=\"bottomd\"] move container to output"
            " DSI-1, fullscreen enable' >/dev/null 2>&1 ) &\n")
    t = t.replace(anchor2, add2, 1)
    p.write_text(t)
    print("run_bedrock.sh: v2.1 applied")

# faster terrain loop: ~9s cycle instead of ~19s
lp = Path("/storage/roms/ports/minecraftbedrock/bottomscreen/terrain_loop.sh")
lt = lp.read_text()
lt2 = lt.replace("  sleep 6\n", "  sleep 3\n", 1).replace(
    "  sleep 12\n", "  sleep 5\n", 1)
if lt2 != lt:
    lp.write_text(lt2)
    print("terrain_loop.sh: 9s cycle")
else:
    print("terrain_loop.sh: already fast (or pattern moved)")
