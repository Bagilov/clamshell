# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is `0`, the interface may still change between minor
releases, and breaking changes are noted explicitly.

## [Unreleased]

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

[Unreleased]: https://github.com/Bagilov/clamshell/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Bagilov/clamshell/releases/tag/v0.1.0
