"""Drives gplaydl inside WSL.

gplaydl comes from minecraft-linux/google-play-api and is the only Play client
still able to download Minecraft. It is a Linux binary, so it runs under WSL and
writes straight into a Windows folder through /mnt.

The account holder's Google sign-in is handled by playstore.py; this module only
passes the resulting long-lived token through to gplaydl.
"""
from __future__ import annotations

import os
import re
import shlex
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Callable

PREFIX = "$HOME/.local/share/mcbedrock-get"
PACKAGE = "com.mojang.minecraftpe"

# Suppress the console window that would otherwise flash on every call.
_NO_WINDOW = 0x08000000


class WslError(RuntimeError):
    """A failure the user can act on."""


def installed_distros() -> list[str]:
    """Return installed WSL distributions without localized header text."""
    result = subprocess.run(
        ["wsl.exe", "--list", "--quiet"],
        capture_output=True,
        text=True,
        timeout=30,
        creationflags=_NO_WINDOW,
    )
    if result.returncode != 0:
        return []
    names = (line.replace("\x00", "").strip() for line in result.stdout.splitlines())
    return [name for name in names if name]


def selected_distro() -> str:
    """Pick an Ubuntu WSL distro, with an explicit environment override."""
    override = os.environ.get("MCBEDROCK_WSL_DISTRO", "").strip()
    if override:
        return override
    names = installed_distros()
    if "Ubuntu" in names:
        return "Ubuntu"
    ubuntu = [name for name in names if name.lower().startswith("ubuntu-")]
    if ubuntu:
        return max(ubuntu, key=lambda name: tuple(int(part) for part in re.findall(r"\d+", name)))
    detail = ", ".join(names) if names else "none found"
    raise WslError(
        "Ubuntu is not installed in WSL. Run  wsl --install -d Ubuntu  from "
        f"an administrator PowerShell, then reboot. Installed distributions: {detail}."
    )


def _run(script: str, stdin: str | None = None, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["wsl.exe", "-d", selected_distro(), "--", "bash", "-lc", script],
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
    except (OSError, subprocess.SubprocessError, WslError):
        return False


def is_installed() -> bool:
    """True when wsl-setup.sh has been run."""
    try:
        return _run(f"test -x {PREFIX}/gplaydl", timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError, WslError):
        return False


def is_signed_in() -> bool:
    try:
        return _run(f"test -s {PREFIX}/token_cache.conf", timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError, WslError):
        return False


def sign_out() -> bool:
    """Remove gplaydl's cached account session and report whether WSL was reached."""
    try:
        result = _run(f"rm -f {PREFIX}/token_cache.conf {PREFIX}/playdl.conf", timeout=60)
    except (OSError, subprocess.SubprocessError, WslError):
        # Local sign-out must still work when WSL was removed or is offline.
        return False
    return result.returncode == 0


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
        ["wsl.exe", "-d", selected_distro(), "--", "bash", to_wsl_path(script)],
        creationflags=subprocess.CREATE_NEW_CONSOLE,
    )


def to_wsl_path(path: Path) -> str:
    """C:\\dir\\file -> /mnt/c/dir/file"""
    text = str(Path(path).resolve()).replace("\\", "/")
    match = re.match(r"^([A-Za-z]):/(.*)$", text)
    if not match:
        raise WslError(f"Not a local Windows path: {path}")
    return f"/mnt/{match.group(1).lower()}/{match.group(2)}"


def _download_into(
    version_code: int,
    base: Path,
    on_line: Callable[[str], None] | None,
    timeout: int,
) -> tuple[int, list[str]]:
    """Run gplaydl into an isolated path and return its exit code/log tail."""
    quoted_output = shlex.quote(to_wsl_path(base))
    script = (
        f"cd {PREFIX} && ./gplaydl --device {PREFIX}/device-arm64.conf --accept-tos "
        f"--app {PACKAGE} --app-version {version_code} --output {quoted_output} 2>&1"
    )

    process = subprocess.Popen(
        ["wsl.exe", "-d", selected_distro(), "--", "bash", "-lc", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        creationflags=_NO_WINDOW,
    )
    # gplaydl redraws its progress with carriage returns, which text mode turns
    # into thousands of lines. Only report when the percentage actually moves,
    # or the UI queue drowns in redraws.
    timed_out = threading.Event()

    def stop_process() -> None:
        if process.poll() is None:
            timed_out.set()
            try:
                process.kill()
            except OSError:
                pass

    watchdog = threading.Timer(timeout, stop_process)
    watchdog.daemon = True
    watchdog.start()
    tail: list[str] = []
    last_percent = -1
    try:
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
        process.wait()
    finally:
        watchdog.cancel()
    if timed_out.is_set():
        raise WslError(f"The download timed out after {timeout // 60} minutes.")
    return process.returncode, tail


def download(
    version_code: int,
    target: Path,
    on_line: Callable[[str], None] | None = None,
    timeout: int = 3600,
) -> list[Path]:
    """Download and atomically publish one complete arm64 split set."""
    target.mkdir(parents=True, exist_ok=True)
    prefix = f"minecraft-{version_code}"
    with tempfile.TemporaryDirectory(prefix=f".{prefix}-", dir=target) as staging_text:
        staging = Path(staging_text)
        base = staging / f"{prefix}.apk"
        returncode, tail = _download_into(version_code, base, on_line, timeout)

        # Judge success by the isolated output, not gplaydl's unreliable exit
        # code and never by files left by an earlier download.
        written = sorted(staging.glob(f"{prefix}*.apk"))
        if not base.is_file():
            raise WslError(
                f"The download produced no base APK (gplaydl exit {returncode}).\n\n"
                + "\n".join(tail[-12:])
            )

        if not any("arm64_v8a" in path.name for path in written):
            names = ", ".join(path.name for path in written)
            raise WslError(
                "Play did not return the arm64 part for this build, so it will not "
                f"run on the device. Got: {names}"
            )

        backup = staging / "previous"
        backup.mkdir()
        previous = sorted(target.glob(f"{prefix}*.apk"))
        moved: list[Path] = []
        try:
            for old in previous:
                old.replace(backup / old.name)
            for source in written:
                destination = target / source.name
                source.replace(destination)
                moved.append(destination)
        except OSError:
            for destination in moved:
                destination.unlink(missing_ok=True)
            for old in backup.glob("*.apk"):
                old.replace(target / old.name)
            raise
        return moved
