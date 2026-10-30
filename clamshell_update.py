"""Update checking for clamshell mode.

Checks the GitHub releases API for a newer version, with the conventions a
self-updating app is expected to follow:

* the check is **throttled** (once a day unless forced), so the CLI is not a
  network client on every menu refresh;
* it **never blocks or breaks** the caller: a failed check leaves the previous
  result in place and reports the reason instead of raising into the app;
* it only **reports**; downloading and installing live in
  :mod:`clamshell_upgrade` and always need explicit consent;
* it **prefers a stable release** over a pre-release, falling back to the newest
  pre-release so a project that marks everything pre-release still updates.

The reduced releases are cached under the support directory, so an offline
machine still sees the last known state.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path

from clamshell_core import DEFAULT_TIMEOUT, SUPPORT_DIR, ClamshellError, run
from clamshell_release import (
    RELEASES_API,
    Release,
    ReleaseError,
    compare_versions,
    normalize_tag,
    parse_version,
    select_release,
)

CURL = Path("/usr/bin/curl")
#: Where the last check is cached. User-owned, so writing needs no privileges.
CACHE_PATH = SUPPORT_DIR / "update-check.json"
#: A day between automatic checks: often enough to notice a release, rare enough
#: that a menu bar app is not a polling client.
CHECK_INTERVAL = 24 * 60 * 60


@dataclass(frozen=True)
class UpdateInfo:
    """Outcome of an update check.

    Attributes:
        current: The running version the check compared against.
        latest: Newest version seen in the release list, or None when unknown.
        release: The release to offer, or None when already up to date.
        checked_at: Epoch seconds of the check that produced this result.
        from_cache: Whether the result came from the throttle cache.
        error: Reason the check failed, or None on success.
    """

    current: str
    latest: str | None
    release: Release | None
    checked_at: int
    from_cache: bool
    error: str | None = None

    @property
    def update_available(self) -> bool:
        """Whether a newer release is available to install."""
        return self.release is not None

    def as_json(self) -> dict:
        """Render the result as the ``clamshell update --json`` payload.

        Returns:
            A JSON-serialisable mapping with camelCase keys, matching the rest of
            the CLI's machine-readable output.
        """
        payload: dict = {
            "current": self.current,
            "latest": self.latest,
            "updateAvailable": self.update_available,
            "checkedAt": self.checked_at,
            "fromCache": self.from_cache,
        }
        if self.error is not None:
            payload["error"] = self.error
        if self.release is not None:
            payload["release"] = {
                "version": self.release.version,
                "tag": self.release.tag,
                "name": self.release.name,
                "prerelease": self.release.prerelease,
                "pageUrl": self.release.page_url,
                "assetName": self.release.asset_name,
                "assetUrl": self.release.asset_url,
                "assetSize": self.release.asset_size,
                "hasDigest": self.release.has_digest,
            }
        return payload


def check_for_update(
    current: str,
    *,
    force: bool = False,
    now: float | None = None,
) -> UpdateInfo:
    """Return the update state for ``current``, using the cache when fresh.

    Args:
        current: The running version to compare against.
        force: Bypass the throttle and query the network even when the cache is
            still within :data:`CHECK_INTERVAL`.
        now: Current epoch seconds, for deterministic tests.

    Returns:
        The check result. A network or parse failure is reported in
        ``UpdateInfo.error`` with ``release`` left None, never raised.

    Raises:
        ClamshellError: If ``current`` is not a semantic version.
    """
    moment = int(now if now is not None else time.time())
    try:
        parse_version(current)
    except ReleaseError as error:
        raise ClamshellError(str(error)) from error
    cached = read_cache()
    if not force and cached is not None:
        age = moment - cached.get("checkedAt", 0)
        if 0 <= age < CHECK_INTERVAL:
            return _info_from_cache(cached, current, moment)
    try:
        payload = fetch_releases()
    except ClamshellError as error:
        # Keep the last good cache rather than erasing it: an offline machine
        # should still know about a release it was already told about.
        if cached is not None:
            stale = _info_from_cache(cached, current, moment)
            return UpdateInfo(
                current=current,
                latest=stale.latest,
                release=stale.release,
                checked_at=stale.checked_at,
                from_cache=True,
                error=str(error),
            )
        return UpdateInfo(
            current=current,
            latest=None,
            release=None,
            checked_at=moment,
            from_cache=False,
            error=str(error),
        )
    slim = slim_payload(payload)
    write_cache(slim, moment, current)
    return _info_from_releases(slim, current, moment, from_cache=False)


def fetch_releases() -> list[dict]:
    """Fetch the releases list from the GitHub API.

    Returns:
        The decoded releases array, newest first.

    Raises:
        ClamshellError: If ``curl`` fails, times out or returns invalid JSON.
    """
    if not CURL.exists():
        raise ClamshellError(f"missing {CURL}")
    result = run(
        [
            str(CURL),
            "-fsSL",
            "--max-time",
            str(int(DEFAULT_TIMEOUT)),
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "User-Agent: clamshell-self-update",
            RELEASES_API,
        ],
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or f"curl exited {result.returncode}"
        raise ClamshellError(f"cannot reach the release list: {detail}")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ClamshellError(f"invalid release list: {error}") from error
    if not isinstance(payload, list):
        raise ClamshellError("unexpected release list format")
    return payload


def slim_payload(payload: list[dict]) -> list[dict]:
    """Reduce a releases payload to the fields an update needs.

    Keeping only what is used makes the cache small and means the cached copy is
    interpreted by exactly the same code as a fresh response.

    Args:
        payload: Decoded releases API array.

    Returns:
        A list of reduced release mappings.
    """
    slim: list[dict] = []
    for entry in payload:
        if not isinstance(entry, dict):
            continue
        assets = [
            {
                "name": asset.get("name", ""),
                "browser_download_url": asset.get("browser_download_url", ""),
                "size": asset.get("size", 0),
                "digest": asset.get("digest", ""),
            }
            for asset in entry.get("assets") or []
            if isinstance(asset, dict)
        ]
        slim.append(
            {
                "tag_name": entry.get("tag_name", ""),
                "name": entry.get("name", ""),
                "body": entry.get("body", ""),
                "prerelease": bool(entry.get("prerelease")),
                "html_url": entry.get("html_url", ""),
                "assets": assets,
            }
        )
    return slim


def read_cache() -> dict | None:
    """Return the cached check result, or None when absent or unreadable."""
    if not CACHE_PATH.exists():
        return None
    try:
        payload = json.loads(CACHE_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def write_cache(candidates: list[dict], moment: int, current: str) -> None:
    """Persist the reduced candidates and the time of the check.

    Writing never raises: a cache that cannot be written only costs an extra
    network check, and must not fail the command the user asked for.
    """
    payload = {"checkedAt": moment, "current": current, "candidates": candidates}
    try:
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        CACHE_PATH.write_text(json.dumps(payload))
    except OSError:
        pass


def _info_from_cache(cached: dict, current: str, moment: int) -> UpdateInfo:
    """Build an :class:`UpdateInfo` from a cached payload."""
    candidates = cached.get("candidates") or []
    checked_at = int(cached.get("checkedAt") or moment)
    if not isinstance(candidates, list):
        candidates = []
    return _info_from_releases(candidates, current, checked_at, from_cache=True)


def _info_from_releases(
    candidates: list[dict],
    current: str,
    checked_at: int,
    *,
    from_cache: bool,
) -> UpdateInfo:
    """Select the offered release and summarise the newest known version."""
    latest: str | None = None
    for entry in candidates:
        try:
            version = normalize_tag(str(entry.get("tag_name", "")))
        except ReleaseError:
            # A malformed cached entry must not abort the whole check.
            continue
        if latest is None or compare_versions(version, latest) > 0:
            latest = version
    release = select_release(candidates, current)
    return UpdateInfo(
        current=current,
        latest=latest,
        release=release,
        checked_at=checked_at,
        from_cache=from_cache,
    )
