#!/usr/bin/env python3
"""Check that public release materials do not include Minecraft payload files."""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import zipfile


FORBIDDEN_PATH_PATTERNS = [
    re.compile(r"(^|/|\\)[^/\\]+\.apk$", re.IGNORECASE),
    re.compile(r"(^|/|\\)[^/\\]+\.apks$", re.IGNORECASE),
    re.compile(r"(^|/|\\)[^/\\]+\.xapk$", re.IGNORECASE),
    re.compile(r"(^|/|\\)libminecraftpe\.so$", re.IGNORECASE),
    re.compile(r"(^|/|\\)level\.dat(_old)?$", re.IGNORECASE),
    re.compile(r"\.mcworld$", re.IGNORECASE),
    re.compile(r"(^|/|\\)versions(/|\\)", re.IGNORECASE),
    re.compile(r"(^|/|\\)profiles(/|\\)", re.IGNORECASE),
    re.compile(r"(^|/|\\)com\.mojang(/|\\)", re.IGNORECASE),
    re.compile(r"resource_packs[/\\]vanilla[/\\]", re.IGNORECASE),
]

REQUIRED_DISCLAIMER = (
    "NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH "
    "MOJANG OR MICROSOFT."
)


def normalized_text(value: str) -> str:
    return " ".join(value.split())


def path_is_forbidden(path: str) -> bool:
    normalized = path.replace("\\", "/")
    return any(pattern.search(normalized) for pattern in FORBIDDEN_PATH_PATTERNS)


def git_files() -> list[str]:
    try:
        out = subprocess.check_output(["git", "ls-files"], text=True)
    except Exception:
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def check_paths(paths: list[str], label: str) -> list[str]:
    return [f"{label}: forbidden path: {path}" for path in paths if path_is_forbidden(path)]


def check_zip(zip_path: pathlib.Path) -> list[str]:
    errors: list[str] = []
    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
        errors.extend(check_paths(names, str(zip_path)))
        readme_name = next((name for name in names if name.rstrip("/") == "README.md"), None)
        if not readme_name:
            errors.append(f"{zip_path}: missing README.md")
        else:
            readme = archive.read(readme_name).decode("utf-8", errors="replace")
            normalized_readme = normalized_text(readme)
            if REQUIRED_DISCLAIMER not in normalized_readme:
                errors.append(f"{zip_path}: README.md missing required disclaimer")
            if "No game files are included" not in readme:
                errors.append(f"{zip_path}: README.md missing no-game-files statement")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip", dest="zip_paths", action="append", default=[], help="Release zip to scan")
    args = parser.parse_args()

    errors: list[str] = []
    errors.extend(check_paths(git_files(), "git"))

    for value in args.zip_paths:
        zip_path = pathlib.Path(value)
        if not zip_path.exists():
            errors.append(f"{zip_path}: file does not exist")
            continue
        errors.extend(check_zip(zip_path))

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print("release safety checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
