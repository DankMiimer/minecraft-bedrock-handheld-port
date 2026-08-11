from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


TOOL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_DIR))
import wsl_backend  # noqa: E402
sys.modules.setdefault("gpsoauth", mock.Mock())
import mcbedrock_get  # noqa: E402
import signin  # noqa: E402


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
            wsl_backend.sign_in("secret-master-token")
        self.assertIn("gplayver", run.call_args.args[0])
        self.assertEqual(run.call_args.kwargs["stdin"], "3\nsecret-master-token\ny\n")

    def test_sign_out_removes_both_caches(self):
        completed = mock.Mock(returncode=0)
        with mock.patch.object(wsl_backend, "_run", return_value=completed) as run:
            self.assertTrue(wsl_backend.sign_out())
        command = run.call_args.args[0]
        self.assertIn("token_cache.conf", command)
        self.assertIn("playdl.conf", command)

    def test_sign_out_reports_unavailable_wsl(self):
        with mock.patch.object(wsl_backend, "_run", side_effect=OSError("missing")):
            self.assertFalse(wsl_backend.sign_out())

    def test_cli_logout_clears_windows_and_wsl_sessions(self):
        with mock.patch.object(wsl_backend, "sign_out", return_value=True) as wsl_logout, \
                mock.patch.object(signin, "forget") as windows_logout:
            self.assertEqual(mcbedrock_get.main(["--logout"]), 0)
        wsl_logout.assert_called_once_with()
        windows_logout.assert_called_once_with()


class DownloadTests(unittest.TestCase):
    def fake_complete(self, _code, base, _on_line, _timeout):
        base.write_bytes(b"base")
        base.with_name(base.stem + ".config.arm64_v8a.apk").write_bytes(b"arm64")
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
        def incomplete(_code, base, _on_line, _timeout):
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
        def no_base(_code, base, _on_line, _timeout):
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
