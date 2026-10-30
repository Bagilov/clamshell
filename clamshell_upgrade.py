"""Downloading and applying a clamshell update.

Split from :mod:`clamshell_update` because this half mutates the system: it
downloads the installer, verifies its checksum and hands it to the macOS
installer. The conventions it follows:

* **Verify before install.** The release's ``sha256`` digest is checked against
  the downloaded bytes; a mismatch aborts. A release without a digest is
  refused unless the caller explicitly opts out, so the default path never
  installs unverified code.
* **One admin prompt, at the moment of consent.** The install runs through the
  same GUI administrator prompt as ``clamshell install``, not a background
  escalation.
* **Keep the session alive.** A running keep-awake session is re-armed after the
  upgrade, so the new watcher code takes over without restoring sleep.
* **Stage in a private temp dir.** The package is downloaded to a fresh
  ``mkdtemp`` directory and removed afterwards, so nothing is left behind and
  no predictable path can be pre-created by another process.
"""

from __future__ import annotations

import hashlib
import shutil
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from clamshell_core import (
    DEFAULT_TIMEOUT,
    LIB_DIR,
    SUPPORT_DIR,
    ClamshellError,
    cancel_timer,
    read_state,
    run,
    schedule_auto_off,
    sleep_disabled,
)
from clamshell_privileged import admin_shell, install_sources
from clamshell_release import Release

INSTALLER = Path("/usr/sbin/installer")
CURL = Path("/usr/bin/curl")
#: How much of the installer is read per read call while hashing.
_CHUNK = 1024 * 1024


@dataclass(frozen=True)
class UpgradeResult:
    """Outcome of applying an update.

    Attributes:
        version: Version that was installed.
        installed: Whether the installer ran successfully.
        asset_name: File name of the installer that was applied.
        digest_verified: Whether the installer's checksum was verified first.
        watcher_restarted: Whether an active session's watcher was re-armed.
        detail: Extra text for the caller, such as a dry-run summary.
    """

    version: str
    installed: bool
    asset_name: str
    digest_verified: bool
    watcher_restarted: bool
    detail: str = ""

    def as_json(self) -> dict:
        """Render the result as the ``clamshell update --install --json`` payload."""
        return {
            "version": self.version,
            "installed": self.installed,
            "assetName": self.asset_name,
            "digestVerified": self.digest_verified,
            "watcherRestarted": self.watcher_restarted,
            "detail": self.detail,
        }


