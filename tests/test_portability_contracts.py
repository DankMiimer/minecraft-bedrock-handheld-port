#!/usr/bin/env python3
"""Regression checks for cross-CFW launcher contracts."""
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_generic_h700_controller_aliases_are_name_disambiguated():
    database = ROOT / "portmaster/minecraftbedrock/minecraftbedrock/controls/rg34xxsp.gamecontrollerdb.txt"
    rows = [line.strip() for line in database.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.startswith("#")]
    parsed = [row.split(",", 2) for row in rows]
    names = {parts[1] for parts in parsed}
    assert {"Anbernic RG34XX-SP Controller", "muOS-Keys", "Deeplay-keys"} <= names
    assert len({parts[0] for parts in parsed}) == 1
    assert all(",a:b1,b:b0,x:b2,y:b3," in row for row in rows)

    patch = (ROOT / "source_release/linux-gamepad.patch").read_text(encoding="utf-8")
    assert "virtual std::string getName() const = 0" in patch
    assert "std::vector<GamepadMapping>" in patch
    assert "mapping.name == name" in patch
    assert "candidates->second.size() == 1" in patch
    assert "buttons[i % len] = nextId++" in patch


def test_menu_failure_does_not_silently_autoplay():
    launcher = (ROOT / "portmaster/minecraftbedrock/Minecraft Bedrock.sh").read_text(
        encoding="utf-8"
    )
    assert "run_launcher_menu || true" not in launcher
    assert "Minecraft was NOT started with hidden defaults." in launcher
    assert "logs/menu-failure.log" in launcher
    assert 'MCPE_MANAGE_FRONTEND:-0' in launcher

    for relative in (
        "portmaster/minecraftbedrock/minecraftbedrock/weston_launch.sh",
        "portmaster/minecraftbedrock/minecraftbedrock/run_bedrock32.sh",
    ):
        text = (ROOT / relative).read_text(encoding="utf-8")
        assert '[ "${MCPE_MANAGE_FRONTEND:-0}" = 1 ] || return' in text


def test_installer_and_runtime_portability_contracts():
    installer = (ROOT / "portmaster/minecraftbedrock/minecraftbedrock/apkmeta.py").read_text(
        encoding="utf-8"
    )
    for suffix in (".apk", ".apks", ".apkm", ".xapk", ".zip"):
        assert suffix in installer
    assert "fcntl.LOCK_EX | fcntl.LOCK_NB" in installer
    assert "recover_incomplete_install" in installer
    assert '"transaction_id": transaction_id' in installer

    launcher = (ROOT / "portmaster/minecraftbedrock/Minecraft Bedrock.sh").read_text(
        encoding="utf-8"
    )
    assert 'ls -A "$GAMEDIR/versions"' not in launcher
    assert "has_installed_version" in launcher
    assert "-iname '*.apkm'" in launcher
    assert "mcpe_loading_screen" not in launcher
    assert "refresh_apk_groups" in launcher
    assert "startup-timing.log" in launcher

    support_bundle = (
        ROOT / "portmaster/minecraftbedrock/minecraftbedrock/create_support_bundle.sh"
    ).read_text(encoding="utf-8")
    assert 'copy_redacted "$GAMEDIR/logs/startup-timing.log"' in support_bundle

    migration = (
        ROOT / "portmaster/minecraftbedrock/minecraftbedrock/migrate_version_metadata.py"
    ).read_text(encoding="utf-8")
    assert "cached_library_hash" in migration
    assert 'metadata.get("game_library_stat")' in migration

    common = (ROOT / "portmaster/minecraftbedrock/minecraftbedrock/lib/common.sh").read_text(
        encoding="utf-8"
    )
    assert "mcpe_select_utf8_locale" in common
    for relative in (
        "portmaster/minecraftbedrock/minecraftbedrock/weston_launch.sh",
        "portmaster/minecraftbedrock/minecraftbedrock/run_bedrock32.sh",
    ):
        runtime = (ROOT / relative).read_text(encoding="utf-8")
        assert 'chmod 700 "$XDG_RUNTIME_DIR"' in runtime
        assert "runtime-arm" in runtime

    binary = ROOT / "portmaster/minecraftbedrock/minecraftbedrock/bin/mcpelauncher-client"
    buildinfo = ROOT / "portmaster/minecraftbedrock/minecraftbedrock/bin/mcpelauncher-client.buildinfo"
    recorded = dict(
        line.split("=", 1) for line in buildinfo.read_text(encoding="utf-8").splitlines()
        if "=" in line
    )
    assert recorded["schema"] == "1"
    assert recorded["target"] == "aarch64-standard-eglut"
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == recorded["sha256"]


