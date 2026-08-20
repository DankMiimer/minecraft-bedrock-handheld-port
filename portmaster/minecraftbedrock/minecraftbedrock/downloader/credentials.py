#!/usr/bin/env python3
"""Bridge the launcher's approved credential response into gplaydl config."""
from __future__ import annotations

import base64
import json
import os
import re
import sys
from pathlib import Path


def has_qt_account(path: Path) -> bool:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    match = re.search(r"(?ms)^\[googlelogin\]\s*$\n(.*?)(?=^\[|\Z)", text)
    return bool(match and re.search(r"(?m)^token=.+$", match.group(1)))


def approved_account(path: Path) -> tuple[str, str]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for line in reversed(lines):
        if line.startswith("CREDB64="):
            raw = base64.b64decode(line[8:].strip(), validate=True)
            data = json.loads(raw.decode("utf-8"))
            return str(data.get("accountIdentifier", "")), str(data.get("accountToken", ""))
    for line in reversed(lines):
        if line.startswith("CRED="):
            return tuple(line[5:].split(":", 1))  # type: ignore[return-value]
    raise ValueError("the approval window returned no Google credential")


def quote_config(value: str, label: str) -> str:
    if not value or "\n" in value or "\r" in value or len(value) > 8192:
        raise ValueError(f"invalid Google {label}")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_playdl(capture: Path, destination: Path) -> None:
    email, token = approved_account(capture)
    content = (
        f"user_email = {quote_config(email, 'email')}\n"
        f"user_token = {quote_config(token, 'token')}\n"
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
        output.write(content)
    os.replace(temporary, destination)
    os.chmod(destination, 0o600)


def write_signin(capture: Path, destination: Path) -> None:
    data = json.loads(capture.read_text(encoding="utf-8"))
    email = str(data.get("accountIdentifier", ""))
    token = str(data.get("accountToken", ""))
    content = (
        f"user_email = {quote_config(email, 'email')}\n"
        f"user_token = {quote_config(token, 'token')}\n"
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
        output.write(content)
    os.replace(temporary, destination)
    os.chmod(destination, 0o600)


def write_access_input(capture: Path, destination: Path) -> None:
    """Create private stdin for gplayver's upstream access-token exchange."""
    data = json.loads(capture.read_text(encoding="utf-8"))
    token = str(data.get("accountToken", ""))
    if not token or "\n" in token or "\r" in token or len(token) > 8192:
        raise ValueError("invalid Google access token")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
        # Method 2 exchanges Google's one-shot oauth_token for the long-lived
        # master token. Y approves saving that exchanged token, not a password.
        output.write(f"2\n{token}\nY\n")
    os.replace(temporary, destination)
    os.chmod(destination, 0o600)


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "has-account":
        return 0 if has_qt_account(Path(sys.argv[2])) else 1
    if len(sys.argv) == 4 and sys.argv[1] == "write-playdl":
        try:
            write_playdl(Path(sys.argv[2]), Path(sys.argv[3]))
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
            print(f"credential approval failed: {error}", file=sys.stderr)
            return 1
        return 0
    if len(sys.argv) == 4 and sys.argv[1] == "write-signin":
        try:
            write_signin(Path(sys.argv[2]), Path(sys.argv[3]))
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
            print(f"credential import failed: {error}", file=sys.stderr)
            return 1
        return 0
    if len(sys.argv) == 4 and sys.argv[1] == "write-access-input":
        try:
            write_access_input(Path(sys.argv[2]), Path(sys.argv[3]))
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
            print(f"credential exchange setup failed: {error}", file=sys.stderr)
            return 1
        return 0
    print(
        "usage: credentials.py has-account QT_CONFIG | "
        "write-playdl CAPTURE OUTPUT | write-signin JSON OUTPUT | "
        "write-access-input JSON OUTPUT",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
