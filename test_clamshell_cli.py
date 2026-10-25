"""Integration tests for the CLI entry point.

The privileged helper, sudo and the display call are stubbed, so these tests
exercise argument parsing and command dispatch without touching the system.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_cli as cli
import clamshell_core as core
from clamshell_battery import BatteryState

MISSING_COMMAND_EXIT = 2
FLOOR_PERCENT = 30
DEADLINE_SECONDS = 600


@pytest.fixture
def stubbed(monkeypatch: pytest.MonkeyPatch) -> dict[str, list[list[str]]]:
    """Replace system calls with recorders and return the recorded buckets."""
    calls: dict[str, list[list[str]]] = {"run": [], "toggled": [], "sleep": []}
    monkeypatch.setattr(core, "require_macos", lambda: None)
    monkeypatch.setattr(core, "run", lambda argv, **k: calls["run"].append(list(argv)))
    monkeypatch.setattr(
        cli, "helper_toggle", lambda enabled: calls["toggled"].append([str(enabled)])
    )
    monkeypatch.setattr(cli, "sleep_display", lambda: calls["sleep"].append(["sleep"]))
    return calls


def test_on_without_triggers_toggles_helper(stubbed: dict) -> None:
    assert cli.main(["on"]) == 0
    assert stubbed["toggled"] == [["True"]]
    assert stubbed["sleep"] == []


def test_on_without_triggers_starts_the_watcher(
    stubbed: dict, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An unlimited session still starts a watcher.

    It is the only thing that keeps the built-in panel dark for a shut lid, so
    a session with no trigger must not skip it.
    """
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "TIMER_SCRIPT", tmp_path / core.TIMER_NAME)
    assert cli.main(["on"]) == 0
    submitted = next(c for c in stubbed["run"] if c[:2] == ["launchctl", "submit"])
    assert submitted[:5] == ["launchctl", "submit", "-l", core.TIMER_LABEL, "--"]
    assert core.read_state().watching is True


def test_on_with_darken_calls_sleep_display(stubbed: dict) -> None:
    assert cli.main(["on", "--darken"]) == 0
    assert stubbed["toggled"] == [["True"]]
    assert stubbed["sleep"] == [["sleep"]]


def test_on_without_darken_never_touches_the_display(stubbed: dict) -> None:
    cli.main(["on", "--for", "10m"])
    assert stubbed["sleep"] == []


def test_on_with_darken_and_duration_schedules_and_darkens(
    stubbed: dict, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "TIMER_SCRIPT", tmp_path / core.TIMER_NAME)
    assert cli.main(["on", "--for", "15m", "--darken"]) == 0
    assert stubbed["sleep"] == [["sleep"]]
    submitted = next(c for c in stubbed["run"] if c[:2] == ["launchctl", "submit"])
    stored = core.read_state()
    assert stored.deadline is not None
    assert str(stored.deadline) in submitted[-1]


def test_on_rejects_battery_out_of_range(stubbed: dict) -> None:
    assert cli.main(["on", "--battery", "99"]) == 1
    assert stubbed["toggled"] == []


def test_on_rejects_invalid_duration(stubbed: dict) -> None:
    assert cli.main(["on", "--for", "soon"]) == 1
    assert stubbed["toggled"] == []


def test_no_command_prints_help() -> None:
    assert cli.main([]) == MISSING_COMMAND_EXIT


