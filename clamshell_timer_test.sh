#!/bin/bash
# Tests for clamshell_timer.sh decision helpers.
#
# The battery and pm-set lookups are stubbed, so no real power state is read.
# Run with: bash clamshell_timer_test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
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

load_timer() {
    CLAMSHELL_TIMER_LIB=1 source "$SCRIPT_DIR/clamshell_timer.sh"
}

# Stub pmset through a function instead of calling the real binary.
stub_pmset() {
    PMSET=stub_pmset
    stub_pmset() {
        printf '%s\n' "$STUB_BATT"
    }
}

run_floor_case() {
    local floor="$1" batt="$2"
    STUB_BATT="$batt"
    FLOOR="$floor"
    if floor_hit; then printf 'hit'; else printf 'no'; fi
}

run_deadline_case() {
    local deadline="$1"
    DEADLINE="$deadline"
    if deadline_hit; then printf 'hit'; else printf 'no'; fi
}

load_timer
stub_pmset

BATTERY_LOW="Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1)	15%; discharging; 1:00 remaining present: true"
BATTERY_HIGH="Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1)	80%; discharging; 5:00 remaining present: true"
AC_LOW="Now drawing from 'AC Power'
 -InternalBattery-0 (id=1)	15%; charging; 1:00 remaining present: true"

assert_eq "$(run_floor_case 20 "$BATTERY_LOW")" "hit" "floor 20 triggers at 15% on battery"
assert_eq "$(run_floor_case 20 "$BATTERY_HIGH")" "no" "floor 20 idle at 80% on battery"
assert_eq "$(run_floor_case 20 "$AC_LOW")" "no" "wall power never hits the floor"
assert_eq "$(run_floor_case 0 "$BATTERY_LOW")" "no" "floor 0 disables the check"
assert_eq "$(run_floor_case 15 "$BATTERY_LOW")" "hit" "floor equal to the level triggers"

PAST=$(( $(date +%s) - 60 ))
FUTURE=$(( $(date +%s) + 3600 ))
assert_eq "$(run_deadline_case "$PAST")" "hit" "past deadline triggers restore"
assert_eq "$(run_deadline_case "$FUTURE")" "no" "future deadline does not trigger"

# The lid guard blanks the built-in panel while the lid is shut, and only then.
# Every probe is stubbed, so the real lid, displays and power state are untouched.
BLANK_LOG="$WORK/blank.log"
LID_YES='      "AppleClamshellState" = Yes'
LID_NO='      "AppleClamshellState" = No'
ONE_INTERNAL='{"spdisplays_ndrvs":[{"spdisplays_connection_type":"spdisplays_internal"}]}'
WITH_EXTERNAL='{"spdisplays_ndrvs":[{"spdisplays_connection_type":"spdisplays_internal"},{"spdisplays_connection_type":"spdisplays_displayport"}]}'
LIT='Assertion status system-wide:
   pid 119(powerd): PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"'
DARK='Assertion status system-wide:
   BackgroundTask 0'

# Answers for the stubbed probes, set by each case before it runs.
LID_STATE="$LID_YES"
DISPLAY_REPORT="$ONE_INTERNAL"
ASSERTIONS_REPORT="$LIT"

# The lid guard needs more than the battery stub above: it queries assertions and
# issues the blank, so install a dispatching stub for both callers.
stub_pmset_for_lid() {
    PMSET=stub_pmset_all
    stub_pmset_all() {
        case "${1:-}" in
            -g)
                case "${2:-}" in
                    assertions) printf '%s\n' "$ASSERTIONS_REPORT" ;;
                    *) printf '%s\n' "$STUB_BATT" ;;
                esac
                ;;
            displaysleepnow) printf 'BLANKED\n' >> "$BLANK_LOG" ;;
        esac
    }
}
IOREG=stub_ioreg
stub_ioreg() { printf '%s\n' "$LID_STATE"; }
SYSTEM_PROFILER=stub_profiler
stub_profiler() { printf '%s\n' "$DISPLAY_REPORT"; }
stub_pmset_for_lid

