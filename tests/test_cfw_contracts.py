#!/usr/bin/env python3
"""Per-CFW conformance contracts (docs/CFW-CONTRACTS.md).

The capability half of each contract is asserted by tests/test_platform.sh
against fixtures built from captured device output. This file asserts the
script-level half: the behaviours that are decided in shell rather than by the
probe, and that no fixture can catch.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / "portmaster/minecraftbedrock/minecraftbedrock"
LAUNCHER = ROOT / "portmaster/minecraftbedrock/Minecraft Bedrock.sh"
CONTRACTS = ROOT / "docs/CFW-CONTRACTS.md"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_every_supported_cfw_has_a_written_contract():
    text = read(CONTRACTS)
    for cfw in ("Knulli", "ROCKNIX", "muOS", "dArkOS"):
        assert f"## {cfw}" in text, cfw
    # Clauses no device backs must say so, so nobody mistakes them for evidence.
    # muOS moved out of this set on 2026-08-24 when an RG34XX-SP running
    # JACARANDA was captured; dArkOS is what remains.
    for cfw in ("dArkOS",):
        heading = next(line for line in text.splitlines() if line.startswith(f"## {cfw}"))
        assert "no reference device" in heading, heading
    assert "**measured**" in text and "**assumed**" in text


def test_knulli_never_stops_emulationstation():
    """emulatorlauncher owns the ES lifecycle; stopping it gives two input owners."""
    weston = read(PAYLOAD / "weston_launch.sh")
    stop = weston.split("stop_emulationstation()", 1)[1].split("start_emulationstation", 1)[0]
    assert "is_knulli" in stop
    assert re.search(r"is_knulli.*\n\s*return", stop), \
        "the Knulli branch must return before touching ES"
    # And the whole legacy path stays behind the explicit opt-in.
    assert '[ "${MCPE_MANAGE_FRONTEND:-0}" = 1 ] || return' in stop


def test_knulli_keeps_its_shared_tree_hidden_and_others_do_not():
    """ES inventories visible directories under roms/ports; a version is tens of
    thousands of files. The workaround must not leak to other firmwares."""
    migrate = read(PAYLOAD / "lib/migrate_data.sh")
    assert "mcpe_prepare_knulli_shared_root" in migrate
    prepare = migrate.split("mcpe_prepare_knulli_shared_root()", 1)[1][:400]
    assert "mcpe_is_knulli || return 0" in prepare, \
        "the hidden root must be gated on Knulli alone"
    assert "mcpe_is_cfw knulli" in migrate


def test_muos_manages_its_own_frontend_and_both_sd_roots():
    launcher = read(LAUNCHER)
    weston = read(PAYLOAD / "weston_launch.sh")
    armhf = read(PAYLOAD / "run_bedrock32.sh")

    # muOS owns the framebuffer outside a port, so this is the one firmware
    # where the port stops and restarts the frontend itself.
    for text in (launcher, weston, armhf):
        assert "frontend.sh" in text and "muxlaunch" in text
    assert "/opt/muos/script/mux/frontend.sh launcher" in weston
    # Restart must not inherit the port's environment.
    restart = weston.split("start_emulationstation()", 1)[1][:900]
    assert "unset" in restart and "GAMEDIR" in restart

    # Both SD roots, uppercase MUOS, and the split install layout.
    for marker in ("/mnt/mmc/MUOS", "/mnt/sdcard/MUOS"):
        assert marker in launcher, marker
    assert "/mnt/mmc/ports/" in launcher and "/mnt/sdcard/ports/" in launcher


def test_rocknix_nests_under_sway_and_never_takes_drm_master():
    """sway owns /dev/dri; selecting KMSDRM there fails to get DRM master."""
    armhf = read(PAYLOAD / "run_bedrock32.sh")
    assert 'pidof sway' in armhf
    video = armhf.split("SWAY_MODE=0", 1)[1][:700]
    assert "wayland" in video and "kmsdrm" in video
    assert re.search(r'SWAY_MODE.*=.*1.*\n.*SDL_VIDEODRIVER=wayland', video) or \
        'export SDL_VIDEODRIVER=wayland' in video

    weston = read(PAYLOAD / "weston_launch.sh")
    # A launch over SSH has no session environment of its own.
    adopt = weston.split("SWAY_MODE=1", 1)[1][:900]
    for name in ("XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "SWAYSOCK"):
        assert name in adopt, name
    assert "/proc/$SWAY_PID/environ" in adopt

    # busybox has no nproc; the reference RGDS confirmed it is absent.
    runner = read(PAYLOAD / "run_bedrock.sh")
    assert "nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo" in runner


def test_arkos_family_layout_and_privilege_are_honoured():
    launcher = read(LAUNCHER)
    # The tools path from the issue #1 log must be searched for control.txt.
    assert "/opt/system/Tools/$PM_DIR" in launcher
    common = read(PAYLOAD / "lib/common.sh")
    assert "/opt/system/Tools/PortMaster" in common, \
        "ArkOS layout inference lost its marker"
    # ESUDO is empty on both measured firmwares and sudo on this family, so it
    # must always be honoured rather than assumed empty.
    for relative in ("weston_launch.sh", "run_bedrock32.sh"):
        text = read(PAYLOAD / relative)
        assert 'ESUDO="${ESUDO:-}"' in text, relative
        assert "$ESUDO" in text, relative


def test_the_probe_fixtures_are_captured_not_invented():
    """The reference devices report strings a plausible guess would get wrong."""
    fixtures = read(ROOT / "tests/test_platform.sh")
    # Knulli calls itself Batocera everywhere except OS_NAME.
    assert "NAME=Batocera.linux" in fixtures and 'OS_NAME="knulli"' in fixtures
    # It never says h700; the profile matches on the SoC string instead.
    assert "allwinner,h616" in fixtures and "sun50iw9p1" in fixtures
    assert "Anbernic RG34XX-SP" in fixtures
    # RGDS identifies by model, and its compatible leads with the board name.
    assert "anbernic,rg-ds" in fixtures
    assert 'OS_NAME="ROCKNIX"' in fixtures
    # muOS reports its model as the bare SoC string and exposes no DRM node,
    # both of which the earlier invented fixture got wrong.
    assert "MustardOS" in fixtures and "JACARANDA" in fixtures
    assert "sun50iw9" in fixtures
    # Fixtures with no device behind them are labelled.
    assert "No dArkOS reference device" in fixtures


def test_the_selftest_answers_before_anything_is_installed():
    """The two firmwares with no reference device need a way to report facts.

    It must work with no Bedrock version present, never start the game, and
    produce something safe to paste into a public issue.
    """
    selftest = read(PAYLOAD / "selftest.sh")
    # Every area a device report is asked for.
    for area in ("firmware", "device", "client", "runtimes", "audio",
                 "controls", "storage", "installed Bedrock versions",
                 "failsafe ladder"):
        assert f'head_ "{area}"' in selftest or f'"{area}"' in selftest, area
    # It must not launch anything.
    for forbidden in ("run_bedrock.sh", "weston_launch.sh", "mcpe_failsafe_apply"):
        assert forbidden not in selftest, forbidden
    # Absent versions are a warning, not a verdict that the device is broken.
    assert "no Bedrock version installed" in selftest
    assert 'bad "no playable Bedrock version"' in selftest
    # Redaction, and the version-shape protection that keeps it useful.
    for needle in ("REDACTED_EMAIL", "REDACTED_IP", "@D@"):
        assert needle in selftest, needle
    # Reachable from the menu as well as over SSH.
    assert 'key = "network"' in read(PAYLOAD / "menu/main.lua")
    assert 'quitWith("selftest")' in read(PAYLOAD / "menu/main.lua")
    assert "selftest)" in read(LAUNCHER)


def test_the_bug_report_asks_for_what_actually_diagnoses_a_failure():
    """Reports used to arrive without the facts needed to act on them.

    Issue #2 has an empty log field because the device froze before anything
    was written; the template now asks for the self test and the breadcrumb
    instead, both of which survive that.
    """
    template = read(ROOT / ".github/ISSUE_TEMPLATE/bug_report.yml")
    assert "selftest" in template and "selftest.sh" in template
    # Every firmware in the contracts must be selectable, or reports land
    # under "other" and lose the one field that routes them.
    for cfw in ("Knulli", "muOS", "ROCKNIX", "ArkOS"):
        assert cfw in template, cfw
    # The breadcrumb and hang report are what a frozen device leaves behind.
    assert "stage.txt" in template and "stage.prev.txt" in template
    assert "hang-report.txt" in template
    # Still must not invite copyrighted or private material.
    assert "Do not attach Minecraft APKs" in template
    assert "I did not attach APKs" in template

    # The checklist that decides when a firmware stops being "best effort".
    testing = read(ROOT / "TESTING.md")
    assert "Per-CFW acceptance checklist" in testing
    for row in ("Self test", "Clean exit", "Frontend restored", "Text entry",
                "World load", "Relaunch"):
        assert row in testing, row


def test_nothing_on_the_launch_path_requires_readelf():
    """readelf is absent on the Knulli reference device."""
    for relative in ("run_bedrock.sh", "run_bedrock32.sh", "weston_launch.sh",
                     "lib/abi.sh", "lib/audio.sh", "lib/watchdog.sh",
                     "lib/platform.sh", "lib/common.sh", "lib/failsafe.sh"):
        assert "readelf" not in read(PAYLOAD / relative), relative
    assert "readelf" not in read(LAUNCHER)


if __name__ == "__main__":
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            function()
    print("CFW contract tests passed")


def test_muos_follows_the_portmaster_redirect():
    """muOS ships a stub control.txt that points at the real install.

    Stopping at the first control.txt found leaves the port with no runtimes,
    so it reports no LOVE menu and cannot offer a way to install an APK.
    """
    launcher = read(ROOT / "portmaster/minecraftbedrock/Minecraft Bedrock.sh")
    score = launcher.split("mcpe_pm_payload_score()", 1)[1].split(chr(10) + "}", 1)[0]
    for marker in ("runtimes", "libs", "funcs.txt", "device_info.txt", "PortMaster.sh"):
        assert marker in score, marker
    # The redirect is adopted only when it is richer than where it came from.
    assert 'mcpe_pm_payload_score "$controlfolder"' in launcher
    assert 'mcpe_pm_payload_score "$cf"' in launcher
    # The self test resolves the same way without sourcing anything.
    selftest = read(PAYLOAD / "selftest.sh")
    assert "mcpe_resolve_pm_root" in selftest
    contracts = read(CONTRACTS)
    assert "The redirect must be followed" in contracts


def test_a_message_has_somewhere_to_go_when_the_console_is_not_rendered():
    """muOS binds no framebuffer console, so /dev/tty1 reaches nobody."""
    message = read(PAYLOAD / "lib/message.sh")
    # The console rung stays first so the firmwares it was verified on keep it.
    assert "mcpe_console_is_visible" in message
    assert "frame buffer device" in message
    # Two further rungs exist for the firmwares that have no console.
    assert "mcpe_msg_love" in message and "mcpe_msg_framebuffer" in message
    launcher = read(ROOT / "portmaster/minecraftbedrock/Minecraft Bedrock.sh")
    show = launcher.split("show_msg() {", 1)[1].split(chr(10) + "}", 1)[0]
    assert "/dev/tty1" in show
    assert "mcpe_console_is_visible" in show
    assert "mcpe_msg_love" in show and "mcpe_msg_framebuffer" in show


def test_stopping_the_muos_frontend_is_always_paired_with_restarting_it():
    """frontend.sh is an init-started supervisor that nothing respawns."""
    message = read(PAYLOAD / "lib/message.sh")
    assert "mcpe_msg_restore_frontend" in message
    assert "/opt/muos/script/mux/frontend.sh launcher" in message
    # Every path that stops it restores it, including an interrupted draw.
    assert message.count("mcpe_msg_restore_frontend") >= 4
    assert "trap 'mcpe_msg_restore_frontend' INT TERM" in message
    contracts = read(CONTRACTS)
    assert "leaves the device" in contracts


def test_a_broken_interpreter_is_reported_as_such():
    """Installing and launching both need python3; say so before it bites."""
    common = read(PAYLOAD / "lib/common.sh")
    health = common.split("mcpe_python_health()", 1)[1].split(chr(10) + "}", 1)[0]
    for module in ("json", "re", "zipfile", "hashlib"):
        assert module in health, module
    launcher = read(ROOT / "portmaster/minecraftbedrock/Minecraft Bedrock.sh")
    assert "mcpe_python_health" in launcher
    assert "mcpe_python_health_hint" in launcher
    # The self test answers the same question without launching anything.
    assert "mcpe_python_health" in read(PAYLOAD / "selftest.sh")
    # A filesystem fault must be named as a firmware problem.
    assert "e2fsck" in common
