"""Tests for the version metadata shipped with the app bundle.

The bundle version and the code version must not drift apart, and the CLI must
expose the version it was built with.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_cli as cli
import clamshell_core as core

SEMVER_PARTS = 3


def test_version_follows_semver() -> None:
    """The project version must stay valid semantic versioning."""
    parts = core.VERSION.split(".")
    assert len(parts) == SEMVER_PARTS
    assert all(part.isdigit() for part in parts)
    assert int(parts[0]) == 0, "major zero marks the pre-release line"


def test_bundle_version_matches_the_code_version() -> None:
    """The app bundle version must not drift from the code version.

    Read through ``plistlib`` and check both keys: a substring search over the
    raw file passes whenever only one of the two version keys is updated.
    """
    plist = plistlib.loads(core.INFO_PLIST.read_bytes())
    assert plist["CFBundleShortVersionString"] == core.VERSION
    assert plist["CFBundleVersion"] == core.VERSION


def test_cli_exposes_the_version_flag() -> None:
    """`clamshell --version` must print the version and exit cleanly."""
    parser = cli.build_parser()
    with pytest.raises(SystemExit) as exit_info:
        parser.parse_args(["--version"])
    assert exit_info.value.code == 0
