"""Every Minecraft Bedrock build the downloader can ask Play for.

Play needs a *version code*, not a version name, and the codes are not derivable
from the name: the encoding changed by era (1.11/1.12 use an "87" prefix,
1.13.0.16+ switch to "94", 1.16.221 uses "95" for armeabi-v7a and "97" for
arm64-v8a). The authoritative mapping is minecraft-linux/mcpelauncher-versiondb,
so this module reads it rather than guessing.

Three sources, in order, so the window always has something to show:

1. the live versiondb files on GitHub,
2. the copy cached under the user's profile from the last successful fetch,
3. CURATED below — the hand-tested builds, whose codes are checked in.

Only step 3 is guaranteed offline, which is why the codes stay written down here
even though versiondb also carries them.
"""
from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

VERSIONDB_URL = (
    "https://raw.githubusercontent.com/minecraft-linux/mcpelauncher-versiondb"
    "/master/versions.{db}.json.min"
)

# The app's own ABI names, and the versiondb file each one is listed in.
ABI_DB = {"arm64": "arm64-v8a", "armhf": "armeabi-v7a"}
ABI_LABELS = {"arm64": "arm64-v8a", "armhf": "armeabi-v7a"}

# A day is far more often than versiondb changes, and a stale list only costs
# the user a version that came out this week.
CACHE_MAX_AGE_SECONDS = 24 * 60 * 60
FETCH_TIMEOUT_SECONDS = 20

# Pocket Edition predates gamepad support entirely: it is a touch-only game, so
# on a handheld with physical buttons it is not merely old, it is unplayable
# without something synthesising touches.
#
# Where "Minecraft: Pocket Edition" became "Minecraft" (Bedrock Edition): the
# 1.2 Better Together Update. Everything below 1.2 in this list is Pocket
# Edition — a different game to set expectations about, not just an old build.
# The Android package name never changed (com.mojang.minecraftpe), so the
# version number is the only thing that says which one you are getting.
BEDROCK_FROM = "1.2"

# The named update each major version belongs to, keyed by (major, minor).
#
# Taken from the "name" field of the infobox on each minecraft.wiki release
# page, not from memory. Versions absent here shipped without a marketing name
# (1.7, 1.8, 1.12, 1.26, and the 0.9-0.13 alphas), and the column is simply left
# blank for them rather than inventing one. 1.6 and 1.13 have no name field but
# their pages describe them as delivering the rest of Update Aquatic and Village
# & Pillage respectively.
UPDATE_NAMES = {
    (0, 14): "Overworld Update",
    (0, 15): "Friendly Update",
    (0, 16): "Boss Update",
    (1, 0): "Ender Update",
    (1, 1): "Discovery Update",
    (1, 2): "Better Together Update",
    (1, 4): "Update Aquatic",
    (1, 5): "Update Aquatic",
    (1, 6): "Update Aquatic",
    (1, 9): "Village & Pillage",
    (1, 10): "Texture Update",
    (1, 11): "Village & Pillage",
    (1, 13): "Village & Pillage",
    (1, 14): "Buzzy Bees",
    (1, 16): "Nether Update",
    (1, 17): "Caves & Cliffs: Part I",
    (1, 18): "Caves & Cliffs: Part II",
    (1, 19): "The Wild Update",
    (1, 20): "Trails & Tales",
    (1, 21): "Tricky Trials",
}

# Where Mojang's new renderer arrives ON ANDROID, which is the only platform
# this tool downloads. RenderDragon shipped platform by platform over three
# years, and the familiar dates are the Windows ones: Xbox at 1.13, PS4 at 1.14,
# Windows 10 at 1.16.200. Android came last and was switched on and off through
# the 1.17.40, 1.18.10 and 1.18.20 betas before sticking at 1.18.30.
# (minecraft.wiki/w/RenderDragon, "Bedrock Edition" history table.)
#
# So an Android 1.17 or 1.18.20 release build does NOT have it, however much the
# version number looks like it should.
RENDERDRAGON_FROM = "1.18.30"

