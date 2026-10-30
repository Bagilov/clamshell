"""Core helpers for clamshell mode on Apple Silicon Macs.

Sleep with the lid closed only works through ``pmset disablesleep``, which
needs root. These helpers keep that one privileged call isolated behind a
narrow helper, parse durations, read the current state and schedule an
automatic switch-off.

Privileged installation lives in :mod:`clamshell_privileged`.
"""

from __future__ import annotations

import plistlib
import re
import shlex
import subprocess
import sys
import time
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

HELPER_PATH = Path("/usr/local/sbin/clamshell-helper")
CLI_PATH = Path("/usr/local/bin/clamshell")
#: Where a user-run `clamshell install` stages its sources and launcher. A
#: packaged install instead uses :data:`LIB_DIR`.
SUPPORT_DIR = Path.home() / "Library/Application Support/clamshell"
#: System-wide location used by the macOS installer package.
LIB_DIR = Path("/usr/local/lib/clamshell")
SUDOERS_PATH = Path("/etc/sudoers.d/clamshell")
TIMER_LABEL = "io.github.bagilov.clamshell.timer"
LEGACY_TIMER_LABELS = ("com.alfagen.clamshell.timer",)
STATE_PATH = SUPPORT_DIR / "state.plist"
MODULE_DIR = Path(__file__).resolve().parent
INFO_PLIST = MODULE_DIR / "ui" / "Resources" / "Info.plist"
HELPER_NAME = "clamshell_helper.sh"
TIMER_NAME = "clamshell_timer.sh"
MODULE_GLOB = "clamshell_*.py"
# The watcher sits beside whichever copy of the code is running, so the repo, a
# user install and a packaged install all resolve it correctly.
TIMER_SCRIPT = MODULE_DIR / TIMER_NAME
PMSET = Path("/usr/bin/pmset")
DEFAULT_TIMEOUT = 60.0
FAR_FUTURE = 4_102_444_800
#: Ceiling on a keep-awake duration. An accidental extra digit would otherwise
#: schedule a session years out; the menu bar app applies the same 30-day limit.
MAX_DURATION_SECONDS = 30 * 86400

#: Project version, following semantic versioning. Major zero marks the current
#: pre-release line: the interface may still change between minor releases.
VERSION = "0.4.0"

_SPAN_RE = re.compile(r"(\d+)([smhd])")
_UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


class ClamshellError(RuntimeError):
    """Raised when a clamshell operation cannot be completed."""


@dataclass(frozen=True)
class TimerState:
    """Persisted session settings.

    Attributes:
        deadline: Epoch seconds when sleep is restored, or None for no limit.
        floor: Battery percentage that restores sleep, or 0 when disabled.
        watching: Whether the session watcher is meant to be running. It is
            stored so an indefinite session — no deadline and no floor — is still
            recognisable, both by ``status`` and by ``reconcile`` after a restart.
    """

    deadline: int | None
    floor: int
    watching: bool = False


def parse_span(value: str) -> int:
    """Convert a human span like ``1h``, ``30m`` or ``1h30m`` to seconds.

    Args:
        value: Span string of ``<number><unit>`` groups, unit in ``s/m/h/d``,
            or a bare integer read as seconds.

    Returns:
        Total duration in seconds, strictly greater than zero.

    Raises:
        ClamshellError: If the span is empty, malformed or evaluates to zero.
    """
    text = value.strip().lower()
    if not text:
        raise ClamshellError("duration must not be empty")
    if text.isdigit():
        seconds = int(text)
    else:
        matches = list(_SPAN_RE.finditer(text))
        if not matches or "".join(m.group(0) for m in matches) != text:
            raise ClamshellError(
                f"invalid duration: {value!r} (use e.g. 45m, 2h, 1h30m)"
            )
        seconds = sum(int(m.group(1)) * _UNITS[m.group(2)] for m in matches)
    if seconds <= 0:
        raise ClamshellError("duration must be greater than zero")
    if seconds > MAX_DURATION_SECONDS:
        raise ClamshellError(
            f"duration must not exceed {format_span(MAX_DURATION_SECONDS)}"
        )
    return seconds


