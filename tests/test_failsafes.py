#!/usr/bin/env python3
"""Every failsafe must carry the evidence needed to delete it.

A fallback with no exit criterion is just a permanent regression that nobody
remembers choosing. This reads the knobs straight out of lib/failsafe.sh rather
than from a hand-maintained list, so adding a rung without registering it
fails here.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LADDER = ROOT / "portmaster/minecraftbedrock/minecraftbedrock/lib/failsafe.sh"
STATE = ROOT / "portmaster/minecraftbedrock/minecraftbedrock/failsafe_state.py"
REGISTER = ROOT / "docs/FAILSAFES.md"

# Set by the ladder as plumbing rather than as a fallback: these describe or
# carry the decision, they are not something a device is being denied.
PLUMBING = {
    "MCPE_FAILSAFE_RUNG", "MCPE_FAILSAFE_RUNG_NAME", "MCPE_FAILSAFE_FLOOR",
    "MCPE_FAILSAFE_STREAK", "MCPE_FAILSAFE_REASON", "MCPE_FAILSAFE_PINNED",
    "MCPE_FAILSAFE_KEY", "MCPE_FAILSAFE_STARTUP_SECONDS",
    "MCPE_FAILSAFE_OUTCOME", "MCPE_FAILSAFE_NEXT_RUNG",
}


def ladder_text() -> str:
    return LADDER.read_text(encoding="utf-8")


def applied_knobs() -> set[str]:
    """Environment variables the rungs actually change."""
    text = ladder_text()
    body = text[text.index("mcpe_failsafe_apply_conservative"):text.index("mcpe_failsafe_apply()")]
    knobs = set(re.findall(r"^\s*export\s+([A-Z0-9_]+)=", body, re.M))
    for line in re.findall(r"^\s*unset\s+(.+)$", body, re.M):
        knobs.update(re.findall(r"[A-Z0-9_]+", line))
    return {k for k in knobs if k not in PLUMBING}


def section(title: str) -> str:
    """The body of one `## ` section, so the register and status tables -- whose
    rows both start with `| FS-` -- are never confused for one another."""
    text = REGISTER.read_text(encoding="utf-8")
    body = text.split(f"## {title}", 1)[1]
    return body.split("\n## ", 1)[0]


def register_rows() -> dict[str, str]:
    rows = {}
    for line in section("The register").splitlines():
        if not line.startswith("| FS-"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        assert len(cells) >= 4, f"malformed register row: {line}"
        rows[cells[0]] = line
    return rows


def test_every_knob_a_rung_changes_is_registered():
    rows = register_rows()
    register = REGISTER.read_text(encoding="utf-8")
    missing = [k for k in applied_knobs() if k not in register]
    assert not missing, (
        f"these are changed by a failsafe rung but have no row in "
        f"docs/FAILSAFES.md: {sorted(missing)}")
    assert rows, "the register has no rows at all"


def test_every_row_says_why_it_exists_and_how_it_ends():
    for fs_id, line in register_rows().items():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        _, failsafe, why, delete_when = cells[0], cells[1], cells[2], cells[3]
        assert failsafe, f"{fs_id}: no description of what it does"
        assert len(why) > 40, f"{fs_id}: no real justification ({why!r})"
        assert len(delete_when) > 40, f"{fs_id}: no real exit criterion"
        # An exit criterion has to name something checkable, not just intent.
        assert not delete_when.lower().startswith("tbd"), f"{fs_id}: exit criterion is a placeholder"


def test_registered_ids_are_unique_and_contiguous():
    ids = list(register_rows())
    assert len(ids) == len(set(ids)), f"duplicate failsafe id: {ids}"
    numbers = sorted(int(i.split("-")[1]) for i in ids)
    assert numbers == list(range(1, len(numbers) + 1)), (
        f"failsafe ids should run FS-1..FS-{len(numbers)}, got {numbers}")


def test_the_register_describes_the_rungs_that_exist():
    """The prose table and the shell must not drift apart."""
    register = REGISTER.read_text(encoding="utf-8")
    ladder = ladder_text()
    for rung in ("tuned", "conservative", "minimal", "diagnostic"):
        assert rung in register, f"rung {rung} is not described in the register"
        assert rung in ladder, f"rung {rung} is not implemented"
    # The state machine's ceiling and the register must agree.
    assert "MAX_RUNG = 3" in STATE.read_text(encoding="utf-8")
    assert "| 3 | diagnostic" in register


def test_every_row_has_a_status():
    """A register nobody revisits is a register that lies.

    Each row carries where its evidence currently stands, so it is visible
    which failsafes are close to removal and which have not moved.
    """
    assert "## Status" in REGISTER.read_text(encoding="utf-8"), "no status section"
    status_rows = {}
    for line in section("Status").splitlines():
        if not line.startswith("| FS-"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        assert len(cells) >= 3, f"malformed status row: {line}"
        status_rows[cells[0]] = cells
    # Look for a row, not merely the id somewhere in the section: the prose
    # under the table names several ids, so a substring check would pass even
    # with the row deleted.
    for fs_id in register_rows():
        assert fs_id in status_rows, f"{fs_id} has no status row"
        # Each status must say what is still missing, not just a mood.
        assert len(status_rows[fs_id][2]) > 30, \
            f"{fs_id}: status does not say what is still missing"


def test_nothing_claims_to_be_discharged_while_still_applied():
    """A rung still changing a knob cannot be described as removed."""
    for line in section("Status").splitlines():
        if not line.startswith("| FS-"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        fs_id, status = cells[0], cells[1].lower()
        if status.startswith("removed"):
            assert fs_id not in register_rows(), (
                f"{fs_id} is marked removed but still has a register row")


if __name__ == "__main__":
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            function()
    print("failsafe register tests passed")
