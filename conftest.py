"""Shared test configuration.

Guards every test against touching real user state. Several commands cancel the
scheduled timer, which deletes the state file and the launchd job; without this
guard a test run would silently wipe a live session on the developer's machine.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clamshell_core as core
import clamshell_update as update


@pytest.fixture(autouse=True)
def isolate_user_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Redirect every user-scoped path into the test's temporary directory.

    ``TIMER_SCRIPT`` is deliberately not patched: it is derived from the module
    location rather than user state, and one test asserts that derivation.
    """
    monkeypatch.setattr(core, "SUPPORT_DIR", tmp_path / "support")
    monkeypatch.setattr(core, "STATE_PATH", tmp_path / "support" / "state.plist")
    # The update cache lives under the same support directory. Patch it through
    # the update module, which owns the reference, so a test that forgets its own
    # patch cannot read or overwrite the developer's real cache.
    cache = tmp_path / "support" / "update-check.json"
    monkeypatch.setattr(update, "CACHE_PATH", cache)


@pytest.fixture(autouse=True)
def block_launchctl(monkeypatch: pytest.MonkeyPatch) -> None:
    """Prevent tests from removing or submitting real launchd jobs.

    Tests that need to observe the calls patch ``run`` themselves; this only
    ensures a test which forgets cannot disturb the live scheduler. The name is
    matched anywhere in the argument list, not just at the front, so a wrapped
    invocation such as ``["sudo", "launchctl", ...]`` is caught too.
    """
    real_run = core.run

    def guarded(argv, **kwargs):
        if "launchctl" in argv:
            return type("Result", (), {"stdout": "", "stderr": "", "returncode": 0})()
        return real_run(argv, **kwargs)

    monkeypatch.setattr(core, "run", guarded)
