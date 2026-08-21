#!/usr/bin/env python3
from __future__ import annotations
import hashlib, json, os, shutil, struct, subprocess, sys, tempfile, time, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "portmaster" / "minecraftbedrock" / "minecraftbedrock" / "apkmeta.py"
VERSION_HELPER = ROOT / "portmaster" / "minecraftbedrock" / "minecraftbedrock" / "version_env.py"
GROUP_HELPER = ROOT / "portmaster" / "minecraftbedrock" / "minecraftbedrock" / "apk_groups.py"
sys.path.insert(0, str(HELPER.parent))
from apkmeta import (InstallError, JOURNAL_NAME, _apk_signing_certificate,
                     recover_incomplete_install)  # noqa: E402
from migrate_version_metadata import (cached_library_hash,
                                      library_stat)  # noqa: E402


def string_pool(strings: list[str]) -> bytes:
    offsets, body = [], bytearray()
    for text in strings:
        encoded = text.encode()
        assert len(text) < 128 and len(encoded) < 128
        offsets.append(len(body))
        body.extend((len(text), len(encoded)))
        body.extend(encoded)
        body.append(0)
    while len(body) % 4: body.append(0)
    start = 28 + 4 * len(strings)
    size = start + len(body)
    return (struct.pack("<HHI", 1, 28, size) +
            struct.pack("<IIIII", len(strings), 0, 0x100, start, 0) +
            struct.pack(f"<{len(offsets)}I", *offsets) + body)


def axml(package: str, version: str | None, code: int, split: str | None = None) -> bytes:
    strings = ["manifest", "package", "versionCode", package]
    if version is not None: strings += ["versionName", version]
    if split: strings += ["split", split]
    index = {value: i for i, value in enumerate(strings)}
    pool = string_pool(strings)
    resources = [0] * len(strings)
    resources[index["versionCode"]] = 0x0101021B
    if version is not None: resources[index["versionName"]] = 0x0101021C
    resource_chunk = struct.pack("<HHI", 0x0180, 8, 8 + 4 * len(resources)) + struct.pack(f"<{len(resources)}I", *resources)
    attrs = []
    def attr(name: str, raw: int, dtype: int, value: int):
        attrs.append(struct.pack("<IIIHBBI", 0xFFFFFFFF, index[name], raw, 8, 0, dtype, value))
    attr("package", index[package], 3, index[package])
    attr("versionCode", 0xFFFFFFFF, 0x10, code)
    if version is not None: attr("versionName", index[version], 3, index[version])
    if split: attr("split", index[split], 3, index[split])
    ext = struct.pack("<IIHHHHHH", 0xFFFFFFFF, index["manifest"], 20, 20, len(attrs), 0, 0, 0)
    start_size = 8 + 8 + len(ext) + sum(map(len, attrs))
    start = struct.pack("<HHI", 0x0102, 16, start_size) + struct.pack("<II", 1, 0xFFFFFFFF) + ext + b"".join(attrs)
    total = 8 + len(pool) + len(resource_chunk) + len(start)
    return struct.pack("<HHI", 3, 8, total) + pool + resource_chunk + start


def apk(path: Path, version: str | None, code: int, role: str, cert: bytes | None = b"official-fixture", pairip: bool = False):
    split = None if role in {"full", "base"} else {"native": "config.arm64_v8a", "assets": "install_pack"}[role]
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("AndroidManifest.xml", axml("com.mojang.minecraftpe", version, code, split))
        if cert is not None:
            archive.writestr("META-INF/CERT.RSA", cert)
        if role in {"full", "native"}:
            archive.writestr("lib/arm64-v8a/libminecraftpe.so", b"fixture-game-lib")
            archive.writestr("lib/arm64-v8a/libfmod.so", b"fixture-fmod")
            if pairip: archive.writestr("lib/arm64-v8a/libpairipcore.so", b"pairip")
        if role in {"full", "assets"}:
            archive.writestr("assets/assets/resource_packs/vanilla/manifest.json", "{}")


def lp32(value: bytes) -> bytes:
    return struct.pack("<I", len(value)) + value


def add_fake_v2_signer(path: Path, certificate: bytes) -> None:
    data = path.read_bytes()
    eocd = data.rfind(b"PK\x05\x06")
    assert eocd >= 0
    central = struct.unpack_from("<I", data, eocd + 16)[0]
    signed_data = lp32(b"") + lp32(lp32(certificate)) + lp32(b"")
    signer = lp32(signed_data) + lp32(b"") + lp32(b"fixture-public-key")
    value = lp32(lp32(signer))
    pair = struct.pack("<Q", 4 + len(value)) + struct.pack("<I", 0x7109871A) + value
    block_size = len(pair) + 24
    block = struct.pack("<Q", block_size) + pair + struct.pack("<Q", block_size) + b"APK Sig Block 42"
    result = bytearray(data[:central] + block + data[central:])
    struct.pack_into("<I", result, eocd + len(block) + 16, central + len(block))
    path.write_bytes(result)


