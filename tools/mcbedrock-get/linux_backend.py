"""Drives gplaydl on Linux, where it simply runs.

The Windows helper installs a whole Ubuntu system to run gplaydl in, because
Windows cannot run it. On Linux that entire problem disappears: the same
binary, built from the same source by the same script, runs directly. So this
backend has no distribution to install, no root user to borrow and no path
translation -- only "is it built yet", and if not, build it.

The public names match wsl_backend so the window can drive either one.
"""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Callable

import apkset

PACKAGE = "com.mojang.minecraftpe"
ABI_PROFILES = apkset.ABI_PROFILES


class WslError(RuntimeError):
    """A failure the user can act on.

    Named for the Windows backend it stands in for, so the window can catch one
    error type whichever platform it is running on.
    """


class RestartNeeded(WslError):
    """Never raised here; Linux has nothing to reboot for. Kept so the window
    can reference it without asking which backend it is talking to."""


def prefix() -> Path:
    """Where gplaydl and its session live, honouring XDG."""
    override = os.environ.get("MCBEDROCK_PREFIX", "").strip()
    if override:
        return Path(override)
    data = os.environ.get("XDG_DATA_HOME", "").strip()
    root = Path(data) if data else Path.home() / ".local" / "share"
    return root / "mcbedrock-get"


def _tool(name: str) -> Path:
    return prefix() / name


def _run(argv: list[str], stdin: str | None = None, timeout: int = 120):
    try:
        return subprocess.run(
            argv,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(prefix()) if prefix().is_dir() else None,
        )
    except subprocess.TimeoutExpired as error:
        raise WslError(f"Command timed out after {timeout} seconds.") from error
    except OSError as error:
        raise WslError(f"Could not run {argv[0]}: {error}") from error


# -- what the window asks about ------------------------------------------

def is_available() -> bool:
    """There is no subsystem to check for; this machine is the machine."""
    return True


def windows_feature_present() -> bool:
    return True


def distro_present() -> bool:
    return True


def is_installed() -> bool:
    return os.access(_tool("gplaydl"), os.X_OK)


def is_signed_in() -> bool:
    for name in ("playdl.conf", "token_cache.conf"):
        path = _tool(name)
        try:
            if path.stat().st_size <= 0:
                return False
        except OSError:
            return False
    return True


def adopt_legacy_install() -> bool:
    """Nothing to adopt: Linux installs have always lived in the user's home."""
    return False


def sign_out() -> bool:
    removed = True
    for name in ("token_cache.conf", "playdl.conf"):
        try:
            _tool(name).unlink(missing_ok=True)
        except OSError:
            removed = False
    return removed


def remove_distro() -> None:
    """Delete the downloader. There is no distribution to unregister."""
    import shutil

    try:
        shutil.rmtree(prefix())
    except OSError as error:
        raise WslError(f"Could not remove {prefix()}: {error}") from error


# -- setup ----------------------------------------------------------------

def install_windows_feature(on_line=None) -> None:
    raise WslError("Nothing to install: this is already Linux.")


def install_distro(on_line=None, timeout: int = 1800) -> None:
    return None


def package_manager() -> str:
    """Which package manager the setup script will use, for the disclosure."""
    from shutil import which

    for tool in ("apt-get", "dnf", "pacman"):
        if which(tool):
            return tool
    return ""