PAYLOAD = ROOT / "portmaster/minecraftbedrock/minecraftbedrock"
LAUNCHER = ROOT / "portmaster/minecraftbedrock/Minecraft Bedrock.sh"


def test_cfw_identity_has_exactly_one_resolver():
    """Per-CFW behaviour must key off mcpe_resolve_cfw, never a local copy.

    Four hand-rolled detectors (two for muOS, two for Knulli) had drifted
    apart, and ROCKNIX and the ArkOS family had none at all.
    """
    common = (PAYLOAD / "lib/common.sh").read_text(encoding="utf-8")
    for canonical in ("knulli", "muos", "rocknix", "arkos", "batocera"):
        assert f"'{canonical}\\n'" in common, canonical
    # The resolver must fail closed rather than invent a plausible id.
    assert "id=unknown" in common and "origin=none" in common
    # CFW_NAME arrives late; a cache that ignores that silently disables every
    # per-CFW behaviour for the whole run.
    assert "mcpe_cfw_cache_key" in common
    assert 'MCPE_CFW_CACHE_KEY:-}" != "$(mcpe_cfw_cache_key)"' in common

    consumers = [
        LAUNCHER,
        PAYLOAD / "lib/migrate_data.sh",
        PAYLOAD / "weston_launch.sh",
        PAYLOAD / "run_bedrock32.sh",
    ]
    for path in consumers:
        text = path.read_text(encoding="utf-8")
        assert "mcpe_is_cfw" in text, path
        # No file may re-derive identity from CFW_NAME by hand.
        assert "cfw_lower" not in text, path
        assert "*muos*" not in text and "*knulli*" not in text, path

    platform = (PAYLOAD / "lib/platform.sh").read_text(encoding="utf-8")
    assert "mcpe_resolve_cfw" in platform
    assert "MCPE_CFW=%q" in platform and "MCPE_CFW_CONFIDENCE=%q" in platform


def test_launch_leaves_a_breadcrumb_that_survives_a_hang():
    """A device that locks up mid-launch must still say where it stopped.

    The launcher log is truncated on start and is useless after a freeze, so
    the breadcrumb is opened first and only reaches `done` on an orderly exit.
    """
    common = (PAYLOAD / "lib/common.sh").read_text(encoding="utf-8")
    assert "stage.prev.txt" in common
    assert "mcpe_stage_begin" in common

    launcher = LAUNCHER.read_text(encoding="utf-8")
    order = [launcher.index(marker) for marker in (
        "mcpe_stage_begin",
        "mcpe_stage payload",
        "mcpe_stage migrate",
        "mcpe_stage probe",
        "mcpe_stage version",
        "mcpe_stage shutdown",
        "mcpe_stage done",
    )]
    assert order == sorted(order), "stage markers are out of launch order"
    # The breadcrumb has to be armed before the first step that can hang.
    assert launcher.index("mcpe_stage_begin") < launcher.index("mcpe_migrate_shared_data")
    assert "MCPE_STAGE_PREV" in launcher

    # `done` marks an orderly end, so it must appear once, immediately before
    # the script exits. A `done` anywhere else would tell the next launch that
    # a hang had been fine.
    lines = launcher.splitlines()
    done_at = [i for i, line in enumerate(lines) if line.strip() == "mcpe_stage done"]
    assert len(done_at) == 1, done_at
    assert "exit " in " ".join(lines[done_at[0] + 1:done_at[0] + 4])

    # A launch that never returns leaves the breadcrumb on client-exec.
    for relative in ("run_bedrock.sh", "run_bedrock32.sh"):
        text = (PAYLOAD / relative).read_text(encoding="utf-8")
        assert "mcpe_stage client-exec" in text, relative

    bundle = (PAYLOAD / "create_support_bundle.sh").read_text(encoding="utf-8")
    for artefact in ("stage.txt", "stage.prev.txt", "boot-report.txt"):
        assert artefact in bundle, artefact
    assert "mcpe_resolve_cfw" in bundle


def test_boot_report_covers_the_required_device_report_fields():
    """TESTING.md asks reporters for these; the port must not make them dig."""
    launcher = LAUNCHER.read_text(encoding="utf-8")
    for key in ("cfw", "host", "graphics", "panel", "audio", "loaders",
                "bedrock", "bedrock_status", "locale"):
        assert f"mcpe_report_set {key} " in launcher, key
    assert "mcpe_report_set abi " in (PAYLOAD / "run_bedrock.sh").read_text(encoding="utf-8")


# The failsafe register is enforced by tests/test_failsafes.py, which reads the
# knobs out of lib/failsafe.sh rather than from a list kept by hand.


