#!/usr/bin/env python3
"""osk_supervisor.py — the bottom screen's landlord.

WHY THIS EXISTS, and why osk_watchdog.py was not enough (2026-07-27):
the watchdog is armed BY osk_show.sh, so it only ever owns a cover that
osk_show.sh raised. On-device evidence showed the Thor Keyboard window
fullscreen on the companion output with NO watchdog armed, no state file and no log —
i.e. the cover appeared by some path osk_show.sh never touched.

The reason is structural: run_bedrock.sh installs

    for_window [title="^Thor Keyboard"] move container to output <companion>, \
        fullscreen enable

so the INSTANT that window maps, for any reason whatsoever, sway
fullscreens it over bottomd. The app's own hidden/shown state is
irrelevant — a mapped window is a cover. Anything that owns the cover
must therefore watch the COMPOSITOR, not our own scripts.

This supervisor does that. It polls sway, and when the keyboard has been
covering the companion output for longer than --grace with no live claim, it runs
osk_hide.sh. It is safe to leave running for a whole session: it does
nothing at all while the bottom screen is visible.

A "live claim" is /tmp/mcpe_osk_state, written by osk_show.sh while the
game genuinely wants a keyboard. With a claim the grace is --claim-grace
(long — you may be typing a sign). With no claim it is --grace (short —
nobody asked for this thing).

Run standalone:
  python3 osk_supervisor.py --log /path/osk_supervisor.log
"""
import argparse
import json
import os
import subprocess
import sys
import time

TITLE = "Thor Keyboard"


def log(f, msg):
    line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
    sys.stderr.write(line + "\n")
    sys.stderr.flush()
    if f:
        f.write(line + "\n")
        f.flush()


def sway(env, *args):
    try:
        out = subprocess.run(["swaymsg", "-t"] + list(args),
                             capture_output=True, timeout=5, env=env)
        if out.returncode != 0:
            return None
        return json.loads(out.stdout.decode("utf-8", "replace"))
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def walk(node, out, output=None):
    """Collect (output, name, app_id, visible, fullscreen) for leaves."""
    if node.get("type") == "output":
        output = node.get("name")
    name = node.get("name")
    if node.get("pid") or node.get("app_id"):
        out.append({
            "output": output,
            "name": name or "",
            "app_id": node.get("app_id") or "",
            "visible": bool(node.get("visible")),
            "fullscreen": node.get("fullscreen_mode", 0),
        })
    for key in ("nodes", "floating_nodes"):
        for child in node.get(key, []) or []:
            walk(child, out, output)


def screen_state(env):
    """-> (keyboard_covering, bottomd_visible) or (None, None) if unknown."""
    tree = sway(env, "get_tree")
    if not tree:
        return (None, None)
    leaves = []
    walk(tree, leaves)
    kb = False
    bd_visible = False
    for w in leaves:
        if TITLE in w["name"] and w["visible"]:
            kb = True
        if w["app_id"] == "bottomd":
            bd_visible = w["visible"]
    return (kb, bd_visible)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hide-cmd", default="/storage/roms/ports/"
                    "minecraftbedrock/bottomscreen/osk_hide.sh")
    ap.add_argument("--state", default="/tmp/mcpe_osk_state")
    ap.add_argument("--log", default="")
    ap.add_argument("--poll-s", type=float, default=0.5)
    # No one claimed this cover -> take it down fast. This is the common
    # case and it is ALWAYS a bug: measured on-device 2026-07-27, opening
    # the inventory makes the game show-then-hide the keyboard inside 2 s
    # (the creative search box takes focus), but the Thor keyboard is a
    # python/SDL app with a multi-second cold start, so its window maps
    # ~1 s AFTER the hide already ran. osk_hide.sh is one-shot and has
    # been consumed, so the window is orphaned the instant it appears.
    # 1.5 s is enough to avoid fighting a legitimate show still settling.
    ap.add_argument("--grace", type=float, default=1.5)
    # the game asked for a keyboard -> you may be typing; be patient
    ap.add_argument("--claim-grace", type=float, default=90.0)
    ap.add_argument("--once", action="store_true",
                    help="observe and log only, never hide")
    args = ap.parse_args()

    env = dict(os.environ)
    env.setdefault("XDG_RUNTIME_DIR", "/var/run/0-runtime-dir")
    env.setdefault("SWAYSOCK",
                   env["XDG_RUNTIME_DIR"] + "/sway-ipc.0.sock")

    f = open(args.log, "a") if args.log else None
    log(f, "supervisor start (grace=%.0fs claim-grace=%.0fs observe=%s)"
        % (args.grace, args.claim_grace, args.once))

    covering_since = None
    last_report = None
    while True:
        time.sleep(args.poll_s)

        kb, bd = screen_state(env)
        if kb is None:
            continue  # sway not reachable; say nothing, do nothing

        claim = os.path.exists(args.state)
        state = (kb, bd, claim)
        if state != last_report:
            log(f, "keyboard_visible=%s bottomd_visible=%s claim=%s"
                % (kb, bd, claim))
            last_report = state

        if not kb:
            covering_since = None
            continue

        if covering_since is None:
            covering_since = time.monotonic()
        held = time.monotonic() - covering_since
        limit = args.claim_grace if claim else args.grace
        if held < limit:
            continue

        if args.once:
            log(f, "OBSERVE-ONLY: would hide now (held %.1fs, claim=%s)"
                % (held, claim))
            covering_since = time.monotonic()  # re-arm, keep observing
            continue

        log(f, "UNCOVERING: keyboard held the panel %.1fs (claim=%s)"
            % (held, claim))
        try:
            subprocess.call(["sh", args.hide_cmd], timeout=20, env=env)
        except (OSError, subprocess.SubprocessError) as e:
            log(f, "hide cmd failed: %s" % e)
        covering_since = None
        time.sleep(1.0)


if __name__ == "__main__":
    sys.exit(main())
