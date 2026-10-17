#!/bin/bash
# Clamshell auto-restore watcher.
#
# Runs as a transient launchctl job. Waits until the deadline passes or, when a
# battery floor is configured, until the battery drops to that floor while
# unplugged. Then restores sleep through the helper, clears the state file and
# removes its own job.
#
# Usage: clamshell-timer <deadline-epoch> <floor-percent|0> <state-path>
#
# Source with CLAMSHELL_TIMER_LIB=1 to reuse the decision helpers in tests.

set -uo pipefail

PMSET=${PMSET:-/usr/bin/pmset}
HELPER=${HELPER:-/usr/local/sbin/clamshell-helper}
LABEL=${LABEL:-io.github.bagilov.clamshell.timer}
INTERVAL=${INTERVAL:-20}
FLOOR=${FLOOR:-0}
DEADLINE=${DEADLINE:-0}

percent_now() {
    "$PMSET" -g batt 2>/dev/null | grep -oE '[0-9]+%' | head -1 | tr -d '%'
}

on_battery() {
    "$PMSET" -g batt 2>/dev/null | grep -q "Battery Power"
}

# Whether the configured battery floor has been reached on battery power.
# A floor of 0 disables the check, and wall power never triggers it.
floor_hit() {
    (( FLOOR > 0 )) || return 1
    on_battery || return 1
    local percent
    percent=$(percent_now) || return 1
    [[ -n "$percent" ]] || return 1
    (( percent <= FLOOR ))
}

# Whether the wall-clock deadline has passed.
deadline_hit() {
    (( $(date +%s) >= DEADLINE ))
}

restore_sleep() {
    sudo -n "$HELPER" off 2>/dev/null || true
    [[ -n "${STATE:-}" ]] && rm -f "$STATE"
    launchctl remove "$LABEL" 2>/dev/null || true
}

main() {
    DEADLINE="${1:?deadline required}"
    FLOOR="${2:-0}"
    STATE="${3:-}"
    while true; do
        if deadline_hit || floor_hit; then
            restore_sleep
            exit 0
        fi
        sleep "$INTERVAL"
    done
}

if [[ "${CLAMSHELL_TIMER_LIB:-}" != "1" ]]; then
    main "$@"
fi
