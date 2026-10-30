"""Integration tests for `clamshell update`.

The check and the install are stubbed, so these tests exercise argument parsing
and the consent boundary: a bare `update` must never touch the system, and only
`--install` may apply a release.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_cli as cli
import clamshell_core as core
import clamshell_update_cli as update_cli
from clamshell_release import Release
from clamshell_upgrade import UpgradeResult

DIGEST = "sha256:" + "a" * 64


def make_release() -> Release:
    """A release that looks installable, for the stubbed check to return."""
    return Release(
        version="0.4.0",
        tag="v0.4.0",
        name="Clamshell 0.4.0",
        notes="",
        prerelease=False,
        page_url="https://example.test/v0.4.0",
        asset_name="Clamshell-0.4.0.pkg",
        asset_url="https://example.test/Clamshell-0.4.0.pkg",
        asset_size=10,
        digest=DIGEST,
    )


def stub_check(monkeypatch, *, release: bool, error: str | None = None) -> None:
    """Replace the update check with a canned result."""
    chosen = make_release() if release else None
    info = update_cli.UpdateInfo(
        current=core.VERSION,
        latest="0.4.0" if release else core.VERSION,
        release=chosen,
        checked_at=0,
        from_cache=False,
        error=error,
    )
    monkeypatch.setattr(update_cli, "check_for_update", lambda *a, **k: info)


def test_check_json_reports_an_available_release(monkeypatch, capsys) -> None:
    stub_check(monkeypatch, release=True)
    assert cli.main(["update", "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["updateAvailable"] is True
    assert payload["release"]["version"] == "0.4.0"


def test_check_reports_up_to_date(capsys, monkeypatch) -> None:
    stub_check(monkeypatch, release=False)
    assert cli.main(["update"]) == 0
    assert "up to date" in capsys.readouterr().out


def test_check_reports_a_failed_check_without_raising(capsys, monkeypatch) -> None:
    """A network failure is a reported state, not a crash: the menu app shows it."""
    stub_check(monkeypatch, release=False, error="offline")
    assert cli.main(["update"]) == 1
    assert "offline" in capsys.readouterr().out


def test_bare_update_never_installs(monkeypatch) -> None:
    """Without --install nothing may be applied, even when a release is available."""
    stub_check(monkeypatch, release=True)

    def forbidden(*_: object, **__: object):
        raise AssertionError("a bare check must not install")

    monkeypatch.setattr(update_cli, "apply_update", forbidden)
    assert cli.main(["update"]) == 0


def test_install_applies_the_selected_release(monkeypatch, capsys) -> None:
    stub_check(monkeypatch, release=True)
    applied: list[str] = []
    monkeypatch.setattr(core, "require_macos", lambda: None)
    monkeypatch.setattr(
        update_cli,
        "apply_update",
        lambda release, **kwargs: (
            applied.append(release.version)
            or UpgradeResult(
                version=release.version,
                installed=True,
                asset_name=release.asset_name,
                digest_verified=True,
                watcher_restarted=False,
            )
        ),
    )
    assert cli.main(["update", "--install"]) == 0
    assert applied == ["0.4.0"]
    assert "Installed Clamshell 0.4.0" in capsys.readouterr().out


def test_install_forwards_verification_flags(monkeypatch) -> None:
    stub_check(monkeypatch, release=True)
    seen: dict[str, object] = {}
    monkeypatch.setattr(core, "require_macos", lambda: None)

    def capture(release: Release, **kwargs: object) -> UpgradeResult:
        seen.update(kwargs)
        return UpgradeResult(
            version=release.version,
            installed=True,
            asset_name=release.asset_name,
            digest_verified=False,
            watcher_restarted=False,
        )

    monkeypatch.setattr(update_cli, "apply_update", capture)
    assert cli.main(["update", "--install", "--allow-unverified"]) == 0
    assert seen["allow_unverified"] is True


def test_dry_run_never_installs(monkeypatch, capsys) -> None:
    stub_check(monkeypatch, release=True)
    monkeypatch.setattr(core, "require_macos", lambda: None)
    seen: dict[str, object] = {}

    def capture(release: Release, **kwargs: object) -> UpgradeResult:
        seen.update(kwargs)
        return UpgradeResult(
            version=release.version,
            installed=False,
            asset_name=release.asset_name,
            digest_verified=True,
            watcher_restarted=False,
            detail="verified; not installed (dry run)",
        )

    monkeypatch.setattr(update_cli, "apply_update", capture)
    assert cli.main(["update", "--install", "--dry-run"]) == 0
    assert seen["dry_run"] is True


def test_install_without_a_release_fails(monkeypatch, capsys) -> None:
    stub_check(monkeypatch, release=False)
    assert cli.main(["update", "--install"]) == 1
    assert "Nothing to install" in capsys.readouterr().err
