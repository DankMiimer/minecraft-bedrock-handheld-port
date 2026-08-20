from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


TOOL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_DIR))
import catalog  # noqa: E402
import wsl_backend  # noqa: E402
sys.modules.setdefault("gpsoauth", mock.Mock())
import mcbedrock_get  # noqa: E402
import signin  # noqa: E402


def fixed_catalog() -> catalog.Catalog:
    """A stand-in for versiondb, so no test reaches the network."""
    return catalog.Catalog(
        releases=[
            catalog.Release("1.21.51.01", {"arm64": 972105101}),
            catalog.Release("1.16.221.01", {"arm64": 971622101, "armhf": 951622101},
                            note="Recommended"),
            catalog.Release("1.16.40.02", {"arm64": 943164002, "armhf": 941164002}),
            catalog.Release("1.12.1.1", {"armhf": 871120101}, beta=True),
        ],
        source="test",
        complete=True,
    )


class DistroTests(unittest.TestCase):
    def test_override_wins(self):
        with mock.patch.dict(os.environ, {"MCBEDROCK_WSL_DISTRO": "Ubuntu-Test"}):
            self.assertEqual(wsl_backend.selected_distro(), "Ubuntu-Test")

    def test_prefers_plain_ubuntu(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            wsl_backend, "installed_distros", return_value=["Ubuntu-24.04", "Ubuntu"]
        ):
            self.assertEqual(wsl_backend.selected_distro(), "Ubuntu")

    def test_accepts_versioned_ubuntu(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            wsl_backend,
            "installed_distros",
            return_value=["Ubuntu-9.10", "Debian", "Ubuntu-24.04"],
        ):
            self.assertEqual(wsl_backend.selected_distro(), "Ubuntu-24.04")

    def test_rejects_missing_ubuntu(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            wsl_backend, "installed_distros", return_value=["Debian"]
        ):
            with self.assertRaises(wsl_backend.WslError):
                wsl_backend.selected_distro()

    @unittest.skipUnless(sys.platform == "win32", "WSL distro detection is Windows-only")
    def test_setup_state_handles_missing_ubuntu(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            wsl_backend, "installed_distros", return_value=[]
        ), mock.patch.object(signin, "load", return_value=None):
            self.assertEqual(mcbedrock_get.setup_state()[:3], (False, False, False))

    def test_windows_path_conversion(self):
        with mock.patch.object(Path, "resolve", return_value=Path("C:/Users/Test User/apk")):
            self.assertEqual(wsl_backend.to_wsl_path(Path("ignored")), "/mnt/c/Users/Test User/apk")


