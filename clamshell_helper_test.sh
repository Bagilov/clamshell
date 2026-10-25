#!/bin/bash
# Tests for clamshell_helper.sh log rotation.
#
# Sources the helper in library mode so `log` runs without touching pmset or the
# real /var/log path. Run with: bash clamshell_helper_test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

assert_eq() {
    local actual="$1" expected="$2" description="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'ok   %s\n' "$description"
    else
        printf 'FAIL %s (expected %s, got %s)\n' "$description" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_true() {
    local condition="$1" description="$2"
    if eval "$condition"; then
        printf 'ok   %s\n' "$description"
    else
        printf 'FAIL %s\n' "$description"
        FAILURES=$((FAILURES + 1))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

LOG="$WORK/helper.log"
export LOG
export MAX_LOG_BYTES=1024
CLAMSHELL_HELPER_LIB=1 source "$SCRIPT_DIR/clamshell_helper.sh"
# Sourcing runs the helper's own `set -euo pipefail`; drop `-e` here so a single
# failing check reports itself instead of killing the whole run.
set +e

# A file larger than the cap is trimmed down to the last 200 lines.
seed_large_log() {
    : > "$LOG"
    local i
    for ((i = 0; i < 400; i++)); do
        printf 'line %04d padded to pass the size cap\n' "$i" >> "$LOG"
    done
}

seed_large_log
log "on"
assert_true "[[ $(wc -l < "$LOG") -lt 250 ]]" "rotation trims an oversized log"

# The rotated file must keep the world-readable mode the postinstall creates,
# not the 0600 that mktemp gives its staging file.
seed_large_log
chmod 644 "$LOG"
log "on"
assert_eq "$(stat -f '%Lp' "$LOG")" "644" "rotation preserves 644 on the log"

# Rotation must not follow a pre-existing symlink at a predictable staging path.
seed_large_log
VICTIM="$WORK/victim"
printf 'do not overwrite\n' > "$VICTIM"
ln -sf "$VICTIM" "$LOG.tmp"
log "off"
assert_eq "$(cat "$VICTIM")" "do not overwrite" "symlink at \$LOG.tmp is not written through"

# A small log is appended to, not rotated.
: > "$LOG"
printf 'first\n' >> "$LOG"
log "on"
assert_true "[[ $(head -1 "$LOG") == first ]]" "small log is appended, not rotated"

# Percent signs and quotes in the message must survive verbatim.
: > "$LOG"
log 'weird %s "quoted"'
assert_true "grep -q 'weird %s \"quoted\"' '$LOG'" "message is recorded verbatim"

# A failing rotation must not abort the caller under `set -e`. `mktemp` still
# succeeds, but `mv` cannot replace the immutable target, so rotation fails at
# the step where `chmod`/`mv` would on a broken volume. The regression the guard
# prevents is `set -e` aborting inside `log()`, so the check is that the caller
# keeps running — not that the append landed.
SEED_LOG="$WORK/immutable.log"
: > "$SEED_LOG"
for ((i = 0; i < 400; i++)); do
    printf 'line %04d padded to pass the size cap\n' "$i" >> "$SEED_LOG"
done
chflags uchg "$SEED_LOG"
MARKER="$WORK/continued"
rm -f "$MARKER"
LOG="$SEED_LOG"
# Run the guarded section as its own script. It must not be placed in an `if`
# condition or `&&` list: those suppress `set -e` in the called shell, which
# would hide exactly the abort this check looks for.
(
    set -e
    log "on"
    : > "$MARKER"
) 2>/dev/null
rotation_status=$?
chflags nouchg "$SEED_LOG" 2>/dev/null || true
assert_eq "$rotation_status" "0" "log survives a failing rotation under set -e"
assert_true "[[ -f '$MARKER' ]]" "caller keeps running after a failed rotation"

if (( FAILURES > 0 )); then
    printf '\n%d check(s) failed\n' "$FAILURES"
    exit 1
fi
printf '\nAll helper checks passed\n'
