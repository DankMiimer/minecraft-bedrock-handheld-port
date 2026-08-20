from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

TOOL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_DIR))
sys.modules.setdefault("gpsoauth", mock.Mock())
import mcbedrock_get  # noqa: E402
import signin  # noqa: E402
import wsl_backend  # noqa: E402


class ReadinessTests(unittest.TestCase):
    """The four states a machine can be in, in the order it passes through."""

    def look(self, feature: bool, distro: bool, tool: bool, account: bool):
        return mock.patch.multiple(
            wsl_backend,
            windows_feature_present=mock.Mock(return_value=feature),
            distro_present=mock.Mock(return_value=distro),
            is_installed=mock.Mock(return_value=tool),
            adopt_legacy_install=mock.Mock(return_value=False),
        ), mock.patch.object(
            signin, "load", return_value=mock.Mock() if account else None
        )

    def readiness(self, **kwargs):
        wsl, account = self.look(**kwargs)
        with wsl, account:
            return mcbedrock_get.readiness()

    def test_a_fresh_windows_needs_everything(self):
        state = self.readiness(feature=False, distro=False, tool=False, account=False)
        self.assertEqual(state.next_step(), "feature")
        self.assertTrue(state.installs_an_os)
        self.assertFalse(state.ready)

    def test_wsl_without_ubuntu_still_installs_an_os(self):
        state = self.readiness(feature=True, distro=False, tool=False, account=False)
        self.assertEqual(state.next_step(), "distro")
        self.assertTrue(state.installs_an_os)

    def test_building_the_downloader_is_not_an_os_install(self):
        # No second consent prompt once Linux is already there.
        state = self.readiness(feature=True, distro=True, tool=False, account=False)
        self.assertEqual(state.next_step(), "tool")
        self.assertFalse(state.installs_an_os)

    def test_signing_in_is_the_last_step(self):
        state = self.readiness(feature=True, distro=True, tool=True, account=False)
        self.assertEqual(state.next_step(), "account")

    def test_everything_present_is_ready(self):
        state = self.readiness(feature=True, distro=True, tool=True, account=True)
        self.assertTrue(state.ready)
        self.assertEqual(state.next_step(), "")

    def test_no_distro_question_is_asked_before_wsl_exists(self):
        # Asking costs a 60-second timeout for an answer already known.
        with mock.patch.object(
            wsl_backend, "windows_feature_present", return_value=False
        ), mock.patch.object(wsl_backend, "distro_present") as distro, mock.patch.object(
            signin, "load", return_value=None
        ):
            mcbedrock_get.readiness()
        distro.assert_not_called()

    def test_an_older_install_is_adopted_instead_of_rebuilt(self):
        with mock.patch.multiple(
            wsl_backend,
            windows_feature_present=mock.Mock(return_value=True),
            distro_present=mock.Mock(return_value=True),
            is_installed=mock.Mock(return_value=False),
            adopt_legacy_install=mock.Mock(return_value=True),
        ), mock.patch.object(signin, "load", return_value=None):
            self.assertTrue(mcbedrock_get.readiness().tool)


class DisclosureTests(unittest.TestCase):
    """Nobody should find out afterwards that an OS was installed."""

    def test_it_says_an_operating_system_is_being_installed(self):
        text = mcbedrock_get.SETUP_EXPLANATION.lower()
        self.assertIn("ubuntu linux", text)
        self.assertIn("operating system", text)
        self.assertIn("inside windows", text)

    def test_it_gives_the_sizes(self):
        self.assertIn("1.5 GB", mcbedrock_get.SETUP_EXPLANATION)
        self.assertIn("500 MB", mcbedrock_get.SETUP_EXPLANATION)

    def test_it_says_how_to_remove_it(self):
        self.assertIn("wsl --unregister", mcbedrock_get.SETUP_EXPLANATION)

    def test_it_says_no_linux_password_is_needed(self):
        self.assertIn("root", mcbedrock_get.SETUP_EXPLANATION.lower())


class RootExecutionTests(unittest.TestCase):
    """No Ubuntu user, no sudo, no terminal - the whole point of the rework."""

    def test_every_command_runs_as_root(self):
        with mock.patch.object(wsl_backend, "selected_distro", return_value="Ubuntu"):
            argv = wsl_backend._wsl_argv("--", "bash", "-lc", "true")
        self.assertEqual(argv[:5], ["wsl.exe", "-d", "Ubuntu", "-u", "root"])

    def test_the_distro_is_installed_without_its_first_run_wizard(self):
        with mock.patch.object(wsl_backend, "_stream", return_value=0) as stream, \
                mock.patch.object(wsl_backend, "distro_present", return_value=True):
            wsl_backend.install_distro()
        self.assertIn("--no-launch", stream.call_args.args[0])

    def test_the_build_never_waits_for_a_keypress(self):
        with mock.patch.object(wsl_backend, "_stream", return_value=0) as stream, \
                mock.patch.object(wsl_backend, "is_installed", return_value=True), \
                mock.patch.object(wsl_backend, "selected_distro", return_value="Ubuntu"), \
                mock.patch.object(Path, "is_file", return_value=True), \
                mock.patch.object(wsl_backend, "to_wsl_path", return_value="/mnt/c/x.sh"):
            wsl_backend.build_downloader(Path("x.sh"))
        command = stream.call_args.args[0][-1]
        self.assertIn("MCBEDROCK_NONINTERACTIVE=1", command)

    def test_a_failed_build_reports_what_the_output_said(self):
        with mock.patch.object(wsl_backend, "_stream", return_value=1), \
                mock.patch.object(wsl_backend, "is_installed", return_value=False), \
                mock.patch.object(wsl_backend, "selected_distro", return_value="Ubuntu"), \
                mock.patch.object(Path, "is_file", return_value=True), \
                mock.patch.object(wsl_backend, "to_wsl_path", return_value="/mnt/c/x.sh"):
            with self.assertRaises(wsl_backend.WslError):
                wsl_backend.build_downloader(Path("x.sh"))

    def test_a_declined_administrator_prompt_is_explained_not_swallowed(self):
        if sys.platform != "win32":
            self.skipTest("Windows only")
        import ctypes

        with mock.patch.object(ctypes.windll.shell32, "ShellExecuteW", return_value=5):
            with self.assertRaisesRegex(wsl_backend.WslError, "declined"):
                wsl_backend.install_windows_feature()

    def test_a_started_installer_asks_for_a_restart(self):
        if sys.platform != "win32":
            self.skipTest("Windows only")
        import ctypes

        with mock.patch.object(ctypes.windll.shell32, "ShellExecuteW", return_value=42):
            with self.assertRaises(wsl_backend.RestartNeeded):
                wsl_backend.install_windows_feature()

    def test_the_legacy_adoption_gives_up_quietly_when_wsl_is_absent(self):
        with mock.patch.object(wsl_backend, "_run", side_effect=OSError("no wsl")):
            self.assertFalse(wsl_backend.adopt_legacy_install())

    def test_removal_reports_a_failure_rather_than_pretending(self):
        failed = subprocess.CompletedProcess([], 1, stdout=b"nope", stderr=b"")
        with mock.patch.object(subprocess, "run", return_value=failed), \
                mock.patch.object(wsl_backend, "selected_distro", return_value="Ubuntu"):
            with self.assertRaises(wsl_backend.WslError):
                wsl_backend.remove_distro()


if __name__ == "__main__":
    unittest.main()