def format_span(seconds: int) -> str:
    """Render a second count as a compact human string like ``1h 30m``.

    Args:
        seconds: Non-positive values render as ``0s``.

    Returns:
        Space-separated ``<count><unit>`` parts in descending unit order.
    """
    if seconds <= 0:
        return "0s"
    parts: list[str] = []
    remaining = seconds
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60), ("s", 1)):
        if remaining >= size:
            count, remaining = divmod(remaining, size)
            parts.append(f"{count}{unit}")
    return " ".join(parts)


def run(
    argv: Sequence[str],
    *,
    check: bool = True,
    timeout: float | None = DEFAULT_TIMEOUT,
) -> subprocess.CompletedProcess:
    """Run a command and capture its text output.

    Args:
        argv: Full command and arguments.
        check: When true, raise ClamshellError on a non-zero exit code.
        timeout: Seconds to wait before killing the command, or None to wait
            indefinitely. A hung child would otherwise block the CLI forever.

    Returns:
        The completed process with captured stdout and stderr.

    Raises:
        ClamshellError: On a non-zero exit code or a timeout.
    """
    try:
        completed = subprocess.run(
            list(argv), check=False, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired as error:
        raise ClamshellError(
            f"{' '.join(argv)} timed out after {timeout:g}s"
        ) from error
    if check and completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "unknown error"
        raise ClamshellError(f"{' '.join(argv)} failed: {detail}")
    return completed


def require_macos() -> None:
    """Abort unless running on macOS with ``pmset`` available."""
    if sys.platform != "darwin":
        raise ClamshellError("clamshell only supports macOS")
    if not PMSET.exists():
        raise ClamshellError(f"missing {PMSET}")


def sleep_disabled() -> bool:
    """Read the system ``SleepDisabled`` flag.

    ``pmset -g`` prints the flag only while sleep is disabled, so a missing
    flag means sleep is currently allowed.

    Returns:
        ``True`` when system sleep is disabled, ``False`` otherwise.
    """
    result = run([str(PMSET), "-g"], check=False)
    for line in result.stdout.splitlines():
        parts = line.split()
        if parts and parts[0] == "SleepDisabled":
            return parts[-1] == "1"
    return False


def helper_toggle(enabled: bool) -> None:
    """Toggle sleep through the privileged helper without a password prompt.

    Args:
        enabled: True disables sleep, False restores normal behaviour.

    Raises:
        ClamshellError: If the helper is not installed or sudo is refused.
    """
    action = "on" if enabled else "off"
    run(["sudo", "-n", str(HELPER_PATH), action])


def sleep_display() -> None:
    """Turn the display off immediately.

    Closing the lid usually blanks the built-in panel on its own, but a few
    Apple Silicon setups keep it lit. This makes the blanking explicit and does
    not require root. It is opt-in because it would otherwise darken the screen
    of a session started with the lid open.
    """
    run([str(PMSET), "displaysleepnow"])


def write_state(deadline: int | None, floor: int = 0, watching: bool = False) -> None:
    """Persist the session trigger and whether a watcher is running.

    Args:
        deadline: Epoch seconds when sleep is restored, or None to clear.
        floor: Battery percentage at which sleep is restored, 0 to disable.
        watching: Whether the session watcher is meant to be running. An
            indefinite session has neither a deadline nor a floor but still
            needs a watcher, so it cannot be inferred from the other two.
    """
    if deadline is None and floor <= 0 and not watching:
        STATE_PATH.unlink(missing_ok=True)
        return
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload: dict[str, int | bool] = {}
    if deadline is not None:
        payload["Deadline"] = deadline
    if floor > 0:
        payload["BatteryFloor"] = floor
    if watching:
        payload["Watching"] = True
    with STATE_PATH.open("wb") as handle:
        plistlib.dump(payload, handle)


def read_state() -> TimerState:
    """Return the persisted session state.

    Returns:
        The stored deadline, battery floor and watcher flag; each ``None``,
        ``0`` or ``False`` when the file is absent, unreadable or does not carry
        that field.
    """
    empty = TimerState(deadline=None, floor=0)
    if not STATE_PATH.exists():
        return empty
    try:
        with STATE_PATH.open("rb") as handle:
            payload = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return empty
    if not isinstance(payload, dict):
        return empty
    raw_deadline = payload.get("Deadline")
    raw_floor = payload.get("BatteryFloor")
    deadline = int(raw_deadline) if isinstance(raw_deadline, (int, float)) else None
    floor = int(raw_floor) if isinstance(raw_floor, (int, float)) else 0
    watching = bool(payload.get("Watching"))
    return TimerState(deadline=deadline, floor=floor, watching=watching)


def cancel_timer() -> None:
    """Remove the scheduled restore job and clear persisted state.

    Labels used by earlier versions are removed too, so an upgrade cannot leave
    an old job behind that would restore sleep at the wrong time.
    """
    for label in (TIMER_LABEL, *LEGACY_TIMER_LABELS):
        run(["launchctl", "remove", label], check=False)
    write_state(None)


def timer_job_running() -> bool:
    """Whether the auto-restore watcher is currently registered with launchd.

    The watcher is submitted as a transient job, so it disappears on reboot and
    can also die on its own. Without this check a leftover state file would look
    like a live session that never fires.

    Returns:
        ``True`` when the watcher label is present in ``launchctl list``.
    """
    result = run(["launchctl", "list"], check=False)
    return TIMER_LABEL in result.stdout


def reconcile_state() -> str:
    """Bring the persisted trigger back in line with reality.

    A state file survives a reboot while the transient watcher job does not, so
    after a restart sleep could stay disabled with nothing left to restore it.
    This runs at application start and does the least surprising thing:

    * no watcher was ever recorded: nothing to do;
    * the watcher is running: leave it alone;
    * a future trigger with no watcher: re-arm it, keeping the remaining time;
    * a trigger that already passed with no watcher: restore sleep and clear;
    * an indefinite session with no watcher: re-arm it, so the built-in panel
      keeps being blanked for a shut lid.

    Returns:
        One of ``clean``, ``running``, ``rearmed`` or ``restored``, describing
        what was found so the caller can report it.

    Raises:
        ClamshellError: If sleep has to be restored and the helper refuses.
    """
    stored = read_state()
    # A state file written before the watcher flag existed still records a real
    # session, so a deadline or a floor also counts as something to reconcile.
    watching = stored.watching or stored.deadline is not None or stored.floor > 0
    if not watching:
        return "clean"
    if timer_job_running():
        return "running"

    now = int(time.time())
    if stored.deadline is not None and stored.deadline <= now:
        # The moment passed with no watcher alive, so the session is orphaned.
        # Restore first: if that fails the state stays, as in `cmd_off`.
        if sleep_disabled():
            helper_toggle(False)
        cancel_timer()
        return "restored"

    seconds = None if stored.deadline is None else stored.deadline - now
    schedule_auto_off(seconds, stored.floor)
    return "rearmed"


def schedule_auto_off(seconds: int | None, floor: int = 0) -> int | None:
    """Start the session watcher, restoring sleep on time, floor, or neither.

    The watcher is submitted for every session, including an indefinite one, and
    not only when a trigger exists: it is also what keeps the built-in panel dark
    while the lid is shut, which macOS does not do on its own once
    ``disablesleep`` is active.

    The job runs the watcher script in the current GUI session and calls the
    helper through the NOPASSWD sudoers rule, so no second admin prompt is
    required.

    Args:
        seconds: Positive delay before sleep is re-enabled, or None when the
            session has no time limit.
        floor: Battery percentage at which sleep is re-enabled, 0 to disable.

    Returns:
        The absolute deadline as epoch seconds, or None when no deadline
        applies.

    Raises:
        ClamshellError: If a duration is given but is not positive.
    """
    if seconds is not None and seconds <= 0:
        raise ClamshellError("duration must be greater than zero")
    cancel_timer()
    deadline = int(time.time()) + seconds if seconds is not None else FAR_FUTURE
    script = (
        f"exec /bin/bash {shlex.quote(str(TIMER_SCRIPT))} "
        f"{deadline} {floor} {shlex.quote(str(STATE_PATH))}"
    )
    run(["launchctl", "submit", "-l", TIMER_LABEL, "--", "/bin/bash", "-c", script])
    stored = deadline if seconds is not None else None
    write_state(stored, floor, watching=True)
    return stored
