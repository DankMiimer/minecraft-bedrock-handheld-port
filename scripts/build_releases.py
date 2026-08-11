#!/usr/bin/env python3
"""Build deterministic standard/RGDS products from the canonical source tree."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import struct
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "portmaster" / "minecraftbedrock"
PAYLOAD_SOURCE = PACKAGE / "minecraftbedrock"
RGDS_RELEASE = ROOT / "bottomscreen" / "release"
BOTTOMSCREEN = ROOT / "bottomscreen"
SOURCE_RELEASE = ROOT / "source_release"
FIXED_TIME = (2026, 1, 1, 0, 0, 0)
STANDARD_LIMIT = 13 * 1024 * 1024

PRIVATE_PARTS = {"_libs", "MCPE_versions", "exported_apks", ".git", "__pycache__"}
RUNTIME_EXCLUDES = {
    "apk", "config", "logs", "runtime", "profiles", "versions", "backups",
    "log.txt", "setup_error.txt", ".mesa_cache",
}


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_text_lf(path: pathlib.Path, value: str) -> None:
    """Write deterministic UTF-8 text without host newline translation."""
    path.write_bytes(value.encode("utf-8"))


def copytree_filtered(source: pathlib.Path, destination: pathlib.Path) -> None:
    def ignore(_directory: str, names: list[str]) -> set[str]:
        return {name for name in names if name in RUNTIME_EXCLUDES or name in PRIVATE_PARTS or name.endswith((".pyc", ".part"))}
    shutil.copytree(source, destination, ignore=ignore)


def require_elf_machine(path: pathlib.Path, elf_class: int, machine: int, label: str) -> None:
    data = path.read_bytes()[:20]
    if len(data) < 20 or data[:4] != b"\x7fELF" or data[4] != elf_class:
        raise SystemExit(f"{label} artifact has the wrong ELF class: {path}")
    endian = "<" if data[5] == 1 else ">"
    actual = struct.unpack_from(endian + "H", data, 18)[0]
    if actual != machine:
        raise SystemExit(f"{label} artifact has wrong machine {actual}: {path}")


def require_aarch64(path: pathlib.Path) -> None:
    require_elf_machine(path, 2, 183, "AArch64")


def require_armhf(path: pathlib.Path) -> None:
    require_elf_machine(path, 1, 40, "ARMHF")


def reject_binary_markers(path: pathlib.Path, markers: tuple[bytes, ...], label: str) -> None:
    data = path.read_bytes().lower()
    for marker in markers:
        if marker.lower() in data:
            raise SystemExit(f"{label} contains forbidden marker {marker!r}: {path}")


def require_binary_marker(path: pathlib.Path, marker: bytes, label: str) -> None:
    if path.stat().st_size > 1024 and marker.lower() not in path.read_bytes().lower():
        raise SystemExit(f"{label} is stale or incompatible; missing marker {marker!r}: {path}")


def stamp_payload(payload: pathlib.Path, version: str, channel: str, edition: dict) -> None:
    edition["version"] = version
    edition["channel"] = channel
    write_text_lf(payload / "PORT_VERSION", version + "\n")
    write_text_lf(payload / "edition.json", json.dumps(edition, indent=2) + "\n")


def standard_edition() -> dict:
    return json.loads((PAYLOAD_SOURCE / "edition.json").read_text(encoding="utf-8"))


def stage_standard(root: pathlib.Path, version: str, channel: str,
                   arm64_client: pathlib.Path, armhf_client: pathlib.Path,
                   context_bridge: pathlib.Path) -> pathlib.Path:
    require_aarch64(arm64_client)
    require_armhf(armhf_client)
    require_aarch64(context_bridge)
    require_binary_marker(arm64_client, b"crusty_gamewindow_context_v1", "standard arm64 client")
    reject_binary_markers(arm64_client, (b"mcpe_telemetry", b"mcpe_mirror"), "standard client")
    reject_binary_markers(armhf_client, (b"mcpe_telemetry", b"mcpe_mirror"), "standard client")
    payload = root / "ports" / "minecraftbedrock"
    copytree_filtered(PAYLOAD_SOURCE, payload)
    shutil.copy2(arm64_client, payload / "bin" / "mcpelauncher-client")
    shutil.copy2(armhf_client, payload / "bin32" / "mcpelauncher-client")
    shutil.copy2(context_bridge, payload / "bin" / "crusty-context-v1.so")
    stamp_payload(payload, version, channel, standard_edition())
    (root / "roms" / "ports").mkdir(parents=True, exist_ok=True)
    shutil.copy2(PACKAGE / "Minecraft Bedrock.sh", root / "ports" / "Minecraft Bedrock.sh")
    shutil.copy2(PACKAGE / "Minecraft Bedrock.sh", root / "roms" / "ports" / "Minecraft Bedrock.sh")
    for name in ("README.md", "COMPATIBILITY.md", "port.json", "gameinfo.xml", "screenshot.png"):
        shutil.copy2(PACKAGE / name, root / name)
    return payload


def rgds_metadata(root: pathlib.Path) -> None:
    port = json.loads((PACKAGE / "port.json").read_text(encoding="utf-8"))
    port["name"] = "minecraftbedrock-rgds.zip"
    port["items"] = ["Minecraft Bedrock RGDS.sh", "minecraftbedrock-rgds"]
    port["attr"]["title"] = "Minecraft Bedrock RGDS"
    port["attr"]["arch"] = ["aarch64"]
    port["attr"]["desc"] = (
        "RGDS dual-screen edition with live minimap/status, SELECT screen swapping, "
        "dual-touch routing and OSK supervision. ROCKNIX/Sway is the validated host. "
        "Requires a legally obtained arm64 Bedrock APK; no game files are included."
    )
    write_text_lf(root / "port.json", json.dumps(port, indent=2) + "\n")
    readme = (PACKAGE / "README.md").read_text(encoding="utf-8")
    readme = readme.replace("# Minecraft Bedrock", "# Minecraft Bedrock RGDS", 1)
    readme = readme.replace(
        "No game files are included",
        "This is the separate RGDS dual-screen edition. ROCKNIX/Sway is validated.\n\nNo game files are included",
        1,
    )
    write_text_lf(root / "README.md", readme)
    shutil.copy2(PACKAGE / "COMPATIBILITY.md", root / "COMPATIBILITY.md")
    shutil.copy2(PACKAGE / "gameinfo.xml", root / "gameinfo.xml")
    shutil.copy2(PACKAGE / "screenshot.png", root / "screenshot.png")


def stage_rgds(root: pathlib.Path, version: str, channel: str, client: pathlib.Path,
               bottomd: pathlib.Path, bedrockmap: pathlib.Path,
               context_bridge: pathlib.Path) -> pathlib.Path:
    for artifact in (client, bottomd, bedrockmap, context_bridge):
        require_aarch64(artifact)
    require_binary_marker(client, b"crusty_gamewindow_context_v1", "RGDS client")
    require_binary_marker(client, b"mcpe_companion", "RGDS client")
    require_binary_marker(bottomd, b"mcpe_companion", "RGDS companion")
    require_binary_marker(bottomd, b"mcpe-rgds-touchinject", "RGDS companion")
    if client.stat().st_size > 1024 and b"mcpe_telemetry" not in client.read_bytes().lower():
        raise SystemExit("RGDS client does not expose the telemetry target")
    if client.stat().st_size > 20 * 1024 * 1024:
        raise SystemExit("RGDS client is not release-stripped (over 20 MiB)")
    payload = root / "ports" / "minecraftbedrock-rgds"
    copytree_filtered(PAYLOAD_SOURCE, payload)
    shutil.rmtree(payload / "bin32", ignore_errors=True)
    shutil.rmtree(payload / "lib32", ignore_errors=True)
    (payload / "run_bedrock32.sh").unlink(missing_ok=True)
    shutil.copy2(client, payload / "bin" / "mcpelauncher-client")
    shutil.copy2(context_bridge, payload / "bin" / "crusty-context-v1.so")
    edition = json.loads((RGDS_RELEASE / "edition.json").read_text(encoding="utf-8"))
    stamp_payload(payload, version, channel, edition)
    shutil.copy2(PACKAGE / "Minecraft Bedrock.sh", payload / "launcher_entry.sh")
    rgds = payload / "rgds"
    rgds.mkdir()
    for name in ("rgds_session.sh", "discover_rgds.py", "input_state.py",
                 "prepare_resources.py"):
        shutil.copy2(RGDS_RELEASE / name, rgds / name)
    for name in ("terrain_loop.sh",):
        shutil.copy2(BOTTOMSCREEN / "bottomd" / name, rgds / name)
    for name in ("osk_show.sh", "osk_hide.sh", "osk_supervisor.py", "thor-keyboard.sh"):
        shutil.copy2(BOTTOMSCREEN / "device" / name, rgds / name)
    shutil.copy2(bottomd, rgds / "bottomd")
    shutil.copy2(bedrockmap, rgds / "bedrockmap")
    shutil.copy2(BOTTOMSCREEN / "bedrockmap" / "block_colors.tsv", rgds / "block_colors.tsv")
    shutil.copy2(BOTTOMSCREEN / "device" / "rgds.gamecontrollerdb.txt", payload / "controls" / "rgds.gamecontrollerdb.txt")
    for path in rgds.rglob("*"):
        lower = path.name.lower()
        if any(word in lower for word in ("devhud", "test_", "westonfix", "touchinject")):
            raise SystemExit(f"experimental RGDS artifact entered release: {path}")
    for prefix in (root / "ports", root / "roms" / "ports"):
        prefix.mkdir(parents=True, exist_ok=True)
        shutil.copy2(RGDS_RELEASE / "Minecraft Bedrock RGDS.sh", prefix / "Minecraft Bedrock RGDS.sh")
    rgds_metadata(root)
    return payload


def iter_files(root: pathlib.Path):
    for path in sorted(root.rglob("*")):
        if path.is_file():
            yield path, path.relative_to(root).as_posix()


def write_sbom(root: pathlib.Path, product: str, version: str) -> pathlib.Path:
    files = []
    for path, name in iter_files(root):
        if name == "SBOM.spdx.json":
            continue
        files.append({
            "SPDXID": "SPDXRef-File-" + hashlib.sha256(name.encode()).hexdigest()[:16],
            "fileName": "./" + name,
            "checksums": [{"algorithm": "SHA256", "checksumValue": sha256(path)}],
            "licenseConcluded": "NOASSERTION",
            "copyrightText": "NOASSERTION",
        })
    verification = hashlib.sha1("".join(sorted(
        item["checksums"][0]["checksumValue"] for item in files
    )).encode()).hexdigest()
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"{product}-{version}",
        "documentNamespace": f"https://github.com/DankMiimer/minecraft-bedrock-handheld-port/spdx/{product}/{version}",
        "creationInfo": {
            "created": "2026-01-01T00:00:00Z",
            "creators": ["Tool: scripts/build_releases.py"],
        },
        "packages": [{
            "name": product,
            "SPDXID": "SPDXRef-Package",
            "versionInfo": version,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": True,
            "packageVerificationCode": {"packageVerificationCodeValue": verification},
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
        }],
        "files": files,
        "relationships": [
            {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Package"},
            *({"spdxElementId": "SPDXRef-Package", "relationshipType": "CONTAINS", "relatedSpdxElement": item["SPDXID"]} for item in files),
        ],
    }
    target = root / "SBOM.spdx.json"
    write_text_lf(target, json.dumps(document, indent=2, sort_keys=True) + "\n")
    return target


def make_zip(root: pathlib.Path, output: pathlib.Path) -> None:
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path, name in iter_files(root):
            info = zipfile.ZipInfo(name, FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            executable = path.suffix in {".sh", ".py"} or "/bin/" in f"/{name}" or name.endswith(("/bottomd", "/bedrockmap", "/mcpelauncher-client"))
            # Mark entries as UNIX regular files.  BusyBox unzip (used by
            # PortMaster CFWs) ignores permission bits on DOS-origin entries.
            info.create_system = 3
            info.external_attr = (0o100755 if executable else 0o100644) << 16
            archive.writestr(info, path.read_bytes())


def source_zip(output: pathlib.Path) -> None:
    root_files = [
        ROOT / ".dockerignore",
        ROOT / ".gitattributes",
        ROOT / "CHANGELOG.md",
        ROOT / "LICENSE",
        ROOT / "LEGAL.md",
        ROOT / "THIRD_PARTY_NOTICES.md",
        ROOT / "RELEASE_CHECKLIST.md",
        ROOT / "TESTING.md",
        ROOT / "VERSION",
    ]
    wanted = [
        SOURCE_RELEASE,
        BOTTOMSCREEN / "bottomd",
        BOTTOMSCREEN / "bedrockmap",
        BOTTOMSCREEN / "telemetry",
        RGDS_RELEASE,
        ROOT / "build" / "clients",
        ROOT / "build" / "companions",
        ROOT / "scripts",
        ROOT / "tests",
        ROOT / ".github" / "workflows",
        # GPL-3 corresponding source for the published mcbedrock-get.exe.
        ROOT / "tools" / "mcbedrock-get",
        PACKAGE,
    ]
    compiled_payload_dirs = {"bin", "bin32", "lib32", "libs.aarch64"}
    # Local build output of the Windows tool: never part of its source. The
    # .spec file is regenerated by build.bat, so excluding it keeps a local
    # source archive byte-identical to one built from a clean checkout.
    build_output_dirs = {".venv", "dist", "build"}
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        source_readme = SOURCE_RELEASE / "README.md"
        info = zipfile.ZipInfo("README.md", FIXED_TIME)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 3
        info.external_attr = 0o100644 << 16
        archive.writestr(info, source_readme.read_bytes())
        for path in root_files:
            if not path.is_file():
                raise SystemExit(f"required source-bundle input missing: {path}")
            info = zipfile.ZipInfo(path.name, FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())
        for source in wanted:
            for path in sorted(source.rglob("*")):
                if not path.is_file() or any(part in PRIVATE_PARTS for part in path.parts):
                    continue
                if source == PACKAGE and any(part in compiled_payload_dirs for part in path.relative_to(source).parts):
                    continue
                if source.name == "mcbedrock-get" and (
                    path.suffix == ".spec"
                    or any(part in build_output_dirs for part in path.relative_to(source).parts)
                ):
                    continue
                if path.suffix in {".o", ".pyc"} or path.name in {"bottomd", "telemetry_dump", "test_feed", "test_mirror", "test_downscale", "test_daynight", "test_worldinfo"}:
                    continue
                rel = path.relative_to(ROOT).as_posix()
                info = zipfile.ZipInfo(rel, FIXED_TIME)
                info.compress_type = zipfile.ZIP_DEFLATED
                executable = path.suffix in {".sh", ".py"}
                info.create_system = 3
                info.external_attr = (0o100755 if executable else 0o100644) << 16
                archive.writestr(info, path.read_bytes())


def inspect_archive(path: pathlib.Path, edition: str) -> None:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        forbidden = (".apk", "libminecraftpe.so", "/versions/", "/profiles/", "/_libs/")
        for name in names:
            normalized = "/" + name.lower()
            if any(value in normalized for value in forbidden):
                raise SystemExit(f"forbidden release path in {path.name}: {name}")
        if edition == "standard":
            markers = ("bottomd", "bedrockmap", "telemetry", "osk_supervisor", "rgds_session", "touchinject", "westonfix")
            for name in names:
                if any(marker in name.lower() for marker in markers):
                    raise SystemExit(f"dual-screen artifact in standard archive: {name}")
        elif edition == "rgds":
            armhf_markers = ("/bin32/", "/lib32/", "run_bedrock32", "arm-linux-gnueabihf")
            for name in names:
                normalized = "/" + name.lower()
                if any(marker in normalized for marker in armhf_markers):
                    raise SystemExit(f"armhf artifact in arm64-only RGDS archive: {name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--version",
        default=(ROOT / "VERSION").read_text(encoding="utf-8").strip(),
        help="release version (defaults to the repository VERSION file)",
    )
    parser.add_argument("--channel", choices=("stable", "testing"), default="stable")
    parser.add_argument("--out-dir", type=pathlib.Path, default=ROOT / "dist" / "release")
    parser.add_argument("--rgds-client", type=pathlib.Path, required=True)
    parser.add_argument("--standard-arm64-client", type=pathlib.Path, required=True)
    parser.add_argument("--standard-armhf-client", type=pathlib.Path, required=True)
    parser.add_argument("--bottomd", type=pathlib.Path, required=True)
    parser.add_argument("--bedrockmap", type=pathlib.Path, required=True)
    parser.add_argument("--context-bridge", type=pathlib.Path, required=True)
    parser.add_argument("--repo", default="DankMiimer/minecraft-bedrock-handheld-port")
    parser.add_argument("--base-index", type=pathlib.Path, default=ROOT / "release-index.json")
    parser.add_argument(
        "--extra-asset",
        type=pathlib.Path,
        action="append",
        default=[],
        dest="extra_assets",
        help="Published alongside the release and listed in SHA256SUMS.txt, but never "
             "added to release-index.json. The index drives the on-device updater, "
             "which must only ever be offered port editions.",
    )
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    products = []
    with tempfile.TemporaryDirectory(prefix="mcpe-release-") as tmp:
        temp = pathlib.Path(tmp)
        standard_root = temp / "standard"
        rgds_root = temp / "rgds"
        stage_standard(standard_root, args.version, args.channel,
                       args.standard_arm64_client, args.standard_armhf_client,
                       args.context_bridge)
        stage_rgds(rgds_root, args.version, args.channel, args.rgds_client, args.bottomd,
                   args.bedrockmap, args.context_bridge)
        standard_sbom = write_sbom(standard_root, "minecraftbedrock-standard", args.version)
        rgds_sbom = write_sbom(rgds_root, "minecraftbedrock-rgds", args.version)
        standard_zip = args.out_dir / f"minecraftbedrock-standard-v{args.version}.zip"
        rgds_zip = args.out_dir / f"minecraftbedrock-rgds-v{args.version}.zip"
        make_zip(standard_root, standard_zip)
        make_zip(rgds_root, rgds_zip)
        inspect_archive(standard_zip, "standard")
        inspect_archive(rgds_zip, "rgds")
        if standard_zip.stat().st_size > STANDARD_LIMIT:
            raise SystemExit(f"standard archive exceeds lightweight gate: {standard_zip.stat().st_size} > {STANDARD_LIMIT}")
        products = [
            ("minecraftbedrock.standard", standard_zip),
            ("minecraftbedrock.rgds", rgds_zip),
        ]
        external_sboms = []
        for name, source in (("standard", standard_sbom), ("rgds", rgds_sbom)):
            target = args.out_dir / f"minecraftbedrock-{name}-v{args.version}.spdx.json"
            shutil.copy2(source, target)
            external_sboms.append((f"{name}-sbom", target))
    src_zip = args.out_dir / f"minecraftbedrock-source-v{args.version}.zip"
    source_zip(src_zip)
    extras = []
    for source in args.extra_assets:
        if not source.is_file():
            raise SystemExit(f"missing extra asset: {source}")
        target = args.out_dir / source.name
        if target != source:
            shutil.copy2(source, target)
        extras.append((f"extra-{source.name}", target))
    sums = products + [("source", src_zip)] + external_sboms + extras
    write_text_lf(
        args.out_dir / "SHA256SUMS.txt",
        "".join(f"{sha256(path)}  {path.name}\n" for _, path in sums),
    )
    tag = f"v{args.version}"
    releases = []
    if args.base_index.is_file():
        base = json.loads(args.base_index.read_text(encoding="utf-8"))
        if base.get("schema") != 2 or not isinstance(base.get("releases"), list):
            raise SystemExit(f"invalid base release index: {args.base_index}")
        product_ids = {edition for edition, _ in products}
        releases = [row for row in base["releases"]
                    if not (row.get("edition") in product_ids and
                            row.get("channel") == args.channel)]
    for edition, path in products:
        releases.append({
            "edition": edition, "channel": args.channel, "version": args.version,
            "asset": path.name,
            "url": f"https://github.com/{args.repo}/releases/download/{tag}/{path.name}",
            "sha256": sha256(path), "size": path.stat().st_size, "minimum_updater": 2,
        })
    releases.sort(key=lambda row: (row["edition"], row["channel"], row["version"]))
    write_text_lf(
        args.out_dir / "release-index.json",
        json.dumps({"schema": 2, "releases": releases}, indent=2) + "\n",
    )
    write_text_lf(
        args.out_dir / "RELEASE_NOTES.md",
        f"# Minecraft Bedrock handheld port {args.version}\n\n"
        f"Channel: `{args.channel}`\n\n"
        "This build contains separate standard and RGDS products. The standard "
        "archive contains no dual-screen runtime. The RGDS archive is arm64-only "
        "and targets ROCKNIX/Sway. Users must supply an official Mojang APK; no "
        "game content or authentication bypass is distributed. RGDS terrain maps "
        "local worlds; LAN client sessions retain live telemetry but explicitly "
        "mark remote terrain unavailable instead of reusing cached local tiles.\n",
    )
    for _, path in sums:
        print(f"built {path.name}: {path.stat().st_size / 1024 / 1024:.2f} MiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
