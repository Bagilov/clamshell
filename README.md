# Clamshell

Keep a MacBook awake with the lid closed on Apple Silicon, from the command
line or a menu bar app.

**Status: pre-release (0.1.0).** The core behaviour is usable, but the command
interface is not yet frozen while the major version is `0`.

macOS sleeps as soon as the lid closes unless sleep is explicitly disabled.
On Apple Silicon, `caffeinate` and ordinary keep-awake menu bar apps (for
example KeepingYouAwake) cannot override that: the only working switch is
`pmset disablesleep`, which needs root.

This project wraps that single privileged call in a tiny root-owned helper with
a narrow `NOPASSWD` sudoers rule, so day-to-day use never asks for a password
and no general root access is granted.

## Layout

| Path | Purpose |
|---|---|
| `clamshell_cli.py` | Command-line interface (`on`, `off`, `status`, `battery`, `install`, `uninstall`) |
| `clamshell_core.py` | Duration parsing, state and timer scheduling |
| `clamshell_battery.py` | Battery level reporting and floor validation |
| `clamshell_privileged.py` | Privileged installation and uninstall helpers |
| `clamshell_helper.sh` | Root-owned helper; accepts only `on` / `off` |
| `clamshell_timer.sh` | Auto-restore watcher; watches the deadline and battery floor |
| `ui/` | Swift menu bar app driving the same CLI |

## Requirements

- macOS 14 or newer on Apple Silicon
- Python 3.9 or newer
- For the menu bar app: a Swift toolchain (Command Line Tools are enough)

## Install

### From the package (recommended)

Download `Clamshell-<version>.pkg` from the
[releases page](https://github.com/Bagilov/clamshell/releases), open it and
follow the installer. It needs one administrator password, then installs:

| Path | Purpose |
|---|---|
| `/Applications/Clamshell.app` | Menu bar app |
| `/usr/local/lib/clamshell/` | CLI sources and watcher |
| `/usr/local/sbin/clamshell-helper` | Root-owned helper; accepts only `on` / `off` |
| `/etc/sudoers.d/clamshell` | `NOPASSWD` rule scoped to that helper only |
| `/usr/local/bin/clamshell` | Launcher on `PATH` |

The package is not notarised, so the first launch may need
**System Settings → Privacy & Security → Open Anyway**.

### From a clone

```bash
python3 clamshell_cli.py install
```

One GUI admin prompt installs the same helper, sudoers rule and `PATH` launcher.

The Python sources, both shell scripts and a second launcher are also copied to
`~/Library/Application Support/clamshell/`. That directory needs no privileges
and stays readable by the sandboxed menu bar app, which cannot read protected
folders such as `~/Documents`. Because the helper is copied there too,
`clamshell install` can be re-run from the installed command on its own.

## Usage

```bash
clamshell on                    # disable sleep until you stop it
clamshell on --for 1h           # disable sleep for one hour, then restore
clamshell on --battery 20       # disable sleep until the battery hits 20%
clamshell on --for 4h --battery 20   # whichever trigger fires first
clamshell on --darken           # also blank the display now
clamshell off                   # restore normal sleep behaviour
clamshell status                # show state and pending triggers
clamshell battery               # show battery level and the configured floor
```

Duration spans accept `s`, `m`, `h`, `d` and combinations: `45m`, `2h`, `1h30m`.

## Install the menu bar app

```bash
ui/build.sh --install     # lint, test, build and copy to /Applications
```

Packaging a distributable installer:

```bash
./package.sh              # writes build/Clamshell-<version>.pkg
```

The shipped binary is built with a neutral scratch path and
`-debug-prefix-map`, so it never embeds the builder's home directory.

The app is an accessory (`LSUIElement`): a moon glyph in the menu bar, no Dock
icon. Its menu offers the duration choices, a "Stop on Low Battery" section with
the battery floor levels, a "Turn Display Off" toggle, "Stop Clamshell Mode",
"Refresh", "About Clamshell" with the repository link, and "Quit".

While a timed session runs, the remaining time is shown next to the glyph in
the menu bar (`3h52m`), ticking every second. It reads `∞` for an unlimited
session and `🔋` for a battery-limited one. The countdown ticks locally from the
last known deadline and re-syncs with `clamshell status` every 5 seconds, so it
stays live without spawning the CLI every second. CLI errors are surfaced in
the menu instead of failing silently.

## How auto-restore works

`clamshell on` with a trigger schedules a transient `launchctl` job that runs
`clamshell_timer.sh`. The watcher checks every 20 seconds and restores sleep
when either the deadline passes or, while running unplugged, the battery drops
to the configured floor. It then calls the helper's `off` action through the
same sudoers rule and clears the state file. No second prompt appears.

The battery floor only applies on battery power: while plugged in the charge is
not draining, so a low reading never cuts a session short.

## Notes

- Closing the lid normally blanks the built-in display on its own; the machine
  then runs headless until you open it again. If a setup keeps the panel lit,
  `clamshell on --darken` blanks it explicitly with `pmset displaysleepnow`,
  which needs no root. It is opt-in so a session started with the lid open is
  not darkened unexpectedly.
- Thermal limits still apply: sustained heavy load with the lid closed can
  throttle the CPU.
- `clamshell uninstall` restores sleep even if the helper is already missing.
- The helper supports only `on` and `off`; the sudoers rule grants nothing else.

## Uninstall

```bash
clamshell uninstall
```

Removes the helper, the sudoers rule, the `PATH` launcher, the helper log and
the support directory, and restores normal sleep behaviour.

## Development

Python and shell:

```bash
ruff check . && ruff format --check .
python -m pytest -q
bash clamshell_timer_test.sh
shellcheck clamshell_helper.sh clamshell_timer.sh clamshell_timer_test.sh
```

Swift (`ui/`):

```bash
swiftformat --lint .
swiftlint --strict
swift test
```

With Command Line Tools only, `swiftlint` needs the bundled framework path, and
`swift test` needs the bundled macro plugin path; `ui/build.sh` sets both.

## License

MIT. See [LICENSE](LICENSE).
