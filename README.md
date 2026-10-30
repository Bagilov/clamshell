# Clamshell

Keep a MacBook awake with the lid closed on Apple Silicon, from the command
line or a menu bar app.

This is the feature macOS calls **clamshell mode** or **closed-display mode**:
it keeps the Mac awake and prevents sleep when the lid shuts, instead of
suspending to disk.

**Status: pre-release (0.5.0).** The core behaviour is usable, but the command
interface is not yet frozen while the major version is `0`.

macOS sleeps as soon as the lid closes unless sleep is explicitly disabled.
On Apple Silicon (M1, M2, M3, M4 and later), `caffeinate` and ordinary
keep-awake menu bar apps (for example KeepingYouAwake) cannot override that:
the only working switch is `pmset disablesleep`, which needs root.

This project wraps that single privileged call in a tiny root-owned helper with
a narrow `NOPASSWD` sudoers rule, so day-to-day use never asks for a password
and no general root access is granted.

## Install in one step

Grab the installer from the release **Assets**, then open it:

1. Open the [releases page](https://github.com/Bagilov/clamshell/releases).
2. Pick the newest entry and expand its **Assets** section.
3. Download `Clamshell-<version>.pkg` and double-click it.

The installer asks for one administrator password and then sets up the CLI, the
helper, the sudoers rule and the menu bar app. See
[Install → From the package](#from-the-package-recommended) for the full layout,
[Agent install](#agent-install) for an unattended script, and
[From a clone](#from-a-clone) if you would rather run it from source.

## Layout

| Path | Purpose |
|---|---|
| `clamshell_cli.py` | Command-line interface (`on`, `off`, `status`, `battery`, `install`, `uninstall`) |
| `clamshell_core.py` | Duration parsing, state and timer scheduling |
| `clamshell_battery.py` | Battery level reporting and floor validation |
| `clamshell_privileged.py` | Privileged installation and uninstall helpers |
| `clamshell_release.py` | Semantic-version and release-asset selection |
| `clamshell_update.py` | Throttled update check and its cache |
| `clamshell_upgrade.py` | Download, checksum verification and install |
| `clamshell_helper.sh` | Root-owned helper; accepts only `on` / `off` |
| `clamshell_timer.sh` | Session watcher; watches the deadline, battery floor and the shut lid, and notifies when a session ends |
| `ui/` | Swift menu bar app driving the same CLI |
| `.github/workflows/release.yml` | Builds and publishes the installer when a `v*` tag is pushed |

## Requirements

- macOS 14 or newer on Apple Silicon
- Python 3.9 or newer
- For the menu bar app: a Swift toolchain (Command Line Tools are enough)

## Install

### From the package (recommended)

Open the [releases page](https://github.com/Bagilov/clamshell/releases) and take
the topmost entry — the newest release. Expand its **Assets** section, download
`Clamshell-<version>.pkg`, then open it and follow the installer.

> While the version is still `0.x`, every release is marked *Pre-release*, so
> GitHub has no "Latest" release and `/releases/latest` redirects to the full
> list. The topmost entry is the one to use.

The installer is attached to the release as an **asset**; it is deliberately not
published to GitHub Packages, which has no registry type for a macOS `.pkg`.
Every asset carries a sha256 digest you can check before installing.

The install needs one administrator password, then sets up:

| Path | Purpose |
|---|---|
| `/Applications/Clamshell.app` | Menu bar app |
| `/usr/local/lib/clamshell/` | CLI sources and watcher |
| `/usr/local/sbin/clamshell-helper` | Root-owned helper; accepts only `on` / `off` |
| `/etc/sudoers.d/clamshell` | `NOPASSWD` rule scoped to that helper only |
| `/usr/local/bin/clamshell` | Launcher on `PATH` |
| `/var/log/clamshell-helper.log` | Helper log, trimmed automatically when it grows |

While a session runs, the pending trigger is stored at
`~/Library/Application Support/clamshell/state.plist`; deleting that file (or
running `clamshell off`) clears the timer.

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
folders such as `~/Documents`. A copy of the helper script lands there as well,
but only as a source: what `sudo` runs is always the root-owned
`/usr/local/sbin/clamshell-helper` named in the sudoers rule, and the copy in the
support directory is never executed with privileges. Keeping it lets
`clamshell install` be re-run from the installed command on its own.

### Agent install

For an automated install, resolve the newest release asset, verify its digest,
then install the package. The script below needs no `gh` login: the releases API
is public, and it falls back to the newest entry when no release is marked
"Latest" because every release is currently a pre-release.

```bash
set -euo pipefail

REPO="Bagilov/clamshell"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

filter='. as $rels
  | ($rels | map(select(.prerelease == false)) | first // $rels[0])
  | (.assets | map(select(.name | endswith(".pkg"))) | first)'

json="$(curl -fsSL "https://api.github.com/repos/$REPO/releases")"
asset="$(printf '%s' "$json" | jq -r "$filter")"

url="$(printf '%s' "$asset" | jq -r .browser_download_url)"
want="$(printf '%s' "$asset" | jq -r .digest | sed 's/^sha256://')"
pkg="$WORK/$(basename "$url")"

curl -fsSL -o "$pkg" "$url"
got="$(shasum -a 256 "$pkg" | awk '{print $1}')"
[ "$got" = "$want" ] || { echo "digest mismatch: $got != $want" >&2; exit 1; }

xattr -d com.apple.quarantine "$pkg" 2>/dev/null || true
sudo installer -pkg "$pkg" -target /
```

The `filter` picks the newest release that is not a pre-release, falling back to
the newest of any kind, then takes the first `.pkg` asset. That keeps the script
working whether or not this project's releases stay marked as pre-releases.

Notes for an agent driving this:

- `installer -pkg ... -target /` must run as root; a non-interactive `sudo`
  needs an already-cached credential — otherwise use a GUI admin prompt via
  `osascript -e 'do shell script "..." with administrator privileges'`.
- The package is ad-hoc signed and not notarised, so clear the quarantine flag
  before a headless install, or the app is blocked on first launch.
- Verify the sha256 digest before installing; release notes and the releases API
  both carry it.
- `clamshell --version` confirms what was installed, and `clamshell status`
  reports the current session.

## Usage

```bash
clamshell on                    # disable sleep until you stop it
clamshell on --for 1h           # disable sleep for one hour, then restore
clamshell on --battery 20       # disable sleep until the battery hits 20%
clamshell on --for 4h --battery 20   # whichever trigger fires first
clamshell on --darken           # also blank the display now
clamshell off                   # restore normal sleep behaviour
clamshell status                # show state and pending triggers
clamshell status --json         # same facts as JSON, for scripts
clamshell battery               # show battery level and the configured floor
clamshell darken                # blank the display now, mid-session
clamshell reconcile             # re-align a timer left over from a restart
clamshell update                # check for a newer release (once a day)
clamshell update --json         # the same check as JSON, for scripts
clamshell update --install      # download, verify and install it
```

Duration spans accept `s`, `m`, `h`, `d` and combinations: `45m`, `2h`, `1h30m`,
up to a maximum of 30 days.

If the machine restarts while a session is pending, the transient watcher job is
gone but the state file remains. The menu bar app calls `clamshell reconcile` at
launch: a trigger still in the future is re-armed with the time that is left, and
one that already passed restores sleep instead of leaving it disabled.

## Updates

The app and the CLI both check GitHub Releases for a newer version.

From the menu bar, **Check for Updates…** runs a check on demand, and when a
newer release is known an **Update to X.Y.Z…** row appears above it. Installing
always asks for confirmation first, then downloads, verifies and installs the
package with one administrator approval, and offers to restart.

From the CLI:

```bash
clamshell update                # report only; never changes the system
clamshell update --install      # apply the newer release
clamshell update --force        # check now, ignoring the day-long throttle
clamshell update --dry-run      # download and verify, but do not install
```

How it behaves, following the usual practice for a self-updating app:

- **Consent before install.** A bare `clamshell update` only reports, and the app
  only installs after an explicit confirmation. Nothing updates on its own.
- **Verify before install.** The release's `sha256` digest is checked against the
  downloaded bytes. A mismatch aborts, and a release with no digest is refused
  unless `--allow-unverified` is passed, so the default path never installs
  unverified code. Release notes show the same digest.
- **Throttled, quiet checks.** Automatic checks are limited to once a day and a
  failed check is silent (`Could not check for updates` in the menu on a manual
  run); the last known result is cached, so an offline machine still sees it.
- **Stable preferred.** A final release is preferred over a pre-release, and only
  a strictly newer version is ever offered. While every release here is marked
  *Pre-release*, the newest pre-release is offered instead.
- **An active session survives.** After an upgrade the watcher is re-armed with
  the time that is left, so the new code takes over without restoring sleep, and
  the updated sources are copied into the user-owned support directory.

## Install the menu bar app

```bash
ui/build.sh --install     # lint, test, build and copy to /Applications
```

Packaging a distributable installer:

```bash
./package.sh              # writes build/Clamshell-<version>.pkg
./package.sh --unsigned   # skip signing when no certificate is present
```

The shipped binary is built with a neutral scratch path and
`-debug-prefix-map`, so it never embeds the builder's home directory. The
product package is signed with a Developer ID Installer certificate when one is
available, and built unsigned otherwise.

Releases are built in CI: pushing a `v*` tag runs `.github/workflows/release.yml`,
which lints, tests, packages, checks the tag against the version in the sources,
and publishes the package as a release asset. A release made by hand should match
that flow so the asset and the digest stay verifiable.

The app is an accessory (`LSUIElement`): a moon glyph in the menu bar, no Dock
icon. Its menu offers the duration choices, a "Stop on Low Battery" section with
the battery floor levels, a "Turn Display Off" toggle, a "Launch at Login"
toggle, "Stop Clamshell Mode", "Refresh", "Check for Updates…" (with an "Update
to X.Y.Z…" row when one is available), "About Clamshell" with the repository
link, "Uninstall Clamshell…", and "Quit".

**Launch at Login** registers the app through `SMAppService`, so a reboot does
not leave a session unmanaged: the app comes back and re-aligns any leftover
watcher at launch. The row only appears for the installed bundle, because a bare
binary run from a build directory has no bundle identifier to register. If macOS
holds the registration for approval, the app says so and points at
**System Settings → General → Login Items**.

**Uninstall Clamshell…** asks for one confirmation and then removes the helper,
the sudoers rule and the command line, and restores normal sleep. The login item
is dropped first, so it cannot relaunch an app whose CLI is gone. The app bundle
itself is left in place to drag to the Trash.

Both the duration and the battery floor can be entered by hand through
**Custom…**. The duration field accepts `45m`, `2h`, `1h30m` or a bare number of
minutes; the battery field accepts any whole level from 5% to 95%. A hand-entered
value is validated before it is used and then shown as a checked menu row.

While a timed session runs, the remaining time is shown next to the glyph in
the menu bar (`3h52m`), ticking every second. It reads `∞` for an unlimited
session and `🔋` for a battery-limited one. The countdown ticks locally from the
last known deadline and re-syncs with `clamshell status` every 5 seconds, so it
stays live without spawning the CLI every second. CLI errors are surfaced in
the menu instead of failing silently.

## How auto-restore works

`clamshell on` starts a transient `launchctl` job that runs `clamshell_timer.sh`
for as long as the session lasts, including an unlimited one. The watcher checks
every 20 seconds and restores sleep when either the deadline passes or, while
running unplugged, the battery drops to the configured floor. It then calls the
helper's `off` action through the same sudoers rule and clears the state file. No
second prompt appears.

When the session ends the watcher posts a notification naming the reason (the
timer finished, or the battery reached the floor), and it notifies if a restore
fails for good so an unattended machine is not left awake silently. Set `NOTIFY=0`
in the watcher environment to turn notifications off.

The battery floor only applies on battery power: while plugged in the charge is
not draining, so a low reading never cuts a session short.

## Keeping the display off

With sleep disabled macOS does **not** blank the built-in panel when the lid
closes: the idle display timer is what normally does that, and on battery that
timer is off entirely (`displaysleep 0`), so the screen can stay lit behind a
shut lid.

The watcher therefore blanks the panel itself on every pass, using
`pmset displaysleepnow` (no root), whenever all three hold:

- the lid is shut,
- the built-in panel is still lit,
- no external display is attached.

Closing the lid with an external screen connected leaves that screen running, as
clamshell mode is supposed to. Every probe fails safe: if the lid state, the
display list or the power state cannot be read, the screen is left alone.

## Notes

- Closing the lid blanks the built-in display: the watcher does it, because
  macOS skips it once sleep is disabled. `clamshell on --darken` (or
  `clamshell darken` mid-session) blanks it immediately, which is useful for a
  session started with the lid already open.
- Thermal limits still apply: sustained heavy load with the lid closed can
  throttle the CPU.
- `clamshell uninstall` restores sleep even if the helper is already missing.
- The helper supports only `on` and `off`; the sudoers rule grants nothing else.
- The only outbound request is the update check against
  `https://api.github.com/repos/Bagilov/clamshell/releases`; its result is cached
  at `~/Library/Application Support/clamshell/update-check.json`. Nothing else in
  the project talks to the network.

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
shellcheck clamshell_helper.sh clamshell_helper_test.sh clamshell_timer.sh \
  clamshell_timer_test.sh ui/build.sh package.sh
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
