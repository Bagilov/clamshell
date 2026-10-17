"""Privileged installation helpers for clamshell mode.

Splitting these from :mod:`clamshell_core` keeps the day-to-day commands free
of root-installation logic and keeps each module within the size limit.

Every privileged write goes through a single GUI administrator prompt built by
:func:`admin_shell`. File content is base64-encoded inline, so no shared
world-writable staging path is involved.
"""

from __future__ import annotations

import base64
import os
import pwd
import re
import shlex
import sys
from collections.abc import Sequence
from pathlib import Path

from clamshell_core import (
    CLI_PATH,
    HELPER_NAME,
    MODULE_GLOB,
    SUDOERS_PATH,
    SUPPORT_DIR,
    TIMER_NAME,
    ClamshellError,
    run,
)

INTERPRETER_CANDIDATES = (Path("/usr/bin/python3"), Path(sys.executable))


def current_user() -> str:
    """Return the invoking account name, validated for shell and sudoers use.

    The sudoers rule and root shell commands embed this value, so it is read
    from the OS rather than the environment and rejected unless it matches the
    POSIX account-name grammar.

    Returns:
        The current account name.

    Raises:
        ClamshellError: If the name cannot be determined or is unsafe.
    """
    try:
        name = pwd.getpwuid(os.getuid()).pw_name
    except KeyError as error:
        raise ClamshellError(f"cannot determine current user: {error}") from error
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", name):
        raise ClamshellError(f"unsafe account name: {name!r}")
    return name


def pick_interpreter(candidates: Sequence[Path] | None = None) -> str:
    """Return the first existing interpreter from ``candidates``.

    Preference goes to the system framework Python, because GUI apps cannot
    read user-owned virtualenvs under TCC-protected folders.

    Args:
        candidates: Interpreter paths to probe, defaulting to the system
            Python followed by the running interpreter.

    Returns:
        Absolute path of a usable interpreter.

    Raises:
        ClamshellError: If none of the candidates exist.
    """
    probes = candidates if candidates is not None else INTERPRETER_CANDIDATES
    for candidate in probes:
        if candidate.exists():
            return str(candidate)
    raise ClamshellError("no usable python3 interpreter found")


def admin_shell(script: str) -> None:
    """Run a shell script as root via a single GUI admin prompt.

    Args:
        script: Shell commands executed with administrator privileges.

    Raises:
        ClamshellError: If the user cancels or the privileged script fails.
    """
    escaped = script.replace("\\", "\\\\").replace('"', '\\"')
    apple = f'do shell script "{escaped}" with administrator privileges'
    result = run(["osascript", "-e", apple], check=False, timeout=None)
    if result.returncode != 0:
        raise ClamshellError(result.stderr.strip() or "administrator action cancelled")


def write_command(target: str, content: str, mode: str = "755") -> str:
    """Build a shell fragment that writes ``content`` to ``target`` as root.

    The content is base64-encoded inline, so no world-writable staging path is
    involved and there is nothing for another local process to substitute.

    Args:
        target: Absolute destination path.
        content: Exact file content to write.
        mode: Octal permission string applied after the write.

    Returns:
        A shell fragment suitable for :func:`admin_shell`.
    """
    payload = base64.b64encode(content.encode()).decode()
    parent = shlex.quote(str(Path(target).parent))
    return (
        f"mkdir -p {parent} && "
        f"printf '%s' '{payload}' | base64 -d > {target} && "
        f"chown root:wheel {target} && chmod {mode} {target}"
    )


def sudoers_command(rule: str) -> str:
    """Build a shell fragment that installs a validated sudoers rule.

    A malformed file in ``/etc/sudoers.d`` makes ``sudo`` refuse every command,
    so the rule is validated with ``visudo -cf`` first and only installed once
    it parses.

    Args:
        rule: Single sudoers rule line.

    Returns:
        A shell fragment suitable for :func:`admin_shell`.
    """
    payload = base64.b64encode(f"{rule}\n".encode()).decode()
    return (
        "set -e; "
        "tmp=$(mktemp /tmp/.clamshell-rule.XXXXXX); "
        f"printf '%s' '{payload}' | base64 -d > \"$tmp\"; "
        'chmod 600 "$tmp"; '
        'visudo -cf "$tmp"; '
        f'install -m 440 -o root -g wheel "$tmp" {SUDOERS_PATH}; '
        'rm -f "$tmp"'
    )


def install_sources(source_dir: Path) -> Path:
    """Copy the CLI sources and helper into the user's support directory.

    ``~/Library/Application Support`` is user-owned and not TCC-protected, so
    the files can be written without admin rights yet stay readable by the
    sandboxed menu bar app. The repository checkout lives under Documents and
    is unreadable from a GUI app.

    The privileged helper is copied too, so the installed CLI can still run
    ``install`` later without reaching back into the checkout. A user-owned
    launcher is written as well, so the app and CLI keep working even before
    the privileged ``PATH`` copy is approved.

    Args:
        source_dir: Directory holding the Python modules and helper script.

    Returns:
        The directory the sources were installed into.

    Raises:
        ClamshellError: If a source file is missing.
    """
    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    names = [path.name for path in sorted(source_dir.glob(MODULE_GLOB))]
    names.extend([HELPER_NAME, TIMER_NAME])
    for name in names:
        source = source_dir / name
        if not source.exists():
            raise ClamshellError(f"missing {source}")
        destination = SUPPORT_DIR / name
        destination.write_text(source.read_text())
        if name in (HELPER_NAME, TIMER_NAME):
            destination.chmod(0o755)
    local = SUPPORT_DIR / "clamshell"
    entry = SUPPORT_DIR / "clamshell_cli.py"
    local.write_text(f'#!/bin/sh\nexec "{pick_interpreter()}" "{entry}" "$@"\n')
    local.chmod(0o755)
    return SUPPORT_DIR


def install_privileged(helper_source: Path, rule: str) -> None:
    """Install the helper, launcher and sudoers rule in one admin prompt.

    The sources are staged first into the user's support directory, which needs
    no privileges; only the root-owned helper, the ``PATH`` launcher and the
    sudoers rule are written through a single GUI prompt.

    Args:
        helper_source: Repository path of the privileged helper script.
        rule: Single sudoers rule line granting only that helper.

    Raises:
        ClamshellError: If ``helper_source`` is missing or install fails.
    """
    if not helper_source.exists():
        raise ClamshellError(f"missing {helper_source}")
    modules = install_sources(helper_source.parent)
    interpreter = pick_interpreter()
    launcher = (
        f'#!/bin/sh\nexec "{interpreter}" "{modules / "clamshell_cli.py"}" "$@"\n'
    )
    fragments = [
        write_command(
            str(Path("/usr/local/sbin/clamshell-helper")), helper_source.read_text()
        ),
        write_command(str(CLI_PATH), launcher),
        sudoers_command(rule),
    ]
    admin_shell("set -e; " + "; ".join(fragments))


def uninstall_command() -> str:
    """Build a shell fragment that removes root-owned files and restores sleep.

    Sleep is re-enabled directly with ``pmset`` rather than through the helper,
    so a missing or already-deleted helper cannot leave sleep disabled.

    Returns:
        A shell fragment suitable for :func:`admin_shell`.
    """
    return (
        "pmset disablesleep 0 >/dev/null 2>&1 || true; "
        f"rm -f /usr/local/sbin/clamshell-helper {SUDOERS_PATH} {CLI_PATH}; "
        f"rm -f /var/log/clamshell-helper.log"
    )
