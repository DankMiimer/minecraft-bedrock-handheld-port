from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

TOOL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_DIR))
import catalog  # noqa: E402


ARM64 = [[971622101, "1.16.221.01", 0], [972105101, "1.21.51.01", 0]]
ARMHF = [
    [951622101, "1.16.221.01", 0],
    [871120101, "1.12.1.1", 0],
    [952605025, "1.26.50.25", 1],
    [871022002, "1.2.20.2", 1],
]


def fake_downloads(**overrides):
    """Stand in for the two versiondb files, one call per ABI."""
    bodies = {"arm64": json.dumps(ARM64), "armhf": json.dumps(ARMHF)}
    bodies.update(overrides)
    return lambda abi: bodies[abi]


class OrderingTests(unittest.TestCase):
    def test_numbers_sort_as_numbers(self):
        self.assertLess(catalog.version_key("1.9.0.5"), catalog.version_key("1.11.4.2"))
        self.assertLess(catalog.version_key("1.16.40.02"), catalog.version_key("1.16.221.01"))

    def test_zero_padding_is_not_a_different_version(self):
        self.assertEqual(catalog.version_key("1.16.40.02"), catalog.version_key("1.16.40.2"))

    def test_letter_suffix_does_not_crash_or_collide(self):
        self.assertNotEqual(catalog.version_key("0.1.1j"), catalog.version_key("0.1.1"))


class MergeTests(unittest.TestCase):
    def load(self, **overrides) -> catalog.Catalog:
        download = fake_downloads(**overrides)
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ, {"MCBEDROCK_CACHE_DIR": tmp}
        ), mock.patch.object(catalog, "_download", side_effect=download):
            return catalog.load()

    def test_both_abis_land_on_one_row(self):
        release = self.load().find("1.16.221.01")
        self.assertEqual(release.codes, {"arm64": 971622101, "armhf": 951622101})

    def test_newest_first(self):
        names = [release.name for release in self.load().releases]
        self.assertEqual(names[0], "1.26.50.25")
        self.assertEqual(names[-1], "1.2.20.2")

    def test_curated_note_is_attached(self):
        self.assertIn("Recommended", self.load().find("1.16.221.01").note)

    def test_curated_builds_missing_from_versiondb_survive(self):
        # 1.11.4.2 is in neither fake file, but its code is checked in.
        release = self.load().find("1.11.4.2")
        self.assertIsNotNone(release)
        self.assertEqual(release.codes["armhf"], 871110402)

    def test_higher_code_wins_for_a_repeated_name(self):
        repeated = json.dumps([[1035, "0.1.3", 0], [1036, "0.1.3", 0]])
        self.assertEqual(self.load(armhf=repeated).find("0.1.3").codes["armhf"], 1036)

    def test_abi_filter_hides_builds_without_a_code(self):
        available = self.load()
        self.assertIsNone(available.find("1.12.1.1").code_for("arm64"))
        self.assertNotIn("1.12.1.1", [r.name for r in available.select("arm64")])


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.catalog = catalog.Catalog(
            releases=[
                catalog.Release("1.26.50.25", {"armhf": 952605025}, beta=True),
                catalog.Release("1.21.124.2", {"armhf": 952112402}),
                catalog.Release("1.16.221.01", {"armhf": 951622101}, note="Recommended"),
                catalog.Release("1.12.1.1", {"armhf": 871120101}, beta=True, note="Tested"),
            ],
            source="test",
            complete=True,
        )

    def test_betas_are_hidden_by_default(self):
        names = [r.name for r in self.catalog.select("armhf")]
        self.assertNotIn("1.26.50.25", names)

    def test_a_tested_build_is_shown_even_when_versiondb_calls_it_beta(self):
        self.assertIn("1.12.1.1", [r.name for r in self.catalog.select("armhf")])

    def test_including_betas_shows_everything(self):
        self.assertEqual(len(self.catalog.select("armhf", include_beta=True)), 4)

    def test_search_puts_the_prefix_match_first(self):
        # "1.21.124.2" contains "1.12" as a substring; 1.12.1.1 still wins.
        names = [r.name for r in self.catalog.select("armhf", include_beta=True, query="1.12")]
        self.assertEqual(names[0], "1.12.1.1")
        self.assertIn("1.21.124.2", names)

    def test_search_also_matches_notes(self):
        names = [r.name for r in self.catalog.select("armhf", query="recommended")]
        self.assertEqual(names, ["1.16.221.01"])



