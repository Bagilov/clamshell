"""Battery level reporting for clamshell mode.

Closing the lid while running on battery drains it quickly, so sessions can
carry a user-chosen floor at which sleep is restored. Only the battery
percentage and power source are needed, both parsed from ``pmset -g batt``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from clamshell_core import PMSET, ClamshellError, run

POWER_SOURCE = re.compile(r"Now drawing from '([^']+)'")
PERCENT = re.compile(r"(\d+)%")
AC_SOURCE = "AC Power"
MIN_PERCENT = 5
MAX_PERCENT = 95


@dataclass(frozen=True)
class BatteryState:
    """A snapshot of the internal battery.

    Attributes:
        percent: Charge percentage, 0-100.
        on_battery: True when the Mac is drawing from battery, not wall power.
    """

    percent: int
    on_battery: bool


def validate_percent(value: int) -> int:
    """Validate a user-supplied battery floor.

    Args:
        value: Requested floor percentage.

    Returns:
        The floor unchanged when it is within the supported range.

    Raises:
        ClamshellError: If the value is outside ``MIN_PERCENT``-``MAX_PERCENT``.
    """
    if not MIN_PERCENT <= value <= MAX_PERCENT:
        raise ClamshellError(
            f"battery floor must be between {MIN_PERCENT} and {MAX_PERCENT}%"
        )
    return value


def battery_state() -> BatteryState | None:
    """Read the current battery state.

    Returns:
        The parsed state, or ``None`` when ``pmset`` reports no internal
        battery (for example on a desktop Mac or when parsing fails).
    """
    result = run([str(PMSET), "-g", "batt"], check=False)
    text = result.stdout
    percent_match = PERCENT.search(text)
    source_match = POWER_SOURCE.search(text)
    if not percent_match or not source_match:
        return None
    return BatteryState(
        percent=int(percent_match.group(1)),
        on_battery=source_match.group(1) != AC_SOURCE,
    )


def floor_reached(floor: int, state: BatteryState) -> bool:
    """Decide whether the floor is reached and sleep should be restored.

    The floor only applies on battery power: while plugged in the charge is not
    draining, so a session should never be cut short by a low reading.

    Args:
        floor: Configured minimum percentage.
        state: Current battery snapshot.

    Returns:
        True when running on battery at or below ``floor``.
    """
    return state.on_battery and state.percent <= floor
