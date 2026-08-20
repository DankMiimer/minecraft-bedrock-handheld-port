"""Download your own Minecraft Bedrock builds for the handheld port.

Sign in with the Google account that owns Minecraft, pick any version from the
list, get the matching arm64 or armhf APKs. The version list comes from
mcpelauncher-versiondb (see catalog.py); downloading is done by gplaydl
(minecraft-linux/google-play-api) running inside WSL, see setup-downloader.sh.

No Minecraft content is bundled with or distributed by this tool.

    mcbedrock_get.py                       open the window
    mcbedrock_get.py --check               report setup state
    mcbedrock_get.py --list                print every downloadable version
    mcbedrock_get.py --login                sign in only
    mcbedrock_get.py --logout              remove saved sessions
    mcbedrock_get.py --download 1.16.221.01 --abi armhf --out D:\\apk
"""
from __future__ import annotations

import argparse
import os
import queue
import re
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

import catalog
import signin

if sys.platform == "win32":
    import wsl_backend as backend
else:
    import linux_backend as backend


def app_dir() -> Path:
    """Folder holding the executable, or the sources when run unfrozen."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).parent
    return Path(__file__).resolve().parent


def login_in_subprocess(email: str = "") -> None:
    """Run sign-in in a child process.

    The embedded browser insists on owning the main thread, which the window
    already occupies, so it gets a process of its own. Only a status code comes
    back — the account and its token are written straight to the user's profile
    by the child, and read back from there with signin.load().
    """
    argv = ["--login"] + ([email] if email else [])
    if getattr(sys, "frozen", False):
        command = [sys.executable, *argv]
    else:
        command = [signin_interpreter(), str(Path(__file__).resolve()), *argv]

    result = subprocess.run(command, capture_output=True, text=True, env=signin_environment())
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Sign-in failed.").strip()
        raise signin.SignInError(message.splitlines()[-1] if message else "Sign-in failed.")

def signin_interpreter() -> str:
    """Which Python draws Google's sign-in page.

    On Windows, this one: the sign-in window is Edge WebView2, which the bundled
    interpreter can drive.

    On Linux it must be the SYSTEM python3. The window is drawn by WebKitGTK
    through PyGObject, and PyGObject is a compiled extension built against the
    system interpreter -- a bundled Python of a different version cannot import
    it at any price. Everything this program adds on top (pywebview, gpsoauth)
    is pure Python, so the system interpreter can import those from here, which
    is what makes the split work at all.
    """
    if sys.platform == "win32" or not getattr(sys, "frozen", False):
        return sys.executable
    return os.environ.get("MCBEDROCK_SYSTEM_PYTHON") or "python3"


def signin_environment() -> dict:
    """Let a system interpreter import the pure-Python parts shipped with us."""
    environment = dict(os.environ)
    if sys.platform == "win32":
        return environment
    bundled = os.environ.get("MCBEDROCK_PURE_PYTHON", "")
    if bundled:
        existing = environment.get("PYTHONPATH", "")
        environment["PYTHONPATH"] = f"{bundled}:{existing}" if existing else bundled
    return environment


APP_NAME = "Minecraft Bedrock APK downloader"

ABI_CHOICES = [
    ("arm64", "64-bit  arm64-v8a", "RG34XX SP, RGDS, most current handhelds"),
    ("armhf", "32-bit  armeabi-v7a", "R36S-class armhf firmware, Miyoo Mini Plus"),
]

# ---- palette -------------------------------------------------------------
# Tk has no styling worth the name of its own, so every colour is set here.
# Dark by choice: this window sits beside a terminal running the WSL build.
INK = "#0f1319"          # window
PANEL = "#171d26"        # cards
RAISED = "#1e2734"       # inputs, list rows
EDGE = "#28323f"         # hairline borders
TEXT = "#e8edf4"
MUTED = "#8d9aad"
GRASS = "#6ab04c"        # the accent, and the primary button
GRASS_HOT = "#7cc75c"
GOLD = "#e3b341"         # tested-build marker
DIRT = "#8a5a3b"
STRIPE = "#1a2330"      # every other row of the version list
ALARM = "#e0655f"       # RenderDragon: known unplayable here

# Display scale, 1.0 until enable_dpi_awareness() measures the real one.
SCALE = 1.0


def px(value: float) -> int:
    """A pixel count written for a 96-dpi screen, on the screen we actually got."""
    return int(round(value * SCALE))


def enable_dpi_awareness() -> float:
    """Claim the display's real pixels, and remember its scale factor.

    Without this Windows draws the window at 96 dpi and then STRETCHES the
    finished bitmap up to the display's scale, which is why an unprepared Tk app
    on a 125% or 150% screen looks soft — every glyph is a resampled 96-dpi
    glyph. Declaring awareness gets crisp text but real pixels, so everything
    sized in pixels below has to be multiplied by px().

    Must run before the first window exists; Windows locks the mode after that.
    """
    global SCALE
    if sys.platform != "win32":
        return SCALE
    import ctypes

    try:
        user32, shcore = ctypes.windll.user32, ctypes.windll.shcore
    except (AttributeError, OSError):
        return SCALE

    claimed = False
    try:
        # -4 is per-monitor v2: also correct after a drag to a second screen.
        claimed = bool(user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)))
    except (AttributeError, OSError):
        claimed = False
    if not claimed:
        for attempt in (lambda: shcore.SetProcessDpiAwareness(2), user32.SetProcessDPIAware):
            try:
                attempt()
                claimed = True
                break
            except (AttributeError, OSError):
                continue
    if not claimed:
        return SCALE

    try:
        dpi = user32.GetDpiForSystem()
    except (AttributeError, OSError):
        dpi = 96
    SCALE = max(1.0, dpi / 96.0)
    return SCALE


def use_dark_titlebar(root) -> None:
    """Ask DWM for the dark title bar, so the frame matches what is inside it."""
    if sys.platform != "win32":
        return
    import ctypes

    try:
        # The frame window is created lazily; without this wm_frame() can still
        # answer 0x0 and the attribute would be set on nothing at all.
        root.update_idletasks()
        handle = int(root.wm_frame(), 16)
        if not handle:
            return
        set_attribute = ctypes.windll.dwmapi.DwmSetWindowAttribute
        set_attribute.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        flag = ctypes.c_int(1)
        # 20 on Windows 11 and late 10; 19 on the builds before it was named.
        for attribute in (20, 19):
            if set_attribute(ctypes.c_void_p(handle), attribute,
                             ctypes.byref(flag), ctypes.sizeof(flag)) == 0:
                return
    except (AttributeError, OSError, ValueError):
        pass


def default_output_dir() -> Path:
    return Path.home() / "Documents" / "MinecraftBedrockPort"


WINDOWS_SETUP_STEPS = (
    ("feature", "Windows Subsystem for Linux"),
    ("distro", "Ubuntu Linux"),
    ("tool", "Google Play downloader"),
    ("account", "Google account"),
)

# Linux runs the downloader directly, so the two install steps that exist only
# to give Windows a Linux to run it in simply are not there.
LINUX_SETUP_STEPS = (
    ("tool", "Google Play downloader"),
    ("account", "Google account"),
)


def setup_steps() -> tuple[tuple[str, str], ...]:
    return WINDOWS_SETUP_STEPS if sys.platform == "win32" else LINUX_SETUP_STEPS

# Shown BEFORE anything is installed. Nobody should discover afterwards that a
# second operating system arrived on their computer, so this says so first, in
# the plainest words available, with the sizes and the way back out.
WINDOWS_SETUP_EXPLANATION = (
    "This installs a complete Ubuntu Linux system inside Windows.\n\n"
    "WHY\n"
    "Google Play only hands Minecraft to a Play client, and the only one that "
    "still works is Linux software. Windows cannot run it, so it runs inside "
    "Linux instead.\n\n"
    "WHAT WILL HAPPEN\n"
    "1. Windows Subsystem for Linux is switched on. Windows will ask for "
    "administrator permission, and may want to restart.\n"
    "2. Ubuntu Linux is downloaded and installed - roughly 500 MB to download "
    "and 1.5 GB on disk.\n"
    "3. Build tools and the downloader are compiled inside it - roughly 2 GB "
    "more, and a few minutes of waiting.\n\n"
    "Ubuntu is a real operating system, not a small library. It runs in a "
    "lightweight virtual machine beside Windows, starts only when something "
    "uses it, and stays on this computer until you remove it. Other programs "
    "can use it too.\n\n"
    "You will not be asked to invent a Linux username or password: this "
    "program does its work as root, which Windows allows without one.\n\n"
    "TO REMOVE IT ALL LATER\n"
    "Open PowerShell and run:    wsl --unregister Ubuntu\n\n"
    "No Minecraft files come from this program.\n\n"
    "Set it up now?"
)


LINUX_SETUP_EXPLANATION = (
    "This builds the Google Play downloader on this computer.\n\n"
    "WHY\n"
    "Google Play only hands Minecraft to a Play client, and the only one that "
    "still works is gplaydl. No distribution packages it, so it is compiled "
    "here from its own source.\n\n"
    "WHAT WILL HAPPEN\n"
    "1. Build tools are installed with your package manager ({manager}). You "
    "will be asked to authorise that once - it is the only part that needs "
    "administrator rights.\n"
    "2. gplaydl is downloaded from minecraft-linux/Google-Play-API and "
    "compiled. This takes a few minutes.\n"
    "3. It is installed under ~/.local/share/mcbedrock-get. Nothing else on "
    "the system is touched.\n\n"
    "The build itself runs as you, not as root, so what it produces belongs to "
    "you and lands in your own home directory.\n\n"
    "TO REMOVE IT ALL LATER\n"
    "Delete ~/.local/share/mcbedrock-get\n\n"
    "No Minecraft files come from this program.\n\n"
    "Set it up now?"
)


def setup_explanation() -> str:
    """What this machine is about to have installed on it, in full."""
    if sys.platform == "win32":
        return WINDOWS_SETUP_EXPLANATION
    manager = backend.package_manager() or "your package manager"
    return LINUX_SETUP_EXPLANATION.format(manager=manager)


@dataclass(frozen=True)
class Readiness:
    """What is in place, one line per thing the user can see in the window."""

    feature: bool = False
    distro: bool = False
    tool: bool = False
    account: bool = False

    @property
    def ready(self) -> bool:
        return self.feature and self.distro and self.tool and self.account

    @property
    def installs_an_os(self) -> bool:
        """True while the remaining work includes putting Linux on the machine."""
        return not (self.feature and self.distro)

    def next_step(self) -> str:
        for key in ("feature", "distro", "tool", "account"):
            if not getattr(self, key):
                return key
        return ""


def readiness() -> Readiness:
    """Look at the machine, not at what we did last time.

    Checking in order matters: asking about the distribution before WSL exists
    starts a sixty-second timeout for an answer already known.
    """
    account = signin.load() is not None
    if not backend.windows_feature_present():
        return Readiness(account=account)
    if not backend.distro_present():
        return Readiness(feature=True, account=account)
    # An install made by an older helper under a normal user's home is adopted
    # rather than rebuilt.
    tool = backend.is_installed() or backend.adopt_legacy_install()
    return Readiness(feature=True, distro=True, tool=tool, account=account)


def setup_state() -> tuple[bool, bool, bool, str]:
    """(wsl, downloader, signed_in, human summary)"""
    creds = signin.load()
    signed_in = creds is not None

    if not backend.is_available():
        return False, False, signed_in, "WSL is not installed. See GETTING-BEDROCK-APKS.md."
    if not backend.is_installed():
        return True, False, signed_in, "Downloader not installed in WSL — run setup-downloader.sh."
    if not signed_in:
        return True, True, False, "Not signed in."
    return True, True, True, f"Ready. Signed in as {creds.email}."


def fetch(version_code: int, out_dir: Path, log, abi: str = "arm64") -> list[Path]:
    """Sign gplaydl in if needed, then download."""
    creds = signin.load()
    if creds is None:
        raise signin.SignInError("Not signed in yet.")
    if not backend.is_signed_in():
        log("Passing your Google session to the downloader…")
        backend.sign_in(creds.email, creds.master_token)
    label = catalog.ABI_LABELS[abi]
    log(f"Downloading {label} build {version_code}. This is a few hundred MB.")
    return backend.download(version_code, out_dir, on_line=log, abi=abi)


# --------------------------------------------------------------------------
# look
# --------------------------------------------------------------------------

def build_theme(root) -> None:
    """Repaint ttk. Everything below assumes clam, the only stock theme that
    honours background colours on Windows."""
    from tkinter import ttk

    style = ttk.Style(root)
    style.theme_use("clam")

    # Point sizes below are physical, so tell Tk how many pixels a point is here.
    root.tk.call("tk", "scaling", (96.0 * SCALE) / 72.0)

    style.configure(".", background=PANEL, foreground=TEXT, borderwidth=0, focuscolor=GRASS)
    style.configure("TFrame", background=PANEL)
    style.configure("TLabel", background=PANEL, foreground=TEXT)
    style.configure("Muted.TLabel", background=PANEL, foreground=MUTED, font=("Segoe UI", 9))
    style.configure("CardTitle.TLabel", background=PANEL, foreground=MUTED,
                    font=("Segoe UI Semibold", 9))
    style.configure("Step.TLabel", background=PANEL, foreground=MUTED,
                    font=("Segoe UI", 9))
    style.configure("StepDone.TLabel", background=PANEL, foreground=GRASS_HOT,
                    font=("Segoe UI", 9))
    style.configure("StepNow.TLabel", background=PANEL, foreground=TEXT,
                    font=("Segoe UI Semibold", 9))
    style.configure("Status.TLabel", background=INK, foreground=MUTED, font=("Segoe UI", 9))
    style.configure("Warn.TLabel", background=PANEL, foreground=ALARM,
                    font=("Segoe UI Semibold", 9))
    style.configure("Detail.TLabel", background=RAISED, foreground=TEXT,
                    font=("Segoe UI", 9), padding=(px(10), px(8)))
    style.configure("StatusStrong.TLabel", background=INK, foreground=TEXT,
                    font=("Segoe UI Semibold", 9))

    for name, background in (("TEntry", RAISED), ("TCombobox", RAISED)):
        style.configure(
            name,
            fieldbackground=background,
            background=background,
            foreground=TEXT,
            insertcolor=TEXT,
            bordercolor=EDGE,
            lightcolor=EDGE,
            darkcolor=EDGE,
            padding=px(5),
        )
    style.map("TEntry", bordercolor=[("focus", GRASS)], lightcolor=[("focus", GRASS)])

    style.configure(
        "TButton",
        background=RAISED,
        foreground=TEXT,
        bordercolor=EDGE,
        lightcolor=RAISED,
        darkcolor=RAISED,
        padding=(px(12), px(6)),
        font=("Segoe UI", 9),
    )
    style.map(
        "TButton",
        background=[("disabled", PANEL), ("pressed", EDGE), ("active", EDGE)],
        foreground=[("disabled", "#5a6474")],
        bordercolor=[("active", GRASS)],
    )

    style.configure(
        "Primary.TButton",
        background=GRASS,
        foreground="#0d1a08",
        bordercolor=GRASS,
        lightcolor=GRASS,
        darkcolor=GRASS,
        padding=(px(18), px(10)),
        font=("Segoe UI Semibold", 11),
    )
    style.map(
        "Primary.TButton",
        background=[("disabled", "#33402c"), ("pressed", GRASS), ("active", GRASS_HOT)],
        foreground=[("disabled", "#6b7a63")],
        bordercolor=[("disabled", "#33402c"), ("active", GRASS_HOT)],
    )

    for name, background in (("TRadiobutton", PANEL), ("TCheckbutton", PANEL)):
        style.configure(name, background=background, foreground=TEXT,
                        indicatorbackground=RAISED, indicatorcolor=RAISED,
                        bordercolor=EDGE, padding=px(2))
        style.map(
            name,
            background=[("active", background)],
            foreground=[("disabled", "#5a6474")],
            indicatorcolor=[("selected", GRASS), ("pressed", GRASS_HOT)],
        )

    style.configure(
        "Catalog.Treeview",
        background=RAISED,
        fieldbackground=RAISED,
        foreground=TEXT,
        bordercolor=EDGE,
        rowheight=px(26),
        font=("Segoe UI", 9),
    )
    style.map(
        "Catalog.Treeview",
        background=[("selected", GRASS)],
        foreground=[("selected", "#0d1a08")],
    )
    style.configure(
        "Catalog.Treeview.Heading",
        background=PANEL,
        foreground=MUTED,
        relief="flat",
        padding=(px(8), px(6)),
        font=("Segoe UI Semibold", 9),
    )
    style.map("Catalog.Treeview.Heading", background=[("active", EDGE)])

    # Arrow buttons are dead weight on a list this long, and clam draws them in
    # its own colours whatever it is told, so the layout simply omits them.
    style.layout(
        "Catalog.Vertical.TScrollbar",
        [("Vertical.Scrollbar.trough", {"sticky": "ns", "children": [
            ("Vertical.Scrollbar.thumb", {"expand": 1, "sticky": "nswe"})]})],
    )
    style.configure(
        "Catalog.Vertical.TScrollbar",
        background=EDGE,
        troughcolor=PANEL,
        bordercolor=PANEL,
        lightcolor=EDGE,
        darkcolor=EDGE,
        gripcount=0,
        width=px(10),
    )
    style.map("Catalog.Vertical.TScrollbar", background=[("active", GRASS)])

    style.configure(
        "Grass.Horizontal.TProgressbar",
        background=GRASS,
        troughcolor=RAISED,
        bordercolor=RAISED,
        lightcolor=GRASS,
        darkcolor=GRASS,
        thickness=px(8),
    )


def block_icon(tk, size: int = 32):
    """A grass block, drawn pixel by pixel, so the app needs no image file."""
    image = tk.PhotoImage(width=size, height=size)
    grass_top, grass_side, soil = "#7cc75c", "#5d9c40", DIRT
    rows = []
    for y in range(size):
        if y < size * 0.28:
            row = [grass_top] * size
        elif y < size * 0.38:
            row = [grass_side] * size
        else:
            # Two shades of soil in a coarse checker, so it reads as dirt.
            row = [soil if (x // 4 + y // 4) % 2 else "#75492f" for x in range(size)]
        rows.append("{" + " ".join(row) + "}")
    # One put() of the whole bitmap; per-pixel puts are a Tcl round trip each.
    image.put(" ".join(rows))
    return image


HEADER_HEIGHT = 96


def draw_header(canvas, width: int) -> None:
    """Title bar: an isometric block, the name, and one line of purpose."""
    canvas.delete("all")
    canvas.configure(bg=INK)
    bottom = px(HEADER_HEIGHT)
    canvas.create_rectangle(0, 0, width, bottom, fill=INK, outline="")
    canvas.create_line(0, bottom - 1, width, bottom - 1, fill=EDGE)

    # Isometric block at a fixed spot on the left.
    cx, cy, w, h = px(44), px(48), px(22), px(12)
    lift, drop = px(8), px(20)
    canvas.create_polygon(cx, cy - h - lift, cx + w, cy - lift, cx, cy, cx - w, cy - lift,
                          fill="#7cc75c", outline="#8ad86a")
    canvas.create_polygon(cx - w, cy - lift, cx, cy, cx, cy + drop, cx - w, cy + drop - lift,
                          fill="#6b3f27", outline="#6b3f27")
    canvas.create_polygon(cx + w, cy - lift, cx, cy, cx, cy + drop, cx + w, cy + drop - lift,
                          fill=DIRT, outline=DIRT)

    canvas.create_text(px(84), px(34), anchor="w", text="mcbedrock-get", fill=TEXT,
                       font=("Segoe UI Semibold", 16))
    canvas.create_text(px(84), px(60), anchor="w",
                       text="Fetch your own Google Play copy of Minecraft Bedrock "
                            "for the handheld port",
                       fill=MUTED, font=("Segoe UI", 9))
    canvas.create_text(width - px(16), px(34), anchor="e",
                       text="NOT AN OFFICIAL MINECRAFT PRODUCT",
                       fill="#5a6474", font=("Segoe UI", 8))


def add_placeholder(entry, variable, text: str) -> None:
    """Grey prompt text inside an empty entry, gone the moment it is typed in."""
    def show() -> None:
        if not variable.get():
            # Flag first: inserting fires the variable's trace, and whatever
            # watches it must already know this text is not a search term.
            entry.placeholding = True
            entry.insert(0, text)
            entry.configure(foreground=MUTED)

    def clear(_event=None) -> None:
        if getattr(entry, "placeholding", False):
            entry.delete(0, "end")
            entry.configure(foreground=TEXT)
            entry.placeholding = False

    entry.bind("<FocusIn>", clear)
    entry.bind("<FocusOut>", lambda _e: show())
    show()


def card(tk, parent, title: str):
    """A titled panel. Returns the frame children go into."""
    from tkinter import ttk

    shell = tk.Frame(parent, bg=PANEL, highlightthickness=1,
                     highlightbackground=EDGE, highlightcolor=EDGE)
    inner = ttk.Frame(shell, padding=(px(14), px(10), px(14), px(12)))
    inner.pack(fill="both", expand=True)
    ttk.Label(inner, text=title.upper(), style="CardTitle.TLabel").pack(anchor="w",
                                                                       pady=(0, px(8)))
    body = ttk.Frame(inner)
    body.pack(fill="both", expand=True)
    shell.body = body
    return shell


# --------------------------------------------------------------------------
# window
# --------------------------------------------------------------------------

class Window:
    def __init__(self, root) -> None:
        import tkinter as tk
        from tkinter import ttk

        self.root = root
        self.events: queue.Queue = queue.Queue()
        self.catalog = catalog.Catalog(releases=[], source="Loading versions…", complete=False)
        self.rows: list[catalog.Release] = []
        self.state = Readiness()
        # Until the first look at the machine comes back, the card must not
        # offer to install Ubuntu on a computer that already has it.
        self.checked = False
        self.busy = False

        root.title(APP_NAME)
        # Hidden while it is assembled, so nobody watches the cards land one by
        # one — and so the dark title bar is set before the frame is ever drawn.
        root.withdraw()
        root.configure(bg=INK)
        build_theme(root)
        self.place_window(root)
        use_dark_titlebar(root)
        self.icon = block_icon(tk, px(32))
        try:
            root.iconphoto(True, self.icon)
        except tk.TclError:
            pass  # A window manager that refuses an icon is not worth a crash.

        self.header = tk.Canvas(root, height=px(HEADER_HEIGHT), bg=INK, highlightthickness=0)
        self.header.pack(fill="x")
        self.header.bind("<Configure>", lambda e: draw_header(self.header, e.width))

        body = tk.Frame(root, bg=INK)
        body.pack(fill="both", expand=True, padx=px(16), pady=px(14))
        body.columnconfigure(0, weight=0, minsize=px(310))
        body.columnconfigure(1, weight=1)
        body.rowconfigure(0, weight=1)

        left = tk.Frame(body, bg=INK)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, px(14)))
        self._build_setup(tk, ttk, left)
        self._build_device(tk, ttk, left)
        self._build_target(tk, ttk, left)

        right = tk.Frame(body, bg=INK)
        right.grid(row=0, column=1, sticky="nsew")
        self._build_catalog(tk, ttk, right)

        self._build_footer(tk, ttk, root)

        self.root.after(100, self.drain)
        threading.Thread(target=self.refresh, daemon=True).start()
        threading.Thread(target=self.load_catalog, daemon=True).start()
        root.deiconify()

    # -- construction ------------------------------------------------------

    def place_window(self, root) -> None:
        """Size for this display and open in the middle of it."""
        width, height = px(1160), px(690)
        root.minsize(px(1000), px(600))
        screen_w, screen_h = root.winfo_screenwidth(), root.winfo_screenheight()
        # Never taller than the screen it has to fit on.
        height = min(height, screen_h - px(80))
        left = max(0, (screen_w - width) // 2)
        top = max(0, (screen_h - height) // 2 - px(30))
        root.geometry(f"{width}x{height}+{left}+{top}")

    def _build_setup(self, tk, ttk, parent) -> None:
        shell = card(tk, parent, "1 · Setup")
        shell.pack(fill="x")
        body = shell.body

        self.step_labels = {}
        for key, title in setup_steps():
            label = ttk.Label(body, text="·  " + title, style="Step.TLabel",
                              wraplength=px(258), justify="left")
            label.pack(anchor="w", pady=(0, px(3)))
            self.step_labels[key] = (label, title)

        self.setup_button = ttk.Button(body, text="Checking…", state="disabled",
                                       command=self.on_setup)
        self.setup_button.pack(fill="x", pady=(px(10), 0))

        extra = ttk.Frame(body)
        extra.pack(fill="x", pady=(px(6), 0))
        self.explain_button = ttk.Button(extra, text="What gets installed?",
                                         command=self.on_explain)
        self.explain_button.pack(side="left")
        self.sign_out_button = ttk.Button(extra, text="Sign out", command=self.on_sign_out)
        self.sign_out_button.pack(side="left", padx=(px(8), 0))

    def _build_device(self, tk, ttk, parent) -> None:
        shell = card(tk, parent, "2 · Your device")
        shell.pack(fill="x", pady=(px(12), 0))
        body = shell.body

        self.abi = tk.StringVar(value="arm64")
        self.abi_buttons = []
        for value, label, hint in ABI_CHOICES:
            button = ttk.Radiobutton(body, text=label, variable=self.abi, value=value)
            button.pack(anchor="w")
            ttk.Label(body, text=hint, style="Muted.TLabel").pack(
                anchor="w", padx=(px(20), 0), pady=(0, px(6)))
            self.abi_buttons.append(button)
        self.abi.trace_add("write", lambda *_: self.repopulate())

    def _build_target(self, tk, ttk, parent) -> None:
        shell = card(tk, parent, "3 · Save the APKs to")
        shell.pack(fill="x", pady=(px(12), 0))
        body = shell.body

        self.out_dir = tk.StringVar(value=str(default_output_dir()))
        ttk.Entry(body, textvariable=self.out_dir).pack(fill="x")
        self.browse_button = ttk.Button(body, text="Browse…", command=self.on_browse)
        self.browse_button.pack(anchor="w", pady=(px(8), 0))
        ttk.Label(
            body,
            text="Afterwards copy every downloaded .apk to\nports/minecraftbedrock-data/apk/ "
                 "on the handheld.",
            style="Muted.TLabel",
            justify="left",
        ).pack(anchor="w", pady=(px(8), 0))

    def _build_catalog(self, tk, ttk, parent) -> None:
        shell = card(tk, parent, "4 · Choose a version")
        shell.pack(fill="both", expand=True)
        body = shell.body

        tools = ttk.Frame(body)
        tools.pack(fill="x", pady=(0, px(8)))
        self.query = tk.StringVar()
        self.search = ttk.Entry(tools, textvariable=self.query, width=22)
        self.search.pack(side="left", padx=(0, px(14)))
        add_placeholder(self.search, self.query, "Search a version…")
        self.query.trace_add("write", lambda *_: self.repopulate())

        self.include_beta = tk.BooleanVar(value=False)
        self.beta_button = ttk.Checkbutton(
            tools,
            text="Include beta & preview builds",
            variable=self.include_beta,
            command=self.repopulate,
        )
        self.beta_button.pack(side="left")

        self.refresh_button = ttk.Button(tools, text="⟳  Refresh list",
                                         command=self.on_refresh_list)
        self.refresh_button.pack(side="right")

        table = ttk.Frame(body)
        table.pack(fill="both", expand=True)
        columns = ("mark", "version", "edition", "update", "renderer", "note")
        self.tree = ttk.Treeview(
            table,
            columns=columns,
            show="headings",
            style="Catalog.Treeview",
            selectmode="browse",
        )
        for column, title, width, anchor, stretch in (
            ("mark", "", 28, "center", False),
            ("version", "Version", 96, "w", False),
            ("edition", "Edition", 100, "w", False),
            ("update", "Update", 152, "w", False),
            ("renderer", "Renderer", 118, "w", False),
            ("note", "Notes", 250, "w", True),
        ):
            self.tree.heading(column, text=title)
            self.tree.column(column, width=px(width), minwidth=px(width // 2),
                             anchor=anchor, stretch=stretch)
        scroll = ttk.Scrollbar(table, orient="vertical", command=self.tree.yview,
                               style="Catalog.Vertical.TScrollbar")
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

        # One tag per (kind, stripe) pair: a row carrying two tags leaves which
        # one wins up to Tk's tag order, and it does not resolve it the way you
        # would guess.
        for kind, colour in (("tested", GOLD), ("beta", MUTED), ("plain", TEXT),
                             ("avoid", ALARM)):
            for index, background in enumerate((RAISED, STRIPE)):
                self.tree.tag_configure(f"{kind}{index}", foreground=colour,
                                        background=background)
        self.tree.bind("<<TreeviewSelect>>", lambda _e: self.update_download_button())
        self.tree.bind("<Double-1>", lambda _e: self.on_download())
        self.tree.bind("<Return>", lambda _e: self.on_download())

        ttk.Label(
            body,
            text=f"RenderDragon builds ({catalog.RENDERDRAGON_FROM} and newer on "
                 "Android) are guaranteed to stutter on this hardware — do not "
                 "use them.",
            style="Warn.TLabel",
            wraplength=px(620),
            justify="left",
        ).pack(anchor="w", pady=(px(8), 0))
        # The Notes column can only ever show a first line, so the selected
        # row's notes are repeated here in full, wrapped.
        self.detail = ttk.Label(
            body,
            text="",
            style="Detail.TLabel",
            wraplength=px(780),
            justify="left",
        )
        self.detail.pack(anchor="w", fill="x", pady=(px(8), 0))

        self.count_label = ttk.Label(body, text="", style="Muted.TLabel")
        self.count_label.pack(anchor="w", pady=(px(6), 0))

        self.download_button = ttk.Button(
            body,
            text="Download",
            style="Primary.TButton",
            command=self.on_download,
            state="disabled",
        )
        self.download_button.pack(fill="x", pady=(px(10), 0))

    def _build_footer(self, tk, ttk, parent) -> None:
        footer = tk.Frame(parent, bg=INK)
        footer.pack(fill="x", padx=px(16), pady=(0, px(14)))
        self.progress = ttk.Progressbar(
            footer, mode="determinate", maximum=100, style="Grass.Horizontal.TProgressbar"
        )
        self.progress.pack(fill="x")
        self.status = ttk.Label(footer, text="Checking setup…", style="StatusStrong.TLabel")
        self.status.pack(anchor="w", pady=(px(8), 0))

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
                self.show_progress_line(str(payload))
            elif kind == "state":
                state, summary = payload
                self.state = state
                self.checked = True
                self.status.configure(text=summary)
                self.paint_setup(state)
                self.set_busy(False)
            elif kind == "notice":
                self.finish_progress()
                from tkinter import messagebox

                messagebox.showinfo(APP_NAME, payload)
            elif kind == "catalog":
                self.catalog = payload
                self.repopulate()
                self.set_busy(False)
            elif kind == "busy":
                self.set_busy(True)
                self.progress.configure(mode="indeterminate")
                self.progress.start(12)
            elif kind == "done":
                self.finish_progress()
                from tkinter import messagebox

                folder, message = payload
                messagebox.showinfo(APP_NAME, message)
                if folder is not None:
                    self.offer_to_open(folder)
            elif kind == "error":
                self.finish_progress()
                self.status.configure(text="Failed. Nothing was changed on disk.")
                from tkinter import messagebox

                messagebox.showerror(APP_NAME, payload)
        self.root.after(100, self.drain)

    def show_progress_line(self, text: str) -> None:
        """Turn gplaydl's chatter into a status line and a real progress bar."""
        match = re.search(r"Downloaded (\d+)%", text)
        if match:
            percent = int(match.group(1))
            if str(self.progress.cget("mode")) != "determinate":
                self.progress.stop()
                self.progress.configure(mode="determinate")
            self.progress.configure(value=percent)
        self.status.configure(text=text[:150])

    def finish_progress(self) -> None:
        self.progress.stop()
        self.progress.configure(mode="determinate", value=0)
        self.set_busy(False)

    def set_busy(self, busy: bool) -> None:
        self.busy = busy
        state = "disabled" if busy else "normal"
        for widget in (
            self.setup_button,
            self.explain_button,
            self.sign_out_button,
            self.browse_button,
            self.refresh_button,
            self.beta_button,
            *self.abi_buttons,
        ):
            widget.configure(state=state)
        self.tree.configure(selectmode="none" if busy else "browse")
        self.paint_setup(self.state)
        self.update_download_button()

    def refresh(self) -> None:
        state = readiness()
        creds = signin.load()
        if not state.feature:
            summary = "Windows Subsystem for Linux is not installed yet."
        elif not state.distro:
            summary = "Ubuntu is not installed yet."
        elif not state.tool:
            summary = "The Play downloader is not built yet."
        elif creds is None:
            summary = "Not signed in."
        else:
            summary = f"Ready. Signed in as {creds.email}."
        self.post("state", (state, summary))

    def paint_setup(self, state: Readiness) -> None:
        """Tick off what is done, and point the one button at what is not."""
        if not self.checked:
            self.setup_button.configure(text="Checking…", state="disabled")
            self.sign_out_button.configure(state="disabled")
            return
        creds = signin.load()
        upcoming = state.next_step()
        for key, title in setup_steps():
            label, _ = self.step_labels[key]
            done = getattr(state, key)
            text = title
            if key == "account" and done and creds:
                text = f"{title} — {creds.email}"
            label.configure(
                text=("✓  " if done else "·  ") + text,
                style="StepDone.TLabel" if done else
                      ("StepNow.TLabel" if key == upcoming else "Step.TLabel"),
            )
        labels = {
            "feature": "Set up Ubuntu and the downloader",
            "distro": "Set up Ubuntu and the downloader",
            "tool": "Build the downloader",
            "account": "Sign in…",
            "": "Everything is ready",
        }
        self.setup_button.configure(
            text=labels[upcoming],
            state="disabled" if (self.busy or state.ready) else "normal",
        )
        self.sign_out_button.configure(
            state="disabled" if (self.busy or not state.account) else "normal"
        )

    def load_catalog(self, force: bool = False) -> None:
        self.post("catalog", catalog.load(force_refresh=force,
                                          on_status=lambda text: self.post("status", text)))

    # -- the list ----------------------------------------------------------

    def repopulate(self) -> None:
        """Refill the table for the current ABI, search text and beta setting."""
        abi = self.abi.get()
        keep = self.selected_release()
        self.rows = self.catalog.select(abi, self.include_beta.get(), self.search_text())

        self.tree.delete(*self.tree.get_children())
        for index, release in enumerate(self.rows):
            if release.curated:
                tag = "tested"
            elif release.beta:
                tag = "beta"
            else:
                tag = "plain"
            # A build that cannot run acceptably here outranks every other
            # label: whatever else it is, the answer is still "not this one".
            if release.renderer(abi) == "renderdragon":
                tag = "avoid"
            self.tree.insert(
                "",
                "end",
                iid=str(index),
                values=(
                    "★" if release.curated else "",
                    release.name,
                    release.edition,
                    release.update_name,
                    release.renderer_label(abi),
                    release.description(abi),
                ),
                tags=(f"{tag}{index % 2}",),
            )

        if self.rows:
            wanted = next((i for i, r in enumerate(self.rows)
                           if keep is not None and r.name == keep.name), None)
            if wanted is None:
                # Nothing carried over: land on the build this port recommends.
                wanted = next((i for i, r in enumerate(self.rows)
                               if r.name == "1.16.221.01"), 0)
            self.tree.selection_set(str(wanted))
            # see() only scrolls far enough to touch the edge, which leaves the
            # chosen row half-hidden at the top. Reveal a few rows past it first.
            self.tree.see(str(min(len(self.rows) - 1, wanted + 4)))
            self.tree.see(str(max(0, wanted - 4)))
            self.tree.see(str(wanted))

        total = len([r for r in self.catalog.releases if r.supports(abi)])
        shown = len(self.rows)
        detail = f"{shown} of {total} {catalog.ABI_LABELS[abi]} builds"
        if shown == total:
            detail = f"{total} {catalog.ABI_LABELS[abi]} builds"
        self.count_label.configure(text=f"{detail}   ·   {self.catalog.source}")
        self.update_download_button()

    def search_text(self) -> str:
        """What the user typed — never the grey placeholder sitting in the box."""
        if getattr(self.search, "placeholding", False):
            return ""
        return self.query.get()

    def selected_release(self) -> catalog.Release | None:
        selection = self.tree.selection()
        if not selection:
            return None
        try:
            return self.rows[int(selection[0])]
        except (ValueError, IndexError):
            return None

    def describe_selection(self, release: catalog.Release | None) -> None:
        """Spell out the selected build, since the table can only show a line."""
        if release is None:
            self.detail.configure(text="Select a version above.", foreground=MUTED)
            return
        abi = self.abi.get()
        heading = " · ".join(
            part for part in (
                release.name,
                release.edition,
                release.update_name,
                release.renderer_label(abi),
            ) if part
        )
        warning = release.advice(abi)
        if release.note and warning:
            body = f"{release.note}\n{warning}"
        else:
            body = release.note or warning or "No warnings — this build is fine to try."
        self.detail.configure(
            text=f"{heading}\n{body}",
            foreground=ALARM if release.renderer(abi) == "renderdragon" else TEXT,
        )

    def update_download_button(self) -> None:
        release = self.selected_release()
        self.describe_selection(release)
        if self.busy or release is None:
            self.download_button.configure(
                text="Download" if release is None else f"Download {release.name}",
                state="disabled",
            )
            return
        self.download_button.configure(
            text=f"Download {release.name}  ·  {catalog.ABI_LABELS[self.abi.get()]}",
            state="normal",
        )

    def confirm_choice(self, release: catalog.Release, messagebox, abi: str) -> bool:
        """Say plainly what is wrong with this build before spending 300 MB."""
        if release.edition == "Pocket Edition":
            return messagebox.askyesno(
                APP_NAME,
                f"{release.name} is Minecraft: Pocket Edition, not Bedrock.\n\n"
                "Pocket Edition has touch controls only — it predates gamepad "
                "support, so the buttons on a handheld will do nothing in it.\n\n"
                "Download it anyway?",
                icon="warning",
                default="no",
            )
        if release.renderer(abi) == "renderdragon":
            return messagebox.askyesno(
                APP_NAME,
                f"{release.name} uses RenderDragon.\n\n"
                "Every RenderDragon build tested on this hardware stutters badly, "
                "and none of them are playable. It also draws a much smaller UI "
                f"than {catalog.BEST_UI}.\n\n"
                "Download it anyway?",
                icon="warning",
                default="no",
            )
        if (release.name, abi) in catalog.NO_RENDERDRAGON:
            return messagebox.askyesno(
                APP_NAME,
                f"{release.name} has RenderDragon switched off, which is why the "
                "port can use a build this recent.\n\n"
                "Mojang disabled it here by mistake and re-uploaded Android two "
                "days later as 1.21.51.02 with it back on, so take care not to "
                f"pick that one. Its UI is also smaller than {catalog.BEST_UI}."
                "\n\nDownload it?",
                default="yes",
            )
        if release.tiny_ui:
            return messagebox.askyesno(
                APP_NAME,
                f"{release.name} draws a tiny UI on a handheld screen.\n\n"
                f"{catalog.BEST_UI} is recommended for that reason.\n\n"
                "Download it anyway?",
                default="no",
            )
        if release.beta and not release.curated:
            return messagebox.askyesno(
                APP_NAME,
                f"{release.name} is a beta or preview build.\n\n"
                "Only the builds marked ★ have been tested with this port.\n\n"
                "Download it anyway?",
                default="no",
            )
        return True

    # -- actions -----------------------------------------------------------

    def offer_to_open(self, folder: Path) -> None:
        from tkinter import messagebox

        if not hasattr(os, "startfile"):
            return
        if messagebox.askyesno(APP_NAME, f"Open {folder} now?"):
            try:
                os.startfile(folder)  # noqa: S606 - a folder the user just chose
            except OSError:
                pass

    def on_browse(self) -> None:
        from tkinter import filedialog

        chosen = filedialog.askdirectory(initialdir=self.out_dir.get() or str(Path.home()))
        if chosen:
            self.out_dir.set(chosen)

    def on_refresh_list(self) -> None:
        self.post("busy")
        self.post("status", "Refreshing the version list…")
        threading.Thread(target=self.load_catalog, args=(True,), daemon=True).start()

    def on_explain(self) -> None:
        from tkinter import messagebox

        messagebox.showinfo(
            APP_NAME, setup_explanation().replace("\n\nSet it up now?", "")
        )

    def on_setup(self) -> None:
        """Do whatever is still missing, in order, without asking again."""
        from tkinter import messagebox

        state = self.state
        if state.ready:
            return
        if state.next_step() == "account":
            self.on_sign_in()
            return
        # Windows is about to gain an operating system; Linux is about to gain
        # a compiler and a binary. Either way, say so before doing it.
        needs_consent = state.installs_an_os or sys.platform != "win32"
        if needs_consent and not messagebox.askyesno(
            APP_NAME, setup_explanation(),
            icon="warning" if state.installs_an_os else "question",
            default="no",
        ):
            return

        self.post("busy")

        def log(line: str) -> None:
            self.post("status", line)

        def work() -> None:
            try:
                if not backend.windows_feature_present():
                    backend.install_windows_feature(log)  # raises RestartNeeded
                if not backend.distro_present():
                    backend.install_distro(log)
                if not backend.is_installed() and not backend.adopt_legacy_install():
                    log("Building the Play downloader inside Ubuntu. A few minutes.")
                    backend.build_downloader(app_dir() / "setup-downloader.sh", log)
                self.post("status", "Setup finished.")
                self.refresh()
            except backend.RestartNeeded as pause:
                self.post("notice", str(pause))
                self.refresh()
            except Exception as error:
                self.post("error", str(error))

        threading.Thread(target=work, daemon=True).start()

    def on_sign_in(self, email: str = "") -> None:
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
                wsl_cleared = backend.sign_out()
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

    def on_download(self) -> None:
        if self.busy:
            return
        release = self.selected_release()
        if release is None:
            return

        from tkinter import messagebox

        state = readiness()
        self.state = state
        self.paint_setup(state)
        if not state.ready:
            messagebox.showinfo(
                APP_NAME,
                "Setup is not finished yet.\n\n"
                "Use the button in step 1 — it does whatever is still missing.",
            )
            return

        abi = self.abi.get()
        code = release.code_for(abi)
        if code is None:
            messagebox.showinfo(
                APP_NAME, f"{release.name} is not available for {catalog.ABI_LABELS[abi]}."
            )
            return
        if not self.confirm_choice(release, messagebox, abi):
            self.finish_progress()
            return
        out_dir = Path(self.out_dir.get())
        self.post("busy")

        def work() -> None:
            try:
                written = fetch(
                    code,
                    out_dir,
                    log=lambda text: self.post("status", text),
                    abi=abi,
                )
                names = "\n".join(f"  {p.name}" for p in written)
                self.post(
                    "done",
                    (
                        out_dir,
                        f"{release.name} ({catalog.ABI_LABELS[abi]}) downloaded to\n{out_dir}\n\n"
                        f"{names}\n\n"
                        "Copy every one of these files to your device, into\n"
                        "ports/minecraftbedrock-data/apk/",
                    ),
                )
            except Exception as error:
                self.post("error", str(error))

        threading.Thread(target=work, daemon=True).start()


