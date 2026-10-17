#!/bin/bash
# Build a macOS installer package for manual installation.
#
# Produces build/Clamshell-<version>.pkg, which installs the CLI, the root-owned
# helper with its narrow sudoers rule, and the menu bar app. Users download the
# package, open it and follow the installer.
#
# Run without arguments to build; pass --unsigned to skip signing (the default
# is to sign with an available Developer ID certificate when one is present).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO_DIR/build"
APP_NAME="Clamshell"
PKG_ID="io.github.bagilov.clamshell"

step() { printf '\n==> %s\n' "$*"; }

VERSION="$(python3 - "$REPO_DIR/clamshell_core.py" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
print(re.search(r'^VERSION = "([^"]+)"', text, re.M).group(1))
PY
)"
PAYLOAD="$BUILD_DIR/payload"
SCRIPTS="$BUILD_DIR/scripts"
PKG="$BUILD_DIR/$APP_NAME-$VERSION.pkg"

step "Building $APP_NAME app ($VERSION)"
"$REPO_DIR/ui/build.sh"

step "Staging payload"
rm -rf "$PAYLOAD" "$SCRIPTS"
mkdir -p "$PAYLOAD/usr/local/lib/clamshell" \
         "$PAYLOAD/usr/local/sbin" \
         "$PAYLOAD/usr/local/bin" \
         "$PAYLOAD/Applications" \
         "$SCRIPTS"

install -m 644 "$REPO_DIR"/clamshell_*.py "$PAYLOAD/usr/local/lib/clamshell/"
install -m 755 "$REPO_DIR/clamshell_timer.sh" "$PAYLOAD/usr/local/lib/clamshell/"
install -m 755 "$REPO_DIR/clamshell_helper.sh" "$PAYLOAD/usr/local/lib/clamshell/"
install -m 755 "$REPO_DIR/clamshell_helper.sh" "$PAYLOAD/usr/local/sbin/clamshell-helper"
cp -R "$REPO_DIR/ui/build/$APP_NAME.app" "$PAYLOAD/Applications/"

# The launcher is pinned to the system interpreter so it works without a user
# virtualenv. The sudoers rule is generated at install time, not here, so the
# package never embeds the build machine's account name.
printf '#!/bin/sh\nexec /usr/bin/python3 /usr/local/lib/clamshell/clamshell_cli.py "$@"\n' \
    > "$PAYLOAD/usr/local/bin/clamshell"
chmod 755 "$PAYLOAD/usr/local/bin/clamshell"

step "Writing installer scripts"
cat > "$SCRIPTS/postinstall" <<'SH'
#!/bin/bash
# Create and validate the sudoers rule for the console user, then fix up
# ownership. A malformed rule would break sudo system-wide, so it is validated
# with visudo and removed on failure.
set -euo pipefail

HELPER=/usr/local/sbin/clamshell-helper
RULE=/etc/sudoers.d/clamshell
LOG=/var/log/clamshell-helper.log
TARGET_USER="$(stat -f '%Su' /dev/console)"

chown -R root:wheel /usr/local/lib/clamshell
chmod 755 "$HELPER"

if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
    printf '%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$HELPER" > "$RULE"
    chown root:wheel "$RULE"
    chmod 440 "$RULE"
    visudo -cf "$RULE" || { rm -f "$RULE"; exit 1; }
fi

# The helper writes this log; pre-create it so the first run needs no extra
# privileges.
: > "$LOG"
chmod 644 "$LOG"
exit 0
SH
chmod 755 "$SCRIPTS/postinstall"

step "Building component package"
pkgbuild \
    --root "$PAYLOAD" \
    --scripts "$SCRIPTS" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --install-location / \
    "$BUILD_DIR/component.pkg"

step "Building product package"
DIST="$BUILD_DIR/distribution.xml"
cat > "$DIST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$APP_NAME $VERSION</title>
    <organization>$PKG_ID</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="true" rootVolumeOnly="true"/>
    <pkg-ref id="$PKG_ID"/>
    <choices-outline>
        <line choice="default">
            <line choice="$PKG_ID"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$PKG_ID" visible="false">
        <pkg-ref id="$PKG_ID"/>
    </choice>
    <pkg-ref id="$PKG_ID" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild --distribution "$DIST" --package-path "$BUILD_DIR" "$PKG"

step "Result"
printf 'Built %s\n' "$PKG"
shasum -a 256 "$PKG"
printf '\nInstall with: open %s\n' "$PKG"