def test_the_ladder_cannot_degrade_a_launch_silently_or_permanently():
    ladder = (PAYLOAD / "lib/failsafe.sh").read_text(encoding="utf-8")
    state = (PAYLOAD / "failsafe_state.py").read_text(encoding="utf-8")
    launcher = LAUNCHER.read_text(encoding="utf-8")

    # Rung 2 builds on rung 1 rather than redefining it.
    assert "mcpe_failsafe_apply_conservative" in ladder
    assert ladder.index("mcpe_failsafe_apply_minimal() {") < ladder.index(
        "mcpe_failsafe_apply()")

    # A degraded launch is announced, with a way back.
    assert 'MCPE_FAILSAFE_RUNG:-0}" -ge 1' in launcher
    assert "safe_mode=0" in launcher
    assert "mcpe_failsafe_describe" in launcher
    assert "safe_mode)" in launcher, "settings.cfg cannot pin the ladder"

    # Escalation is bounded, and only a directly observed failure is permanent.
    assert "MAX_RUNG = 3" in state
    assert 'entry["floor"] = max(entry["floor"]' in state
    assert state.index('entry["last_outcome"] = "inferred_startup_failure"') < \
        state.index('entry["rung"] += 1')
    assert 'entry["floor"]' not in state.split("inferred_startup_failure")[1].split("append_ledger")[0]

    # Every transition is recorded where a device report can see it.
    assert "failsafe-ledger.tsv" in state
    bundle = (PAYLOAD / "create_support_bundle.sh").read_text(encoding="utf-8")
    assert "failsafe-ledger.tsv" in bundle and "launch_state.json" in bundle

    # The ladder decides after the saved profile is loaded, so it can override it.
    assert launcher.index("apply_settings\n") < launcher.index("mcpe_failsafe_plan")
    assert launcher.index("mcpe_failsafe_plan") < launcher.index(
        'bash "$GAMEDIR/run_bedrock.sh"')
    assert launcher.index("mcpe_failsafe_record") > launcher.index(
        'bash "$GAMEDIR/run_bedrock.sh"')

    # The diagnostic rung must not become a second exit path that skips the
    # frontend restore; it shares the shutdown/pm_finish tail with a real run.
    assert launcher.index("status=3") < launcher.index("mcpe_stage shutdown")
    assert launcher.index("mcpe_stage shutdown") < launcher.index("  pm_finish || true")


def test_the_registry_only_claims_guards_that_can_actually_fire():
    """A patch the binary compiles out is not protection.

    Both in-client guards are wrapped in `#if !defined(__aarch64__) return;`,
    and the HTTP-resolver one additionally checks the game directory for
    "1.16.221.01". The registry used to list them on three combinations where
    they provably cannot run, so the port believed it was covered when it was
    not, and nothing took over.
    """
    import json

    patch = (ROOT / "source_release/mcpelauncher-client.patch").read_text(encoding="utf-8")
    for guard in ("patchEduModeNullDeref", "patchOldHttpResolveCrash"):
        body = patch.split(guard, 1)[1][:600]
        assert "#if !defined(__aarch64__)" in body, f"{guard} is no longer arm64-only"
    assert 'gameDir.find("1.16.221.01")' in patch

    registry = json.loads(
        (PAYLOAD / "compat/compatibility.json").read_text(encoding="utf-8"))
    for entry in registry["versions"]:
        patches = entry.get("patches") or []
        where = f"{entry['version']}/{entry['abi']}"
        if entry["abi"] != "arm64":
            assert not patches, f"{where} claims arm64-only guards: {patches}"
        if "http_resolver_guard" in patches:
            assert entry["version"] == "1.16.221.01", \
                f"{where} claims a guard pinned to the 1.16.221.01 binary"


def test_the_launcher_covers_startup_crashes_the_client_cannot():
    """Where no in-client guard applies, the launcher reports offline instead.

    A muOS report (10 Jul): the game exits before the character menu with Wi-Fi
    on and reaches it every time offline. MCPE_FAKE_NO_NETWORK is the general
    form of the fix and was previously referenced only inside the C++ patch --
    no shell script ever set it.
    """
    launcher = LAUNCHER.read_text(encoding="utf-8")
    assert "MCPE_FAKE_NO_NETWORK" in launcher
    assert 'MCPE_PROFILE_CLASS:-default}" = legacy_1_16' in launcher
    assert 'MCPE_PATCH_HTTP_RESOLVE:-0}" != 1' in launcher
    # LAN multiplayer is a headline feature, so this must be overridable and
    # must say so when it takes LAN away.
    assert "network)" in launcher, "settings.cfg cannot override the network policy"
    assert "LAN will not work" in launcher
    menu = (PAYLOAD / "menu/main.lua").read_text(encoding="utf-8")
    assert 'key = "network"' in menu

    patch = (ROOT / "source_release/mcpelauncher-client.patch").read_text(encoding="utf-8")
    assert 'std::getenv("MCPE_FAKE_NO_NETWORK")' in patch


