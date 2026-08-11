"""Google sign-in: obtains the long-lived account token gplaydl needs.

The account holder signs in on Google's own page inside an embedded browser.
This never reads, stores, or transmits a password — only the token Google issues
afterwards, kept in the user's own profile directory.

Deliberately free of any Play-protocol dependency: the download is gplaydl's job.
"""
from __future__ import annotations

import json
import os
import secrets
import time
from dataclasses import dataclass
from pathlib import Path

import gpsoauth

EMBEDDED_SETUP_URL = "https://accounts.google.com/EmbeddedSetup"


class SignInError(RuntimeError):
    """A failure the user can act on."""


@dataclass(frozen=True)
class Credentials:
    email: str
    master_token: str


def credentials_path() -> Path:
    root = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return Path(root) / "mcbedrock-get" / "account.json"


def load() -> Credentials | None:
    path = credentials_path()
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return Credentials(email=data["email"], master_token=data["master_token"])
    except (OSError, ValueError, KeyError):
        return None


def save(creds: Credentials) -> None:
    path = credentials_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"email": creds.email, "master_token": creds.master_token}, indent=2),
            encoding="utf-8",
        )
    except OSError as error:
        raise SignInError(f"Could not save the account session: {error}") from error


def forget() -> None:
    path = credentials_path()
    try:
        if path.is_file():
            path.unlink()
    except OSError as error:
        raise SignInError(f"Could not remove the Windows account session: {error}") from error


def harvest_oauth_token(timeout_seconds: int = 600) -> str:
    """Show Google's sign-in page and return the cookie it sets on success."""
    import webview

    captured: dict[str, str] = {}

    def watch(window) -> None:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            time.sleep(1.0)
            try:
                jar = window.get_cookies()
            except Exception:  # still navigating, or already closed
                continue
            for cookie in jar or []:
                for key in cookie.keys():
                    if key == "oauth_token":
                        captured["token"] = cookie[key].value
                        window.destroy()
                        return
        window.destroy()

    window = webview.create_window(
        "Sign in to Google — Minecraft Bedrock APK downloader",
        EMBEDDED_SETUP_URL,
        width=560,
        height=740,
    )
    webview.start(watch, window)

    token = captured.get("token")
    if not token:
        raise SignInError(
            "Sign-in did not complete. Close the window only after Google says "
            "you are signed in."
        )
    return token


def exchange_for_master_token(email: str, oauth_token: str) -> Credentials:
    """Trade the one-shot sign-in cookie for a long-lived account token."""
    response = gpsoauth.exchange_token(email, oauth_token, secrets.token_hex(8))
    master = response.get("Token")
    if not master:
        raise SignInError(
            "Google did not return an account token: "
            + (response.get("Error") or "no reason given")
        )
    return Credentials(email=email, master_token=master)


def run_login(email: str) -> Credentials:
    creds = exchange_for_master_token(email, harvest_oauth_token())
    save(creds)
    return creds
