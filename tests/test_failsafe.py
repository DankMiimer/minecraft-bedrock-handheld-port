#!/usr/bin/env python3
"""Behaviour of the failsafe ladder's launch-attempt state machine."""
from __future__ import annotations

import io
import json
import shlex
import sys
import tempfile
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / "portmaster/minecraftbedrock/minecraftbedrock"
sys.path.insert(0, str(PAYLOAD))

import failsafe_state  # noqa: E402

KEY = "2.0.0|knulli|1.16.221.01|auto"


def call(command, gamedir, key, *args) -> dict:
    """Run a subcommand and parse the shell assignments it emits."""
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        getattr(failsafe_state, command)(gamedir, key, *args)
    values = {}
    for line in buffer.getvalue().splitlines():
        name, _, raw = line.partition("=")
        values[name] = shlex.split(raw)[0] if raw else ""
    return values


def plan(gamedir, previous_stage="", pinned="", startup=120, key=KEY) -> dict:
    return call("plan", gamedir, key, previous_stage, pinned, startup)


def record(gamedir, rung, exit_status, duration, startup=120) -> dict:
    return call("record", gamedir, KEY, rung, exit_status, duration, startup)


def entry(gamedir) -> dict:
    return failsafe_state.load_state(gamedir)["entries"][KEY]


def fresh():
    return Path(tempfile.mkdtemp(prefix="mcpe-failsafe-"))


def test_a_clean_device_stays_on_the_tuned_profile():
    game = fresh()
    assert plan(game)["MCPE_FAILSAFE_RUNG"] == "0"
    assert record(game, 0, 0, 900)["MCPE_FAILSAFE_OUTCOME"] == "success"
    assert plan(game)["MCPE_FAILSAFE_RUNG"] == "0"
    # Success at the floor must not try to climb below it.
    assert record(game, 0, 0, 900)["MCPE_FAILSAFE_NEXT_RUNG"] == "0"
    assert plan(game)["MCPE_FAILSAFE_RUNG"] == "0"


def test_an_observed_startup_failure_escalates_and_sets_a_floor():
    game = fresh()
    plan(game)
    result = record(game, 0, 1, 4)
    assert result["MCPE_FAILSAFE_OUTCOME"] == "startup_failure"
    assert result["MCPE_FAILSAFE_NEXT_RUNG"] == "1"
    assert entry(game)["floor"] == 1
    assert plan(game)["MCPE_FAILSAFE_RUNG"] == "1"


def test_a_device_that_only_works_in_safe_mode_does_not_oscillate():
    """The bug this floor exists to prevent: good launch, bad launch, forever."""
    game = fresh()
    plan(game)
    record(game, 0, 1, 4)              # rung 0 is known bad -> floor 1
    for _ in range(6):
        assert plan(game)["MCPE_FAILSAFE_RUNG"] == "1"
        record(game, 1, 0, 900)        # works at rung 1, every time
    assert entry(game)["rung"] == 1
    assert entry(game)["floor"] == 1


def test_a_late_crash_does_not_cost_a_rung():
    """An hour of play then a crash on exit is not a startup problem."""
    game = fresh()
    plan(game)
    result = record(game, 0, 139, 3600)
    assert result["MCPE_FAILSAFE_OUTCOME"] == "late_failure"
    assert result["MCPE_FAILSAFE_NEXT_RUNG"] == "0"
    assert entry(game)["floor"] == 0


def test_a_hang_is_inferred_from_the_breadcrumb_but_is_not_made_permanent():
    """A run that never returns escalates, yet must not pin the device.

    The breadcrumb cannot tell a freeze apart from a player pulling the power
    after a long session, so this weaker signal is allowed to spend a rung but
    not to raise the floor.
    """
    game = fresh()
    plan(game)                                     # leaves a pending attempt
    result = plan(game, previous_stage="client-exec")
    assert result["MCPE_FAILSAFE_RUNG"] == "1"
    assert "client-exec" in result["MCPE_FAILSAFE_REASON"]
    assert entry(game)["floor"] == 0                # <- not permanent
    # Because the floor stayed put, two good launches climb back to tuned.
    record(game, 1, 0, 900)
    plan(game)
    assert record(game, 1, 0, 900)["MCPE_FAILSAFE_NEXT_RUNG"] == "0"