class SessionTests(unittest.TestCase):
    def test_windows_session_save_and_forget(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ, {"LOCALAPPDATA": tmp}, clear=True
        ):
            credentials = signin.Credentials("owner@example.com", "test-token")
            signin.save(credentials)
            self.assertEqual(signin.load(), credentials)
            signin.forget()
            self.assertIsNone(signin.load())

    def test_sign_in_passes_token_to_gplayver(self):
        completed = mock.Mock(stdout="signed in", stderr="", returncode=0)
        with mock.patch.object(wsl_backend, "_run", return_value=completed) as run, \
                mock.patch.object(wsl_backend, "is_signed_in", return_value=True):
            wsl_backend.sign_in("owner@example.com", "secret-master-token")
        command = run.call_args.args[0]
        self.assertIn("gplayver", command)
        self.assertIn("--login-no-verify", command)
        self.assertNotIn("--interactive", command)
        self.assertNotIn("owner@example.com", command)
        self.assertNotIn("secret-master-token", command)
        self.assertNotIn("$?", command)
        self.assertNotIn("$session", command)
        self.assertIn("tr -d", command)
        self.assertEqual(
            run.call_args.kwargs["stdin"],
            'user_email = "owner@example.com"\nuser_token = "secret-master-token"\n',
        )
        self.assertEqual(run.call_args.kwargs["timeout"], 120)

    def test_sign_in_rejects_multiline_credentials(self):
        with mock.patch.object(wsl_backend, "_run") as run:
            with self.assertRaisesRegex(wsl_backend.WslError, "saved Google token is invalid"):
                wsl_backend.sign_in("owner@example.com", "secret\ninjected = value")
        run.assert_not_called()

    def test_sign_in_reports_noninteractive_failure(self):
        completed = mock.Mock(stdout="upstream error", stderr="", returncode=1)
        with mock.patch.object(wsl_backend, "_run", return_value=completed):
            with self.assertRaisesRegex(wsl_backend.WslError, "upstream error"):
                wsl_backend.sign_in("owner@example.com", "secret-master-token")

    def test_run_turns_timeout_into_actionable_error(self):
        expired = subprocess.TimeoutExpired(cmd=["wsl.exe"], timeout=12)
        with mock.patch.object(wsl_backend, "selected_distro", return_value="Ubuntu-Test"), \
                mock.patch.object(wsl_backend.subprocess, "run", side_effect=expired):
            with self.assertRaisesRegex(wsl_backend.WslError, "timed out after 12 seconds"):
                wsl_backend._run("true", timeout=12)

    def test_sign_out_removes_both_caches(self):
        completed = mock.Mock(returncode=0)
        with mock.patch.object(wsl_backend, "_run", return_value=completed) as run:
            self.assertTrue(wsl_backend.sign_out())
        command = run.call_args.args[0]
        self.assertIn("token_cache.conf", command)
        self.assertIn("playdl.conf", command)

    def test_signed_in_requires_config_and_cache(self):
        completed = mock.Mock(returncode=0)
        with mock.patch.object(wsl_backend, "_run", return_value=completed) as run:
            self.assertTrue(wsl_backend.is_signed_in())
        command = run.call_args.args[0]
        self.assertIn("playdl.conf", command)
        self.assertIn("token_cache.conf", command)

    def test_sign_out_reports_unavailable_wsl(self):
        with mock.patch.object(wsl_backend, "_run", side_effect=OSError("missing")):
            self.assertFalse(wsl_backend.sign_out())

    def test_cli_logout_clears_windows_and_wsl_sessions(self):
        with mock.patch.object(mcbedrock_get.backend, "sign_out", return_value=True) as wsl_logout, \
                mock.patch.object(signin, "forget") as windows_logout:
            self.assertEqual(mcbedrock_get.main(["--logout"]), 0)
        wsl_logout.assert_called_once_with()
        windows_logout.assert_called_once_with()


