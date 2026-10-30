"""Tests for the update check: throttling, caching and failure handling.

The network is never touched: ``fetch_releases`` is replaced with a stub that
returns a canned payload or raises. The cache path is redirected into a
temporary directory, so a test can never read or write the user's real one.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_core as core
import clamshell_update as update

DIGEST = "sha256:" + "b" * 64
HOUR = 3600


def release_entry(tag: str, *, prerelease: bool = False) -> dict:
    """Build one slim release entry as the cache stores it."""
    name = f"Clamshell-{tag.lstrip('v')}.pkg"
    return {
        "tag_name": tag,
        "name": tag,
        "body": "",
        "prerelease": prerelease,
        "html_url": f"https://example.test/{tag}",
        "assets": [
            {
                "name": name,
                "browser_download_url": f"https://example.test/{name}",
                "size": 10,
                "digest": DIGEST,
            }
        ],
    }


@pytest.fixture(autouse=True)
def isolate_cache(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep the cache file inside the test's temporary directory."""
    monkeypatch.setattr(update, "CACHE_PATH", tmp_path / "update-check.json")


def test_check_uses_the_network_on_a_cold_cache(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.4.0")])
    info = update.check_for_update("0.3.0", now=1000.0)
    assert info.update_available
    assert info.release is not None
    assert info.release.version == "0.4.0"
    assert not info.from_cache
    assert info.error is None


def test_check_serves_a_fresh_cache_without_the_network(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.4.0")])
    first = update.check_for_update("0.3.0", now=1000.0)
    assert first.release is not None

    def explode() -> list[dict]:
        raise AssertionError("the network must not be touched while the cache is fresh")

    monkeypatch.setattr(update, "fetch_releases", explode)
    second = update.check_for_update("0.3.0", now=1000.0 + HOUR)
    assert second.from_cache
    assert second.release is not None
    assert second.release.version == "0.4.0"


def test_check_refreshes_an_expired_cache(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.4.0")])
    update.check_for_update("0.3.0", now=1000.0)
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.5.0")])
    refreshed = update.check_for_update("0.3.0", now=1000.0 + update.CHECK_INTERVAL + 1)
    assert not refreshed.from_cache
    assert refreshed.release is not None
    assert refreshed.release.version == "0.5.0"


def test_force_bypasses_a_fresh_cache(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.4.0")])
    update.check_for_update("0.3.0", now=1000.0)
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.5.0")])
    forced = update.check_for_update("0.3.0", force=True, now=1000.0 + HOUR)
    assert forced.release is not None
    assert forced.release.version == "0.5.0"


def test_no_update_reports_up_to_date(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.3.0")])
    info = update.check_for_update("0.3.0", now=1000.0)
    assert not info.update_available
    assert info.release is None
    assert info.error is None


def test_a_failed_check_reports_the_error(monkeypatch: pytest.MonkeyPatch) -> None:
    def offline() -> list[dict]:
        raise core.ClamshellError("cannot reach the release list")

    monkeypatch.setattr(update, "fetch_releases", offline)
    info = update.check_for_update("0.3.0", now=1000.0)
    assert info.error is not None
    assert info.release is None


def test_a_failed_check_keeps_the_last_known_release(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.4.0")])
    update.check_for_update("0.3.0", now=1000.0)

    def offline() -> list[dict]:
        raise core.ClamshellError("offline")

    monkeypatch.setattr(update, "fetch_releases", offline)
    stale = update.check_for_update(
        "0.3.0", force=True, now=1000.0 + update.CHECK_INTERVAL + 1
    )
    assert stale.error == "offline"
    assert stale.release is not None
    assert stale.release.version == "0.4.0"
    assert stale.from_cache


def test_cache_survives_a_corrupt_file(monkeypatch: pytest.MonkeyPatch) -> None:
    update.CACHE_PATH.write_text("{not json")
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.4.0")])
    info = update.check_for_update("0.3.0", now=1000.0)
    assert info.release is not None
    assert info.error is None


def test_slim_payload_keeps_only_the_fields_an_update_needs() -> None:
    slim = update.slim_payload(
        [
            {
                "tag_name": "v0.4.0",
                "name": "n",
                "body": "notes",
                "prerelease": False,
                "html_url": "u",
                "assets": [{"name": "a.pkg", "browser_download_url": "d", "size": 5}],
                "extra": "dropped",
            }
        ]
    )
    assert list(slim[0]) == [
        "tag_name",
        "name",
        "body",
        "prerelease",
        "html_url",
        "assets",
    ]
    assert slim[0]["assets"][0] == {
        "name": "a.pkg",
        "browser_download_url": "d",
        "size": 5,
        "digest": "",
    }


def test_write_cache_never_raises_on_an_unwritable_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(update, "CACHE_PATH", Path("/proc/does-not-exist/update.json"))
    update.write_cache([release_entry("v0.4.0")], 1000, "0.3.0")


def test_json_payload_has_camel_case_keys(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(update, "fetch_releases", lambda: [release_entry("v0.4.0")])
    payload = update.check_for_update("0.3.0", now=1000.0).as_json()
    assert payload["updateAvailable"] is True
    assert payload["release"]["hasDigest"] is True
    assert json.loads(json.dumps(payload)) == payload


def test_check_rejects_a_non_semver_current() -> None:
    with pytest.raises(core.ClamshellError):
        update.check_for_update("development", now=1000.0)
