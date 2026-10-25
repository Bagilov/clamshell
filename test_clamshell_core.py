"""Tests for clamshell duration parsing, formatting and state handling.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import plistlib
import subprocess
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_core as core

DEADLINE = 1234
SEMVER_PARTS = 3
FLOOR = 25
#: Values used by the reconcile tests, where the watch job is re-armed.
REARM_SECONDS = 600
REARM_FLOOR = 30


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


def test_write_state_records_an_indefinite_session(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An unlimited session has no deadline or floor but still needs a watcher.

    The flag cannot be inferred from the other two fields, so without it
    ``reconcile`` would treat a live session as nothing to do.
    """
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    core.write_state(None, 0, watching=True)
    state = core.read_state()
    assert state.deadline is None
    assert state.floor == 0
    assert state.watching is True


def test_read_state_defaults_watching_to_false(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A state file written before the flag existed must still be readable."""
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    core.write_state(DEADLINE)
    assert core.read_state().watching is False


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


@pytest.mark.parametrize("payload", [[1, 2, 3], "a string", 42])
def test_read_state_tolerates_non_dict_plist(
    payload: object, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A valid plist that is not a dict must not crash the CLI.

    ``clamshell status`` reads this file, so an unexpected shape would
    otherwise take down the whole command instead of degrading gracefully.
    """
    state = tmp_path / "state.plist"
    with state.open("wb") as handle:
        plistlib.dump(payload, handle)
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


def test_run_falls_back_to_stdout_for_error_detail(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """When stderr is empty the failure detail must come from stdout."""

    class Completed:
        returncode = 1
        stdout = "from stdout"
        stderr = ""

    monkeypatch.setattr(core.subprocess, "run", lambda *a, **k: Completed())
    with pytest.raises(core.ClamshellError, match="from stdout"):
        core.run(["false"])


def test_run_uses_unknown_error_when_both_streams_empty(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Completed:
        returncode = 1
        stdout = ""
        stderr = ""

    monkeypatch.setattr(core.subprocess, "run", lambda *a, **k: Completed())
    with pytest.raises(core.ClamshellError, match="unknown error"):
        core.run(["false"])


def test_run_does_not_raise_when_check_is_false(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Completed:
        returncode = 1
        stdout = ""
        stderr = "boom"

    monkeypatch.setattr(core.subprocess, "run", lambda *a, **k: Completed())
    result = core.run(["false"], check=False)
    assert result.returncode == 1


def test_require_macos_rejects_other_platforms(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(core.sys, "platform", "linux")
    with pytest.raises(core.ClamshellError, match="macOS"):
        core.require_macos()


def test_require_macos_rejects_missing_pmset(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core.sys, "platform", "darwin")
    monkeypatch.setattr(core, "PMSET", tmp_path / "absent-pmset")
    with pytest.raises(core.ClamshellError, match="pmset"):
        core.require_macos()


def test_helper_toggle_maps_to_helper_actions(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    core.helper_toggle(True)
    core.helper_toggle(False)
    assert calls == [
        ["sudo", "-n", str(core.HELPER_PATH), "on"],
        ["sudo", "-n", str(core.HELPER_PATH), "off"],
    ]


def test_sleep_display_calls_displaysleepnow(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    core.sleep_display()
    assert calls == [[str(core.PMSET), "displaysleepnow"]]


def test_sleep_display_needs_no_privileges(monkeypatch: pytest.MonkeyPatch) -> None:
    """Displaysleepnow runs as the user, so no sudo must appear in the call."""
    calls: list[list[str]] = []
    monkeypatch.setattr(core, "run", lambda argv, **k: calls.append(list(argv)))
    core.sleep_display()
    assert "sudo" not in calls[0]


def test_timer_script_sits_beside_the_running_code() -> None:
    """The watcher resolves next to the running module.

    That makes the repo, a user install and a packaged install all work without
    rewiring the path, and a mismatch would silently break every restore.
    """
    assert core.TIMER_SCRIPT == core.MODULE_DIR / core.TIMER_NAME
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


def test_parse_span_rejects_a_duration_over_the_limit() -> None:
    """An accidental extra digit must not schedule a session years out."""
    with pytest.raises(core.ClamshellError):
        core.parse_span("31d")
    assert core.parse_span("30d") == core.MAX_DURATION_SECONDS


def test_reconcile_state_does_nothing_without_a_trigger(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "timer_job_running", lambda: False)
    assert core.reconcile_state() == "clean"


def test_reconcile_state_leaves_a_running_watcher_alone(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "timer_job_running", lambda: True)
    core.write_state(int(time.time()) + 600)
    assert core.reconcile_state() == "running"


def test_reconcile_state_rearms_a_future_trigger_after_a_reboot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A reboot kills the transient watcher but leaves the state file behind."""
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "timer_job_running", lambda: False)
    scheduled: list[tuple[int | None, int]] = []
    monkeypatch.setattr(
        core, "schedule_auto_off", lambda s, f=0: scheduled.append((s, f))
    )
    core.write_state(int(time.time()) + REARM_SECONDS, REARM_FLOOR)
    assert core.reconcile_state() == "rearmed"
    assert scheduled and scheduled[0][1] == REARM_FLOOR
    assert 0 < scheduled[0][0] <= REARM_SECONDS


def test_reconcile_state_restores_sleep_when_the_deadline_passed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A missed restore must not leave sleep disabled forever."""
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "timer_job_running", lambda: False)
    monkeypatch.setattr(core, "sleep_disabled", lambda: True)
    toggled: list[bool] = []
    monkeypatch.setattr(core, "helper_toggle", toggled.append)
    core.write_state(int(time.time()) - 60)
    assert core.reconcile_state() == "restored"
    assert toggled == [False]


def test_reconcile_state_keeps_the_state_when_restoring_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "timer_job_running", lambda: False)
    monkeypatch.setattr(core, "sleep_disabled", lambda: True)

    def refuse(_enabled: bool) -> None:
        raise core.ClamshellError("sudo refused")

    monkeypatch.setattr(core, "helper_toggle", refuse)
    core.write_state(int(time.time()) - 60)
    with pytest.raises(core.ClamshellError):
        core.reconcile_state()
    assert core.read_state().deadline is not None
