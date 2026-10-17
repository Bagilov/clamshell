"""Tests for clamshell duration parsing, formatting and state handling.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_core as core

DEADLINE = 1234
FLOOR = 25


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("1", 1),
        ("30s", 30),
        ("45m", 2700),
        ("2h", 7200),
        ("1d", 86400),
        ("1h30m", 5400),
        ("1d2h3m4s", 93784),
    ],
)
def test_parse_span_returns_seconds(value: str, expected: int) -> None:
    assert core.parse_span(value) == expected


@pytest.mark.parametrize("value", ["", "   ", "abc", "1x", "h", "1h30", "-5m"])
def test_parse_span_rejects_invalid(value: str) -> None:
    with pytest.raises(core.ClamshellError):
        core.parse_span(value)


def test_parse_span_rejects_zero() -> None:
    with pytest.raises(core.ClamshellError):
        core.parse_span("0")


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [
        (0, "0s"),
        (-10, "0s"),
        (45, "45s"),
        (60, "1m"),
        (3661, "1h 1m 1s"),
        (86400, "1d"),
    ],
)
def test_format_span_round_trips_units(seconds: int, expected: str) -> None:
    assert core.format_span(seconds) == expected


def test_format_span_is_inverse_for_minutes() -> None:
    assert core.format_span(core.parse_span("90m")) == "1h 30m"


def test_write_and_read_state_round_trip(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    core.write_state(DEADLINE)
    assert core.read_state() == core.TimerState(deadline=DEADLINE, floor=0)
    core.write_state(None)
    assert core.read_state() == core.TimerState(deadline=None, floor=0)


def test_write_state_stores_battery_floor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    core.write_state(DEADLINE, FLOOR)
    assert core.read_state() == core.TimerState(deadline=DEADLINE, floor=FLOOR)


def test_write_state_supports_floor_without_deadline(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    core.write_state(None, FLOOR)
    state = core.read_state()
    assert state.deadline is None
    assert state.floor == FLOOR
    assert state.is_active is True


def test_write_state_none_removes_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state = tmp_path / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", state)
    core.write_state(DEADLINE)
    assert state.exists()
    core.write_state(None)
    assert not state.exists()


def test_read_state_returns_none_for_missing_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "absent.plist")
    assert core.read_state() == core.TimerState(deadline=None, floor=0)


def test_read_state_tolerates_corrupt_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state = tmp_path / "state.plist"
    state.write_bytes(b"not a plist")
    monkeypatch.setattr(core, "STATE_PATH", state)
    assert core.read_state() == core.TimerState(deadline=None, floor=0)


def test_write_state_creates_parent_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    nested = tmp_path / "a" / "b" / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", nested)
    core.write_state(42)
    assert nested.exists()
    with nested.open("rb") as handle:
        assert plistlib.load(handle) == {"Deadline": 42}


def test_sleep_disabled_parses_flag(monkeypatch: pytest.MonkeyPatch) -> None:
    class Result:
        stdout = "System-wide power settings:\n SleepDisabled\t\t1\n"

    monkeypatch.setattr(core, "run", lambda *a, **k: Result())
    assert core.sleep_disabled() is True


def test_sleep_disabled_false_when_flag_absent(monkeypatch: pytest.MonkeyPatch) -> None:
    class Result:
        stdout = "System-wide power settings:\n sleep                 1\n"

    monkeypatch.setattr(core, "run", lambda *a, **k: Result())
    assert core.sleep_disabled() is False


def test_run_raises_on_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    def explode(*args: object, **kwargs: object) -> None:
        raise subprocess.TimeoutExpired(cmd="sleep", timeout=1)

    monkeypatch.setattr(core.subprocess, "run", explode)
    with pytest.raises(core.ClamshellError):
        core.run(["sleep", "999"], timeout=1)


def test_run_raises_on_nonzero_exit(monkeypatch: pytest.MonkeyPatch) -> None:
    class Completed:
        returncode = 1
        stdout = ""
        stderr = "boom"

    monkeypatch.setattr(core.subprocess, "run", lambda *a, **k: Completed())
    with pytest.raises(core.ClamshellError):
        core.run(["false"])


def test_helper_toggle_maps_to_helper_actions(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    core.helper_toggle(True)
    core.helper_toggle(False)
    assert calls == [
        ["sudo", "-n", str(core.HELPER_PATH), "on"],
        ["sudo", "-n", str(core.HELPER_PATH), "off"],
    ]


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


def test_schedule_auto_off_requires_a_trigger() -> None:
    with pytest.raises(core.ClamshellError):
        core.schedule_auto_off(None, 0)


def test_timer_script_path_matches_installed_name() -> None:
    """The watcher path must match what install_sources writes.

    A mismatch here silently breaks every scheduled restore, because the
    launchd job would exec a file that does not exist.
    """
    assert core.TIMER_SCRIPT == core.SUPPORT_DIR / core.TIMER_NAME
    assert core.TIMER_SCRIPT.name == core.TIMER_NAME


def test_schedule_auto_off_runs_the_installed_watcher(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "TIMER_SCRIPT", tmp_path / core.TIMER_NAME)
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    core.schedule_auto_off(60)
    assert (
        core.TIMER_NAME
        in next(c for c in calls if c[:2] == ["launchctl", "submit"])[-1]
    )


def test_schedule_auto_off_rejects_non_positive_seconds() -> None:
    with pytest.raises(core.ClamshellError):
        core.schedule_auto_off(0)
