"""Tests for downloading, verifying and applying an update.

The security-relevant behaviour is the checksum gate and the refusal to install
a release without one, so those paths are covered explicitly. Nothing here
touches the network, the installer or launchd: every side effect is stubbed.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_core as core
import clamshell_upgrade as upgrade
from clamshell_release import Release

REMAINING_SECONDS = 1800
FLOOR_PERCENT = 25


def make_release(tmp_path: Path, payload: bytes, *, digest: str | None) -> Release:
    """Return a release whose asset "download" writes ``payload``."""
    asset = tmp_path / "Clamshell-9.9.9.pkg"
    return Release(
        version="9.9.9",
        tag="v9.9.9",
        name="Clamshell 9.9.9",
        notes="",
        prerelease=False,
        page_url="https://example.test/v9.9.9",
        asset_name=asset.name,
        asset_url=f"https://example.test/{asset.name}",
        asset_size=len(payload),
        digest=digest or "",
    )


def stub_download(monkeypatch: pytest.MonkeyPatch, payload: bytes) -> None:
    """Make ``download_release`` write the payload instead of using curl."""

    def fake(release: Release, destination: Path) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(payload)
        return destination

    monkeypatch.setattr(upgrade, "download_release", fake)


def test_sha256_matches_hashlib(tmp_path: Path) -> None:
    target = tmp_path / "file.bin"
    target.write_bytes(b"clamshell")
    assert upgrade.sha256_of(target) == hashlib.sha256(b"clamshell").hexdigest()


def test_verify_accepts_a_matching_digest(tmp_path: Path) -> None:
    payload = b"package-bytes"
    release = make_release(
        tmp_path, payload, digest="sha256:" + hashlib.sha256(payload).hexdigest()
    )
    package = tmp_path / release.asset_name
    package.write_bytes(payload)
    assert upgrade.verify_download(package, release, allow_unverified=False) is True


def test_verify_rejects_a_mismatch(tmp_path: Path) -> None:
    release = make_release(tmp_path, b"x", digest="sha256:" + "0" * 64)
    package = tmp_path / release.asset_name
    package.write_bytes(b"x")
    with pytest.raises(core.ClamshellError) as error:
        upgrade.verify_download(package, release, allow_unverified=False)
    assert "checksum mismatch" in str(error.value)


def test_verify_refuses_a_release_without_a_digest(tmp_path: Path) -> None:
    release = make_release(tmp_path, b"x", digest=None)
    package = tmp_path / release.asset_name
    package.write_bytes(b"x")
    with pytest.raises(core.ClamshellError) as error:
        upgrade.verify_download(package, release, allow_unverified=False)
    assert "--allow-unverified" in str(error.value)


def test_verify_allows_missing_digest_only_when_opted_in(tmp_path: Path) -> None:
    release = make_release(tmp_path, b"x", digest=None)
    package = tmp_path / release.asset_name
    package.write_bytes(b"x")
    assert upgrade.verify_download(package, release, allow_unverified=True) is False


def test_dry_run_verifies_without_installing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    payload = b"package-bytes"
    release = make_release(
        tmp_path, payload, digest="sha256:" + hashlib.sha256(payload).hexdigest()
    )
    stub_download(monkeypatch, payload)

    def forbidden(*_: object, **__: object) -> None:
        raise AssertionError("a dry run must not install")

    monkeypatch.setattr(upgrade, "install_package", forbidden)
    result = upgrade.apply_update(release, dry_run=True)
    assert not result.installed
    assert result.digest_verified
    assert "not installed" in result.detail


def test_apply_update_installs_after_verifying(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    payload = b"package-bytes"
    release = make_release(
        tmp_path, payload, digest="sha256:" + hashlib.sha256(payload).hexdigest()
    )
    stub_download(monkeypatch, payload)
    installed: list[Path] = []
    monkeypatch.setattr(
        upgrade, "install_package", lambda path, **_: installed.append(path)
    )
    monkeypatch.setattr(upgrade, "sync_support_dir", lambda: True)
    monkeypatch.setattr(upgrade, "restart_watcher", lambda: True)

    result = upgrade.apply_update(release)
    assert result.installed
    assert result.digest_verified
    assert result.watcher_restarted
    assert installed and installed[0].name == release.asset_name


def test_apply_update_aborts_on_a_bad_digest_before_installing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    release = make_release(tmp_path, b"x", digest="sha256:" + "0" * 64)
    stub_download(monkeypatch, b"tampered")

    def forbidden(*_: object, **__: object) -> None:
        raise AssertionError("a failed checksum must stop before installing")

    monkeypatch.setattr(upgrade, "install_package", forbidden)
    with pytest.raises(core.ClamshellError):
        upgrade.apply_update(release)


def test_apply_update_cleans_up_its_staging_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    payload = b"package-bytes"
    release = make_release(
        tmp_path, payload, digest="sha256:" + hashlib.sha256(payload).hexdigest()
    )
    staged: list[Path] = []

    def fake(release: Release, destination: Path) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(payload)
        staged.append(destination.parent)
        return destination

    monkeypatch.setattr(upgrade, "download_release", fake)
    monkeypatch.setattr(upgrade, "install_package", lambda *_, **__: None)
    monkeypatch.setattr(upgrade, "sync_support_dir", lambda: True)
    monkeypatch.setattr(upgrade, "restart_watcher", lambda: False)
    upgrade.apply_update(release)
    assert staged and not staged[0].exists()


def test_restart_watcher_does_nothing_without_a_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(upgrade, "read_state", lambda: core.TimerState(None, 0, False))
    assert upgrade.restart_watcher() is False


def test_restart_watcher_rearms_a_dead_session_without_sleep_disabled(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        upgrade,
        "read_state",
        lambda: core.TimerState(deadline=None, floor=0, watching=True),
    )
    monkeypatch.setattr(upgrade, "sleep_disabled", lambda: False)
    cancelled: list[bool] = []
    monkeypatch.setattr(upgrade, "cancel_timer", lambda: cancelled.append(True))
    assert upgrade.restart_watcher() is False
    assert cancelled == [True]


def test_restart_watcher_keeps_the_remaining_time(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    deadline = int(core.time.time()) + REMAINING_SECONDS
    monkeypatch.setattr(
        upgrade,
        "read_state",
        lambda: core.TimerState(deadline=deadline, floor=FLOOR_PERCENT, watching=True),
    )
    monkeypatch.setattr(upgrade, "sleep_disabled", lambda: True)
    scheduled: list[tuple[int | None, int]] = []
    monkeypatch.setattr(
        upgrade,
        "schedule_auto_off",
        lambda seconds, floor: scheduled.append((seconds, floor)),
    )
    assert upgrade.restart_watcher() is True
    assert scheduled and 0 < scheduled[0][0] <= REMAINING_SECONDS
    assert scheduled[0][1] == FLOOR_PERCENT


def test_sync_support_dir_reports_when_no_source_exists(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(upgrade, "LIB_DIR", tmp_path / "missing-lib")
    monkeypatch.setattr(upgrade, "SUPPORT_DIR", tmp_path / "missing-support")
    assert upgrade.sync_support_dir() is False


def test_installed_sources_dir_prefers_the_library_layout(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    library = tmp_path / "lib"
    library.mkdir()
    monkeypatch.setattr(upgrade, "LIB_DIR", library)
    assert upgrade.installed_sources_dir() == library