# ...and one build had it switched off by accident. The original Android
# release of 1.21.51, on December 9 2024, shipped with RenderDragon disabled for
# ARMv8 (arm64) — which is the only reason a build this recent is usable here.
# ARMv7 was unaffected and kept it.
#
# Two days later Mojang re-uploaded Android as 1.21.51.02 to turn it back on, so
# these are two SEPARATE builds with two separate Play codes (972105101 and
# 972105102), not one name serving different files. Asking for a version code
# gets exactly the build asked for.
NO_RENDERDRAGON = {("1.21.51.01", "arm64")}

# Extra context for exactly those two builds, so neither is picked by accident.
RENDERER_NOTES = {
    ("1.21.51.01", "arm64"): "RenderDragon was left switched off by mistake in "
                             "this original release — take this, not the "
                             "1.21.51.02 re-upload",
    ("1.21.51.02", "arm64"): "the Android re-upload of 1.21.51.01 with "
                             "RenderDragon switched back on — take .01 instead",
}

# Above this, the UI is drawn too small to use comfortably on a handheld
# screen. It is why 1.16.221.01 is the recommended build and not the newest
# no-RenderDragon one.
BEST_UI = "1.16.221.01"

# Hand-tested builds: name -> (codes by ABI, why anyone would pick it).
#
# NB: never derive a code by pattern; every one of these was looked up in
# versiondb. Neighbours for bisecting the launcher's version floor:
#   1.11.4.2 = 871110402   1.13.1.5 = 941130105  (both armeabi-v7a)
CURATED: dict[str, tuple[dict[str, int], str]] = {
    "1.2.20.2": (
        {"armhf": 871022002},
        "Last 1.2 — oldest modern-launcher target tried (no-GPU MM+)",
    ),
    "1.6.0.30": (
        {"armhf": 871060030},
        "Last 1.6 — lighter engine again (no-GPU MM+)",
    ),
    "1.9.0.5": (
        {"armhf": 871090005},
        "Last 1.9 — next rung down from 1.11 (no-GPU MM+)",
    ),
    "1.11.4.2": (
        {"armhf": 871110402},
        "BEST measured MM+ build: 7.03 fps, 2% stalls",
    ),
    "1.12.1.1": (
        {"armhf": 871120101},
        "Last 1.12 — 5-chunk floor, near-best on MM+",
    ),
    "1.16.0.2": (
        {"armhf": 941160002},
        "Earliest 1.16 — smallest footprint (experimental)",
    ),
    "1.16.40.02": (
        {"arm64": 943164002, "armhf": 941164002},
        "Early legacy-GLES build, both ABIs",
    ),
    "1.16.221.01": (
        {"arm64": 971622101, "armhf": 951622101},
        "Recommended — best UI scaling on a small screen",
    ),
    "1.21.51.01": (
        {"arm64": 972105101},
        "Newest build the port can use",
    ),
}


class CatalogError(RuntimeError):
    """A failure the user can act on."""


def version_key(name: str) -> tuple:
    """Order builds the way a human reads them: 1.9.0.5 before 1.11.4.2.

    Names are not plain numbers — early ones carry a letter ("0.1.1j"), and the
    parts are not zero-padded consistently ("1.16.40.02" next to "1.16.0.2"), so
    compare the numbers as numbers and keep the leftover text as a tie-break.
    """
    numbers = [int(part) for part in re.findall(r"\d+", name)]
    numbers += [0] * (4 - len(numbers))
    return tuple(numbers), re.sub(r"[\d.]", "", name)