class RendererTests(unittest.TestCase):
    """RenderDragon shipped platform by platform; only Android matters here.

    Timeline from minecraft.wiki/w/RenderDragon: Xbox 1.13, PS4 1.14, Windows 10
    1.16.200, Android not until 1.18.30 after three rounds of beta toggling.
    """

    def release(self, name: str, **kw) -> catalog.Release:
        return catalog.Release(name, {"arm64": 1, "armhf": 2}, **kw)

    def test_android_predates_renderdragon_all_the_way_to_1_18_30(self):
        # These look modern but are pre-RenderDragon on Android.
        for name in ("1.16.221.01", "1.17.41.01", "1.18.10.04", "1.18.20.25"):
            self.assertEqual(self.release(name).renderer("arm64"), "legacy", name)
            self.assertNotIn("guaranteed to stutter", self.release(name).advice("arm64"))

    def test_renderdragon_lands_on_android_at_1_18_30(self):
        for name in ("1.18.30.04", "1.19.0.05", "1.20.15.01", "1.26.44.3"):
            release = self.release(name)
            self.assertEqual(release.renderer("arm64"), "renderdragon", name)
            self.assertEqual(release.renderer_label("arm64"), "RenderDragon")
            self.assertIn("guaranteed to stutter", release.advice("arm64"))

    def test_only_1_21_51_01_dropped_renderdragon_and_only_on_arm64(self):
        original = self.release("1.21.51.01")
        self.assertEqual(original.renderer("arm64"), "legacy")
        # ARMv7 was never affected.
        self.assertEqual(original.renderer("armhf"), "renderdragon")

    def test_the_1_21_51_02_reupload_is_a_separate_build_and_still_flagged(self):
        # Mojang re-uploaded Android as .02 with RenderDragon back on; it has its
        # own Play code, so it is a different build, not the same one served
        # differently.
        reupload = self.release("1.21.51.02")
        self.assertEqual(reupload.renderer("arm64"), "renderdragon")
        self.assertIn("guaranteed to stutter", reupload.advice("arm64"))
        self.assertIn("take .01 instead", reupload.advice("arm64"))

    def test_the_two_1_21_51_builds_point_at_each_other(self):
        self.assertIn("1.21.51.02", self.release("1.21.51.01").advice("arm64"))
        self.assertNotIn("1.21.51.02", self.release("1.21.51.01").advice("armhf"))

    def test_neighbouring_1_21_builds_keep_renderdragon(self):
        # The exception is one build, not the whole 1.21 line.
        self.assertEqual(self.release("1.21.50.28").renderer("arm64"), "renderdragon")
        self.assertEqual(self.release("1.21.60.10").renderer("arm64"), "renderdragon")

    def test_tiny_ui_starts_immediately_above_the_recommended_build(self):
        self.assertFalse(self.release("1.16.221.01").tiny_ui)
        self.assertFalse(self.release("1.16.220.02").tiny_ui)
        for name in ("1.17.0.02", "1.21.51.01", "1.26.44.3"):
            self.assertTrue(self.release(name).tiny_ui, name)
            self.assertIn("tiny UI", self.release(name).advice("arm64"))

    def test_a_curated_note_keeps_its_warning_beside_it(self):
        release = self.release("1.21.51.01", note="Newest build")
        description = release.description("arm64")
        self.assertTrue(description.startswith("Newest build"))
        self.assertIn("tiny UI", description)

    def test_searching_for_the_warning_finds_the_builds_it_applies_to(self):
        available = catalog.Catalog(
            releases=[self.release("1.20.15.01"), self.release("1.16.221.01")],
            source="test",
            complete=True,
        )
        found = available.select("arm64", query="renderdragon")
        self.assertEqual([r.name for r in found], ["1.20.15.01"])


