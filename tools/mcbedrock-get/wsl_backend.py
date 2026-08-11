"""Drives gplaydl inside WSL.

gplaydl comes from minecraft-linux/google-play-api and is the only Play client
still able to download Minecraft. It is a Linux binary, so it runs under WSL and
writes straight into a Windows folder through /mnt.

The account holder's Google sign-in is handled by playstore.py; this module only
passes the resulting long-lived token through to gplaydl.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Callable

DISTRO = "Ubuntu"
PREFIX = "$HOME/.local/share/mcbedrock-get"
PACKAGE = "com.mojang.minecraftpe"

# Suppress the console window that would otherwise flash on every call.
_NO_WINDOW = 0x08000000


class WslError(RuntimeError):
    """A failure the user can act on."""


def _run(script: str, stdin: str | None = None, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["wsl.exe", "-d", DISTRO, "--", "bash", "-lc", script],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=timeout,
        creationflags=_NO_WINDOW,
    )


def is_available() -> bool:
    """True when WSL exists and the distro starts."""
    try:
        return _run("true", timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def is_installed() -> bool:
    """True when wsl-setup.sh has been run."""
    try:
        return _run(f"test -x {PREFIX}/gplaydl", timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def is_signed_in() -> bool:
    try:
        return _run(f"test -s {PREFIX}/token_cache.conf", timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def sign_in(master_token: str) -> None:
    """Hand gplaydl the account token and let it cache its own session.

    Option 3 of its interactive menu takes a master token, which is what our
    sign-in already produces and what survives longest.
    """
    # gplayver, not gplaydl: this only needs to authenticate and cache a
    # session. Asking gplaydl to log in would also make it start a download.
    result = _run(
        f"cd {PREFIX} && ./gplayver --interactive --device device-arm64.conf "
        f"--save-auth --accept-tos --app {PACKAGE} 2>&1 || true",
        stdin=f"3\n{master_token}\ny\n",
        timeout=300,
    )
    output = (result.stdout or "") + (result.stderr or "")
    if "Failed to login" in output:
        raise WslError(
            "gplaydl rejected the account token. Sign out in this app and sign in again."
        )
    if not is_signed_in():
        raise WslError("gplaydl did not save a session.\n\n" + output.strip()[-500:])


def run_setup_in_terminal(script: Path) -> None:
    """Open a visible console running wsl-setup.sh.

    It must be visible: the script uses sudo, and the password prompt has to be
    somewhere the user can actually answer it.
    """
    if not script.is_file():
        raise WslError(f"wsl-setup.sh is missing. Expected it at:\n\n{script}")
    subprocess.Popen(
        ["wsl.exe", "-d", DISTRO, "--", "bash", to_wsl_path(script)],
        creationflags=subprocess.CREATE_NEW_CONSOLE,
    )


def to_wsl_path(path: Path) -> str:
    """C:\\dir\\file -> /mnt/c/dir/file"""
    text = str(Path(path).resolve()).replace("\\", "/")
    match = re.match(r"^([A-Za-z]):/(.*)$", text)
    if not match:
        raise WslError(f"Not a local Windows path: {path}")
    return f"/mnt/{match.group(1).lower()}/{match.group(2)}"


def download(
    version_code: int,
    target: Path,
    on_line: Callable[[str], None] | None = None,
    timeout: int = 3600,
) -> list[Path]:
    """Download one version's base APK and splits into `target`.

    gplaydl names splits by inserting the component id before the extension, so
    a base of minecraft-<version>.apk yields minecraft-<version>.config.arm64_v8a.apk
    alongside it.
    """
    target.mkdir(parents=True, exist_ok=True)
    base = target / f"minecraft-{version_code}.apk"

    script = (
        f"cd {PREFIX} && ./gplaydl --device {PREFIX}/device-arm64.conf --accept-tos "
        f"--app {PACKAGE} --app-version {version_code} --output '{to_wsl_path(base)}' 2>&1"
    )

    process = subprocess.Popen(
        ["wsl.exe", "-d", DISTRO, "--", "bash", "-lc", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        creationflags=_NO_WINDOW,
    )
    # gplaydl redraws its progress with carriage returns, which text mode turns
    # into thousands of lines. Only report when the percentage actually moves,
    # or the UI queue drowns in redraws.
    tail: list[str] = []
    last_percent = -1
    for line in process.stdout or []:
        line = line.strip()
        if not line:
            continue
        tail.append(line)
        del tail[:-40]
        if not on_line:
            continue
        match = re.search(r"Downloaded (\d+)%", line)
        if match:
            percent = int(match.group(1))
            if percent != last_percent:
                last_percent = percent
                on_line(line)
        else:
            on_line(line)
    process.wait(timeout=timeout)

    # Judge success by what is on disk, not by the exit code: gplaydl returns
    # non-zero even after a complete download. Matching on the version code
    # rather than diffing the folder also keeps re-downloads working.
    written = sorted(target.glob(f"{base.stem}*.apk"))
    if not written:
        raise WslError(
            f"The download produced no files (gplaydl exit {process.returncode}).\n\n"
            + "\n".join(tail[-12:])
        )

    if not any("arm64_v8a" in f.name for f in written):
        names = ", ".join(f.name for f in written)
        raise WslError(
            "Play did not return the arm64 part for this build, so it will not "
            f"run on the device. Got: {names}"
        )
    return written
