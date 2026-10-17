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
(cd "$UI_DIR" && swiftformat --lint . >/dev/null)
(cd "$UI_DIR" && ${LINT_ENV[@]+"${LINT_ENV[@]}"} swiftlint --strict --quiet)
(cd "$UI_DIR" && swift test ${TEST_PLUGIN_ARGS[@]+"${TEST_PLUGIN_ARGS[@]}"})

step "Building release binary"
(cd "$UI_DIR" && swift build -c release --product "$APP_NAME")
BINARY="$(cd "$UI_DIR" && swift build -c release --show-bin-path)/$APP_NAME"

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
rm -rf "$DESTINATION"
cp -R "$APP_BUNDLE" "$DESTINATION"
printf '\nInstalled %s\nLaunch it from Launchpad or: open -a %s\n' "$DESTINATION" "$APP_NAME"