def test_both_launch_paths_share_one_audio_triage():
    """The 32-bit path had none, so OpenAL walked its own preference list."""
    audio = (PAYLOAD / "lib/audio.sh").read_text(encoding="utf-8")
    assert "mcpe_resolve_audio" in audio
    assert "mcpe_pipewire_client_usable" in audio
    for relative in ("run_bedrock.sh", "run_bedrock32.sh"):
        text = (PAYLOAD / relative).read_text(encoding="utf-8")
        assert "lib/audio.sh" in text, relative
        assert "mcpe_resolve_audio" in text, relative
    # The old inline copy must be gone, not merely bypassed.
    assert "find_pulse_socket() {" not in (PAYLOAD / "run_bedrock.sh").read_text(
        encoding="utf-8")


def test_both_launch_paths_are_supervised_during_startup():
    watchdog = (PAYLOAD / "lib/watchdog.sh").read_text(encoding="utf-8")
    assert "mcpe_watchdog_start" in watchdog
    assert "hang-report.txt" in watchdog
    assert "mcpe_stage first-frame" in watchdog and "mcpe_stage window" in watchdog
    # Stall detection, not an absolute deadline: a slow first launch on a cold
    # card is healthy, and killing it would be worse than the hang.
    assert "MCPE_STALL_SECONDS:-90" in watchdog
    assert "MCPE_STARTUP_TIMEOUT:-0" in watchdog
    for relative in ("weston_launch.sh", "run_bedrock32.sh"):
        text = (PAYLOAD / relative).read_text(encoding="utf-8")
        assert "lib/watchdog.sh" in text, relative
        assert "mcpe_watchdog_start" in text, relative
        assert "mcpe_watchdog_stop" in text, relative


def test_abi_choice_asks_about_the_loader_not_the_kernel():
    abi = (PAYLOAD / "lib/abi.sh").read_text(encoding="utf-8")
    assert "mcpe_loader_present" in abi
    runner = (PAYLOAD / "run_bedrock.sh").read_text(encoding="utf-8")
    assert "mcpe_loader_present arm64" in runner
    assert "mcpe_loader_present armhf" in runner
    # dArkOS RE: 64-bit kernel, armhf userland, reported "usable: 64=1".
    assert '"$(uname -m 2>/dev/null)" = aarch64' not in runner

    launcher = LAUNCHER.read_text(encoding="utf-8")
    # gptokeyb attaches by process name; DEVICE_ARCH is unset on several CFWs.
    assert 'basename "${LOVE_BINARY:-}"' in launcher


def test_the_boot_report_reaches_the_log_on_every_exit():
    """A report a reporter never sees is not a report.

    mcpe_report_print used to be called once, just before the game started, so
    every exit before that point -- no version, no LOVE runtime, a broken
    interpreter, a failed probe -- left logs/boot-report.txt on disk and nothing
    in logs/launcher.log. launcher.log is the file the issue template asks for
    and the file reporters paste; issue #10 pasted it twice, without the report.
    """
    launcher = LAUNCHER.read_text(encoding="utf-8")
    common = (PAYLOAD / "lib/common.sh").read_text(encoding="utf-8")

    # Armed at the first point the report file exists, before anything can exit.
    begin = launcher.index('mcpe_report_begin "$GAMEDIR/logs/boot-report.txt"')
    trap = launcher.index("trap mcpe_report_print EXIT")
    assert begin < trap, "the report trap must be armed after the report is opened"
    first_exit = launcher.index("exit 1", trap)
    assert trap < first_exit, "the report trap must be armed before the first exit"

    # The later frontend trap must not silently replace it.
    assert "trap 'menu_restore_frontend; mcpe_report_print' EXIT" in launcher
    assert "trap menu_restore_frontend EXIT" not in launcher

    # And printing twice must not produce two blocks.
    assert 'MCPE_REPORT_PRINTED:-0' in common
    assert "MCPE_REPORT_PRINTED=1" in common


