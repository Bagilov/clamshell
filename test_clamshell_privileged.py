"""Tests for clamshell privileged-install helpers.

Run with: .venv/bin/python -m pytest clamshell/ -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_core as core
import clamshell_privileged as privileged


def test_current_user_returns_safe_account(monkeypatch: pytest.MonkeyPatch) -> None:
    class Pw:
        pw_name = "testuser"

    monkeypatch.setattr(privileged.pwd, "getpwuid", lambda uid: Pw())
    assert privileged.current_user() == "testuser"


def test_current_user_rejects_unsafe_name(monkeypatch: pytest.MonkeyPatch) -> None:
    class Pw:
        pw_name = "bad user\nroot ALL=(root) NOPASSWD: ALL"

    monkeypatch.setattr(privileged.pwd, "getpwuid", lambda uid: Pw())
    with pytest.raises(core.ClamshellError):
        privileged.current_user()


def test_current_user_errors_when_lookup_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    def explode(uid: int) -> None:
        raise KeyError(uid)

    monkeypatch.setattr(privileged.pwd, "getpwuid", explode)
    with pytest.raises(core.ClamshellError):
        privileged.current_user()


def test_pick_interpreter_prefers_first_candidate(tmp_path: Path) -> None:
    system = tmp_path / "python3"
    system.write_text("#!/bin/sh\n")
    assert privileged.pick_interpreter((system, tmp_path / "absent")) == str(system)


def test_pick_interpreter_errors_when_none_exist(tmp_path: Path) -> None:
    with pytest.raises(core.ClamshellError):
        privileged.pick_interpreter((tmp_path / "absent",))


def test_write_command_embeds_content_without_temp_staging() -> None:
    fragment = privileged.write_command("/usr/local/bin/demo", "hello\n")
    assert "base64 -d" in fragment
    assert "/tmp" not in fragment
    assert "chmod 755 /usr/local/bin/demo" in fragment


def test_write_command_creates_parent_directory() -> None:
    fragment = privileged.write_command("/usr/local/lib/demo/tool", "x")
    assert "mkdir -p /usr/local/lib/demo" in fragment


def test_sudoers_command_validates_before_install() -> None:
    fragment = privileged.sudoers_command("testuser ALL=(root) NOPASSWD: /bin/true")
    assert fragment.index("visudo -cf") < fragment.index("install -m 440")
    assert str(core.SUDOERS_PATH) in fragment


def test_admin_shell_waits_without_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: dict[str, object] = {}

    class Completed:
        returncode = 0
        stdout = ""
        stderr = ""

    def fake_run(argv: list[str], **kwargs: object) -> Completed:
        seen.update(kwargs)
        seen["argv"] = argv
        return Completed()

    monkeypatch.setattr(privileged, "run", fake_run)
    privileged.admin_shell("true")
    assert seen["timeout"] is None
    assert "with administrator privileges" in str(seen["argv"])


def test_admin_shell_raises_when_cancelled(monkeypatch: pytest.MonkeyPatch) -> None:
    class Completed:
        returncode = 1
        stdout = ""
        stderr = "User canceled."

    monkeypatch.setattr(privileged, "run", lambda *a, **k: Completed())
    with pytest.raises(core.ClamshellError, match="User canceled"):
        privileged.admin_shell("true")


def make_source(tmp_path: Path) -> Path:
    """Create a minimal checkout layout for install_sources tests."""
    source = tmp_path / "repo"
    source.mkdir()
    for name in ("clamshell_core.py", "clamshell_cli.py", "clamshell_privileged.py"):
        (source / name).write_text(f"# {name}\n")
    (source / core.HELPER_NAME).write_text("#!/bin/bash\n")
    (source / core.TIMER_NAME).write_text("#!/bin/bash\n")
    return source


def test_install_sources_copies_modules_and_helper(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = make_source(tmp_path)
    support = tmp_path / "support"
    monkeypatch.setattr(privileged, "SUPPORT_DIR", support)
    result = privileged.install_sources(source)
    assert result == support
    for name in (
        "clamshell_core.py",
        "clamshell_cli.py",
        "clamshell_privileged.py",
        core.HELPER_NAME,
        core.TIMER_NAME,
    ):
        assert (support / name).exists()
    launcher = support / "clamshell"
    assert launcher.exists()
    assert launcher.stat().st_mode & 0o111


def test_install_sources_includes_helper_so_reinstall_works(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = make_source(tmp_path)
    support = tmp_path / "support"
    monkeypatch.setattr(privileged, "SUPPORT_DIR", support)
    privileged.install_sources(source)
    assert (support / core.HELPER_NAME).exists()
    assert (support / core.TIMER_NAME).exists()


def test_install_sources_raises_for_missing_module(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "repo"
    source.mkdir()
    (source / "clamshell_core.py").write_text("# core\n")
    monkeypatch.setattr(privileged, "SUPPORT_DIR", tmp_path / "support")
    with pytest.raises(core.ClamshellError):
        privileged.install_sources(source)


def test_uninstall_restores_sleep_without_helper() -> None:
    fragment = privileged.uninstall_command()
    assert "pmset disablesleep 0" in fragment
    assert fragment.index("pmset disablesleep 0") < fragment.index("rm -f")
    assert str(core.SUDOERS_PATH) in fragment
    assert str(core.CLI_PATH) in fragment


def test_uninstall_removes_helper_log() -> None:
    assert "/var/log/clamshell-helper.log" in privileged.uninstall_command()
