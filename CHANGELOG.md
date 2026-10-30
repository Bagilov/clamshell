# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is `0`, the interface may still change between minor
releases, and breaking changes are noted explicitly.

## [Unreleased]

## [0.4.0] - 2026-10-30

### Added

- `clamshell update` checks GitHub Releases for a newer version, and
  `clamshell update --install` downloads, verifies and installs it. The check is
  throttled to once a day (`--force` overrides), and the result is available as
  JSON with `--json` for the menu bar app.
- The menu bar app checks for updates in the background and offers **Update
  to X.Y.Z…** when one is available, next to an always-present **Check for
  Updates…** row. Installing always asks for confirmation first, and the app
  offers to restart once the new version is in place.
- The installer is verified against the release's `sha256` digest before it is
  installed. A release without a digest is refused unless
  `--allow-unverified` is passed, so the default path never installs unverified
  code. `--dry-run` downloads and verifies without installing.
- An active keep-awake session is re-armed on the new version after an upgrade,
  so the new watcher takes over without restoring sleep. The updated sources are
  also copied into the user-owned support directory, which the menu bar app reads.

### Changed

- Release selection prefers a final release over a pre-release and only ever
  offers something strictly newer than the running version. With this project's
  releases currently all marked as pre-releases, the newest pre-release is
  offered instead, so updates still work either way.

## [0.3.0] - 2026-10-28

### Added

- `clamshell reconcile` re-aligns a pending session after a restart: a trigger
  still in the future is re-armed with the remaining time, and one that already
  passed restores sleep instead of leaving it disabled forever. The menu bar app
  runs it at launch.
- `clamshell status --json` and `clamshell battery --json` emit machine-readable
  state. The menu bar app now reads the JSON form, falling back to the text
  parser for an older CLI.
- `clamshell darken` blanks the display on demand, so the menu bar toggle also
  applies to a session that is already running.
- The menu bar app remembers the chosen battery floor, duration, custom span and
  display toggle across launches.
- `clamshell on` now always starts the session watcher, including for an
  unlimited session with no time limit and no battery floor. The watcher is what
  keeps the built-in panel dark for a shut lid, and an unlimited session is
  re-armed by `clamshell reconcile` after a restart.

### Fixed

- The built-in display is now blanked when the lid closes. With sleep disabled
  macOS does not do this on its own: the idle display timer normally handles it,
  and on battery that timer is off, so a shut lid could leave the panel lit. The
  session watcher blanks it again on every pass, and skips that when an external
  display is attached or any probe fails.
- `clamshell off` restores sleep before cancelling the timer. Cancelling first
  could leave sleep disabled with no trigger and no state file to recover from.
- The watcher no longer discards a failed restore: it retries, logs to
  `~/Library/Logs/clamshell.log`, and keeps the state file so a refused `sudo`
  cannot let the battery drain unnoticed.
- A duration longer than 30 days is rejected by the CLI, matching the limit the
  menu bar app already enforced, so a stray digit cannot schedule a session years
  out.
- The menu bar no longer crashes with `NSInternalInconsistencyException` when the
  status menu is rebuilt while it is still installed — for example after picking a
  custom battery floor. The state row is created per build, like every other item.
- The menu now checks the duration that is actually running, and nothing is
  checked when a custom span is in use.
- A command that times out keeps the child's stderr in the error message, so a
  Python traceback is no longer replaced by a bare "timed out". The text is
  truncated, so a runaway log cannot bloat the alert.
- The helper keeps logging when a rotation step fails: under `set -e` a failing
  `chmod`/`mv` could abort it before the current action was recorded.
- The version test now compares both `Info.plist` keys through `plistlib`, so a
  bundle whose two version strings drifted apart is caught instead of passing on
  a substring match.
- `ui/build.sh` names the real problem when an earlier `sudo` install left a
  root-owned bundle behind, instead of failing with a bare permission error, and
  no longer hides `swiftformat` output.
- The menu bar app no longer hangs for the full command timeout when the CLI
  writes more than the ~64 KiB pipe buffer. Output is drained on background
  queues, and a timed-out child is terminated, then killed if it refuses to exit.
- A CLI error is now shown in front of the active app, and the countdown keeps
  ticking while the menu is open.
- `clamshell status` reports a reached battery floor even when a time limit is
  also active.
- The helper rotates its log through a `mktemp` file, so a pre-created symlink at
  the old predictable path cannot redirect the write. The rotated file keeps the
  world-readable `644` mode of the original.
- A command that times out now returns even when a surviving descendant still
  holds the output pipe open, so the app can never wait forever on a reader.
- `package.sh` fails with a clear message when the version cannot be read and
  ships only the known modules instead of every `clamshell_*.py`.

### Documentation

- README states the current version, documents the helper log and state-file
  paths, and no longer implies the helper copy under
  `~/Library/Application Support/clamshell/` is what runs as root.

## [0.2.0] - 2026-10-18

### Added

- Manual entry in the menu bar app: **Custom…** under the duration choices
  accepts forms like `45m`, `2h`, `1h30m` or a bare number of minutes, and
  **Custom…** under the battery floor accepts any level from 5% to 95%.

### Changed

- The battery floor is now a value rather than a fixed set, so a hand-entered
  level becomes a first-class choice and is shown as a checked menu row.

## [0.1.1] - 2026-10-18

### Fixed

- The menu bar app no longer prevents the Mac from sleeping. It opted out of
  App Nap with `.userInitiated`, which also sets the `idleSystemSleepDisabled`
  bit, so the app held a power assertion for as long as it ran. After a timed
  session expired the Mac stayed awake instead of sleeping. The policy now uses
  `.userInitiatedAllowingIdleSystemSleep` and is covered by tests.

## [0.1.0] - 2026-10-17

First pre-release. The core behaviour is usable, but the command interface is
not yet frozen.

### Added

- `clamshell on` to keep the Mac awake with the lid closed, plus `off` and
  `status`.
- `--for SPAN` on `on` to restore sleep after a duration such as `45m` or
  `1h30m`.
- `--battery PERCENT` on `on` to restore sleep at a battery floor, applied only
  while running unplugged.
- `--darken` on `on` to blank the display immediately with `pmset
  displaysleepnow`, for setups where closing the lid leaves the panel lit.
- `clamshell battery` to show the level, power source and configured floor.
- `install` and `uninstall` commands that set up a root-owned helper with a
  narrow `NOPASSWD` sudoers rule behind a single admin prompt.
- A launchd watcher that restores sleep on the deadline or the battery floor.
- A Swift menu bar app with a live countdown, battery floor selection, a
  display toggle and surfaced CLI errors.
- `--version`, and bundle/version consistency checks.

[Unreleased]: https://github.com/Bagilov/clamshell/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/Bagilov/clamshell/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Bagilov/clamshell/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Bagilov/clamshell/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/Bagilov/clamshell/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Bagilov/clamshell/releases/tag/v0.1.0