class DownloadTests(unittest.TestCase):
    def fake_complete(self, _code, base, _on_line, _timeout, abi):
        base.write_bytes(b"base")
        marker = "arm64_v8a" if abi == "arm64" else "armeabi_v7a"
        base.with_name(base.stem + f".config.{marker}.apk").write_bytes(abi.encode())
        return 1, ["complete"]

    def test_complete_set_is_published(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            wsl_backend, "_download_into", side_effect=self.fake_complete
        ):
            written = wsl_backend.download(971622101, Path(tmp))
            self.assertEqual({path.name for path in written}, {
                "minecraft-971622101.apk",
                "minecraft-971622101.config.arm64_v8a.apk",
            })

    def test_complete_armhf_set_is_published(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            wsl_backend, "_download_into", side_effect=self.fake_complete
        ):
            written = wsl_backend.download(971622101, Path(tmp), abi="armhf")
            self.assertEqual({path.name for path in written}, {
                "minecraft-971622101.apk",
                "minecraft-971622101.config.armeabi_v7a.apk",
            })

    def fake_monolithic(self, _code, base, _on_line, _timeout, abi):
        """Pre-App-Bundle build: ONE apk carrying lib/<abi>/, no config parts."""
        lib = "arm64-v8a" if abi == "arm64" else "armeabi-v7a"
        with zipfile.ZipFile(base, "w") as archive:
            archive.writestr(f"lib/{lib}/libminecraftpe.so", b"native")
        return 1, ["complete"]

    def test_monolithic_pre_bundle_apk_is_published(self):
        # 1.12.1.1 and friends predate split APKs; requiring a config.<abi>.apk
        # rejected them even though the base APK has the native library inside.
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            wsl_backend, "_download_into", side_effect=self.fake_monolithic
        ):
            written = wsl_backend.download(871120101, Path(tmp), abi="armhf")
            self.assertEqual(
                {path.name for path in written}, {"minecraft-871120101.apk"}
            )

    def test_monolithic_apk_missing_the_abi_is_still_rejected(self):
        def wrong_abi(_code, base, _on_line, _timeout, _abi):
            with zipfile.ZipFile(base, "w") as archive:
                archive.writestr("lib/x86/libminecraftpe.so", b"native")
            return 1, ["complete"]

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            wsl_backend, "_download_into", side_effect=wrong_abi
        ), self.assertRaisesRegex(wsl_backend.WslError, "did not return"):
            wsl_backend.download(871120101, Path(tmp), abi="armhf")

    def test_armhf_profile_can_upgrade_an_existing_setup(self):
        completed = mock.Mock(stdout="", stderr="", returncode=0)
        with mock.patch.object(wsl_backend, "_run", return_value=completed) as run:
            wsl_backend.ensure_device_profile("armhf")
        self.assertIn("device-armhf.conf", run.call_args.args[0])
        self.assertIn("armeabi-v7a", run.call_args.kwargs["stdin"])

    def test_unknown_abi_is_rejected_before_download(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(
            wsl_backend.WslError, "Unknown APK architecture"
        ):
            wsl_backend.download(971622101, Path(tmp), abi="x86")

    def test_cli_uses_the_armhf_specific_version_code(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            catalog, "load", return_value=fixed_catalog()
        ), mock.patch.object(mcbedrock_get, "fetch", return_value=[]) as fetch:
            result = mcbedrock_get.main([
                "--download", "1.16.221.01", "--abi", "armhf", "--out", tmp
            ])
        self.assertEqual(result, 0)
        self.assertEqual(fetch.call_args.args[0], 951622101)
        self.assertEqual(fetch.call_args.kwargs["abi"], "armhf")

    def test_cli_rejects_unavailable_armhf_version(self):
        with mock.patch.object(catalog, "load", return_value=fixed_catalog()),                 mock.patch.object(mcbedrock_get, "fetch") as fetch:
            result = mcbedrock_get.main([
                "--download", "1.21.51.01", "--abi", "armhf"
            ])
        self.assertEqual(result, 2)
        fetch.assert_not_called()

    def test_cli_rejects_a_version_nobody_has_heard_of(self):
        with mock.patch.object(catalog, "load", return_value=fixed_catalog()),                 mock.patch.object(mcbedrock_get, "fetch") as fetch:
            self.assertEqual(mcbedrock_get.main(["--download", "9.9.9.9"]), 2)
        fetch.assert_not_called()

    def test_cli_accepts_any_version_the_catalog_lists(self):
        # The point of reading versiondb: builds that were never in the
        # hand-written table are downloadable too.
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            catalog, "load", return_value=fixed_catalog()
        ), mock.patch.object(mcbedrock_get, "fetch", return_value=[]) as fetch:
            result = mcbedrock_get.main([
                "--download", "1.16.40.02", "--abi", "armhf", "--out", tmp
            ])
        self.assertEqual(result, 0)
        self.assertEqual(fetch.call_args.args[0], 941164002)

    def test_redownload_replaces_old_files(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            wsl_backend, "_download_into", side_effect=self.fake_complete
        ):
            target = Path(tmp)
            old = target / "minecraft-971622101.config.old.apk"
            old.write_bytes(b"old")
            wsl_backend.download(971622101, target)
            self.assertFalse(old.exists())
            self.assertEqual((target / "minecraft-971622101.apk").read_bytes(), b"base")

    def test_missing_arm64_keeps_previous_files(self):
        def incomplete(_code, base, _on_line, _timeout, _abi):
            base.write_bytes(b"base")
            return 1, ["no split"]

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            wsl_backend, "_download_into", side_effect=incomplete
        ):
            target = Path(tmp)
            old = target / "minecraft-971622101.apk"
            old.write_bytes(b"previous")
            with self.assertRaises(wsl_backend.WslError):
                wsl_backend.download(971622101, target)
            self.assertEqual(old.read_bytes(), b"previous")

    def test_missing_base_is_rejected(self):
        def no_base(_code, base, _on_line, _timeout, _abi):
            base.with_name(base.stem + ".config.arm64_v8a.apk").write_bytes(b"arm64")
            return 2, ["failed"]

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            wsl_backend, "_download_into", side_effect=no_base
        ):
            with self.assertRaisesRegex(wsl_backend.WslError, "no base APK"):
                wsl_backend.download(971622101, Path(tmp))

    def test_download_failure_keeps_previous_files(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            wsl_backend, "_download_into", side_effect=wsl_backend.WslError("network failed")
        ):
            target = Path(tmp)
            old = target / "minecraft-971622101.apk"
            old.write_bytes(b"previous")
            with self.assertRaisesRegex(wsl_backend.WslError, "network failed"):
                wsl_backend.download(971622101, target)
            self.assertEqual(old.read_bytes(), b"previous")


if __name__ == "__main__":
    unittest.main()
