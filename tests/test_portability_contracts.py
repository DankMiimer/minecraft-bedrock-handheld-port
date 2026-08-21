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


if __name__ == "__main__":
    test_generic_h700_controller_aliases_are_name_disambiguated()
    test_menu_failure_does_not_silently_autoplay()
    test_installer_and_runtime_portability_contracts()
    print("portability contract tests passed")
