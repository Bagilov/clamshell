#!/bin/bash
# Tests for clamshell_timer.sh decision helpers.
#
# The battery and pm-set lookups are stubbed, so no real power state is read.
# Run with: bash clamshell_timer_test.sh

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

if (( FAILURES > 0 )); then
    printf '\n%d check(s) failed\n' "$FAILURES"
    exit 1
fi
printf '\nAll timer checks passed\n'
