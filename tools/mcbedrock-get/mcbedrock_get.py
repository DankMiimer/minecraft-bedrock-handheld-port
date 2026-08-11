"""Download your own Minecraft Bedrock builds for the handheld port.

Sign in with the Google account that owns Minecraft, press a version, get the
arm64 APKs. Downloading is done by gplaydl (minecraft-linux/google-play-api)
running inside WSL; see wsl-setup.sh.

No Minecraft content is bundled with or distributed by this tool.

    mcbedrock_get.py                       open the window
    mcbedrock_get.py --check               report setup state
    mcbedrock_get.py --login you@gmail.com sign in only
    mcbedrock_get.py --logout              remove saved sessions
    mcbedrock_get.py --download 1.16.221.01 --out D:\\apk
"""
from __future__ import annotations

import argparse
import queue
import subprocess
import sys
import threading
from pathlib import Path

import signin
import wsl_backend


def app_dir() -> Path:
    """Folder holding the executable, or the sources when run unfrozen."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).parent
    return Path(__file__).resolve().parent


def login_in_subprocess(email: str) -> None:
    """Run sign-in in a child process.

    The embedded browser insists on owning the main thread, which the window
    already occupies, so it gets a process of its own. Only a status code comes
    back — the account token is written straight to the user's profile by the
    child.
    """
    if getattr(sys, "frozen", False):
        command = [sys.executable, "--login", email]
    else:
        command = [sys.executable, str(Path(__file__).resolve()), "--login", email]

    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Sign-in failed.").strip()
        raise signin.SignInError(message.splitlines()[-1] if message else "Sign-in failed.")

APP_NAME = "Minecraft Bedrock APK downloader"

# The only two builds worth offering: the port's recommended default and the
# newest one it has tested. Everything else is a support burden.
VERSIONS = [
    ("1.16.221.01", 971622101, "Recommended — best UI scaling on a small screen"),
    ("1.21.51.01", 972105101, "Newest tested build without RenderDragon"),
]

SETUP_HINT = (
    "The downloader is not installed in WSL yet. This is a one-time setup of "
    "a few minutes.\n\n"
    "Install it now?\n\n"
    "A terminal window will open and ask for your Ubuntu password, then build "
    "the downloader."
)


def default_output_dir() -> Path:
    return Path.home() / "Documents" / "MinecraftBedrockPort"


def setup_state() -> tuple[bool, bool, bool, str]:
    """(wsl, downloader, signed_in, human summary)"""
    creds = signin.load()
    signed_in = creds is not None

    if not wsl_backend.is_available():
        return False, False, signed_in, "WSL is not installed. See GETTING-BEDROCK-APKS.md."
    if not wsl_backend.is_installed():
        return True, False, signed_in, "Downloader not installed in WSL — run wsl-setup.sh."
    if not signed_in:
        return True, True, False, "Not signed in."
    return True, True, True, f"Ready. Signed in as {creds.email}."


def fetch(version_code: int, out_dir: Path, log) -> list[Path]:
    """Sign gplaydl in if needed, then download."""
    creds = signin.load()
    if creds is None:
        raise signin.SignInError("Not signed in yet.")
    if not wsl_backend.is_signed_in():
        log("Passing your Google session to the downloader…")
        wsl_backend.sign_in(creds.master_token)
    log(f"Downloading build {version_code}. This is a few hundred MB.")
    return wsl_backend.download(version_code, out_dir, on_line=log)


# --------------------------------------------------------------------------
# window
# --------------------------------------------------------------------------

class Window:
    def __init__(self, root) -> None:
        import tkinter as tk
        from tkinter import ttk

        self.root = root
        self.events: queue.Queue = queue.Queue()

        root.title(APP_NAME)
        root.geometry("620x360")
        root.minsize(560, 340)

        outer = ttk.Frame(root, padding=14)
        outer.pack(fill="both", expand=True)

        account = ttk.LabelFrame(outer, text="Google account that owns Minecraft", padding=10)
        account.pack(fill="x")
        self.email = tk.StringVar()
        ttk.Label(account, text="Email:").grid(row=0, column=0, sticky="w")
        ttk.Entry(account, textvariable=self.email, width=34).grid(row=0, column=1, padx=8)
        self.sign_in_button = ttk.Button(account, text="Sign in…", command=self.on_sign_in)
        self.sign_in_button.grid(row=0, column=2)
        self.sign_out_button = ttk.Button(account, text="Sign out", command=self.on_sign_out)
        self.sign_out_button.grid(row=0, column=3, padx=(6, 0))

        picker = ttk.LabelFrame(outer, text="Download", padding=10)
        picker.pack(fill="x", pady=12)
        self.version_buttons = []
        for row, (name, code, note) in enumerate(VERSIONS):
            button = ttk.Button(
                picker,
                text=f"Download {name}",
                width=26,
                command=lambda c=code, n=name: self.on_download(c, n),
            )
            button.grid(row=row, column=0, pady=4, sticky="w")
            ttk.Label(picker, text=note, foreground="#666").grid(
                row=row, column=1, padx=10, sticky="w"
            )
            self.version_buttons.append(button)

        target = ttk.LabelFrame(outer, text="Save to", padding=10)
        target.pack(fill="x")
        self.out_dir = tk.StringVar(value=str(default_output_dir()))
        ttk.Entry(target, textvariable=self.out_dir).pack(side="left", fill="x", expand=True)
        ttk.Button(target, text="Browse…", command=self.on_browse).pack(side="left", padx=(8, 0))

        self.progress = ttk.Progressbar(outer, mode="indeterminate")
        self.progress.pack(fill="x", pady=(12, 6))
        self.status = ttk.Label(outer, text="Checking setup…", foreground="#444")
        self.status.pack(anchor="w")

        self.root.after(100, self.drain)
        threading.Thread(target=self.refresh, daemon=True).start()

    # -- plumbing ----------------------------------------------------------

    def post(self, kind: str, payload=None) -> None:
        self.events.put((kind, payload))

    def drain(self) -> None:
        while True:
            try:
                kind, payload = self.events.get_nowait()
            except queue.Empty:
                break
            if kind == "status":
                self.status.configure(text=str(payload)[:150])
            elif kind == "state":
                signed_in, summary = payload
                self.status.configure(text=summary)
                creds = signin.load()
                if creds:
                    self.email.set(creds.email)
                self.set_busy(False)
            elif kind == "busy":
                self.set_busy(True)
                self.progress.start(12)
            elif kind == "done":
                self.set_busy(False)
                self.progress.stop()
                from tkinter import messagebox

                messagebox.showinfo(APP_NAME, payload)
            elif kind == "error":
                self.set_busy(False)
                self.progress.stop()
                from tkinter import messagebox

                messagebox.showerror(APP_NAME, payload)
        self.root.after(100, self.drain)

    def set_busy(self, busy: bool) -> None:
        state = "disabled" if busy else "normal"
        for button in self.version_buttons:
            button.configure(state=state)
        self.sign_in_button.configure(state=state)
        self.sign_out_button.configure(state=state)

    def refresh(self) -> None:
        _, _, signed_in, summary = setup_state()
        self.post("state", (signed_in, summary))

    # -- actions -----------------------------------------------------------

    def on_browse(self) -> None:
        from tkinter import filedialog

        chosen = filedialog.askdirectory(initialdir=self.out_dir.get() or str(Path.home()))
        if chosen:
            self.out_dir.set(chosen)

    def on_sign_in(self) -> None:
        email = self.email.get().strip()
        if "@" not in email:
            from tkinter import messagebox

            messagebox.showinfo(APP_NAME, "Type the email of the account that owns Minecraft.")
            return

        self.post("busy")
        self.post("status", "Waiting for the Google sign-in window…")

        def work() -> None:
            try:
                login_in_subprocess(email)
                self.post("status", "Signed in.")
                self.refresh()
            except Exception as error:
                self.post("error", str(error))

        threading.Thread(target=work, daemon=True).start()

    def on_sign_out(self) -> None:
        self.post("busy")
        self.post("status", "Removing the saved account session…")

        def work() -> None:
            try:
                wsl_cleared = wsl_backend.sign_out()
                signin.forget()
                message = (
                    "Signed out on Windows and in WSL."
                    if wsl_cleared
                    else "Signed out on Windows. WSL was unavailable; run Sign out "
                         "again after Ubuntu starts to clear its cache."
                )
                self.post("state", (False, message))
            except Exception as error:
                self.post("error", str(error))

        threading.Thread(target=work, daemon=True).start()

    def on_download(self, code: int, name: str) -> None:
        ready_wsl, ready_tool, signed_in, _ = setup_state()
        from tkinter import messagebox

        if not ready_wsl:
            messagebox.showerror(
                APP_NAME,
                "WSL is not installed.\n\n"
                "Open PowerShell as administrator, run  wsl --install  and reboot.",
            )
            return
        if not ready_tool:
            if messagebox.askyesno(APP_NAME, SETUP_HINT):
                try:
                    wsl_backend.run_setup_in_terminal(app_dir() / "wsl-setup.sh")
                    self.status.configure(text="Setup running in the terminal window…")
                except Exception as error:
                    messagebox.showerror(APP_NAME, str(error))
            return
        if not signed_in:
            messagebox.showinfo(APP_NAME, "Sign in first.")
            return

        out_dir = Path(self.out_dir.get())
        self.post("busy")

        def work() -> None:
            try:
                written = fetch(code, out_dir, log=lambda text: self.post("status", text))
                names = "\n".join(f"  {p.name}" for p in written)
                self.post(
                    "done",
                    f"{name} downloaded to\n{out_dir}\n\n{names}\n\n"
                    "Copy every one of these files to your device, into\n"
                    "ports/minecraftbedrock-data/apk/",
                )
            except Exception as error:
                self.post("error", str(error))

        threading.Thread(target=work, daemon=True).start()


def run_window() -> int:
    import tkinter as tk

    root = tk.Tk()
    Window(root)
    root.mainloop()
    return 0


# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("--check", action="store_true", help="report setup state")
    parser.add_argument("--login", metavar="EMAIL", help="sign in and exit")
    parser.add_argument("--logout", action="store_true", help="remove saved account sessions")
    parser.add_argument("--download", metavar="VERSION", help="e.g. 1.16.221.01")
    parser.add_argument("--out", metavar="DIR", help="where to save")
    args = parser.parse_args(argv)

    if args.check:
        wsl, tool, signed_in, summary = setup_state()
        print(f"WSL:        {'yes' if wsl else 'no'}")
        print(f"downloader: {'yes' if tool else 'no'}")
        print(f"signed in:  {'yes' if signed_in else 'no'}")
        print(summary)
        return 0 if (wsl and tool) else 1

    if args.login:
        print(f"Signed in as {signin.run_login(args.login).email}.")
        return 0

    if args.logout:
        wsl_cleared = wsl_backend.sign_out()
        signin.forget()
        if wsl_cleared:
            print("Signed out on Windows and in WSL.")
        else:
            print(
                "Signed out on Windows. WSL was unavailable; run --logout again "
                "after Ubuntu starts to clear its cache."
            )
        return 0

    if args.download:
        match = next((v for v in VERSIONS if v[0] == args.download), None)
        if match is None:
            names = ", ".join(v[0] for v in VERSIONS)
            print(f"Unknown version {args.download!r}. Available: {names}", file=sys.stderr)
            return 2
        out_dir = Path(args.out) if args.out else default_output_dir()
        for path in fetch(match[1], out_dir, log=print):
            print(f"  {path.name}")
        return 0

    return run_window()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (signin.SignInError, wsl_backend.WslError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
