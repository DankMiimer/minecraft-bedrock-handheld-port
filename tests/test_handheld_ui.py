"""Protect other packs and shared profiles when the optional UI changes version."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

PAYLOAD = Path(__file__).resolve().parents[1] / "portmaster/minecraftbedrock/minecraftbedrock"
spec = importlib.util.spec_from_file_location("handheld_ui", PAYLOAD / "handheld_ui.py")
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.profile = Path(self.tmp.name)
        self.activation = self.profile / "mcpelauncher/games/com.mojang/minecraftpe/global_resource_packs.json"
        self.other = {"pack_id": "other-user-pack", "version": [4, 2, 1], "subpack": "custom"}
        ui.atomic_json(self.activation, [self.other])

    def sync(self, request=None, version=ui.TARGET_VERSION, digest=ui.TARGET_SHA256, abi="arm64"):
        return ui.sync(PAYLOAD, self.profile, version, digest, request, abi)

    def packs(self):
        return json.loads(self.activation.read_text())

    def test_default_off_does_not_rewrite_user_state(self):
        before = self.activation.read_bytes()
        self.assertFalse(self.sync()["enabled"])
        self.assertEqual(before, self.activation.read_bytes())

    def test_on_off_preserves_other_pack_fields(self):
        self.assertTrue(self.sync(True)["enabled"])
        self.assertEqual(self.packs()[1], self.other)
        self.sync()
        self.assertEqual(len(self.packs()), 2)
        self.sync(False)
        self.assertEqual(self.packs(), [self.other])
        self.assertFalse(self.sync()["enabled"])
        self.assertTrue(list((self.profile / "handheld-ui-backups").iterdir()))

    def test_unused_feature_does_not_require_valid_unrelated_pack_state(self):
        self.activation.write_text("unrelated preexisting state")
        self.assertFalse(self.sync()["enabled"])
        self.assertEqual(self.activation.read_text(), "unrelated preexisting state")

    def test_version_switch_disables_then_restores_requested_pack(self):
        self.sync(True)
        self.assertFalse(self.sync(version="1.16.221.01-971622101-arm64")["enabled"])
        self.assertEqual(self.packs(), [self.other])
        self.assertTrue(self.sync()["enabled"])

    def test_wrong_library_and_abi_disable_pack(self):
        self.sync(True)
        self.assertFalse(self.sync(digest="different-library")["enabled"])
        self.assertEqual(self.packs(), [self.other])
        self.assertFalse(self.sync(abi="armhf")["enabled"])
        with self.assertRaises(ValueError):
            self.sync(True, digest="different-library")

    def test_malformed_activation_is_preserved(self):
        self.activation.write_text("{broken user state")
        before = self.activation.read_bytes()
        with self.assertRaises(ValueError):
            self.sync(True)
        self.assertEqual(self.activation.read_bytes(), before)
        self.assertFalse((self.profile / "handheld-ui.json").exists())

    def test_existing_unrelated_directory_is_not_overwritten(self):
        manifest = self.profile / "mcpelauncher/games/com.mojang/resource_packs/handheld-ui/manifest.json"
        ui.atomic_json(manifest, {"header": {"uuid": "someone-elses-pack"}})
        with self.assertRaises(ValueError):
            self.sync(True)
        self.assertEqual(self.packs(), [self.other])
        self.assertEqual(json.loads(manifest.read_text())["header"]["uuid"], "someone-elses-pack")


if __name__ == "__main__":
    unittest.main()