def ask_for_address() -> str:
    """A one-field dialog, used only when Google would not name the account."""
    try:
        import tkinter as tk
        from tkinter import simpledialog
    except ImportError:
        return ""

    root = tk.Tk()
    root.withdraw()
    use_dark_titlebar(root)
    try:
        answer = simpledialog.askstring(
            APP_NAME,
            "Signed in — but Google did not say which account it was.\n\n"
            "Type the address of the account that owns Minecraft.\n"
            "You will not have to sign in again.",
            parent=root,
        )
    finally:
        root.destroy()
    return (answer or "").strip()


def interactive_login(email: str = "") -> signin.Credentials:
    """Sign in once, and only once.

    If Google will not say which account signed in, the address is asked for
    HERE, while the one-shot token from that sign-in is still held. Raising
    instead spends the token and forces a second trip through Google's page,
    which is exactly what the first version of this did.
    """
    detected, token = signin.harvest_session()
    address = email.strip() or detected or ask_for_address()
    if "@" not in address:
        raise signin.SignInError("No account address was given, so nothing was saved.")
    return signin.complete_login(address, token)


def run_window() -> int:
    enable_dpi_awareness()  # Before the first window: Windows locks the mode.
    import tkinter as tk

    root = tk.Tk()
    Window(root)
    root.mainloop()
    return 0


# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    # The notes carry en-dashes and middots, and a stock Windows console is
    # cp1252, which turns them into replacement characters.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError, ValueError):
            pass

    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("--check", action="store_true", help="report setup state")
    parser.add_argument("--list", action="store_true", help="print every downloadable version")
    parser.add_argument(
        "--login",
        nargs="?",
        const="",
        metavar="EMAIL",
        help="sign in and exit; the address is only needed if it cannot be read back",
    )
    parser.add_argument("--logout", action="store_true", help="remove saved account sessions")
    parser.add_argument("--download", metavar="VERSION", help="e.g. 1.16.221.01")
    parser.add_argument(
        "--abi",
        choices=tuple(catalog.ABI_DB),
        default="arm64",
        help="APK architecture (default: arm64)",
    )
    parser.add_argument("--out", metavar="DIR", help="where to save")
    parser.add_argument(
        "--all",
        action="store_true",
        help="with --list, include beta and preview builds",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="re-fetch the version list instead of using the saved copy",
    )
    args = parser.parse_args(argv)

    if args.check:
        state = readiness()
        # "WSL" means nothing on a Linux desktop, where there is no subsystem
        # and no distribution -- only the downloader and the account.
        for key, title in setup_steps():
            print(f"{title + ':':<32}{'yes' if getattr(state, key) else 'no'}")
        creds = signin.load()
        print(f"Ready. Signed in as {creds.email}." if state.ready and creds
              else "Setup is not finished.")
        return 0 if (state.tool and state.distro and state.feature) else 1

    if args.list:
        available = catalog.load(force_refresh=args.refresh)
        print(f"{available.source}\n")
        for release in available.select(args.abi, include_beta=args.all):
            mark = "*" if release.curated else " "
            renderer = "RenderDragon" if release.renderer(args.abi) == "renderdragon" else ""
            print(f" {mark} {release.name:<14} {release.code_for(args.abi):<10} "
                  f"{release.edition:<15} {release.update_name:<24} {renderer:<13} "
                  f"{release.description(args.abi)}".rstrip())
        print(
            f"\nRenderDragon builds ({catalog.RENDERDRAGON_FROM} and newer) are "
            "guaranteed to stutter on this hardware; do not use them."
        )
        print(
            f"Everything above {catalog.BEST_UI} also draws a tiny UI on a "
            "handheld screen."
        )
        print(
            f"Below {catalog.BEDROCK_FROM} the game is Minecraft: Pocket Edition, "
            "not Bedrock, and has touch controls only."
        )
        if not args.all:
            print("(beta and preview builds hidden; pass --all to see them)")
        return 0

    if args.login is not None:
        print(f"Signed in as {interactive_login(args.login).email}.")
        return 0

    if args.logout:
        wsl_cleared = backend.sign_out()
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
        available = catalog.load(force_refresh=args.refresh)
        release = available.find(args.download)
        if release is None:
            print(
                f"Unknown version {args.download!r}. Run --list to see what is available.",
                file=sys.stderr,
            )
            return 2
        code = release.code_for(args.abi)
        if code is None:
            print(
                f"Version {release.name} is not available for {catalog.ABI_LABELS[args.abi]}.",
                file=sys.stderr,
            )
            return 2
        out_dir = Path(args.out) if args.out else default_output_dir()
        for path in fetch(code, out_dir, log=print, abi=args.abi):
            print(f"  {path.name}")
        return 0

    return run_window()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (signin.SignInError, backend.WslError, catalog.CatalogError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    except BrokenPipeError:
        # `--list | head` is an ordinary thing to type, and it closes the pipe
        # under us. Point stdout at nowhere before exiting, or the interpreter
        # tries to flush it on the way out and reports the same failure again.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