class EditionTests(unittest.TestCase):
    """Pocket Edition and Bedrock are different games; the list says which."""

    def release(self, name: str, **kw) -> catalog.Release:
        return catalog.Release(name, {"armhf": 1}, **kw)

    def test_below_1_2_is_pocket_edition(self):
        for name in ("0.1.1j", "0.15.10.1", "1.0.5.0", "1.1.5.1"):
            self.assertEqual(self.release(name).edition, "Pocket Edition", name)

    def test_1_2_and_above_is_bedrock(self):
        # 1.2 is the Better Together Update, where the rename happened.
        for name in ("1.2.20.2", "1.11.4.2", "1.16.221.01", "1.26.44.3"):
            self.assertEqual(self.release(name).edition, "Bedrock", name)

    def test_beta_is_spelled_out_now_that_the_type_column_is_gone(self):
        self.assertIn("beta/preview build",
                      self.release("1.26.50.25", beta=True).advice("armhf"))
        self.assertNotIn("beta", self.release("1.16.221.01").advice("armhf"))

    def test_pocket_edition_warns_that_it_is_touch_only(self):
        self.assertIn("touch controls only", self.release("1.1.5.1").advice("armhf"))

    def test_bedrock_does_not_carry_the_touch_warning(self):
        self.assertNotIn("touch", self.release("1.16.221.01").advice("armhf"))



class UpdateNameTests(unittest.TestCase):
    """Names come from minecraft.wiki infoboxes, not from recollection."""

    def name_for(self, version: str) -> str:
        return catalog.Release(version, {"arm64": 1}).update_name

    def test_the_headline_updates(self):
        self.assertEqual(self.name_for("1.16.221.01"), "Nether Update")
        self.assertEqual(self.name_for("1.2.20.2"), "Better Together Update")
        self.assertEqual(self.name_for("1.21.51.01"), "Tricky Trials")
        self.assertEqual(self.name_for("1.0.5.0"), "Ender Update")

    def test_any_patch_of_a_major_version_inherits_its_name(self):
        for version in ("1.16.0.2", "1.16.40.02", "1.16.221.01"):
            self.assertEqual(self.name_for(version), "Nether Update", version)

    def test_the_two_halves_of_caves_and_cliffs_are_distinguished(self):
        self.assertEqual(self.name_for("1.17.41.01"), "Caves & Cliffs: Part I")
        self.assertEqual(self.name_for("1.18.0.02"), "Caves & Cliffs: Part II")

    def test_unnamed_releases_stay_blank_rather_than_invented(self):
        for version in ("1.7.0.5", "1.12.1.1", "1.26.44.3", "0.11.0.1"):
            self.assertEqual(self.name_for(version), "", version)


class SourceTests(unittest.TestCase):
    def test_offline_with_no_cache_falls_back_to_the_checked_in_builds(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ, {"MCBEDROCK_CACHE_DIR": tmp}
        ), mock.patch.object(catalog, "_download", side_effect=urllib.error.URLError("offline")):
            available = catalog.load()
        self.assertFalse(available.complete)
        self.assertEqual(
            {r.name for r in available.releases}, set(catalog.CURATED)
        )
        self.assertIsNotNone(available.find("1.16.221.01").code_for("arm64"))

    def test_a_saved_list_is_reused_without_asking_github_again(self):
        download = mock.Mock(side_effect=fake_downloads())
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ, {"MCBEDROCK_CACHE_DIR": tmp}
        ), mock.patch.object(catalog, "_download", download):
            catalog.load()
            self.assertEqual(download.call_count, 2)
            catalog.load()
            self.assertEqual(download.call_count, 2)
            catalog.load(force_refresh=True)
            self.assertEqual(download.call_count, 4)

    def test_a_stale_list_is_used_when_github_cannot_be_reached(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ, {"MCBEDROCK_CACHE_DIR": tmp}
        ):
            with mock.patch.object(catalog, "_download", side_effect=fake_downloads()):
                catalog.load()
            for path in Path(tmp).glob("*.json.min"):
                os.utime(path, (0, time.time() - 10 * catalog.CACHE_MAX_AGE_SECONDS))
            with mock.patch.object(
                catalog, "_download", side_effect=urllib.error.URLError("offline")
            ):
                available = catalog.load()
        self.assertTrue(available.complete)
        self.assertIsNotNone(available.find("1.12.1.1"))

    def test_a_corrupt_saved_list_does_not_take_the_app_down(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ, {"MCBEDROCK_CACHE_DIR": tmp}
        ):
            Path(tmp).mkdir(exist_ok=True)
            for abi in catalog.ABI_DB:
                path = Path(tmp) / f"versions.{catalog.ABI_DB[abi]}.json.min"
                path.write_text("{not json", encoding="utf-8")
            with mock.patch.object(
                catalog, "_download", side_effect=urllib.error.URLError("offline")
            ):
                available = catalog.load()
        self.assertFalse(available.complete)
        self.assertTrue(available.releases)


if __name__ == "__main__":
    unittest.main()
