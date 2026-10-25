#!/bin/bash
# Build and install the Clamshell menu bar app.
#
# Compiles the Swift package in release mode, assembles a .app bundle with the
# accessory Info.plist, and installs it to /Applications. `--install` performs
# the copy; without it the bundle is only built under ui/build.

set -euo pipefail

UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$UI_DIR/build"
APP_NAME="Clamshell"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DESTINATION="/Applications/$APP_NAME.app"

# Command Line Tools alone ship the Swift Testing macro plugin and the
# sourcekitd framework outside the default search paths, so point the tools at
# them when full Xcode is absent.
TEST_PLUGIN_ARGS=()
LINT_ENV=()
CLT_LIBS=/Library/Developer/CommandLineTools/usr/lib
if [[ ! -d /Applications/Xcode.app ]] && [[ -d $CLT_LIBS/swift/host/plugins/testing ]]; then
    TEST_PLUGIN_ARGS=(-Xswiftc -plugin-path -Xswiftc "$CLT_LIBS/swift/host/plugins/testing")
    LINT_ENV=(env "DYLD_FRAMEWORK_PATH=$CLT_LIBS")
fi

step() { printf '\n==> %s\n' "$*"; }

step "Running lint and tests"
# Lint output is kept: under `set -e` a formatting failure ends the script, and
# suppressing the report would leave the developer without the offending file.
(cd "$UI_DIR" && swiftformat --lint .)
(cd "$UI_DIR" && ${LINT_ENV[@]+"${LINT_ENV[@]}"} swiftlint --strict --quiet)
(cd "$UI_DIR" && swift test ${TEST_PLUGIN_ARGS[@]+"${TEST_PLUGIN_ARGS[@]}"})

step "Building release binary"
# Shipped binaries must not embed the builder's absolute paths, which would leak
# a user name and directory layout through Swift reflection metadata. Two things
# are needed, because the path is recorded twice:
#   * a scratch path outside the checkout, so the build directory carries no
#     user-identifying path of its own
#   * -debug-prefix-map entries for the source root and the scratch path
# Both keys are resolved with pwd -P so they match the compiler's own view.
SOURCE_ROOT="$(cd "$UI_DIR/.." && pwd -P)"
SCRATCH="${TMPDIR:-/tmp}/clamshell-build.$$"
trap 'rm -rf "$SCRATCH"' EXIT
(cd "$UI_DIR" && swift build -c release --product "$APP_NAME" --scratch-path "$SCRATCH" \
    -Xswiftc -debug-prefix-map -Xswiftc "$SOURCE_ROOT=/build" \
    -Xswiftc -debug-prefix-map -Xswiftc "$SCRATCH=/build")
BINARY="$(cd "$UI_DIR" && swift build -c release --product "$APP_NAME" \
    --scratch-path "$SCRATCH" --show-bin-path)/$APP_NAME"

step "Assembling $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$UI_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

step "Signing (ad-hoc)"
codesign --force --deep --sign - "$APP_BUNDLE"

if [[ "${1:-}" != "--install" ]]; then
    printf '\nBuilt %s\nRun with --install to copy it to %s\n' "$APP_BUNDLE" "$DESTINATION"
    exit 0
fi

step "Installing to $DESTINATION"
# /Applications is group-writable by admins, so no sudo is needed for a normal
# user. A copy left by an earlier `sudo` run is root-owned, though, and that is
# the one case worth naming instead of failing with a bare "Permission denied".
if [[ -e "$DESTINATION" && ! -w "$DESTINATION" ]]; then
    printf 'Cannot replace %s: it is not writable by the current user.\n' "$DESTINATION" >&2
    printf 'It looks like an earlier install was run with sudo; remove it, e.g.:\n' >&2
    printf '  sudo rm -rf %s\n' "$DESTINATION" >&2
    exit 1
fi
rm -rf "$DESTINATION"
cp -R "$APP_BUNDLE" "$DESTINATION"
printf '\nInstalled %s\nLaunch it from Launchpad or: open -a %s\n' "$DESTINATION" "$APP_NAME"