@dataclass(frozen=True)
class Release:
    """One Minecraft version, with the Play code for each ABI that has one."""

    name: str
    codes: dict[str, int] = field(default_factory=dict)
    beta: bool = False
    note: str = ""

    @property
    def curated(self) -> bool:
        return bool(self.note)

    def code_for(self, abi: str) -> int | None:
        return self.codes.get(abi)

    def supports(self, abi: str) -> bool:
        return abi in self.codes

    @property
    def update_name(self) -> str:
        """"Nether Update", "Better Together Update", … or "" if unnamed."""
        numbers = version_key(self.name)[0]
        return UPDATE_NAMES.get((numbers[0], numbers[1]), "")

    @property
    def edition(self) -> str:
        if version_key(self.name) < version_key(BEDROCK_FROM):
            return "Pocket Edition"
        return "Bedrock"

    def renderer(self, abi: str) -> str:
        """'legacy' or 'renderdragon' — which depends on the ABI, not just the
        version: 1.21.51.01 dropped RenderDragon on arm64 and kept it on armhf."""
        if (self.name, abi) in NO_RENDERDRAGON:
            return "legacy"
        if version_key(self.name) >= version_key(RENDERDRAGON_FROM):
            return "renderdragon"
        return "legacy"

    def renderer_label(self, abi: str) -> str:
        return "RenderDragon" if self.renderer(abi) == "renderdragon" else "No RenderDragon"

    @property
    def tiny_ui(self) -> bool:
        return version_key(self.name) > version_key(BEST_UI)

    def advice(self, abi: str) -> str:
        """The warning this build has earned, if any."""
        parts = []
        if self.edition == "Pocket Edition":
            parts.append("touch controls only — no gamepad support")
        if self.beta:
            parts.append("beta/preview build")
        if self.renderer(abi) == "renderdragon":
            parts.append("RenderDragon — guaranteed to stutter, do not use")
        extra = RENDERER_NOTES.get((self.name, abi))
        if extra:
            parts.append(extra)
        if self.tiny_ui:
            parts.append("tiny UI on a handheld screen")
        return " · ".join(parts)

    def description(self, abi: str) -> str:
        """What the Notes column shows: why to pick it, and why not to."""
        return " · ".join(part for part in (self.note, self.advice(abi)) if part)


@dataclass(frozen=True)
class Catalog:
    """Every known release, newest first, plus where the list came from."""

    releases: list[Release]
    source: str
    complete: bool

    def find(self, name: str) -> Release | None:
        wanted = version_key(name)
        return next((r for r in self.releases if version_key(r.name) == wanted), None)

    def select(self, abi: str, include_beta: bool = False, query: str = "") -> list[Release]:
        """The rows to show: this ABI only, filtered by the beta and search boxes.

        Curated builds ignore the beta filter. Several of them (1.2.20.2,
        1.6.0.30, 1.9.0.5) are flagged beta in versiondb, and hiding the builds
        this port was tuned on would be the opposite of helpful.

        Typing "1.12" has to reach 1.12.1.1 first. A plain substring test does
        not: "1.21.124.2" contains "1.12" too, and there are dozens of those. So
        names that START with what was typed come first, and everything else
        that merely mentions it follows, each half still newest-first.
        """
        text = query.strip().lower()
        leading, trailing = [], []
        for release in self.releases:
            if not release.supports(abi):
                continue
            if release.beta and not include_beta and not release.curated:
                continue
            if not text:
                leading.append(release)
            elif release.name.lower().startswith(text):
                leading.append(release)
            elif text in release.name.lower() or text in release.description(abi).lower():
                trailing.append(release)
        return leading + trailing


# --------------------------------------------------------------------------
# cache
# --------------------------------------------------------------------------

def cache_dir() -> Path:
    override = os.environ.get("MCBEDROCK_CACHE_DIR", "").strip()
    if override:
        return Path(override)
    root = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return Path(root) / "mcbedrock-get" / "versiondb"


def _cache_file(abi: str) -> Path:
    return cache_dir() / f"versions.{ABI_DB[abi]}.json.min"


def _read_cache(abi: str) -> tuple[str | None, float]:
    path = _cache_file(abi)
    try:
        return path.read_text(encoding="utf-8"), path.stat().st_mtime
    except OSError:
        return None, 0.0


def _write_cache(abi: str, text: str) -> None:
    path = _cache_file(abi)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        # Write beside and rename, so a half-written file can never be read back
        # as a truncated version list.
        temporary = path.with_suffix(".part")
        temporary.write_text(text, encoding="utf-8")
        temporary.replace(path)
    except OSError:
        pass  # A cache that cannot be written is not worth failing a download over.


def _download(abi: str) -> str:
    url = VERSIONDB_URL.format(db=ABI_DB[abi])
    request = urllib.request.Request(url, headers={"User-Agent": "mcbedrock-get"})
    with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_SECONDS) as response:
        return response.read().decode("utf-8")


