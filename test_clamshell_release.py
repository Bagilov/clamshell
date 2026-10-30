"""Tests for semantic versioning and release selection.

Cover the semver precedence rules an update check depends on, asset picking
(including sidecar rejection) and the "prefer stable, fall back to pre-release"
selection, which is what lets a project marking every release as a pre-release
still update.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_release as release

DIGEST = "sha256:" + "a" * 64
ASSET_SIZE = 1234


def make_release(
    tag: str,
    *,
    prerelease: bool = False,
    asset: str | None = None,
    digest: str = DIGEST,
) -> dict:
    """Build a minimal GitHub release mapping."""
    name = asset if asset is not None else f"Clamshell-{tag.lstrip('v')}.pkg"
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
                "size": ASSET_SIZE,
                "digest": digest,
            }
        ],
    }


def test_parse_version_accepts_optional_v_prefix() -> None:
    assert release.parse_version("v1.2.3") == (1, 2, 3, "")
    assert release.parse_version("1.2.3") == (1, 2, 3, "")


def test_parse_version_rejects_non_semver() -> None:
    with pytest.raises(release.ReleaseError):
        release.parse_version("1.2")
    with pytest.raises(release.ReleaseError):
        release.parse_version("latest")


def test_compare_versions_orders_by_numeric_fields() -> None:
    assert release.compare_versions("0.9.0", "0.10.0") == -1
    assert release.compare_versions("1.0.0", "0.9.9") == 1
    assert release.compare_versions("1.0.0", "1.0.0") == 0


def test_compare_versions_prefers_final_over_prerelease() -> None:
    assert release.compare_versions("1.0.0", "1.0.0-rc.1") == 1
    assert release.compare_versions("1.0.0-beta", "1.0.0") == -1


def test_compare_versions_orders_prerelease_fields_numerically() -> None:
    assert release.compare_versions("1.0.0-alpha.2", "1.0.0-alpha.10") == -1
    assert release.compare_versions("1.0.0-alpha", "1.0.0-alpha.1") == -1
    assert release.compare_versions("1.0.0-alpha.1", "1.0.0-beta") == -1


def test_compare_versions_ignores_build_metadata() -> None:
    assert release.compare_versions("1.0.0+build.1", "1.0.0+build.2") == 0


def test_normalize_tag_strips_only_a_leading_v() -> None:
    assert release.normalize_tag("v0.4.0") == "0.4.0"
    assert release.normalize_tag("0.4.0") == "0.4.0"


def test_select_asset_prefers_pkg_and_skips_sidecars() -> None:
    assets = [
        {"name": "Clamshell-1.0.0.pkg.sha256"},
        {"name": "Clamshell-1.0.0.pkg.sig"},
        {"name": "notes.txt"},
        {"name": "Clamshell-1.0.0.pkg"},
    ]
    assert release.select_asset(assets)["name"] == "Clamshell-1.0.0.pkg"


def test_select_asset_returns_none_without_a_package() -> None:
    assert release.select_asset([{"name": "notes.txt"}]) is None
    assert release.select_asset([]) is None


def test_to_release_reads_digest_and_size() -> None:
    parsed = release.to_release(make_release("v0.4.0"))
    assert parsed is not None
    assert parsed.version == "0.4.0"
    assert parsed.asset_name == "Clamshell-0.4.0.pkg"
    assert parsed.asset_size == ASSET_SIZE
    assert parsed.has_digest
    assert parsed.digest_hex == "a" * 64


def test_to_release_ignores_a_malformed_entry() -> None:
    assert release.to_release({"tag_name": "not-a-version", "assets": []}) is None
    assert release.to_release({"tag_name": "v1.0.0", "assets": []}) is None


def test_to_release_without_digest_reports_none() -> None:
    parsed = release.to_release(make_release("v0.4.0", digest=""))
    assert parsed is not None
    assert not parsed.has_digest
    assert parsed.digest_hex is None


def test_select_release_returns_none_when_current_is_newest() -> None:
    payload = [make_release("v0.3.0"), make_release("v0.2.0")]
    assert release.select_release(payload, "0.3.0") is None


def test_select_release_picks_the_newest_final_release() -> None:
    payload = [make_release("v0.5.0", prerelease=True), make_release("v0.4.0")]
    chosen = release.select_release(payload, "0.3.0")
    assert chosen is not None
    assert chosen.version == "0.4.0"


def test_select_release_falls_back_to_a_prerelease() -> None:
    payload = [make_release("v0.5.0", prerelease=True)]
    chosen = release.select_release(payload, "0.3.0")
    assert chosen is not None
    assert chosen.version == "0.5.0"


def test_select_release_skips_releases_without_an_installer() -> None:
    payload = [
        {"tag_name": "v0.5.0", "prerelease": False, "assets": []},
        make_release("v0.4.0"),
    ]
    chosen = release.select_release(payload, "0.3.0")
    assert chosen is not None
    assert chosen.version == "0.4.0"


def test_select_release_rejects_a_bad_current_version() -> None:
    with pytest.raises(release.ReleaseError):
        release.select_release([make_release("v0.4.0")], "unknown")