def test_a_missing_love_runtime_is_not_reported_as_a_missing_game():
    """Issue #10 selected "the launcher menu never appeared" and was told that
    no Minecraft version was installed. Both can be true at once, and only one
    of them is the thing to fix."""
    launcher = LAUNCHER.read_text(encoding="utf-8")
    assert "MENU_UNAVAILABLE_REASON" in launcher
    assert "mcpe_report_set menu " in launcher
    assert "mcpe_report_set menu_searched" in launcher
    # The paths searched come from one list, so the report cannot drift from
    # the lookup it is describing.
    assert launcher.count("love_txt_candidates") >= 3
    assert launcher.count('"$controlfolder/runtimes/love_11.5/love.txt"') == 1
    # The no-version message leads with the runtime when that is the cause.
    no_version = launcher.split("if ! has_installed_version && [ -z \"$MENU_LOVE_TXT\" ]", 1)[1][:1200]
    assert "LOVE 11.5 runtime was not found" in no_version
    assert "No Minecraft version installed." in no_version


def test_the_port_states_what_this_release_claims_for_the_firmware():
    """v2.0.0 covers Knulli, muOS and ROCKNIX. The ArkOS family has never had a
    device, so its paths ship unverified and must say so rather than being read
    as a supported firmware regressing."""
    common = (PAYLOAD / "lib/common.sh").read_text(encoding="utf-8")
    assert "mcpe_cfw_support()" in common
    support = common.split("mcpe_cfw_support()", 1)[1].split("\n}", 1)[0]
    assert "knulli|rocknix|muos" in support
    assert "reference" in support
    for unclaimed in ("arkos", "batocera"):
        assert unclaimed in support, unclaimed
    assert support.count("unverified") >= 3, "every uncovered case must say unverified"

    assert "mcpe_report_set cfw_support" in LAUNCHER.read_text(encoding="utf-8")
    selftest = (PAYLOAD / "selftest.sh").read_text(encoding="utf-8")
    assert "mcpe_cfw_support" in selftest, "the self test must report the same answer"

    # The documents have to agree with the code.
    contracts = (ROOT / "docs/CFW-CONTRACTS.md").read_text(encoding="utf-8")
    assert "Out of scope for v2.0.0" in contracts


def test_the_rgds_edition_declares_itself_experimental():
    """The second-screen companion is early development on one device. A player
    picking it should be told by the port, not by a bug."""
    import json

    rgds = json.loads((ROOT / "bottomscreen/release/edition.json").read_text(encoding="utf-8"))
    standard = json.loads(
        (PAYLOAD / "edition.json").read_text(encoding="utf-8")
    )
    assert rgds["stability"] == "experimental"
    assert standard.get("stability", "stable") == "stable"

    common = (PAYLOAD / "lib/common.sh").read_text(encoding="utf-8")
    assert "MCPE_EDITION_STABILITY" in common
    # Absent means stable, so an older manifest keeps its meaning.
    assert 'MCPE_EDITION_STABILITY:-stable' in common

    launcher = LAUNCHER.read_text(encoding="utf-8")
    assert "This edition is EXPERIMENTAL" in launcher

    for document in ("README.md", "README.txt",
                     "portmaster/minecraftbedrock/README.md"):
        text = (ROOT / document).read_text(encoding="utf-8").lower()
        assert "experimental" in text and "rgds" in text, document


def test_an_empty_update_channel_tells_the_player_what_to_do():
    """A fresh install defaults to the stable channel. An index carrying only
    testing entries then failed with a count, which is not something a player
    can act on."""
    selector = (PAYLOAD / "release_select.py").read_text(encoding="utf-8")
    assert "no {args.channel} release published" in selector
    assert "change Update channel in Settings" in selector


if __name__ == "__main__":
    test_generic_h700_controller_aliases_are_name_disambiguated()
    test_menu_failure_does_not_silently_autoplay()
    test_installer_and_runtime_portability_contracts()
    test_cfw_identity_has_exactly_one_resolver()
    test_launch_leaves_a_breadcrumb_that_survives_a_hang()
    test_boot_report_covers_the_required_device_report_fields()
    test_the_ladder_cannot_degrade_a_launch_silently_or_permanently()
    test_the_registry_only_claims_guards_that_can_actually_fire()
    test_the_launcher_covers_startup_crashes_the_client_cannot()
    test_both_launch_paths_share_one_audio_triage()
    test_both_launch_paths_are_supervised_during_startup()
    test_abi_choice_asks_about_the_loader_not_the_kernel()
    test_the_boot_report_reaches_the_log_on_every_exit()
    test_a_missing_love_runtime_is_not_reported_as_a_missing_game()
    test_the_port_states_what_this_release_claims_for_the_firmware()
    test_the_rgds_edition_declares_itself_experimental()
    test_an_empty_update_channel_tells_the_player_what_to_do()
    print("portability contract tests passed")