def invoke(game: Path, *paths: Path, ok: bool = True):
    env = os.environ.copy()
    env["MCPE_ALLOW_UNVERIFIED_APK"] = "1"
    env["MCPE_INSTALL_SYNC"] = "0"
    result = subprocess.run([sys.executable, str(HELPER), "--install", "--gamedir", str(game), *map(str, paths)], text=True, capture_output=True, env=env)
    if ok and result.returncode:
        raise AssertionError(result.stderr + result.stdout)
    if not ok and result.returncode == 0:
        raise AssertionError("install unexpectedly succeeded")
    return result


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="apkmeta-test-") as tmpstr:
        tmp = Path(tmpstr); game = tmp / "game"; (game / "versions").mkdir(parents=True)
        (game / "compat").mkdir()
        shutil.copy2(ROOT / "portmaster/minecraftbedrock/minecraftbedrock/compat/compatibility.json",
                     game / "compat/compatibility.json")
        registry_path = game / "compat/compatibility.json"
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        fixture_hash = hashlib.sha256(b"fixture-game-lib").hexdigest()
        fallback_index = next(
            index for index, row in enumerate(registry["versions"])
            if row["version"] == "1.21.51.01" and row["abi"] == "arm64"
            and not row.get("game_library_sha256")
        )
        registry["versions"].insert(fallback_index, {
            "version": "1.21.51.01", "abi": "arm64",
            "game_library_sha256": fixture_hash, "status": "best_effort",
            "profile": "default", "renderer_profile": "test_no_renderdragon",
            "recommendation": "newest_tested_no_renderdragon",
        })
        registry_path.write_text(json.dumps(registry), encoding="utf-8")
        (tmp / "v2").mkdir()
        v2 = tmp / "v2" / "v2-only.apk"; apk(v2, "1.21.51.01", 972105101, "base", cert=None)
        fake_certificate = b"fixture-v2-certificate"
        add_fake_v2_signer(v2, fake_certificate)
        parsed_certificate, verified = _apk_signing_certificate(v2)
        assert parsed_certificate == fake_certificate and not verified
        full = tmp / "full.apk"; apk(full, "1.20.62.02", 972007102, "full")
        strict = subprocess.run(
            [sys.executable, str(HELPER), "--install", "--gamedir", str(game), str(full)],
            text=True, capture_output=True,
        )
        assert strict.returncode != 0 and "signing certificate" in strict.stderr
        invoke(game, full)
        target = game / "versions" / "1.20.62.02-972007102-arm64"
        assert (target / "lib/arm64-v8a/libminecraftpe.so").is_file()
        assert (target / "assets/assets/resource_packs/vanilla/manifest.json").is_file()
        assert json.loads((target / "version.json").read_text())["version_name"] == "1.20.62.02"
        assert json.loads((target / "version.json").read_text())["schema"] == 2
        target_metadata = json.loads((target / "version.json").read_text())
        target_library = target / "lib/arm64-v8a/libminecraftpe.so"
        assert target_metadata["game_library_stat"] == library_stat(target_library)

        cached = "a" * 64
        assert cached_library_hash(
            {"game_library_sha256": cached,
             "game_library_stat": library_stat(target_library)},
            target_library, library_stat(target_library),
        ) == cached
        target_library.write_bytes(b"changed-game-lib")
        assert cached_library_hash(
            {"game_library_sha256": cached,
             "game_library_stat": target_metadata["game_library_stat"]},
            target_library, library_stat(target_library),
        ) == hashlib.sha256(b"changed-game-lib").hexdigest()
        # Restore the fixture used by the following compatibility assertions.
        target_library.write_bytes(b"fixture-game-lib")
        env_result = subprocess.run(
            [sys.executable, str(VERSION_HELPER), str(game), str(target)],
            text=True, capture_output=True, check=True,
        )
        assert "MCPE_BEDROCK_VERSION_NAME=1.20.62.02" in env_result.stdout
        assert "MCPE_COMPACTION_AVAILABLE=1" in env_result.stdout

        base, native, assets = tmp / "base.apk", tmp / "native.apk", tmp / "assets.apk"
        apk(base, "1.17.41.01", 97174101, "base")
        # Real Android split manifests often inherit versionName from the base.
        apk(native, None, 97174101, "native")
        apk(assets, None, 97174101, "assets")
        invoke(game, base, native, assets)
        assert (game / "versions" / "1.17.41.01-97174101-arm64").is_dir()
        groups = tmp / "groups"
        env = os.environ.copy(); env["MCPE_ALLOW_UNVERIFIED_APK"] = "1"
        subprocess.run([sys.executable, str(GROUP_HELPER), str(tmp), str(groups)], check=True, env=env)
        group_rows = (groups / "index.tsv").read_text().splitlines()
        # ready flag, then the untested reason (empty for in-range builds)
        assert len(group_rows) == 2
        assert all(row.split("\t")[3:] == ["1", ""] for row in group_rows), group_rows
        first_index_mtime = (groups / "index.tsv").stat().st_mtime_ns
        time.sleep(0.02)
        subprocess.run([sys.executable, str(GROUP_HELPER), str(tmp), str(groups)], check=True, env=env)
        assert (groups / "index.tsv").stat().st_mtime_ns == first_index_mtime
        assert json.loads((groups / ".input-state.json").read_text())["schema"] == 2

        # APKMirror/APKPure/Split APK Installer containers are outer ZIPs of
        # ordinary APKs. They must be expanded privately while metadata keeps
        # the original user-supplied filename for provenance.
        bundle_parts = tmp / "bundle-parts"
        bundle_parts.mkdir()
        bundle_base = bundle_parts / "base.apk"
        bundle_native = bundle_parts / "config.arm64_v8a.apk"
        bundle_assets = bundle_parts / "install_pack.apk"
        apk(bundle_base, "1.16.221.01", 971622101, "base")
        apk(bundle_native, None, 971622101, "native")
        apk(bundle_assets, None, 971622101, "assets")
        bundle = tmp / "minecraft.apkm"
        with zipfile.ZipFile(bundle, "w") as archive:
            archive.write(bundle_base, "splits/base.apk")
            archive.write(bundle_native, "splits/config.arm64_v8a.apk")
            archive.write(bundle_assets, "install_pack.apk")
        invoke(game, bundle)
        bundle_target = game / "versions/1.16.221.01-971622101-arm64"
        bundle_metadata = json.loads((bundle_target / "version.json").read_text(encoding="utf-8"))
        assert bundle_metadata["sources"] == ["minecraft.apkm"]
        assert len(bundle_metadata["source_members"]) == 3
        assert not any(path.name == "bundle-apks" for path in (game / "versions").iterdir())

        empty_bundle = tmp / "not-an-apk-set.xapk"
        with zipfile.ZipFile(empty_bundle, "w") as archive:
            archive.writestr("manifest.json", "{}")
        rejected_bundle = invoke(game, empty_bundle, ok=False)
        assert "contains no APK files" in rejected_bundle.stderr

        # Simulate a power cut after one target rename. Recovery may delete
        # only a target tagged with the journal's transaction ID.
        interrupted_id = "a" * 32
        interrupted = game / "versions/interrupted-arm64"
        interrupted.mkdir()
        (interrupted / "version.json").write_text(
            json.dumps({"transaction_id": interrupted_id}), encoding="utf-8"
        )
        stage = game / "versions/.staging-test-interrupted"
        stage.mkdir()
        (game / "versions" / JOURNAL_NAME).write_text(json.dumps({
            "schema": 1,
            "transaction_id": interrupted_id,
            "stage_name": stage.name,
            "target_names": [interrupted.name],
            "committed": [interrupted.name],
        }), encoding="utf-8")
        assert recover_incomplete_install(game / "versions")
        assert not interrupted.exists() and not stage.exists()
        assert not (game / "versions" / JOURNAL_NAME).exists()

        foreign = game / "versions/foreign-arm64"
        foreign.mkdir()
        (foreign / "version.json").write_text(
            json.dumps({"transaction_id": "b" * 32}), encoding="utf-8"
        )
        (game / "versions" / JOURNAL_NAME).write_text(json.dumps({
            "schema": 1,
            "transaction_id": interrupted_id,
            "stage_name": ".staging-test-foreign",
            "target_names": [foreign.name],
            "committed": [],
        }), encoding="utf-8")
        try:
            recover_incomplete_install(game / "versions")
            raise AssertionError("foreign transaction target was accepted")
        except InstallError as exc:
            assert "belongs to another transaction" in str(exc)
        assert foreign.is_dir()
        (game / "versions" / JOURNAL_NAME).unlink()

        fingerprinted = tmp / "fingerprinted.apk"
        apk(fingerprinted, "1.21.51.01", 972105101, "full")
        invoke(game, fingerprinted)
        fingerprinted_target = game / "versions/1.21.51.01-972105101-arm64/version.json"
        fingerprinted_metadata = json.loads(fingerprinted_target.read_text(encoding="utf-8"))
        assert fingerprinted_metadata["game_library_sha256"] == fixture_hash
        assert fingerprinted_metadata["compatibility"]["renderer_profile"] == "test_no_renderdragon"
        assert fingerprinted_metadata["compatibility"]["recommendation"] == "newest_tested_no_renderdragon"

        mixed = tmp / "mixed.apk"; apk(mixed, "1.18.0", 97180000, "assets")
        invoke(game, base, native, mixed, ok=False)
        assert not any("1.18.0" in p.name for p in (game / "versions").iterdir())

        badsign = tmp / "badsign.apk"; apk(badsign, "1.19.0", 97190000, "native", cert=b"different")
        samebase = tmp / "samebase.apk"; apk(samebase, "1.19.0", 97190000, "base")
        sameassets = tmp / "sameassets.apk"; apk(sameassets, "1.19.0", 97190000, "assets")
        invoke(game, samebase, badsign, sameassets, ok=False)

        pair = tmp / "pair.apk"; apk(pair, "1.26.32.2", 97263202, "full", pairip=True)
        invoke(game, pair, ok=False)
        assert not any("1.26.32.2" in p.name for p in (game / "versions").iterdir())

        # Regression for the output-path bug that once allowed rmtree() to
        # target an input ancestor. Keep the destructive failure mode scoped
        # entirely inside this TemporaryDirectory.
        unsafe_root = tmp / "unsafe-output"
        unsafe_input = unsafe_root / "apk"
        unsafe_input.mkdir(parents=True)
        unsafe_apk = unsafe_input / "base.apk"
        apk(unsafe_apk, "1.21.51.01", 972105101, "base")
        sentinel = unsafe_root / "must-survive.txt"
        sentinel.write_text("keep", encoding="utf-8")
        unsafe = subprocess.run(
            [sys.executable, str(GROUP_HELPER), str(unsafe_input), str(unsafe_root)],
            text=True, capture_output=True, env=env,
        )
        assert unsafe.returncode != 0
        assert "refusing unsafe output directory" in unsafe.stderr
        assert sentinel.read_text(encoding="utf-8") == "keep"
        # A build outside the tested range is offered by the version browser,
        # so the installer must not simply refuse it -- it must refuse until
        # the user has said yes, and it must refuse before doing the work.
        untested = tmp / "untested.apk"; apk(untested, "1.14.60.5", 943146005, "full")
        refused = invoke(game, untested, ok=False)
        assert "UNTESTED:1.14.60.5:" in refused.stderr, refused.stderr
        assert not any("1.14.60.5" in p.name for p in (game / "versions").iterdir())
        # Refused up front: nothing was unpacked and no staging survived.
        assert not any(p.name.startswith(".staging-") for p in (game / "versions").iterdir())

        confirmed = subprocess.run(
            [sys.executable, str(HELPER), "--install", "--allow-untested",
             "--gamedir", str(game), str(untested)],
            text=True, capture_output=True, env=env,
        )
        assert confirmed.returncode == 0, confirmed.stderr + confirmed.stdout
        untested_target = game / "versions" / "1.14.60.5-943146005-arm64"
        assert (untested_target / "lib/arm64-v8a/libminecraftpe.so").is_file()
        # Installed, but still recorded as untested so a support request can
        # tell the difference between this and a build we stand behind.
        recorded = json.loads((untested_target / "version.json").read_text(encoding="utf-8"))
        assert recorded["compatibility"]["status"] == "unsupported"
        assert recorded["compatibility"]["verdict"] == "untested"

        # Asking for something already present is not a failure.
        again = subprocess.run(
            [sys.executable, str(HELPER), "--install", "--allow-untested",
             "--gamedir", str(game), str(untested)],
            text=True, capture_output=True, env=env,
        )
        assert again.returncode == 0, again.stderr + again.stdout
        assert "ALREADY_INSTALLED=1.14.60.5-943146005-arm64" in again.stdout, again.stdout

        # Confirmation does not unlock what genuinely cannot run.
        blocked = tmp / "blocked.apk"; apk(blocked, "1.26.40.1", 972604001, "full")
        denied = subprocess.run(
            [sys.executable, str(HELPER), "--install", "--allow-untested",
             "--gamedir", str(game), str(blocked)],
            text=True, capture_output=True, env=env,
        )
        assert denied.returncode != 0
        assert "cannot be installed" in denied.stderr or "PairIP" in denied.stderr, denied.stderr

    print("APK metadata/install tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
