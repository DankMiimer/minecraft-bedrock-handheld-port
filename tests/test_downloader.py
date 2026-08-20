#!/usr/bin/env python3
from __future__ import annotations

import base64
import importlib.util
import io
import json
import lzma
import os
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "portmaster/minecraftbedrock/minecraftbedrock/downloader"


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, MODULE / f"{name}.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


credentials = load("credentials")
deb_extract = load("deb_extract")


def ar_member(name: str, payload: bytes) -> bytes:
    header = (
        f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{0o100644:<8}{len(payload):<10}`\n"
    ).encode("ascii")
    return header + payload + (b"\n" if len(payload) & 1 else b"")


class DownloaderTests(unittest.TestCase):
    def test_approved_credential_is_written_without_echoing_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            account = {"accountIdentifier": "owner@example.com", "accountToken": "token:private"}
            encoded = base64.b64encode(json.dumps(account).encode()).decode()
            capture = root / "capture"
            capture.write_text("unrelated warning\nCREDB64=" + encoded + "\n", encoding="utf-8")
            output = root / "playdl.conf"
            credentials.write_playdl(capture, output)
            text = output.read_text(encoding="utf-8")
            self.assertIn('user_email = "owner@example.com"', text)
            self.assertIn('user_token = "token:private"', text)
            if os.name != "nt":
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_qt_account_requires_token_in_google_group(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "ui.conf"
            config.write_text("[other]\ntoken=no\n", encoding="utf-8")
            self.assertFalse(credentials.has_qt_account(config))
            config.write_text("[googlelogin]\nidentifier=x\ntoken=encrypted-value\n", encoding="utf-8")
            self.assertTrue(credentials.has_qt_account(config))

    def test_quick_signin_result_is_written_to_playdl_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            capture = root / "signin.json"
            capture.write_text(
                json.dumps(
                    {
                        "accountIdentifier": "owner@example.com",
                        "accountToken": "oauth-private",
                    }
                ),
                encoding="utf-8",
            )
            output = root / "playdl.conf"
            credentials.write_signin(capture, output)
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                'user_email = "owner@example.com"\n'
                'user_token = "oauth-private"\n',
            )

    def test_quick_signin_oauth_token_uses_upstream_exchange_input(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            capture = root / "signin.json"
            capture.write_text(
                json.dumps(
                    {
                        "accountIdentifier": "owner@example.com",
                        "accountToken": "oauth-private",
                    }
                ),
                encoding="utf-8",
            )
            output = root / "google-access-input"
            credentials.write_access_input(capture, output)
            self.assertEqual(output.read_text(encoding="utf-8"), "2\noauth-private\nY\n")

    def test_deb_extractor_only_publishes_the_keyboard_elf(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tar_buffer = io.BytesIO()
            elf = b"\x7fELF" + b"x" * 5000
            with tarfile.open(fileobj=tar_buffer, mode="w") as archive:
                info = tarfile.TarInfo(
                    "./usr/lib/aarch64-linux-gnu/qt6/plugins/platforminputcontexts/"
                    "libqtvirtualkeyboardplugin.so"
                )
                info.size = len(elf)
                archive.addfile(info, io.BytesIO(elf))
            data = lzma.compress(tar_buffer.getvalue())
            package = root / "keyboard.deb"
            package.write_bytes(
                deb_extract.AR_MAGIC
                + ar_member("debian-binary", b"2.0\n")
                + ar_member("data.tar.xz", data)
            )
            output = root / "plugins/platforminputcontexts/libqtvirtualkeyboardplugin.so"
            deb_extract.extract_plugin(package, output)
            self.assertEqual(output.read_bytes(), elf)
            generic = root / "libOpenGL.so.0"
            deb_extract.extract_elf(
                package,
                deb_extract.PLUGIN_SUFFIX,
                generic,
                "test runtime",
            )
            self.assertEqual(generic.read_bytes(), elf)

    def test_runtime_pins_are_sha256_and_sized(self):
        values = {}
        for line in (MODULE / "runtime.conf").read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                key, value = line.split("=", 1)
                values[key] = value
        self.assertRegex(values["APPIMAGE_SHA256"], r"^[0-9a-f]{64}$")
        self.assertRegex(values["KEYBOARD_DEB_SHA256"], r"^[0-9a-f]{64}$")
        self.assertGreater(int(values["APPIMAGE_SIZE"]), 100_000_000)
        self.assertGreater(int(values["KEYBOARD_DEB_SIZE"]), 4_000)

    def test_arm64_qt_glx_compat_shim_is_packaged(self):
        shim = MODULE / "lib/libqt-xcb-glx-compat.so"
        payload = shim.read_bytes()
        self.assertEqual(payload[:4], b"\x7fELF")
        # ELF class 2 is 64-bit; e_machine 183 is AArch64.
        self.assertEqual(payload[4], 2)
        self.assertEqual(int.from_bytes(payload[18:20], "little"), 183)
        run_script = (MODULE / "run.sh").read_text(encoding="utf-8")
        self.assertIn("headless noop kiosk llvmpipe", run_script)
        self.assertIn("CRUSTY_GL4ES=1", run_script)
        self.assertIn("SYSTEM_XKB_LINK=/usr/share/X11/xkb", run_script)
        self.assertIn("trap cleanup_system_xkb_link EXIT", run_script)
        self.assertIn("libqt-xcb-glx-compat.so", run_script)
        shim_source = (
            ROOT / "tools/ondevice-downloader/qt-xcb-glx-compat.c"
        ).read_text(encoding="utf-8")
        self.assertIn('RTLD_NEXT, "crusty_glXGetProcAddressARB"', shim_source)
        self.assertIn('resolver((const unsigned char *)"glGetString")', shim_source)
        self.assertNotIn('dlsym(RTLD_NEXT, "glXGetProcAddress")', shim_source)

    def test_controller_navigation_reads_rg34xxsp_evdev_directly(self):
        session = (MODULE / "gui-session.sh").read_text(encoding="utf-8")
        outer = (MODULE / "run.sh").read_text(encoding="utf-8")
        helper_source = (
            ROOT / "tools/ondevice-downloader/google-signin-quick/main.cpp"
        ).read_text(encoding="utf-8")
        signin = MODULE / "bin/mcpe-signin"
        payload = signin.read_bytes()
        self.assertEqual(payload[:4], b"\x7fELF")
        self.assertEqual(payload[4], 2)
        self.assertEqual(int.from_bytes(payload[18:20], "little"), 183)
        self.assertIn('QStringLiteral("/dev/input")', helper_source)
        self.assertIn('Anbernic RG34XX-SP Controller', helper_source)
        self.assertIn('event.code - BTN_GAMEPAD', helper_source)
        self.assertIn('QGuiApplication::inputMethod()->isVisible()', helper_source)
        self.assertIn('emit keyboardNavigationKey(event.value < 0 ? Qt::Key_Up : Qt::Key_Down)', helper_source)
        self.assertIn('emit keyboardNavigationKey(Qt::Key_Return)', helper_source)
        qml = (MODULE / "signin.qml").read_text(encoding="utf-8")
        self.assertIn('InputContext.priv.navigationKeyPressed', qml)
        self.assertIn('InputContext.priv.navigationKeyReleased', qml)
        self.assertNotIn('$GPTOKEYB mcpe-signin', session)
        self.assertNotIn('$GPTOKEYB mcpe-signin', outer)
        self.assertIn('/tmp/weston/share/X11/xkb', session)
        self.assertIn('write-access-input', session)
        self.assertIn('--interactive', outer)
        self.assertIn('<"$auth_input"', outer)
        self.assertIn('WebEngineView', (MODULE / "signin.qml").read_text(encoding="utf-8"))

    def test_on_device_progress_and_experimental_abi_contracts(self):
        outer = (
            ROOT / "portmaster/minecraftbedrock/Minecraft Bedrock.sh"
        ).read_text(encoding="utf-8")
        run = (MODULE / "run.sh").read_text(encoding="utf-8")
        validator = (MODULE / "validate_download.py").read_text(encoding="utf-8")
        menu = (
            ROOT / "portmaster/minecraftbedrock/minecraftbedrock/menu/main.lua"
        ).read_text(encoding="utf-8")

        self.assertIn("draw_downloader_progress", outer)
        self.assertIn("draw_downloader_progress_love", outer)
        self.assertIn("MCPE_DOWNLOADER_PROGRESS", outer)
        self.assertIn("MCPE_DOWNLOADER_INTERACTIVE_ACK", outer)
        self.assertIn('download "$code" "$abi"', outer)
        self.assertIn("percent|active|heading|detail", run)
        self.assertIn("progress 66 interactive", run)
        self.assertIn("wait_for_interactive_handoff", run)
        self.assertIn("Downloaded[[:space:]]+([0-9]+)%", run)
        self.assertIn("last_progress_pct=-1", run)
        self.assertIn('[ "$progress_pct" = "$last_progress_pct" ] && continue', run)
        self.assertNotIn('printf \'%s\\n\' "$line" | tee -a "$LOG"', run)
        self.assertIn('"$SCRIPT_DIR/version_catalog.tsv"', run)
        self.assertIn('"$GAMEDIR/downloader/version_catalog.tsv"', outer)
        self.assertIn('prepare_device_profile "$abi"', run)
        self.assertIn('{"arm64": "arm64-v8a", "armhf": "armeabi-v7a"}', validator)
        self.assertIn("OTHER_DOWNLOADS", menu)
        self.assertIn("currentOtherDownloads", menu)
        self.assertIn('screen == "download_other"', menu)
        self.assertIn('entry.code .. ":" .. entry.abi', menu)
        self.assertIn("Other versions [EXPERIMENTAL]", menu)
        self.assertIn('rowH = 0.082', menu)
        self.assertIn('"<>", "ARM64/32"', menu)
        self.assertIn('"X", "release/beta"', menu)
        self.assertIn("bodyFont:getWrap(line, bodyWidth)", menu)
        self.assertIn('screen == "download_info"', menu)
        self.assertIn('drawList(top, items, 0, {rowH = 0.105})', menu)
        self.assertIn('drawHints({{"B", "back to downloads"}})', menu)
        self.assertIn("All %s %s", menu)
        # The menu must describe builds from the generated columns, never from
        # a second hand-written table that can disagree with them.
        self.assertNotIn("CATALOG_DETAILS", menu)
        self.assertIn("Play code ", menu)
        self.assertNotIn("972006202", menu)
        self.assertNotIn("951604002", menu)

        progress_ui = (MODULE / "progress-ui/main.lua").read_text(encoding="utf-8")
        self.assertIn("MCPE_PROGRESS_EXIT_INTERACTIVE", progress_ui)
        self.assertIn('mode == "interactive"', progress_ui)
        self.assertIn("GOOGLE PLAY APK DOWNLOADER", progress_ui)

        support = (
            ROOT
            / "portmaster/minecraftbedrock/minecraftbedrock/create_support_bundle.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('copy_redacted "$GAMEDIR/logs/downloader.log"', support)

        self.assertEqual(
            (MODULE / "device-armhf.conf").read_text(encoding="utf-8"),
            "config.native_platforms = [\n    armeabi-v7a\n]\n",
        )

    def test_complete_supported_google_play_catalog(self):
        catalog = MODULE / "version_catalog.tsv"
        rows = []
        for line in catalog.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            self.assertEqual(len(fields), 8, line)
            code, abi, channel, version = fields[:4]
            rows.append((code, abi, channel, version))

        # Every build Play still serves, minus 1.26+, is roughly a thousand.
        self.assertGreater(len(rows), 900)
        self.assertEqual(len(rows), len(set(rows)))
        self.assertEqual({row[1] for row in rows}, {"arm64", "armhf"})
        self.assertEqual({row[2] for row in rows}, {"release", "preview"})
        self.assertTrue(all(row[0].isdigit() for row in rows))
        # The whole range is offered now, not just 1.16-1.21: the older builds
        # matter for weak hardware. 1.26+ stays out because its PairIP
        # packaging cannot be opened by the launcher at all.
        self.assertTrue(any(row[3].startswith("1.2.") for row in rows))
        self.assertTrue(any(row[3].startswith("0.") for row in rows))
        self.assertFalse(any(row[3].startswith(("1.26.", "1.27.")) for row in rows))

        requests = {(code, abi) for code, abi, _channel, _version in rows}
        for request in {
            ("971622101", "arm64"),
            ("972105101", "arm64"),
            ("951622101", "armhf"),
            ("941164002", "armhf"),
            ("972105068", "arm64"),
        }:
            self.assertIn(request, requests)

        # The catalog is still built from the upstream versiondb databases, but
        # the fetching and the classification now live in one place shared with
        # the Windows helper, so the two downloaders cannot describe the same
        # build differently.
        updater = (
            ROOT / "scripts/update_gplay_version_catalog.py"
        ).read_text(encoding="utf-8")
        self.assertIn("tools", updater)
        self.assertIn("import catalog", updater)
        helper = (ROOT / "tools/mcbedrock-get/catalog.py").read_text(encoding="utf-8")
        self.assertIn("versions.{db}.json.min", helper)
        self.assertIn("arm64-v8a", helper)
        self.assertIn("armeabi-v7a", helper)


if __name__ == "__main__":
    unittest.main()
