#!/usr/bin/env python3
"""Launch-attempt state machine for the failsafe ladder.

The port ships deliberately conservative fallbacks so that an untested device
starts *something* rather than freezing, and each fallback carries the evidence
needed to delete it again (docs/FAILSAFES.md).

The ladder is per (port build, CFW, Bedrock version, ABI preference): a device
that cannot run the tuned profile drops one rung on its next launch, and climbs
back once the lower rung proves itself. Two rules keep that from thrashing:

* `floor` is raised only by a startup failure this port actually *observed* --
  the launcher returned a bad status quickly. A failure merely *inferred* from
  the breadcrumb of a run that never came back escalates for the next launch
  but does not become permanent, because that inference cannot yet tell a hang
  apart from a player pulling the power after an hour of play. The startup
  watchdog's first-frame marker replaces the inference; until then the weaker
  signal is not allowed to pin a device to a degraded profile.
* Climbing back down needs two consecutive good launches, so one lucky start
  does not undo a rung that is genuinely required.
"""
from __future__ import annotations

import json
import shlex
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = 1
MAX_RUNG = 3
RUNG_NAMES = {0: "tuned", 1: "conservative", 2: "minimal", 3: "diagnostic"}

# Breadcrumb stages that mean the client had been started. Anything earlier is
# a launch the player abandoned or a setup problem the ladder cannot fix, so it
# must not spend a rung.
LAUNCH_STAGES = {"abi", "runtime", "client-exec", "window"}

# Reaching the first frame means startup succeeded. A run that stops there
# without reporting was interrupted during play -- the player pulled the power,
# or something killed it -- and escalating the ladder for that would degrade a
# device that demonstrably works. Observed on the reference RGDS, where an
# interrupted session was logged as an inferred startup failure.
STARTED_STAGES = {"first-frame"}

LEDGER_HEADER = "timestamp\tkey\tevent\trung\toutcome\treason\tduration_s\texit\n"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def emit(key: str, value: object) -> None:
    print(f"{key}={shlex.quote(str(value))}")


def _state_path(gamedir: Path) -> Path:
    return gamedir / "config/launch_state.json"


def load_state(gamedir: Path) -> dict:
    path = _state_path(gamedir)
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"schema": SCHEMA, "entries": {}}
    if not isinstance(state, dict) or state.get("schema") != SCHEMA:
        return {"schema": SCHEMA, "entries": {}}
    if not isinstance(state.get("entries"), dict):
        state["entries"] = {}
    return state


