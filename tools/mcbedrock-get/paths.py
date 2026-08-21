"""Where this program keeps its files, per platform convention.

Windows puts per-user application data under %LOCALAPPDATA%. Linux puts it
under $XDG_DATA_HOME, defaulting to ~/.local/share -- not in a bare directory
in the home folder, which is what a Windows-shaped path lands as when it is
carried across unchanged.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

APP = "mcbedrock-get"


def data_dir() -> Path:
    """The per-user data directory, created by whoever writes into it."""
    override = os.environ.get("MCBEDROCK_DATA_DIR", "").strip()
    if override:
        return Path(override)
    if sys.platform == "win32":
        root = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        return Path(root) / APP
    data = os.environ.get("XDG_DATA_HOME", "").strip()
    root = Path(data) if data else Path.home() / ".local" / "share"
    return root / APP
