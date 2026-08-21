"""Drives gplaydl inside WSL.

gplaydl comes from minecraft-linux/google-play-api and is the only Play client
still able to download Minecraft. It is a Linux binary, so it runs under WSL and
writes straight into a Windows folder through /mnt.

The account holder's Google sign-in is handled by signin.py; this module only
passes the resulting long-lived token through to gplaydl.
"""
from __future__ import annotations

import os
import re
import shlex
import sys
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Callable

import apkset

# Everything runs as root inside the distribution. Windows grants that without
# a password by design, which removes the whole "create a UNIX user, remember a
# second password, type it into a terminal" detour from first-run setup. $HOME
# is therefore /root, and an install made by an older helper under a normal
# user's home is simply rebuilt once.
WSL_USER = "root"
DISTRO = "Ubuntu"
PREFIX = "$HOME/.local/share/mcbedrock-get"
PACKAGE = "com.mojang.minecraftpe"
# What a complete download looks like is shared with the Linux backend.
ABI_PROFILES = apkset.ABI_PROFILES

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


def _wsl_argv(*arguments: str) -> list[str]:
    return ["wsl.exe", "-d", selected_distro(), "-u", WSL_USER, *arguments]


def _run(script: str, stdin: str | None = None, timeout: int = 120) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            _wsl_argv("--", "bash", "-lc", script),
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
            creationflags=_NO_WINDOW,
        )
    except subprocess.TimeoutExpired as error:
        raise WslError(f"WSL command timed out after {timeout} seconds.") from error


def is_available() -> bool:
    """True when WSL exists and the distro starts."""
    try:
        return _run("true", timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError, WslError):
        return False


def is_installed() -> bool:
    """True when setup-downloader.sh has been run."""
    try:
        return _run(f"test -x {PREFIX}/gplaydl", timeout=60).returncode == 0
    except (OSError, subprocess.SubprocessError, WslError):
        return False


def is_signed_in() -> bool:
    try:
        return _run(
            f"test -s {PREFIX}/playdl.conf && test -s {PREFIX}/token_cache.conf",
            timeout=60,
        ).returncode == 0
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


def _config_value(value: str, label: str) -> str:
    """Quote one upstream config value without allowing extra config lines."""
    if not value or "\n" in value or "\r" in value:
        raise WslError(f"The saved Google {label} is invalid. Sign out and sign in again.")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _abi_profile(abi: str) -> tuple[str, str, str]:
    try:
        return apkset.abi_profile(abi)
    except apkset.DownloadError as error:
        raise WslError(str(error)) from error


def ensure_device_profile(abi: str) -> None:
    """Install the fixed upstream device override for one supported ABI.

    Older helper setups only created the arm64 file. Creating the armhf
    override here makes an updated executable work without asking the user to
    rebuild gplaydl or rerun the privileged WSL setup.
    """
    filename, native_platform, _ = _abi_profile(abi)
    config = f"config.native_platforms = [\n    {native_platform}\n]\n"
    script = (
        f"cd {PREFIX} || exit 1; umask 077; "
        f"tr -d '\\r' > {filename}.new || exit 1; "
        f"chmod 600 {filename}.new || exit 1; "
        f"mv -f {filename}.new {filename}"
    )
    result = _run(script, stdin=config, timeout=60)
    if result.returncode != 0:
        output = ((result.stdout or "") + (result.stderr or "")).strip()
        raise WslError(
            f"Could not prepare the {native_platform} downloader profile.\n\n"
            + output[-500:]
        )


def sign_in(email: str, master_token: str) -> None:
    """Create gplaydl's private config and establish its cached session.

    Upstream's interactive master-token path retries forever when its initial
    verification call fails and stdin has already closed. The token itself is
    still valid for Google Play API calls, so use the upstream non-interactive
    no-verify path. Send the config on stdin so credentials never appear in a
    Windows or Linux process command line.
    """
    config = (
        f"user_email = {_config_value(email, 'email')}\n"
        f"user_token = {_config_value(master_token, 'token')}\n"
    )
    script = (
        f"cd {PREFIX} || exit 1; umask 077; "
        "rm -f playdl.conf.new; trap 'rm -f playdl.conf.new' EXIT HUP INT TERM; "
        "tr -d '\\r' > playdl.conf.new || exit 1; chmod 600 playdl.conf.new || exit 1; "
        "mv -f playdl.conf.new playdl.conf || exit 1; rm -f token_cache.conf; "
        "if ./gplayver --login-no-verify --device device-arm64.conf "
        f"--accept-tos --app {PACKAGE} 2>&1; then exit 0; "
        "else rm -f playdl.conf token_cache.conf; exit 1; fi"
    )
    try:
        result = _run(script, stdin=config, timeout=120)
    except WslError:
        # A killed WSL wrapper can leave the file written before gplayver ran.
        sign_out()
        raise
    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        raise WslError("Google Play session setup failed.\n\n" + output.strip()[-500:])
    if not is_signed_in():
        sign_out()
        raise WslError("gplaydl did not save a session.\n\n" + output.strip()[-500:])