def sha256_of(path: Path) -> str:
    """Return the hex sha256 of a file, read in chunks.

    Args:
        path: File to hash. Installers are small, but chunking avoids loading a
            whole file into memory and keeps the helper reusable.

    Returns:
        Lowercase hexadecimal digest.
    """
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(_CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def download_release(release: Release, destination: Path) -> Path:
    """Download a release's installer asset to ``destination``.

    Args:
        release: Release whose asset should be fetched.
        destination: Path to write the installer to.

    Returns:
        The written path.

    Raises:
        ClamshellError: If the asset URL is missing or the download fails.
    """
    if not release.asset_url:
        raise ClamshellError(f"release {release.version} has no installer asset")
    if not CURL.exists():
        raise ClamshellError(f"missing {CURL}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    run(
        [
            str(CURL),
            "-fsSL",
            "--max-time",
            str(max(int(DEFAULT_TIMEOUT), 600)),
            "-o",
            str(destination),
            release.asset_url,
        ],
        check=True,
    )
    if not destination.exists() or destination.stat().st_size == 0:
        raise ClamshellError("downloaded installer is empty")
    return destination


def verify_download(path: Path, release: Release, *, allow_unverified: bool) -> bool:
    """Verify a downloaded installer against the release digest.

    Args:
        path: Downloaded installer.
        release: Release the installer was fetched for.
        allow_unverified: Whether to proceed when the release carries no digest.

    Returns:
        ``True`` when a digest was present and matched, ``False`` when no digest
        was available and the caller allowed proceeding without one.

    Raises:
        ClamshellError: If the digest is missing and not allowed, or it does not
            match the downloaded bytes.
    """
    expected = release.digest_hex
    if expected is None:
        if allow_unverified:
            return False
        raise ClamshellError(
            f"release {release.version} has no sha256 digest; "
            "pass --allow-unverified to install anyway"
        )
    actual = sha256_of(path)
    if actual != expected:
        raise ClamshellError(
            f"checksum mismatch for {release.asset_name}: "
            f"expected {expected}, got {actual}"
        )
    return True


def install_package(path: Path, *, use_gui_prompt: bool = True) -> None:
    """Install a ``.pkg`` with the macOS installer.

    Args:
        path: Package to install.
        use_gui_prompt: When true, escalate through a single GUI administrator
            prompt (the app has no terminal); when false, require an already
            privileged context or a cached ``sudo``.

    Raises:
        ClamshellError: If the installer is missing or the install fails.
    """
    if not INSTALLER.exists():
        raise ClamshellError(f"missing {INSTALLER}")
    if use_gui_prompt:
        admin_shell(f"{INSTALLER} -pkg {path} -target /")
        return
    run(["sudo", "-n", str(INSTALLER), "-pkg", str(path), "-target", "/"])


def apply_update(
    release: Release,
    *,
    allow_unverified: bool = False,
    dry_run: bool = False,
    use_gui_prompt: bool = True,
) -> UpgradeResult:
    """Download, verify and install a release, then re-sync the local install.

    Args:
        release: Release to apply.
        allow_unverified: Whether to install when the release has no digest.
        dry_run: When true, download and verify but do not install.
        use_gui_prompt: Whether to escalate through a GUI admin prompt.

    Returns:
        An :class:`UpgradeResult` describing what happened.

    Raises:
        ClamshellError: If the download, verification or install fails.
    """
    staging = Path(tempfile.mkdtemp(prefix="clamshell-upgrade."))
    try:
        package = staging / (release.asset_name or f"Clamshell-{release.version}.pkg")
        download_release(release, package)
        verified = verify_download(package, release, allow_unverified=allow_unverified)
        if dry_run:
            return UpgradeResult(
                version=release.version,
                installed=False,
                asset_name=release.asset_name,
                digest_verified=verified,
                watcher_restarted=False,
                detail=f"verified {package.name}; not installed (dry run)",
            )
        install_package(package, use_gui_prompt=use_gui_prompt)
        sync_support_dir()
        restarted = restart_watcher()
        return UpgradeResult(
            version=release.version,
            installed=True,
            asset_name=release.asset_name,
            digest_verified=verified,
            watcher_restarted=restarted,
            detail=f"installed {release.version}",
        )
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def installed_sources_dir() -> Path | None:
    """Return the directory the installed CLI is running from, if discoverable.

    A package install keeps the modules under :data:`LIB_DIR`; a user-run
    ``install`` copies them into the support directory. Both are valid upgrade
    targets, so the caller can tell which layout is live.

    Returns:
        The library directory when present, else the support directory when it
        holds the CLI, else None.
    """
    if LIB_DIR.is_dir():
        return LIB_DIR
    if (SUPPORT_DIR / "clamshell_cli.py").exists():
        return SUPPORT_DIR
    return None


def sync_support_dir() -> bool:
    """Copy the freshly installed sources into the user-owned support directory.

    The menu bar app and the user-owned launcher read the support directory, so
    a package that updated ``/usr/local`` alone would leave the app on the old
    code. The copy is user-owned and needs no privileges.

    Returns:
        ``True`` when the sources were synced, ``False`` when no source
        directory could be found to sync from.
    """
    source = installed_sources_dir()
    if source is None:
        return False
    install_sources(source)
    return True


def restart_watcher() -> bool:
    """Re-arm an active session so the new watcher code takes over.

    The watcher runs as a transient launchd job reading the script it started
    with, so an upgrade would otherwise leave the old lid-guard logic running
    until the session ends. Sleep is left disabled: the session is re-armed with
    the time that remains, not restarted.

    Returns:
        ``True`` when a session was re-armed, ``False`` when none was active.
    """
    stored = read_state()
    if not (stored.watching or stored.deadline is not None or stored.floor > 0):
        return False
    if not sleep_disabled():
        # No live sleep session: drop any stale state instead of re-arming.
        cancel_timer()
        return False
    remaining = None
    if stored.deadline is not None:
        remaining = max(1, stored.deadline - int(time.time()))
    schedule_auto_off(remaining, stored.floor)
    return True