def _parse(text: str) -> list[tuple[int, str, bool]]:
    """versiondb ships [[code, name, isBeta], …]; reject anything else."""
    try:
        raw = json.loads(text)
    except ValueError as error:
        raise CatalogError(f"The version list is not valid JSON: {error}") from error
    entries = []
    for item in raw if isinstance(raw, list) else []:
        if not isinstance(item, list) or len(item) < 2:
            continue
        try:
            code, name = int(item[0]), str(item[1])
        except (TypeError, ValueError):
            continue
        if name:
            entries.append((code, name, bool(item[2]) if len(item) > 2 else False))
    if not entries:
        raise CatalogError("The version list arrived empty.")
    return entries


# --------------------------------------------------------------------------
# assembly
# --------------------------------------------------------------------------

def _curated_only() -> list[Release]:
    releases = [
        Release(name=name, codes=dict(codes), beta=False, note=note)
        for name, (codes, note) in CURATED.items()
    ]
    return sorted(releases, key=lambda r: version_key(r.name), reverse=True)


def _merge(per_abi: dict[str, list[tuple[int, str, bool]]]) -> list[Release]:
    """Fold the per-ABI files into one row per version name.

    A name can appear more than once in a single file (0.1.3 is listed as both
    1035 and 1036). The higher code is the later build of that name, and that is
    the one Play will still serve.
    """
    codes: dict[str, dict[str, int]] = {}
    betas: dict[str, list[bool]] = {}
    for abi, entries in per_abi.items():
        for code, name, beta in entries:
            slot = codes.setdefault(name, {})
            if code > slot.get(abi, 0):
                slot[abi] = code
            betas.setdefault(name, []).append(beta)

    # Curated names are written the way versiondb writes them, but compare on the
    # numeric key anyway so a "1.16.40.2" spelling still picks up its note.
    notes = {version_key(name): note for name, (_, note) in CURATED.items()}
    releases = []
    for name, abi_codes in codes.items():
        releases.append(
            Release(
                name=name,
                codes=abi_codes,
                # Only beta when no ABI calls it a release build.
                beta=all(betas[name]),
                note=notes.get(version_key(name), ""),
            )
        )

    # Anything curated but missing from versiondb still belongs in the list.
    known = {version_key(r.name) for r in releases}
    releases += [r for r in _curated_only() if version_key(r.name) not in known]
    return sorted(releases, key=lambda r: version_key(r.name), reverse=True)


def load(
    force_refresh: bool = False,
    on_status: Callable[[str], None] | None = None,
) -> Catalog:
    """Build the catalog from the freshest source that answers.

    Never raises: a downloader that will not open because GitHub is unreachable
    is worse than one showing the nine builds whose codes are checked in.
    """
    def say(text: str) -> None:
        if on_status is not None:
            on_status(text)

    per_abi: dict[str, list[tuple[int, str, bool]]] = {}
    stale = False
    fetched = False
    for abi in ABI_DB:
        cached, age = _read_cache(abi)
        fresh_enough = cached and (time.time() - age) < CACHE_MAX_AGE_SECONDS
        if cached and fresh_enough and not force_refresh:
            try:
                per_abi[abi] = _parse(cached)
                continue
            except CatalogError:
                pass  # Fall through and re-fetch a corrupt cache.

        say(f"Getting the {ABI_LABELS[abi]} version list…")
        try:
            text = _download(abi)
            per_abi[abi] = _parse(text)
            _write_cache(abi, text)
            fetched = True
            continue
        except (urllib.error.URLError, OSError, CatalogError, ValueError):
            pass

        if cached:
            try:
                per_abi[abi] = _parse(cached)
                stale = True
                continue
            except CatalogError:
                pass

    if not per_abi:
        return Catalog(
            releases=_curated_only(),
            source="offline — showing the built-in tested builds only",
            complete=False,
        )

    releases = _merge(per_abi)
    if stale or len(per_abi) < len(ABI_DB):
        source = f"{len(releases)} builds from the last saved version list"
    elif fetched:
        source = f"{len(releases)} builds from mcpelauncher-versiondb"
    else:
        source = f"{len(releases)} builds (saved version list)"
    return Catalog(releases=releases, source=source, complete=True)


def names(releases: Iterable[Release]) -> str:
    return ", ".join(release.name for release in releases)