run_lid_case() {
    LID_STATE="$1"
    DISPLAY_REPORT="$2"
    ASSERTIONS_REPORT="$3"
    if should_blank_for_lid; then printf 'blank'; else printf 'keep'; fi
}

assert_eq "$(run_lid_case "$LID_YES" "$ONE_INTERNAL" "$LIT")" "blank" "shut lid with only the built-in panel is blanked"
assert_eq "$(run_lid_case "$LID_NO" "$ONE_INTERNAL" "$LIT")" "keep" "an open lid is left alone"
assert_eq "$(run_lid_case "$LID_YES" "$WITH_EXTERNAL" "$LIT")" "keep" "an external display keeps the panel on"
assert_eq "$(run_lid_case "$LID_YES" "$ONE_INTERNAL" "$DARK")" "keep" "an already dark panel is not re-blanked"
assert_eq "$(run_lid_case "$LID_YES" "" "$LIT")" "keep" "an unreadable display list is treated as an external display"

# The blank itself must reach pmset, and a failing blank must not abort a pass.
LID_STATE="$LID_YES"
DISPLAY_REPORT="$ONE_INTERNAL"
ASSERTIONS_REPORT="$LIT"
rm -f "$BLANK_LOG"
blank_display_for_lid
assert_true "[[ -s '$BLANK_LOG' ]]" "a shut lid with a lit panel blanks the display"

# restore_sleep must keep the state file and the job when the helper call fails,
# so the pending restore stays visible instead of silently draining the battery.
STATE="$WORK/state.plist"
: > "$STATE"
export LOG="$WORK/clamshell.log"
ATTEMPTS=0
MAX_ATTEMPTS=3

stub_helper_fail() { sudo() { return 1; }; }
stub_helper_ok() { sudo() { return 0; }; }
stub_launchctl() { launchctl() { return 0; }; }

# Notifications go through a stub: a real osascript call during tests would post
# a visible banner and make the suite non-hermetic. The stub is reached through
# $OSASCRIPT from the sourced watcher, so it records whatever it is called with.
NOTIFY_LOG="$WORK/notify.log"
stub_osascript() { printf '%s\n' "$@" >> "$NOTIFY_LOG"; }
OSASCRIPT=stub_osascript

stub_helper_fail
stub_launchctl
restore_sleep
assert_eq "$?" "2" "a failed restore asks for a retry"
assert_true "[[ -f '$STATE' ]]" "a failed restore keeps the state file"
assert_true "[[ ! -s '$NOTIFY_LOG' ]]" "a retryable failure stays silent"

ATTEMPTS=2
rm -f "$NOTIFY_LOG"
restore_sleep
assert_eq "$?" "1" "the retry budget eventually gives up"
assert_true "[[ -f '$STATE' ]]" "giving up still keeps the state file"
assert_true "grep -q 'Could not restore sleep' '$NOTIFY_LOG'" "giving up posts a notification"

stub_helper_ok
ATTEMPTS=0
rm -f "$NOTIFY_LOG"
restore_sleep "battery reached 15%"
assert_eq "$?" "0" "a successful restore reports success"
assert_true "[[ ! -f '$STATE' ]]" "a successful restore clears the state file"
assert_true "grep -q 'battery reached 15%' '$NOTIFY_LOG'" "a successful restore names the reason"

# The notification is suppressed entirely when NOTIFY=0.
NOTIFY=0
rm -f "$NOTIFY_LOG"
: > "$STATE"
restore_sleep "the timer finished"
assert_true "[[ ! -s '$NOTIFY_LOG' ]]" "NOTIFY=0 keeps the watcher silent"
NOTIFY=1

# end_reason reports the floor when it triggered, and the timer otherwise.
STUB_BATT="$BATTERY_LOW"
FLOOR=20
assert_eq "$(end_reason)" "battery reached 15%" "the floor is named when it triggered"
FLOOR=0
assert_eq "$(end_reason)" "the timer finished" "the timer is named without a floor"

if (( FAILURES > 0 )); then
    printf '\n%d check(s) failed\n' "$FAILURES"
    exit 1
fi
printf '\nAll timer checks passed\n'
