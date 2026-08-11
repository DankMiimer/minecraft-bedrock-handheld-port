#!/usr/bin/env python3
"""apply_container_patch.py — wire MCPE_TF_CONTAINER_OPEN in the client.

Until now mcpe_telemetry_container() existed in telemetry_writer.c but
NOTHING in the client ever called it — only test_feed did. The flag was
therefore always clear on real hardware, and bottomd's container branch
was dead code (DUALSCREEN_RESEARCH_DB.md §3.2 candidate C).

This patches mcpelauncher-client/src/jni/main_activity.h to drive the
flag from cursor-lock state:

    lockCursor()    -> gameplay has the pointer   -> container closed
    unlockCursor()  -> a UI screen has it         -> container open

Why cursor lock and not a ScreenController hook: 1.20.62.02 is fully
stripped and exports no ScreenController symbols at all (see
bottomscreen/analysis/SYMBOL_FINDINGS.md), so a symbol hook would only
work on 1.16.221.01. Cursor lock lives in the launcher and is identical
on every version.

Idempotent: re-running on an already-patched file is a no-op.
Usage: apply_container_patch.py [path/to/main_activity.h]
"""
import shutil
import sys

DEFAULT = ("/root/mcpe/work/source/mcpelauncher/mcpelauncher-client/"
           "src/jni/main_activity.h")

DECL = """
// Weak telemetry hooks — see bottomscreen/telemetry/. Declared weak so a
// build without the telemetry module links and runs unchanged.
extern "C" {
__attribute__((weak)) void mcpe_telemetry_container(int open);
}
"""

HELPER = """
    // ---- MCPE_TF_CONTAINER_OPEN feed -------------------------------
    // Bedrock unlocks the mouse cursor whenever a UI screen takes over
    // the world view (inventory, crafting table, chest, pause, chat) and
    // re-locks it on return to gameplay. Cursor-lock state is therefore
    // a VERSION-INDEPENDENT "a screen is up" signal, which matters
    // because 1.20.62.02 is fully stripped and exports no
    // ScreenController symbols to hook.
    //
    // NOTE the signal is BROADER than "container": pause and chat also
    // unlock the cursor. For the bottom screen that is the semantics we
    // want — "the player is in a UI, not in the world".
    static void telemetryContainer(int open) {
        if(&mcpe_telemetry_container)
            mcpe_telemetry_container(open);
    }

"""

LOCK_OLD = """    void lockCursor() {
        window->setCursorDisabled(true);
    }"""
LOCK_NEW = """    void lockCursor() {
        window->setCursorDisabled(true);
        telemetryContainer(0);
    }"""

UNLOCK_OLD = """    void unlockCursor() {
        window->setCursorDisabled(false);
    }"""
UNLOCK_NEW = """    void unlockCursor() {
        window->setCursorDisabled(false);
        telemetryContainer(1);
    }"""


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    if "telemetryContainer" in src:
        print("already patched, nothing to do: %s" % path)
        return 0

    for needle in (LOCK_OLD, UNLOCK_OLD, "#include <log.h>"):
        if needle not in src:
            print("REFUSING: anchor not found in %s:\n---\n%s\n---"
                  % (path, needle))
            return 1

    backup = path + ".pre-container"
    shutil.copy2(path, backup)

    src = src.replace("#include <log.h>", "#include <log.h>\n" + DECL, 1)
    src = src.replace(LOCK_OLD, HELPER + LOCK_NEW, 1)
    src = src.replace(UNLOCK_OLD, UNLOCK_NEW, 1)

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print("patched %s (backup: %s)" % (path, backup))
    print("rebuild with eglut_build/_container_build_incr.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
