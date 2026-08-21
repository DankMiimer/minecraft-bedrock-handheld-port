#!/usr/bin/env python3
"""Generate launcher-menu choices for complete, metadata-matched APK sets."""
from __future__ import annotations
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

from apkmeta import (InstallError, MOJANG_CERTS, PACKAGE, choose_sources,
                     expand_input_paths, input_files, inspect_apk,
                     normalized_group, validate_signers)


def clean_text(value: object) -> str:
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def add_choice(output: Path, rows: list[str], title: str, description: str,
               files: list[str], ready: bool) -> None:
    digest = hashlib.sha256("\0".join(files + [title]).encode()).hexdigest()[:16]
    (output / f"{digest}.txt").write_text("".join(name + "\n" for name in files), encoding="utf-8")
    rows.append("\t".join((digest, clean_text(title), clean_text(description), "1" if ready else "0")))


def input_state(apkdir: Path) -> dict[str, object]:
    files = []
    for path in input_files(apkdir):
        stat = path.stat()
        files.append([path.name, stat.st_size, stat.st_mtime_ns])
    return {"schema": 2, "files": files}


def cache_is_complete(output: Path, state: dict[str, object]) -> bool:
    try:
        cached = json.loads((output / ".input-state.json").read_text(encoding="utf-8"))
        if cached != state:
            return False
        rows = (output / "index.tsv").read_text(encoding="utf-8").splitlines()
        return all((output / f"{row.split(chr(9), 1)[0]}.txt").is_file()
                   for row in rows if row)
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return False


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: apk_groups.py APKDIR OUTPUT", file=sys.stderr)
        return 2
    apkdir, output = (Path(value).resolve() for value in sys.argv[1:])
    cwd = Path.cwd().resolve()
    # The output is disposable launcher state, but neither the input tree nor
    # an ancestor/work directory ever is. Refuse unsafe caller expansion
    # before considering the recursive cleanup below.
    if (output == cwd or output == apkdir or output in apkdir.parents or
            output == Path(output.anchor) or output.is_symlink()):
        print(f"refusing unsafe output directory: {output}", file=sys.stderr)
        return 2
    if output.exists() and not output.is_dir():
        print(f"output is not a directory: {output}", file=sys.stderr)
        return 2
    state = input_state(apkdir)
    # This cache only controls menu presentation. setup_apk.py independently
    # re-reads manifests, split dependencies, signers and PairIP immediately
    # before installation, so a cache hit never authorizes stale APK content.
    if output.is_dir() and cache_is_complete(output, state):
        return 0
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    rows: list[str] = []
    infos = []
    with tempfile.TemporaryDirectory(prefix="mcpe-apk-groups-") as temporary:
        workspace = Path(temporary)
        for index, path in enumerate(input_files(apkdir)):
            if any(ch in path.name for ch in "|\t\r\n"):
                add_choice(output, rows, path.name, "Invalid filename", [], False)
                continue
            try:
                expanded = expand_input_paths([path], workspace / str(index))
                infos.extend(
                    inspect_apk(real_path, display_name, input_name)
                    for real_path, display_name, input_name in expanded
                )
            except (InstallError, OSError) as exc:
                add_choice(output, rows, path.name, f"Invalid APK input: {exc}", [path.name], False)

    grouped: dict[tuple[object, ...], list] = {}
    for info in infos:
        # Android split manifests commonly omit versionName.  versionCode and the
        # signing identity are the authoritative set keys; normalized_group()
        # below inherits the base APK's sole versionName and rejects conflicts.
        key = (info.package, info.version_code, info.signer)
        grouped.setdefault(key, []).append(info)

    for (_package, _code, _signer), members in sorted(grouped.items(), key=lambda item: str(item[0])):
        full = [info for info in members if info.role == "full"]
        candidates = [[info] for info in full]
        split_members = [info for info in members if info.role != "full"]
        if split_members:
            candidates.append(split_members)
        for candidate in candidates:
            names = sorted({info.input_name for info in candidate})
            abis = sorted({abi for info in candidate for abi in info.abis})
            abi_label = "/".join("arm64" if abi == "arm64-v8a" else "armhf" for abi in abis) or "no ARM ABI"
            versions = sorted({info.version_name for info in candidate if info.version_name})
            version = versions[0] if len(versions) == 1 else ("mixed" if versions else "unknown")
            title = f"Bedrock {version or 'unknown'} ({abi_label})"
            try:
                package, _version_code, version_name = normalized_group(candidate)
                if package != PACKAGE:
                    raise InstallError("not the Mojang Bedrock package")
                signer, signer_status = validate_signers(candidate)
                choose_sources(candidate)
                if any(info.has_pairip for info in candidate):
                    raise InstallError("unsupported PairIP/new ABI")
                if signer_status == "verified_mojang" and signer not in MOJANG_CERTS:
                    raise InstallError("signer is not Mojang")
                desc = f"Complete {len(candidate)}-file set; {signer_status}; version code {_version_code}"
                add_choice(output, rows, f"Bedrock {version_name} ({abi_label})", desc, names, True)
            except InstallError as exc:
                add_choice(output, rows, title, f"Not installable: {exc}", names, False)

    (output / "index.tsv").write_text("\n".join(rows) + ("\n" if rows else ""), encoding="utf-8")
    (output / ".input-state.json").write_text(
        json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
