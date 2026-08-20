"""Google sign-in: obtains the long-lived account token gplaydl needs.

The account holder signs in on Google's own page inside an embedded browser.
This never reads, stores, or transmits a password — only the token Google issues
afterwards, kept in the user's own profile directory.

Deliberately free of any Play-protocol dependency: the download is gplaydl's job.
"""
from __future__ import annotations

import json
import os
import re
import secrets
import time
from dataclasses import dataclass
from pathlib import Path

import gpsoauth

import paths

EMBEDDED_SETUP_URL = "https://accounts.google.com/EmbeddedSetup"

# Reading back which account signed in, so the address does not have to be
# typed as well as entered on Google's own page.
#
# This is asked FROM INSIDE the signed-in page, never by navigating the window
# to it. An earlier version did navigate, and when the request came back 400 the
# user was left staring at Google's error page inside the sign-in window, with
# the sign-in already spent. In-page it is invisible: it either answers or it
# does not, and the window keeps showing what the user expects.
LIST_ACCOUNTS_PATHS = (
    "/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard",
    "/ListAccounts?json=standard",
)

# Started once, then polled: pywebview hands back the value of the expression,
# and a promise is not a value, so the result is parked on window instead.
READ_ACCOUNT_JS = """
(function () {
  if (!window.__mcbStarted) {
    window.__mcbStarted = true;
    window.__mcbResult = "";
    var paths = %s;
    var attempt = function (index) {
      if (index >= paths.length) { window.__mcbResult = "none"; return; }
      fetch(paths[index], { credentials: "include" })
        .then(function (response) { return response.ok ? response.text() : ""; })
        .then(function (body) {
          var found = body && body.match(/"([^"\s@]+@[^"\s]+)"/);
          if (found) { window.__mcbResult = "ok:" + found[1]; } else { attempt(index + 1); }
        })
        .catch(function () { attempt(index + 1); });
    };
    attempt(0);
  }
  return window.__mcbResult;
})()
""" % json.dumps(list(LIST_ACCOUNTS_PATHS))


class SignInError(RuntimeError):
    """A failure the user can act on."""


@dataclass(frozen=True)
class Credentials:
    email: str
    master_token: str


def credentials_path() -> Path:
    return paths.data_dir() / "account.json"


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


def email_from_text(text: str) -> str:
    """Pull an address out of a ListAccounts response, or out of page text.

    The response is a JSON array of account records, in which the address is
    the only quoted field that can hold an @.
    """
    match = re.search(r'"([^"\s@]+@[^"\s]+)"', text or "")
    if match:
        return match.group(1)
    match = re.search(r"[\w.+-]+@[\w-]+\.[\w.-]+", text or "")
    return match.group(0) if match else ""


def read_account_email(window, timeout_seconds: int = 12) -> str:
    """Ask Google which account just signed in, without leaving the page.

    Best effort by design, and silent when it fails: the caller asks the user
    instead, with the sign-in already in hand.
    """
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            result = window.evaluate_js(READ_ACCOUNT_JS)
        except Exception:  # page still settling, or scripting refused
            result = None
        if isinstance(result, str) and result.startswith("ok:"):
            return result[3:]
        if result == "none":
            break
        time.sleep(0.5)

    # Last resort: whatever the finished sign-in page is showing.
    try:
        return email_from_text(window.evaluate_js("document.body ? document.body.innerText : ''"))
    except Exception:
        return ""


def harvest_session(timeout_seconds: int = 600) -> tuple[str, str]:
    """Show Google's sign-in page; return (email, the cookie it sets on success).

    The email comes back empty when it could not be read, and the caller then
    has to supply one.
    """
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
                        captured["email"] = read_account_email(window)
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
    return captured.get("email", ""), token


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


def complete_login(email: str, oauth_token: str) -> Credentials:
    """Turn a finished sign-in into the saved account session."""
    creds = exchange_for_master_token(email, oauth_token)
    save(creds)
    return creds


def run_login(email: str = "") -> Credentials:
    """Sign in, working out the account address unless one was supplied."""
    detected, token = harvest_session()
    address = email.strip() or detected
    if not address:
        raise SignInError(
            "Signed in, but Google did not say which account it was. Run "
            "mcbedrock-get --login you@example.com to name it."
        )
    return complete_login(address, token)