def save_state(gamedir: Path, state: dict) -> None:
    """Replace the state file atomically.

    A half-written state file on a device that lost power would be read back as
    corrupt and silently reset the ladder, so the rename is what publishes it.
    """
    path = _state_path(gamedir)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(".json.new")
        temp.write_text(json.dumps(state, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        temp.replace(path)
    except OSError as exc:
        print(f"failsafe: could not persist launch state: {exc}", file=sys.stderr)


def entry_for(state: dict, key: str) -> dict:
    entry = state["entries"].get(key)
    if not isinstance(entry, dict):
        entry = {}
    entry.setdefault("rung", 0)
    entry.setdefault("floor", 0)
    entry.setdefault("streak", 0)
    entry.setdefault("last_outcome", "none")
    for field in ("rung", "floor", "streak"):
        value = entry[field]
        if not isinstance(value, int) or not 0 <= value <= MAX_RUNG:
            entry[field] = 0
    state["entries"][key] = entry
    return entry


def append_ledger(gamedir: Path, row: dict) -> None:
    path = gamedir / "logs/failsafe-ledger.tsv"
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        new = not path.exists() or path.stat().st_size == 0
        with path.open("a", encoding="utf-8") as handle:
            if new:
                handle.write(LEDGER_HEADER)
            handle.write(
                "{timestamp}\t{key}\t{event}\t{rung}\t{outcome}\t{reason}\t"
                "{duration_s}\t{exit}\n".format(**row)
            )
    except OSError as exc:
        print(f"failsafe: could not append to the ledger: {exc}", file=sys.stderr)


def classify_recorded(exit_status: int, duration: int, startup_seconds: int) -> str:
    if exit_status == 0:
        return "success"
    if duration >= startup_seconds:
        # It ran long enough to have been played. Whatever went wrong at the
        # end is not something a more conservative launch profile addresses.
        return "late_failure"
    return "startup_failure"


def plan(gamedir: Path, key: str, previous_stage: str, pinned: str,
         startup_seconds: int) -> int:
    state = load_state(gamedir)
    entry = entry_for(state, key)
    reason = "no change"

    pending = entry.pop("pending", None)
    if isinstance(pending, dict):
        # The previous launch never reported an outcome: it hung, was killed,
        # or the device lost power. The breadcrumb says how far it got.
        if previous_stage in LAUNCH_STAGES:
            entry["last_outcome"] = "inferred_startup_failure"
            entry["streak"] = 0
            if entry["rung"] < MAX_RUNG:
                entry["rung"] += 1
            reason = f"previous launch stopped at '{previous_stage}' without returning"
        elif previous_stage in STARTED_STAGES:
            entry["last_outcome"] = "interrupted_after_start"
            reason = (f"previous launch reached '{previous_stage}' and was interrupted "
                      "during play; startup was fine, so the rung is unchanged")
        else:
            entry["last_outcome"] = "abandoned"
            reason = f"previous launch ended at '{previous_stage}' before starting the game"
        append_ledger(gamedir, {
            "timestamp": _now(), "key": key, "event": "infer",
            "rung": pending.get("rung", entry["rung"]),
            "outcome": entry["last_outcome"], "reason": reason,
            "duration_s": "", "exit": "",
        })

    if pinned != "":
        try:
            rung = max(0, min(MAX_RUNG, int(pinned)))
        except ValueError:
            rung = entry["rung"]
        else:
            reason = f"pinned by MCPE_SAFE_MODE={rung}"
        emit("MCPE_FAILSAFE_PINNED", 1)
    else:
        rung = entry["rung"]
        emit("MCPE_FAILSAFE_PINNED", 0)

    entry["pending"] = {"rung": rung, "started": _now()}
    save_state(gamedir, state)

    emit("MCPE_FAILSAFE_KEY", key)
    emit("MCPE_FAILSAFE_RUNG", rung)
    emit("MCPE_FAILSAFE_RUNG_NAME", RUNG_NAMES[rung])
    emit("MCPE_FAILSAFE_FLOOR", entry["floor"])
    emit("MCPE_FAILSAFE_STREAK", entry["streak"])
    emit("MCPE_FAILSAFE_REASON", reason)
    emit("MCPE_FAILSAFE_STARTUP_SECONDS", startup_seconds)
    return 0


def record(gamedir: Path, key: str, rung: int, exit_status: int, duration: int,
           startup_seconds: int) -> int:
    state = load_state(gamedir)
    entry = entry_for(state, key)
    entry.pop("pending", None)

    outcome = classify_recorded(exit_status, duration, startup_seconds)
    entry["last_outcome"] = outcome
    reason = ""

    if outcome == "success":
        entry["streak"] += 1
        if entry["streak"] >= 2 and rung > entry["floor"]:
            entry["rung"] = rung - 1
            entry["streak"] = 0
            reason = f"two clean launches at rung {rung}; trying rung {rung - 1}"
        else:
            entry["rung"] = rung
            reason = f"clean launch at rung {rung}"
    elif outcome == "startup_failure":
        entry["streak"] = 0
        # Observed directly, so this rung is known bad on this device and the
        # ladder must not drift back below it on its own.
        entry["floor"] = max(entry["floor"], min(MAX_RUNG, rung + 1))
        entry["rung"] = min(MAX_RUNG, rung + 1)
        reason = f"exit {exit_status} after {duration}s, below the {startup_seconds}s startup window"
    else:
        entry["streak"] = 0
        entry["rung"] = rung
        reason = f"exit {exit_status} after {duration}s; treated as a late failure, rung unchanged"

    entry["updated"] = _now()
    save_state(gamedir, state)
    append_ledger(gamedir, {
        "timestamp": _now(), "key": key, "event": "record", "rung": rung,
        "outcome": outcome, "reason": reason,
        "duration_s": duration, "exit": exit_status,
    })
    emit("MCPE_FAILSAFE_OUTCOME", outcome)
    emit("MCPE_FAILSAFE_NEXT_RUNG", entry["rung"])
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print("usage: failsafe_state.py plan|record <gamedir> <key> ...", file=sys.stderr)
        return 2
    command, gamedir, key = argv[1], Path(argv[2]), argv[3]
    rest = argv[4:]

    def as_int(value: str, fallback: int) -> int:
        try:
            return int(value)
        except (TypeError, ValueError):
            return fallback

    if command == "plan":
        previous_stage = rest[0] if len(rest) > 0 else ""
        pinned = rest[1] if len(rest) > 1 else ""
        startup = as_int(rest[2] if len(rest) > 2 else "", 120)
        return plan(gamedir, key, previous_stage, pinned, startup)
    if command == "record":
        rung = as_int(rest[0] if len(rest) > 0 else "", 0)
        exit_status = as_int(rest[1] if len(rest) > 1 else "", 0)
        duration = as_int(rest[2] if len(rest) > 2 else "", 0)
        startup = as_int(rest[3] if len(rest) > 3 else "", 120)
        return record(gamedir, key, rung, exit_status, duration, startup)
    print(f"unknown failsafe command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
