"""Tests for battery reporting and the battery-floor trigger.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_battery as battery
import clamshell_core as core

ON_BATTERY = (
    "Now drawing from 'Battery Power'\n"
    " -InternalBattery-0 (id=1234567)\t42%; discharging; 3:15 remaining present: true\n"
)
ON_AC = (
    "Now drawing from 'AC Power'\n"
    " -InternalBattery-0 (id=1234567)\t88%; charged; 0:00 remaining present: true\n"
)
NO_BATTERY = "Now drawing from 'AC Power'\n"


class Result:
    def __init__(self, stdout: str) -> None:
        self.stdout = stdout


def test_battery_state_parses_battery_power(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(battery, "run", lambda *a, **k: Result(ON_BATTERY))
    state = battery.battery_state()
    assert state == battery.BatteryState(percent=42, on_battery=True)


def test_battery_state_parses_ac_power(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(battery, "run", lambda *a, **k: Result(ON_AC))
    state = battery.battery_state()
    assert state == battery.BatteryState(percent=88, on_battery=False)


def test_battery_state_returns_none_without_battery(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(battery, "run", lambda *a, **k: Result(NO_BATTERY))
    assert battery.battery_state() is None


def test_battery_state_returns_none_on_unparseable_output(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(battery, "run", lambda *a, **k: Result("garbage\n"))
    assert battery.battery_state() is None


@pytest.mark.parametrize("value", [5, 20, 50, 95])
def test_validate_percent_accepts_supported_range(value: int) -> None:
    assert battery.validate_percent(value) == value


@pytest.mark.parametrize("value", [0, 4, 96, 100, -5])
def test_validate_percent_rejects_out_of_range(value: int) -> None:
    with pytest.raises(core.ClamshellError):
        battery.validate_percent(value)


def test_floor_reached_when_on_battery_at_floor() -> None:
    state = battery.BatteryState(percent=20, on_battery=True)
    assert battery.floor_reached(20, state) is True


def test_floor_reached_when_on_battery_below_floor() -> None:
    state = battery.BatteryState(percent=15, on_battery=True)
    assert battery.floor_reached(20, state) is True


def test_floor_not_reached_while_plugged_in() -> None:
    state = battery.BatteryState(percent=10, on_battery=False)
    assert battery.floor_reached(20, state) is False


def test_floor_not_reached_above_floor_on_battery() -> None:
    state = battery.BatteryState(percent=55, on_battery=True)
    assert battery.floor_reached(20, state) is False
