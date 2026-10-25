#!/usr/bin/env python3
"""Command-line interface for clamshell mode on Apple Silicon Macs.

Commands:
    install                     Install helper, sudoers rule and CLI.
    uninstall                   Remove helper, sudoers rule and CLI.
    on [--for SPAN] [--battery] [--darken]
                                Disable sleep, with optional auto-restore.
    off                         Restore normal sleep behaviour.
    status                      Show the current state and pending triggers.
    battery                     Show battery level and the configured floor.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from collections.abc import Sequence
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from clamshell_battery import MAX_PERCENT, MIN_PERCENT, battery_state, validate_percent
from clamshell_core import (
    CLI_PATH,
    HELPER_NAME,
    HELPER_PATH,
    MODULE_DIR,
    SUDOERS_PATH,
    SUPPORT_DIR,
    VERSION,
    ClamshellError,
    cancel_timer,
    format_span,
    helper_toggle,
    parse_span,
    read_state,
    reconcile_state,
    require_macos,
    schedule_auto_off,
    sleep_disabled,
    sleep_display,
)
from clamshell_privileged import (
    admin_shell,
    current_user,
    install_privileged,
    uninstall_command,
)


def cmd_on(args: argparse.Namespace) -> int:
    """Disable sleep with optional time and battery-floor auto-restore.

    Running ``on`` clears any pending trigger first, so an earlier session
    cannot silently turn sleep back on later in the day. A watcher is always
    left running: besides the triggers, it is what keeps the built-in panel dark
    while the lid is shut.
    """
    require_macos()
    floor = validate_percent(args.battery) if args.battery is not None else 0
    seconds = parse_span(args.duration) if args.duration else None
    helper_toggle(True)
    schedule_auto_off(seconds, floor)
    triggers = []
    if seconds is not None:
        triggers.append(f"auto-restore in {format_span(seconds)}")
    if floor > 0:
        triggers.append(f"auto-restore at {floor}% battery")
    message = "Sleep disabled."
    if triggers:
        message += " " + ", ".join(triggers).capitalize() + "."
    else:
        message += " The lid can be closed now; run 'clamshell off' to stop."
    print(message)
    if args.darken:
        sleep_display()
        print("Display turned off.")
    return 0


def cmd_battery(args: argparse.Namespace) -> int:
    """Print the current battery level and whether the floor would apply."""
    state = battery_state()
    stored = read_state()
    if getattr(args, "json", False):
        print(
            json.dumps(
                {
                    "percent": None if state is None else state.percent,
                    "onBattery": None if state is None else state.on_battery,
                    "floor": stored.floor,
                },
                sort_keys=True,
            )
        )
        return 0
    if state is None:
        print("No battery detected (desktop Mac or unsupported hardware).")
        return 0
    source = "battery" if state.on_battery else "wall power"
    print(f"Battery at {state.percent}% (drawing from {source}).")
    if stored.floor > 0:
        if state.on_battery:
            print(f"Battery floor set to {stored.floor}%.")
        else:
            print(f"Battery floor {stored.floor}% set; paused while on wall power.")
    return 0


def cmd_off(_: argparse.Namespace) -> int:
    """Restore normal sleep behaviour and drop any pending trigger.

    Sleep is restored before the timer is cancelled. If the privileged call
    fails, the timer and state survive so the session can still be recovered;
    cancelling first would leave sleep disabled with nothing left to restore it.
    """
    helper_toggle(False)
    cancel_timer()
    print("Sleep restored to normal behaviour.")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    """Print the current sleep state and any pending auto-restore trigger.

    ``--json`` emits the same facts for programmatic callers (the menu bar app),
    which otherwise has to parse the human text and breaks on any wording change.
    """
    disabled = sleep_disabled()
    stored = read_state()
    if getattr(args, "json", False):
        remaining = None
        if stored.deadline is not None:
            remaining = max(0, stored.deadline - int(time.time()))
        print(
            json.dumps(
                {
                    "disabled": disabled,
                    "remainingSeconds": remaining,
                    "floor": stored.floor,
                },
                sort_keys=True,
            )
        )
        return 0
    if disabled:
        print("Sleep is DISABLED (clamshell mode active).")
    else:
        print("Sleep is enabled (normal behaviour).")
    if stored.deadline is not None:
        remaining = stored.deadline - int(time.time())
        if remaining > 0:
            print(f"Auto-restore in {format_span(remaining)}.")
        else:
            print("Auto-restore deadline has passed; run 'clamshell off' if needed.")
    if stored.floor > 0:
        print(f"Auto-restore at {stored.floor}% battery.")
        state = battery_state()
        if state is not None and state.on_battery and state.percent <= stored.floor:
            print("Battery floor reached; run 'clamshell off' if needed.")
    return 0


def cmd_reconcile(_: argparse.Namespace) -> int:
    """Re-align a leftover timer with reality after a restart.

    The watcher is a transient launchd job, so a reboot or a crash can leave a
    state file behind with nothing scheduled. Called by the menu bar app at
    launch; safe to run at any time.
    """
    outcome = reconcile_state()
    messages = {
        "clean": "Nothing to reconcile.",
        "running": "Auto-restore watcher is running.",
        "rearmed": "Auto-restore watcher re-armed after a restart.",
        "restored": "Missed auto-restore applied; sleep restored.",
    }
    print(messages[outcome])
    return 0


def cmd_darken(_: argparse.Namespace) -> int:
    """Blank the display now, for a session that is already running.

    ``on --darken`` only blanks the display as the session starts; this lets the
    menu bar app apply the toggle to a session that is already active.
    """
    require_macos()
    sleep_display()
    print("Display turned off.")
    return 0


def cmd_install(_: argparse.Namespace) -> int:
    """Install the helper, CLI sources, launcher and sudoers rule.

    The helper source sits beside the modules in a checkout, but a package
    install puts the executable in ``HELPER_PATH`` and keeps only the modules
    under the library directory. Both layouts are accepted so `install` still
    works after a package install.
    """
    require_macos()
    helper_src = helper_source()
    rule = f"{current_user()} ALL=(root) NOPASSWD: {HELPER_PATH}"
    install_privileged(helper_src, rule)
    print(f"Installed helper at {HELPER_PATH} and rule at {SUDOERS_PATH}.")
    print(f"CLI available as {CLI_PATH}. Try: clamshell on --for 1h")
    return 0


def helper_source() -> Path:
    """Locate the helper script from either install layout.

    Returns:
        The checkout copy when present, otherwise the installed executable.

    Raises:
        ClamshellError: If neither candidate exists.
    """
    candidates = (MODULE_DIR / HELPER_NAME, HELPER_PATH)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise ClamshellError(f"missing helper script (looked in {MODULE_DIR})")


def cmd_uninstall(_: argparse.Namespace) -> int:
    """Remove the helper, sudoers rule, launcher and installed sources."""
    cancel_timer()
    admin_shell(uninstall_command())
    shutil.rmtree(SUPPORT_DIR, ignore_errors=True)
    print("Clamshell removed. Normal sleep behaviour restored.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Build the argparse command-line parser."""
    parser = argparse.ArgumentParser(
        prog="clamshell",
        description="Keep this MacBook awake with the lid closed.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {VERSION}",
    )
    sub = parser.add_subparsers(dest="command")

    on = sub.add_parser("on", help="disable sleep so the lid can be closed")
    on.add_argument(
        "--for",
        dest="duration",
        metavar="SPAN",
        help="auto-restore sleep after a span such as 45m, 2h, 1h30m",
    )
    on.add_argument(
        "--battery",
        dest="battery",
        type=int,
        metavar="PERCENT",
        help=f"auto-restore sleep at this battery level ({MIN_PERCENT}-{MAX_PERCENT})",
    )
    on.add_argument(
        "--darken",
        action="store_true",
        help="turn the display off immediately (useful when the lid stays open)",
    )
    on.set_defaults(func=cmd_on)

    off = sub.add_parser("off", help="restore normal sleep behaviour")
    off.set_defaults(func=cmd_off)

    status = sub.add_parser("status", help="show current clamshell state")
    status.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable JSON instead of text",
    )
    status.set_defaults(func=cmd_status)

    reconcile = sub.add_parser(
        "reconcile", help="re-align a leftover timer after a restart"
    )
    reconcile.set_defaults(func=cmd_reconcile)

    battery = sub.add_parser("battery", help="show battery level and floor")
    battery.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable JSON instead of text",
    )
    battery.set_defaults(func=cmd_battery)

    darken = sub.add_parser("darken", help="turn the display off now")
    darken.set_defaults(func=cmd_darken)

    install = sub.add_parser("install", help="install helper and sudoers rule")
    install.set_defaults(func=cmd_install)

    uninstall = sub.add_parser("uninstall", help="remove helper and sudoers rule")
    uninstall.set_defaults(func=cmd_uninstall)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Parse arguments and dispatch to the selected command."""
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 2
    try:
        return int(args.func(args))
    except ClamshellError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
