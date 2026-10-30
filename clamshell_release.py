"""Release metadata handling for self-update.

Keeps the pure, network-free half of the update path: parsing semantic
versions, comparing them, and picking the right release and installer asset out
of a GitHub releases payload. Everything here takes already-decoded JSON, so it
is fully unit-testable without touching the network.

The network half lives in :mod:`clamshell_update`; downloading and installing
lives in :mod:`clamshell_upgrade`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

#: Canonical ``owner/name`` of the project on GitHub.
REPOSITORY = "Bagilov/clamshell"
#: Releases API endpoint, newest first. A page is enough: the newest release is
#: always at the top and only the newest newer-than-current candidate is used.
RELEASES_API = f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=20"

_VERSION_RE = re.compile(
    r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$"
)
_DIGEST_RE = re.compile(r"^sha256:([0-9a-fA-F]{64})$")
#: Asset suffixes that look like an installer but are metadata, not a package.
_ASSET_REJECT_SUFFIXES = (".sha256", ".sha256sum", ".sig", ".json", ".txt")


class ReleaseError(RuntimeError):
    """Raised when release metadata cannot be interpreted."""


@dataclass(frozen=True)
class Release:
    """A downloadable release, reduced to what an update needs.

    Attributes:
        version: Normalised version without the ``v`` prefix, e.g. ``0.4.0``.
        tag: Original git tag, e.g. ``v0.4.0``.
        name: Human-readable release title.
        notes: Release body, used for the changelog link and preview.
        prerelease: Whether GitHub marks the release as a pre-release.
        page_url: HTML URL of the release page.
        asset_name: File name of the installer asset.
        asset_url: Direct download URL of the installer asset.
        asset_size: Installer size in bytes, or 0 when it was not reported.
        digest: ``sha256:<hex>`` digest of the installer, or "" when absent.
    """

    version: str
    tag: str
    name: str
    notes: str
    prerelease: bool
    page_url: str
    asset_name: str
    asset_url: str
    asset_size: int
    digest: str

    @property
    def digest_hex(self) -> str | None:
        """The bare sha256 hex digest, or None when the release carries none."""
        match = _DIGEST_RE.match(self.digest)
        return match.group(1).lower() if match else None

    @property
    def has_digest(self) -> bool:
        """Whether a usable sha256 digest is available for verification."""
        return self.digest_hex is not None


def parse_version(text: str) -> tuple[int, int, int, str]:
    """Parse a version string into a comparable tuple.

    Args:
        text: Version such as ``0.4.0``, ``v1.2.3`` or ``1.0.0-beta.1``.

    Returns:
        ``(major, minor, patch, prerelease)`` where the last element is the
        empty string for a final release and the pre-release part otherwise.

    Raises:
        ReleaseError: If the text is not a recognised semantic version.
    """
    match = _VERSION_RE.match(text.strip())
    if match is None:
        raise ReleaseError(f"not a semantic version: {text!r}")
    major, minor, patch, prerelease, _build = match.groups()
    return (int(major), int(minor), int(patch), prerelease or "")


def compare_versions(left: str, right: str) -> int:
    """Compare two versions with semantic-versioning precedence.

    A pre-release sorts before its own final release (``1.0.0-beta`` <
    ``1.0.0``), and build metadata is ignored, per the semver specification.

    Args:
        left: Left-hand version string.
        right: Right-hand version string.

    Returns:
        ``-1`` when ``left`` is older, ``0`` when equal, ``1`` when newer.
    """
    left_parts = parse_version(left)
    right_parts = parse_version(right)
    if left_parts[:3] != right_parts[:3]:
        return -1 if left_parts[:3] < right_parts[:3] else 1
    left_pre = left_parts[3]
    right_pre = right_parts[3]
    if left_pre == right_pre:
        return 0
    if not left_pre:
        return 1
    if not right_pre:
        return -1
    return _compare_prerelease(left_pre, right_pre)


def _compare_prerelease(left: str, right: str) -> int:
    """Compare two pre-release identifiers field by field.

    Numeric fields compare numerically and rank below alphanumeric ones, so
    ``1.0.0-alpha.2`` precedes ``1.0.0-alpha.10`` precedes ``1.0.0-alpha.beta``.
    """
    left_fields = left.split(".")
    right_fields = right.split(".")
    for left_field, right_field in zip(left_fields, right_fields):
        if left_field == right_field:
            continue
        left_numeric = left_field.isdigit()
        right_numeric = right_field.isdigit()
        if left_numeric and right_numeric:
            return -1 if int(left_field) < int(right_field) else 1
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return -1 if left_field < right_field else 1
    if len(left_fields) == len(right_fields):
        return 0
    return -1 if len(left_fields) < len(right_fields) else 1


def select_asset(assets: list[dict]) -> dict | None:
    """Pick the installer asset from a release's asset list.

    Prefers a ``.pkg``, and skips sidecar files such as ``.pkg.sha256`` or
    ``.pkg.sig`` that also end in a package-like name.

    Args:
        assets: Decoded ``assets`` array of a GitHub release.

    Returns:
        The chosen asset mapping, or None when the release carries no installer.
    """
    for asset in assets:
        name = str(asset.get("name", ""))
        if not name.endswith(".pkg"):
            continue
        lowered = name.lower()
        if any(lowered.endswith(suffix) for suffix in _ASSET_REJECT_SUFFIXES):
            continue
        return asset
    return None


def to_release(payload: dict) -> Release | None:
    """Convert one GitHub release mapping into a :class:`Release`.

    Args:
        payload: A single element of the releases API array.

    Returns:
        The reduced release, or None when the payload has no usable tag or no
        installer asset, so a malformed entry cannot abort the whole check.
    """
    tag = str(payload.get("tag_name", ""))
    try:
        version = normalize_tag(tag)
    except ReleaseError:
        return None
    asset = select_asset(payload.get("assets") or [])
    if asset is None:
        return None
    digest = str(asset.get("digest") or "")
    return Release(
        version=version,
        tag=tag,
        name=str(payload.get("name") or tag),
        notes=str(payload.get("body") or ""),
        prerelease=bool(payload.get("prerelease")),
        page_url=str(payload.get("html_url") or ""),
        asset_name=str(asset.get("name") or ""),
        asset_url=str(asset.get("browser_download_url") or ""),
        asset_size=int(asset.get("size") or 0),
        digest=digest,
    )


def normalize_tag(tag: str) -> str:
    """Return the bare version of a release tag.

    Args:
        tag: Git tag such as ``v0.4.0`` or ``0.4.0``.

    Returns:
        The version without a leading ``v``.

    Raises:
        ReleaseError: If the tag is not a semantic version.
    """
    parse_version(tag)
    text = tag.strip()
    return text[1:] if text[:1] in ("v", "V") else text


def select_release(payload: list[dict], current: str) -> Release | None:
    """Choose the release to offer as an update.

    Only releases strictly newer than ``current`` are candidates. A final
    release is preferred over a pre-release; when nothing final is newer, the
    newest pre-release is offered instead, so a project that marks every release
    as a pre-release still updates.

    Args:
        payload: Decoded releases API array, newest first.
        current: The running version.

    Returns:
        The chosen release, or None when the project is already up to date.

    Raises:
        ReleaseError: If ``current`` is not a semantic version.
    """
    parse_version(current)
    releases = [r for r in (to_release(entry) for entry in payload) if r is not None]
    newer = [r for r in releases if compare_versions(r.version, current) > 0]
    if not newer:
        return None
    final = [r for r in newer if not r.prerelease]
    pool = final or newer
    return max(pool, key=lambda release: parse_version(release.version))
