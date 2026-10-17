# Contributing

Thanks for taking a look. This is a small macOS-only utility.

## Requirements

- macOS on Apple Silicon
- Python 3.9 or newer
- For the menu bar app: a Swift toolchain (Command Line Tools are enough)
- `ruff`, `pytest`, `shellcheck`, `swiftformat` and `swiftlint` for checks

## Before opening a pull request

Run the same checks as CI and make sure they pass.

Python:

```bash
ruff check .
ruff format --check .
python -m pytest -q
bash clamshell_timer_test.sh
shellcheck clamshell_helper.sh clamshell_timer.sh clamshell_timer_test.sh ui/build.sh
```

Swift, from `ui/`:

```bash
swiftformat --lint .
swiftlint --strict
swift test
```

With Command Line Tools only, `swiftlint` needs `DYLD_FRAMEWORK_PATH` pointing at
`/Library/Developer/CommandLineTools/usr/lib`, and `swift test` needs
`-Xswiftc -plugin-path -Xswiftc <clt>/usr/lib/swift/host/plugins/testing`.
`ui/build.sh` sets both automatically.

## Guidelines

- Keep behaviour covered by tests; bug fixes should add a regression test.
- Keep files under 300 lines and prefer splitting by responsibility.
- Use explicit types; avoid `Any` and unchecked suppressions.
- Explain changes to the privileged install path carefully: it writes to
  `/usr/local/sbin` and `/etc/sudoers.d` through a single admin prompt.
- Never commit secrets, `.env` files or machine-specific absolute paths.

## Scope

The project intentionally stays small: one privileged helper that accepts only
`on` and `off`, and a CLI plus menu bar app around it. Broad new dependencies
are unlikely to be accepted; the Python side uses the standard library only.