# --------------------------------------------------------------------------
# first-run installation
# --------------------------------------------------------------------------

def _stream(argv: list[str], on_line, timeout: int) -> int:
    """Run a command, forwarding its output a line at a time. Returns the code.

    wsl.exe writes its OWN messages as UTF-16 while everything running inside
    the distribution writes UTF-8, so the stream is decoded permissively and
    stray NULs are dropped rather than shown.
    """
    process = subprocess.Popen(
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        creationflags=_NO_WINDOW,
    )
    deadline = threading.Timer(timeout, process.kill)
    deadline.daemon = True
    deadline.start()
    try:
        for raw in process.stdout or []:
            line = raw.decode("utf-8", "replace").replace("\x00", "").strip()
            if line and on_line is not None:
                on_line(line)
        process.wait()
    finally:
        deadline.cancel()
    return process.returncode


def windows_feature_present() -> bool:
    """True when the Windows Subsystem for Linux itself is installed."""
    try:
        result = subprocess.run(
            ["wsl.exe", "--status"],
            capture_output=True,
            timeout=60,
            creationflags=_NO_WINDOW,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def distro_present() -> bool:
    return any(name == DISTRO or name.startswith(DISTRO + "-") for name in installed_distros())


class RestartNeeded(WslError):
    """Windows enabled the feature but will not finish until it reboots."""


def _asks_for_a_restart(text: str) -> bool:
    lowered = text.lower()
    return "restart" in lowered or "reboot" in lowered


def install_windows_feature(on_line=None) -> None:
    """Turn on the Windows feature. Needs administrator, so Windows asks.

    Uses ShellExecute's "runas" verb rather than telling the user to go and find
    an administrator terminal: the UAC prompt IS the elevation step, and it is
    one click instead of a paragraph of instructions.
    """
    if sys.platform != "win32":
        raise WslError("This helper only installs WSL on Windows.")
    import ctypes

    if on_line:
        on_line("Asking Windows to enable the Subsystem for Linux...")
        on_line("Approve the administrator prompt that appears.")
    # SW_SHOWNORMAL=1: the command window it opens is this step's only progress.
    result = int(ctypes.windll.shell32.ShellExecuteW(
        None, "runas", "wsl.exe", "--install --no-distribution", None, 1
    ))
    # ShellExecuteW returns >32 on success; 5 is ERROR_ACCESS_DENIED (declined).
    if result == 5:
        raise WslError("The administrator prompt was declined, so nothing was installed.")
    if result <= 32:
        raise WslError("Windows could not start the installer (code %d)." % result)
    raise RestartNeeded(
        "Windows is installing the Subsystem for Linux.\n\n"
        "Let it finish, restart the computer, then open this program again - "
        "it carries on from here."
    )


def install_distro(on_line=None, timeout: int = 1800) -> None:
    """Download and register Ubuntu, without launching its first-run wizard.

    --no-launch is the point: that wizard exists only to create a UNIX user and
    password, and nothing here needs one because every command runs as root.
    """
    if on_line:
        on_line("Downloading " + DISTRO + ". About 500 MB, unpacking to roughly 1.5 GB.")
    lines: list[str] = []

    def record(line: str) -> None:
        lines.append(line)
        del lines[:-30]
        if on_line:
            on_line(line)

    code = _stream(["wsl.exe", "--install", "-d", DISTRO, "--no-launch"], record, timeout)
    if code != 0 and not distro_present():
        joined = "\n".join(lines[-10:])
        if _asks_for_a_restart(joined):
            raise RestartNeeded(
                "Windows needs to restart before Ubuntu can be installed.\n\n"
                "Restart the computer, then open this program again."
            )
        raise WslError("Ubuntu could not be installed (code %d).\n\n%s" % (code, joined))
    if on_line:
        on_line(DISTRO + " is installed.")


def _default_user_home() -> str:
    """The home of UID 1000, which is where an older helper built gplaydl."""
    try:
        result = _run("getent passwd 1000 | cut -d: -f6", timeout=60)
    except (OSError, subprocess.SubprocessError, WslError):
        return ""
    home = (result.stdout or "").strip()
    return home if result.returncode == 0 and home.startswith("/") else ""


def adopt_legacy_install() -> bool:
    """Move a pre-root install into root's home instead of rebuilding it.

    Older helpers built gplaydl under the default user's home. Switching to root
    would otherwise make a working install invisible and cost the user another
    five-minute build for nothing. The cached Google session is deliberately
    left behind: it re-establishes itself on the next download, and a credential
    file is not worth copying about to save one silent step.

    Written without shell variables on purpose -- an assignment does not survive
    this `wsl.exe -- bash -lc` invocation, though $HOME and $(...) both do.
    """
    home = _default_user_home()
    if not home:
        return False
    legacy = shlex.quote(home + "/.local/share/mcbedrock-get")
    script = (
        f"test -x {legacy}/gplaydl || exit 1; "
        f"test -x {PREFIX}/gplaydl && exit 1; "
        f"mkdir -p {PREFIX} || exit 1; "
        f"cp -a {legacy}/gplaydl {legacy}/gplayver {PREFIX}/ || exit 1; "
        f"cp -a {legacy}/device-arm64.conf {PREFIX}/ 2>/dev/null; "
        f"cp -a {legacy}/device-armhf.conf {PREFIX}/ 2>/dev/null; "
        f"test -x {PREFIX}/gplaydl"
    )
    try:
        return _run(script, timeout=180).returncode == 0
    except (OSError, subprocess.SubprocessError, WslError):
        return False


def build_downloader(script: Path, on_line=None, timeout: int = 3600) -> None:
    """Run setup-downloader.sh as root, with its output coming back to the window.

    No terminal and no password: the script sees it is root and skips sudo, and
    MCBEDROCK_NONINTERACTIVE stops it waiting for a keypress at the end.
    """
    if not script.is_file():
        raise WslError("setup-downloader.sh is missing. Expected it at:\n\n%s" % script)
    argv = _wsl_argv(
        "--", "bash", "-lc",
        "MCBEDROCK_NONINTERACTIVE=1 bash " + shlex.quote(to_wsl_path(script)),
    )
    lines: list[str] = []

    def record(line: str) -> None:
        lines.append(line)
        del lines[:-40]
        if on_line:
            on_line(line)

    code = _stream(argv, record, timeout)
    if code != 0 or not is_installed():
        raise WslError(
            "The downloader could not be built inside Ubuntu.\n\n"
            + "\n".join(lines[-12:])
        )


def remove_distro() -> None:
    """Delete the distribution and everything in it. Only ever on request."""
    result = subprocess.run(
        ["wsl.exe", "--unregister", selected_distro()],
        capture_output=True,
        timeout=300,
        creationflags=_NO_WINDOW,
    )
    if result.returncode != 0:
        detail = (result.stdout + result.stderr).decode("utf-8", "replace").replace("\x00", "")
        raise WslError("Ubuntu could not be removed.\n\n%s" % detail.strip()[-400:])


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
    abi: str,
) -> tuple[int, list[str]]:
    """Run gplaydl into an isolated path and return its exit code/log tail."""
    filename, _, _ = _abi_profile(abi)
    ensure_device_profile(abi)
    quoted_output = shlex.quote(to_wsl_path(base))
    script = (
        f"cd {PREFIX} && ./gplaydl --device {PREFIX}/{filename} --accept-tos "
        f"--app {PACKAGE} --app-version {version_code} --output {quoted_output} 2>&1"
    )

    process = subprocess.Popen(
        _wsl_argv("--", "bash", "-lc", script),
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
    abi: str = "arm64",
) -> list[Path]:
    """Download and atomically publish one complete matching ARM split set."""
    _, native_platform, split_marker = _abi_profile(abi)
    target.mkdir(parents=True, exist_ok=True)
    prefix = f"minecraft-{version_code}"
    with tempfile.TemporaryDirectory(prefix=f".{prefix}-", dir=target) as staging_text:
        staging = Path(staging_text)
        base = staging / f"{prefix}.apk"
        returncode, tail = _download_into(version_code, base, on_line, timeout, abi)

        written = sorted(staging.glob(f"{prefix}*.apk"))
        try:
            apkset.check_complete(base, written, abi, returncode, tail, on_line)
        except apkset.DownloadError as error:
            raise WslError(str(error)) from error
        return apkset.publish(staging, target, prefix)
