#!/usr/bin/env python3
"""apply_mirror_patch.py — wire the inventory MIRROR into the client.

Three edits, all idempotent:

1. fake_egl.cpp — capture the back buffer in eglSwapBuffers, BEFORE the
   swap (the rendered frame is still there). mcpe_mirror_capture() is a
   cheap early-out unless a capture is genuinely due, so the gameplay
   path pays essentially nothing: it only runs while a container is open
   and only at MCPE_MIRROR_FPS.

2. main_activity.h — when the optional cursor signal exists, drive
   mcpe_mirror_set_active() from it. On Bedrock 1.16 that signal is absent;
   bottomd's heartbeat request channel is the authoritative fallback.

3. CMakeLists.txt — add src/telemetry/mirror_writer.c to the client
   target.

Refuses on anchor mismatch rather than guessing. Backs up each file it
touches as <file>.pre-mirror.

Copies the mirror module sources itself.

Usage: apply_mirror_patch.py [source_root]
  source_root defaults to /root/mcpe/work/source/mcpelauncher
"""
import os
import shutil
import sys

DEFAULT_ROOT = "/root/mcpe/work/source/mcpelauncher"

EGL_INC_OLD = '#include "telemetry/telemetry_writer.h"'
EGL_INC_NEW = ('#include "telemetry/telemetry_writer.h"\n'
               '#include "telemetry/mirror_writer.h"')

EGL_SWAP_OLD = """    auto frameStart = FrameMetricsState::Clock::now();
    ((GameWindow *)surface)->swapBuffers();"""
EGL_SWAP_NEW = """    auto frameStart = FrameMetricsState::Clock::now();
    // Inventory MIRROR: grab the finished frame BEFORE it is swapped
    // away. No-op unless a container is open and a capture is due, so
    // the normal gameplay path is untouched.
    {
        int mw = 0, mh = 0;
        ((GameWindow *)surface)->getWindowSize(mw, mh);
        mcpe_mirror_capture(mw, mh);
    }
    ((GameWindow *)surface)->swapBuffers();"""

MA_DECL_OLD = "__attribute__((weak)) void mcpe_telemetry_container(int open);"
MA_DECL_NEW = ("__attribute__((weak)) void mcpe_telemetry_container(int open);\n"
               "__attribute__((weak)) void mcpe_mirror_set_active(int active);")

MA_BODY_OLD = """    static void telemetryContainer(int open) {
        if(&mcpe_telemetry_container)
            mcpe_telemetry_container(open);
    }"""
MA_BODY_NEW = """    static void telemetryContainer(int open) {
        if(&mcpe_telemetry_container)
            mcpe_telemetry_container(open);
        // Same signal gates the mirror capture: readback happens only
        // while a UI screen actually owns the view.
        if(&mcpe_mirror_set_active)
            mcpe_mirror_set_active(open);
    }"""

CM_OLD = "src/telemetry/telemetry_writer.c"
CM_NEW = "src/telemetry/telemetry_writer.c src/telemetry/mirror_writer.c"


def patch(path, edits, marker):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    if marker in src:
        print("  already patched: %s" % path)
        return True
    for old, _new in edits:
        if old not in src:
            print("  REFUSING: anchor not found in %s:\n---\n%s\n---"
                  % (path, old))
            return False
    shutil.copy2(path, path + ".pre-mirror")
    for old, new in edits:
        src = src.replace(old, new, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print("  patched: %s (backup .pre-mirror)" % path)
    return True


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ROOT
    client = os.path.join(root, "mcpelauncher-client")
    ok = True

    telemetry = os.path.join(client, "src", "telemetry")
    os.makedirs(telemetry, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    for name in ("mirror_writer.c", "mirror_writer.h", "mcpe_mirror_abi.h"):
        shutil.copy2(os.path.join(here, name), os.path.join(telemetry, name))
    print("0. copied mirror sources -> %s" % telemetry)

    print("1. fake_egl.cpp (capture hook)")
    ok &= patch(os.path.join(client, "src/fake_egl.cpp"),
                [(EGL_INC_OLD, EGL_INC_NEW), (EGL_SWAP_OLD, EGL_SWAP_NEW)],
                "mcpe_mirror_capture")

    print("2. main_activity.h (optional cursor-signal fast path)")
    activity = os.path.join(client, "src/jni/main_activity.h")
    with open(activity, "r", encoding="utf-8") as f:
        activity_text = f.read()
    if "mcpe_mirror_set_active" in activity_text:
        print("  already patched: %s" % activity)
    elif MA_DECL_OLD in activity_text and MA_BODY_OLD in activity_text:
        ok &= patch(activity,
                    [(MA_DECL_OLD, MA_DECL_NEW),
                     (MA_BODY_OLD, MA_BODY_NEW)],
                    "mcpe_mirror_set_active")
    else:
        print("  no cursor telemetry anchor; using request channel only")

    print("3. CMakeLists.txt (add mirror_writer.c)")
    ok &= patch(os.path.join(client, "CMakeLists.txt"),
                [(CM_OLD, CM_NEW)], "mirror_writer.c")

    if not ok:
        print("\nFAILED — nothing further was changed.")
        return 1
    print("\nOK. Mirror capture and the request channel are wired; rebuild "
          "the client.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
