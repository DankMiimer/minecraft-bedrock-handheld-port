from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parents[1]
PACKAGER = TOOL_DIR / "package_release.py"
EXPECTED = {
    "README.md",
    "mcbedrock-get.exe",
    "mcbedrock-get-NOTICES.txt",
    "Create desktop shortcut.cmd",
    "setup-downloader.sh",
}


class PackageTests(unittest.TestCase):
    def test_bundle_is_deterministic_and_complete(self):
        with tempfile.TemporaryDirectory() as tmp_text:
            tmp = Path(tmp_text)
            inputs = tmp / "inputs"
            first = tmp / "first"
            second = tmp / "second"
            inputs.mkdir()
            (inputs / "mcbedrock-get.exe").write_bytes(b"fake executable")
            (inputs / "mcbedrock-get-NOTICES.txt").write_text(
                "generated notices\n", encoding="utf-8"
            )
            for output in (first, second):
                subprocess.run(
                    [
                        sys.executable,
                        str(PACKAGER),
                        "--version",
                        "9.9.9-test",
                        "--dist",
                        str(inputs),
                        "--out-dir",
                        str(output),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            name = "mcbedrock-get-windows-v9.9.9-test.zip"
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())
            with zipfile.ZipFile(first / name) as archive:
                self.assertEqual(set(archive.namelist()), EXPECTED)
                for info in archive.infolist():
                    self.assertEqual(info.date_time, (2026, 1, 1, 0, 0, 0))
                    self.assertEqual((info.external_attr >> 16) & 0o777, 0o644)


if __name__ == "__main__":
    unittest.main()
