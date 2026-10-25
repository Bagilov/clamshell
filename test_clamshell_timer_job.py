"""Tests for the auto-restore timer lifecycle and restart reconciliation.

These cover the job that actually restores sleep: cancelling it, scheduling it,
and repairing the state left behind when a machine restarts mid-session.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_core as core

DEADLINE = 1234
FLOOR = 25
#: Values used by the reconcile tests, where the watcher job is re-armed.
REARM_SECONDS = 600
REARM_FLOOR = 30


def test_cancel_timer_removes_job_and_clears_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state = tmp_path / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", state)
    core.write_state(DEADLINE)
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    core.cancel_timer()
    assert ["launchctl", "remove", core.TIMER_LABEL] in calls
    assert not state.exists()


def test_cancel_timer_also_removes_legacy_labels(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An upgraded install must not leave an old job that fires early."""
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    core.cancel_timer()
    for label in core.LEGACY_TIMER_LABELS:
        assert ["launchctl", "remove", label] in calls


def test_schedule_auto_off_submits_job_and_stores_deadline(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state = tmp_path / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", state)
    monkeypatch.setattr(core, "TIMER_SCRIPT", tmp_path / "clamshell-timer")
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    deadline = core.schedule_auto_off(60)
    submitted = next(c for c in calls if c[:2] == ["launchctl", "submit"])
    assert submitted[:5] == ["launchctl", "submit", "-l", core.TIMER_LABEL, "--"]
    assert str(deadline) in submitted[-1]
    assert " 0 " in submitted[-1]
    assert core.read_state().deadline == deadline


def test_schedule_auto_off_passes_battery_floor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "TIMER_SCRIPT", tmp_path / "clamshell-timer")
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    core.schedule_auto_off(120, FLOOR)
    assert (
        f" {FLOOR} " in next(c for c in calls if c[:2] == ["launchctl", "submit"])[-1]
    )
    stored = core.read_state()
    assert stored.floor == FLOOR
    assert stored.deadline is not None


def test_schedule_auto_off_supports_floor_only(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state = tmp_path / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", state)
    monkeypatch.setattr(core, "TIMER_SCRIPT", tmp_path / "clamshell-timer")
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    result = core.schedule_auto_off(None, FLOOR)
    assert result is None
    assert (
        str(core.FAR_FUTURE)
        in next(c for c in calls if c[:2] == ["launchctl", "submit"])[-1]
    )
    stored = core.read_state()
    assert stored.deadline is None
    assert stored.floor == FLOOR


def test_schedule_auto_off_supports_an_indefinite_session(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An indefinite session still runs the watcher.

    The watcher is what keeps the built-in panel dark for a shut lid, so a
    session with no deadline and no floor must not skip it.
    """
    state = tmp_path / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", state)
    monkeypatch.setattr(core, "TIMER_SCRIPT", tmp_path / "clamshell-timer")
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    assert core.schedule_auto_off(None, 0) is None
    submitted = next(c for c in calls if c[:2] == ["launchctl", "submit"])
    assert str(core.FAR_FUTURE) in submitted[-1]
    stored = core.read_state()
    assert stored.deadline is None
    assert stored.floor == 0
    assert stored.watching is True


def test_reconcile_rearms_an_indefinite_session_after_a_restart(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A vanished watcher for an unlimited session must be re-armed.

    Otherwise the built-in panel stops being blanked for a shut lid with no
    visible reason.
    """
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "timer_job_running", lambda: False)
    scheduled: list[tuple[int | None, int]] = []
    monkeypatch.setattr(
        core, "schedule_auto_off", lambda s, f=0: scheduled.append((s, f))
    )
    core.write_state(None, 0, watching=True)
    assert core.reconcile_state() == "rearmed"
    assert scheduled == [(None, 0)]


def test_reconcile_ignores_a_state_file_with_no_watcher(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A legacy file with neither trigger nor flag is not a live session."""
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "timer_job_running", lambda: False)
    scheduled: list[tuple[int | None, int]] = []
    monkeypatch.setattr(
        core, "schedule_auto_off", lambda s, f=0: scheduled.append((s, f))
    )
    core.write_state(None)
    assert core.reconcile_state() == "clean"
    assert scheduled == []