def test_off_cancels_timer_and_restores_sleep(
    stubbed: dict, tmp_path: Path, monkeypatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    assert cli.main(["off"]) == 0
    assert stubbed["toggled"] == [["False"]]
    removed = [c for c in stubbed["run"] if c[:2] == ["launchctl", "remove"]]
    assert removed


def test_off_keeps_the_timer_when_restoring_sleep_fails(
    stubbed: dict, tmp_path: Path, monkeypatch
) -> None:
    """A failed restore must not cancel the trigger that could still save it.

    Cancelling first would leave sleep disabled with nothing scheduled, so the
    battery could drain with no recovery path.
    """

    def refuse(_enabled: bool) -> None:
        raise core.ClamshellError("sudo refused")

    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    core.write_state(int(time.time()) + 600)
    monkeypatch.setattr(cli, "helper_toggle", refuse)
    assert cli.main(["off"]) == 1
    assert core.read_state().deadline is not None, "the trigger must survive"


def test_status_json_is_machine_readable(
    stubbed: dict, tmp_path: Path, monkeypatch, capsys
) -> None:
    state = tmp_path / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", state)
    monkeypatch.setattr(cli, "sleep_disabled", lambda: True)
    core.write_state(int(time.time()) + DEADLINE_SECONDS, FLOOR_PERCENT)
    assert cli.main(["status", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["disabled"] is True
    assert payload["floor"] == FLOOR_PERCENT
    assert 0 < payload["remainingSeconds"] <= DEADLINE_SECONDS


def test_status_text_stays_the_default(
    stubbed: dict, tmp_path: Path, monkeypatch, capsys
) -> None:
    """The JSON flag must not change the human-readable default."""
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(cli, "sleep_disabled", lambda: False)
    assert cli.main(["status"]) == 0
    assert "Sleep is enabled" in capsys.readouterr().out


def test_battery_json_reports_no_battery(stubbed: dict, monkeypatch, capsys) -> None:
    monkeypatch.setattr(cli, "battery_state", lambda: None)
    assert cli.main(["battery", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["percent"] is None
    assert payload["onBattery"] is None


def test_reconcile_reports_a_running_watcher(
    stubbed: dict, tmp_path: Path, monkeypatch, capsys
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(core, "timer_job_running", lambda: True)
    core.write_state(int(time.time()) + DEADLINE_SECONDS)
    assert cli.main(["reconcile"]) == 0
    assert "running" in capsys.readouterr().out


def test_darken_blanks_the_display(stubbed: dict) -> None:
    assert cli.main(["darken"]) == 0
    assert stubbed["sleep"] == [["sleep"]]


def test_status_reports_enabled_without_triggers(
    stubbed: dict, tmp_path: Path, monkeypatch
) -> None:
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(cli, "sleep_disabled", lambda: False)
    assert cli.main(["status"]) == 0


def test_status_reports_active_with_deadline(
    stubbed: dict, tmp_path: Path, monkeypatch
) -> None:
    state = tmp_path / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", state)
    monkeypatch.setattr(cli, "sleep_disabled", lambda: True)
    core.write_state(int(time.time()) + 600)
    assert cli.main(["status"]) == 0


def test_status_mentions_floor(stubbed: dict, tmp_path: Path, monkeypatch) -> None:
    state = tmp_path / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", state)
    monkeypatch.setattr(cli, "sleep_disabled", lambda: True)
    core.write_state(None, 25)
    assert cli.main(["status"]) == 0


def test_status_warns_about_reached_floor_even_with_deadline(
    stubbed: dict, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    """A timer must not hide an already-reached battery floor.

    Reported by review: with `--for 2h --battery 50` at 10% the warning was
    gated behind `deadline is None`, so the user saw only the countdown.
    """
    state = tmp_path / "state.plist"
    monkeypatch.setattr(core, "STATE_PATH", state)
    monkeypatch.setattr(cli, "sleep_disabled", lambda: True)
    monkeypatch.setattr(
        cli, "battery_state", lambda: BatteryState(percent=10, on_battery=True)
    )
    core.write_state(int(time.time()) + 3600, 50)
    assert cli.main(["status"]) == 0
    assert "Battery floor reached" in capsys.readouterr().out


def test_battery_reports_missing_battery(stubbed: dict, monkeypatch) -> None:
    monkeypatch.setattr(cli, "battery_state", lambda: None)
    assert cli.main(["battery"]) == 0


def test_battery_reports_level_and_floor(
    stubbed: dict, tmp_path: Path, monkeypatch
) -> None:

    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(
        cli, "battery_state", lambda: BatteryState(percent=42, on_battery=True)
    )
    core.write_state(None, 25)
    assert cli.main(["battery"]) == 0


def test_battery_reports_paused_on_wall_power(
    stubbed: dict, tmp_path: Path, monkeypatch
) -> None:

    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(
        cli, "battery_state", lambda: BatteryState(percent=90, on_battery=False)
    )
    core.write_state(None, 25)
    assert cli.main(["battery"]) == 0


def test_install_runs_privileged_install(stubbed: dict, monkeypatch, tmp_path) -> None:
    calls: list[object] = []
    monkeypatch.setattr(cli, "install_privileged", lambda h, r: calls.append((h, r)))
    monkeypatch.setattr(cli, "current_user", lambda: "tester")
    assert cli.main(["install"]) == 0
    assert len(calls) == 1
    helper, rule = calls[0]
    assert helper.name == core.HELPER_NAME
    assert rule.startswith("tester ALL=(root) NOPASSWD:")


def test_uninstall_removes_support_directory(
    stubbed: dict, monkeypatch, tmp_path
) -> None:
    support = tmp_path / "support"
    support.mkdir()
    (support / "clamshell_cli.py").write_text("# x\n")
    scripts: list[str] = []
    # STATE_PATH must be redirected too: uninstall cancels the timer, and an
    # unpatched path would delete the real user state file.
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "state.plist")
    monkeypatch.setattr(cli, "SUPPORT_DIR", support)
    monkeypatch.setattr(cli, "admin_shell", scripts.append)
    assert cli.main(["uninstall"]) == 0
    assert not support.exists()
    assert any("pmset disablesleep 0" in s for s in scripts)


def test_helper_source_prefers_the_checkout_copy(tmp_path: Path, monkeypatch) -> None:
    """A checkout keeps the helper beside the modules."""
    module_dir = tmp_path / "repo"
    module_dir.mkdir()
    (module_dir / core.HELPER_NAME).write_text("#!/bin/bash\n")
    monkeypatch.setattr(cli, "MODULE_DIR", module_dir)
    monkeypatch.setattr(cli, "HELPER_PATH", tmp_path / "sbin" / "clamshell-helper")
    assert cli.helper_source() == module_dir / core.HELPER_NAME


def test_helper_source_falls_back_to_the_installed_helper(
    tmp_path: Path, monkeypatch
) -> None:
    """A package install keeps only the executable, so fall back to it.

    Without this, `clamshell install` would fail after a package install.
    """
    module_dir = tmp_path / "lib"
    module_dir.mkdir()
    installed = tmp_path / "sbin" / "clamshell-helper"
    installed.parent.mkdir()
    installed.write_text("#!/bin/bash\n")
    monkeypatch.setattr(cli, "MODULE_DIR", module_dir)
    monkeypatch.setattr(cli, "HELPER_PATH", installed)
    assert cli.helper_source() == installed


def test_helper_source_raises_when_nothing_exists(tmp_path: Path, monkeypatch) -> None:
    module_dir = tmp_path / "lib"
    module_dir.mkdir()
    monkeypatch.setattr(cli, "MODULE_DIR", module_dir)
    monkeypatch.setattr(cli, "HELPER_PATH", tmp_path / "absent")
    with pytest.raises(core.ClamshellError):
        cli.helper_source()
