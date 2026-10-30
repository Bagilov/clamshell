"""The `clamshell update` command and its output.

Split from :mod:`clamshell_cli` so the dispatcher stays a thin argument-routing
layer and the update wording lives beside the feature it describes. The command
is deliberately split in two halves — report, and install on request — because a
bare check must never change the system.
"""

from __future__ import annotations

import argparse
import json
import sys

from clamshell_core import VERSION, require_macos
from clamshell_update import UpdateInfo, check_for_update
from clamshell_upgrade import UpgradeResult, apply_update

UP_TO_DATE_EXIT = 0
CHECK_FAILED_EXIT = 1


def add_update_parser(sub: argparse._SubParsersAction) -> None:
    """Register the `update` subcommand on the main parser.

    Kept beside the command so the flags and the code that reads them stay in one
    file, and the main dispatcher stays a thin routing layer.
    """
    update = sub.add_parser("update", help="check for or install a newer release")
    update.add_argument(
        "--install",
        action="store_true",
        help="download and install the newer release (needs one admin prompt)",
    )
    update.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable JSON instead of text",
    )
    update.add_argument(
        "--force",
        action="store_true",
        help="check now, even if a check already ran in the last day",
    )
    update.add_argument(
        "--dry-run",
        action="store_true",
        help="download and verify the installer without installing it",
    )
    update.add_argument(
        "--allow-unverified",
        action="store_true",
        help="install even when the release carries no checksum (not recommended)",
    )
    update.set_defaults(func=cmd_update)


def cmd_update(args: argparse.Namespace) -> int:
    """Check for a newer release, and optionally install it.

    ``update`` on its own only reports; installing requires ``--install``, so a
    bare check can never change the system. The check is throttled to once a day
    unless ``--force`` is given, and a failed check is reported rather than
    raised, so the menu bar app can show "could not check" without an alert.
    """
    info = check_for_update(VERSION, force=bool(getattr(args, "force", False)))
    as_json = bool(getattr(args, "json", False))
    if as_json and not args.install:
        print(json.dumps(info.as_json(), sort_keys=True))
        return UP_TO_DATE_EXIT if info.error is None else CHECK_FAILED_EXIT
    if not as_json:
        print_update_status(info)
    if not args.install:
        return UP_TO_DATE_EXIT if info.error is None else CHECK_FAILED_EXIT
    if info.release is None:
        reason = info.error or "no newer release is available"
        print(f"Nothing to install: {reason}.", file=sys.stderr)
        return CHECK_FAILED_EXIT
    require_macos()
    result = apply_update(
        info.release,
        allow_unverified=bool(getattr(args, "allow_unverified", False)),
        dry_run=bool(getattr(args, "dry_run", False)),
    )
    return print_upgrade_result(result, as_json=as_json)


def print_update_status(info: UpdateInfo) -> None:
    """Print a human-readable update summary."""
    if info.error is not None:
        print(f"Could not check for updates: {info.error}")
        if info.latest is not None:
            print(f"Last known version: {info.latest}.")
        return
    if info.release is None:
        latest = f" (newest seen: {info.latest})" if info.latest else ""
        print(f"Clamshell {info.current} is up to date{latest}.")
        return
    release = info.release
    kind = "pre-release" if release.prerelease else "release"
    print(f"Clamshell {release.version} is available; you have {info.current}.")
    print(f"{release.name} ({kind}): {release.page_url}")
    if release.has_digest:
        print("The installer checksum will be verified before installing.")
    else:
        print("Warning: this release carries no checksum to verify.")


def print_upgrade_result(result: UpgradeResult, *, as_json: bool) -> int:
    """Print an upgrade result and map it to an exit code.

    A successful install, and a dry run that stops before installing, are both
    success; ``installed`` distinguishes them in the JSON payload.
    """
    if as_json:
        print(json.dumps(result.as_json(), sort_keys=True))
        return UP_TO_DATE_EXIT
    print(
        f"Installed Clamshell {result.version}." if result.installed else result.detail
    )
    if result.installed:
        if not result.digest_verified:
            print("Warning: installed without checksum verification.")
        if result.watcher_restarted:
            print("Active session re-armed on the new version.")
        print("The menu bar app picks up the new version on its next launch.")
    return UP_TO_DATE_EXIT