def test_an_interrupted_session_does_not_cost_a_rung():
    """Reaching the first frame means startup worked.

    A run that stops there without reporting was interrupted during play, not
    during startup. Observed on the reference RGDS, where an interrupted
    session was logged as an inferred startup failure and escalated the ladder
    on a device that demonstrably works.
    """
    game = fresh()
    plan(game)
    result = plan(game, previous_stage="first-frame")
    assert result["MCPE_FAILSAFE_RUNG"] == "0", "a played session escalated the ladder"
    assert entry(game)["last_outcome"] == "interrupted_after_start"
    assert entry(game)["floor"] == 0

    # A hang before the first frame still escalates.
    game = fresh()
    plan(game)
    assert plan(game, previous_stage="window")["MCPE_FAILSAFE_RUNG"] == "1"


def test_quitting_before_the_game_starts_costs_nothing():
    game = fresh()
    plan(game)
    result = plan(game, previous_stage="menu")
    assert result["MCPE_FAILSAFE_RUNG"] == "0"
    assert entry(game)["last_outcome"] == "abandoned"


def test_the_ladder_stops_at_the_diagnostic_rung():
    game = fresh()
    for expected in ("1", "2", "3", "3"):
        current = int(plan(game)["MCPE_FAILSAFE_RUNG"])
        assert record(game, current, 1, 2)["MCPE_FAILSAFE_NEXT_RUNG"] == expected


def test_safe_mode_pins_the_rung_in_both_directions():
    game = fresh()
    plan(game)
    record(game, 0, 1, 2)
    record(game, 1, 1, 2)
    assert entry(game)["rung"] == 2
    forced = plan(game, pinned="0")
    assert forced["MCPE_FAILSAFE_RUNG"] == "0"
    assert forced["MCPE_FAILSAFE_PINNED"] == "1"
    assert "MCPE_SAFE_MODE=0" in forced["MCPE_FAILSAFE_REASON"]
    # Pinning does not rewrite the history the ladder has learned.
    assert entry(game)["rung"] == 2
    assert plan(game, pinned="9")["MCPE_FAILSAFE_RUNG"] == "3"


def test_state_that_cannot_be_trusted_is_rebuilt_rather_than_obeyed():
    game = fresh()
    (game / "config").mkdir(parents=True)
    for junk in ("{not json", '{"schema": 99}', '{"schema": 1, "entries": []}'):
        (game / "config/launch_state.json").write_text(junk, encoding="utf-8")
        assert plan(game)["MCPE_FAILSAFE_RUNG"] == "0"
    # An out-of-range rung must not select a nonexistent profile.
    (game / "config/launch_state.json").write_text(
        json.dumps({"schema": 1, "entries": {KEY: {"rung": 47, "floor": -3}}}),
        encoding="utf-8")
    assert plan(game)["MCPE_FAILSAFE_RUNG"] == "0"


def test_every_transition_is_written_down():
    game = fresh()
    plan(game)
    record(game, 0, 1, 3)
    plan(game)
    record(game, 1, 0, 900)
    rows = (game / "logs/failsafe-ledger.tsv").read_text(encoding="utf-8").splitlines()
    assert rows[0].startswith("timestamp\tkey\tevent")
    assert len(rows) == 3                      # header + two records
    assert "startup_failure" in rows[1]
    assert "success" in rows[2]
    assert all(row.count("\t") == 7 for row in rows)


def test_the_ladder_is_per_port_build_so_an_update_gets_a_fresh_chance():
    game = fresh()
    plan(game)
    record(game, 0, 1, 3)
    assert entry(game)["floor"] == 1
    assert plan(game, key="2.0.1|knulli|1.16.221.01|auto")["MCPE_FAILSAFE_RUNG"] == "0"
    # ...and the original build's hard-won floor is still there afterwards.
    assert entry(game)["floor"] == 1


if __name__ == "__main__":
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            function()
    print("failsafe ladder tests passed")