def build_downloader(script: Path, on_line=None, timeout: int = 3600) -> None:
    """Install build dependencies and compile gplaydl, here, as this user.

    The script asks for authorisation itself -- graphically through pkexec when
    there is no terminal -- and only for the package installation. The build
    stays unprivileged so its output lands in this user's home.
    """
    if not script.is_file():
        raise WslError(f"The setup script is missing. Expected it at:\n\n{script}")

    lines: list[str] = []
    process = subprocess.Popen(
        ["bash", str(script)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env={**os.environ, "MCBEDROCK_NONINTERACTIVE": "1"},
    )
    deadline = threading.Timer(timeout, process.kill)
    deadline.daemon = True
    deadline.start()
    try:
        for raw in process.stdout or []:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            lines.append(line)
            del lines[:-40]
            if on_line is not None:
                on_line(line)
        process.wait()
    finally:
        deadline.cancel()

    if process.returncode != 0 or not is_installed():
        raise WslError(
            "The Play downloader could not be built.\n\n" + "\n".join(lines[-12:])
        )


def ensure_device_profile(abi: str) -> None:
    """Write the fixed upstream device override for one supported ABI."""
    filename, native_platform, _ = apkset.abi_profile(abi)
    target = _tool(filename)
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(".new")
        temporary.write_text(
            f"config.native_platforms = [\n    {native_platform}\n]\n", encoding="utf-8"
        )
        os.chmod(temporary, 0o600)
        temporary.replace(target)
    except OSError as error:
        raise WslError(
            f"Could not prepare the {native_platform} downloader profile: {error}"
        ) from error


def _config_value(value: str, label: str) -> str:
    if not value or "\n" in value or "\r" in value:
        raise WslError(f"The saved Google {label} is invalid. Sign out and sign in again.")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def sign_in(email: str, master_token: str) -> None:
    """Create gplaydl's private config and establish its cached session.

    The config goes in with mode 0600 before anything reads it, and the token
    never appears in a command line -- same rules as the Windows path.
    """
    config = (
        f"user_email = {_config_value(email, 'email')}\n"
        f"user_token = {_config_value(master_token, 'token')}\n"
    )
    target = _tool("playdl.conf")
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(".new")
        temporary.write_text(config, encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(target)
        _tool("token_cache.conf").unlink(missing_ok=True)
    except OSError as error:
        raise WslError(f"Could not write the downloader session: {error}") from error

    result = _run(
        [
            str(_tool("gplayver")), "--login-no-verify",
            "--device", str(_tool("device-arm64.conf")),
            "--accept-tos", "--app", PACKAGE,
        ],
        timeout=120,
    )
    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0 or not is_signed_in():
        sign_out()
        raise WslError("Google Play session setup failed.\n\n" + output.strip()[-500:])


# -- downloading ----------------------------------------------------------

def _download_into(version_code: int, base: Path, on_line, timeout: int, abi: str):
    filename, _, _ = apkset.abi_profile(abi)
    ensure_device_profile(abi)
    argv = [
        str(_tool("gplaydl")),
        "--device", str(_tool(filename)),
        "--accept-tos",
        "--app", PACKAGE,
        "--app-version", str(version_code),
        "--output", str(base),
    ]
    process = subprocess.Popen(
        argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=str(prefix())
    )
    timed_out = threading.Event()

    def stop() -> None:
        if process.poll() is None:
            timed_out.set()
            try:
                process.kill()
            except OSError:
                pass

    watchdog = threading.Timer(timeout, stop)
    watchdog.daemon = True
    watchdog.start()

    tail: list[str] = []
    last_percent = -1
    try:
        # gplaydl redraws its progress with carriage returns; only report when
        # the percentage actually moves, or the UI queue drowns in redraws.
        for raw in process.stdout or []:
            line = raw.decode("utf-8", "replace").strip()
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
    abi: str = "arm64",
) -> list[Path]:
    """Download and atomically publish one complete matching ARM split set."""
    apkset.abi_profile(abi)
    target.mkdir(parents=True, exist_ok=True)
    prefix_name = f"minecraft-{version_code}"
    with tempfile.TemporaryDirectory(prefix=f".{prefix_name}-", dir=target) as staging_text:
        staging = Path(staging_text)
        base = staging / f"{prefix_name}.apk"
        returncode, tail = _download_into(version_code, base, on_line, timeout, abi)
        written = sorted(staging.glob(f"{prefix_name}*.apk"))
        try:
            apkset.check_complete(base, written, abi, returncode, tail, on_line)
        except apkset.DownloadError as error:
            raise WslError(str(error)) from error
        return apkset.publish(staging, target, prefix_name)


def to_wsl_path(path: Path) -> str:
    """No translation is needed when the path is already a Linux path."""
    return str(Path(path).resolve())


def selected_distro() -> str:
    return "linux"


def installed_distros() -> list[str]:
    return ["linux"]

