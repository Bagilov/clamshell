#!/bin/bash
# Clamshell session watcher.
#
# Runs as a transient launchctl job for as long as sleep is disabled. Waits until
# the deadline passes or, when a battery floor is configured, until the battery
# drops to that floor while unplugged. Then restores sleep through the helper,
# clears the state file and removes its own job.
#
# It also keeps the built-in panel dark: with `pmset disablesleep` active macOS
# does not blank the screen when the lid closes (the idle display timer normally
# does that, and on battery that timer is off), so a shut lid can leave the panel
# lit. Each pass blanks it again unless an external display is attached.
#
# Usage: clamshell-timer <deadline-epoch> <floor-percent|0> <state-path>
#
# Source with CLAMSHELL_TIMER_LIB=1 to reuse the decision helpers in tests.

set -uo pipefail

PMSET=${PMSET:-/usr/bin/pmset}
IOREG=${IOREG:-/usr/sbin/ioreg}
SYSTEM_PROFILER=${SYSTEM_PROFILER:-/usr/sbin/system_profiler}
HELPER=${HELPER:-/usr/local/sbin/clamshell-helper}
OSASCRIPT=${OSASCRIPT:-/usr/bin/osascript}
LABEL=${LABEL:-io.github.bagilov.clamshell.timer}
INTERVAL=${INTERVAL:-20}
FLOOR=${FLOOR:-0}
DEADLINE=${DEADLINE:-0}
# Post a notification when a session ends. Set to 0 to keep the watcher silent.
NOTIFY=${NOTIFY:-1}
# The watcher runs as the invoking user, so it cannot write the helper log in
# /var/log; its own diagnostics go to the user's log directory instead.
LOG=${LOG:-$HOME/Library/Logs/clamshell.log}
# A refused sudo is usually transient (the user may be mid-authentication), so
# the restore is retried before the watcher gives up.
MAX_ATTEMPTS=${MAX_ATTEMPTS:-5}
ATTEMPTS=0

log_line() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true
}

# Post a user notification without blocking the watcher.
#
# The watcher runs unattended, so the only way a user learns a session ended —
# or that a restore failed — is a notification. Any failure is swallowed: a
# missing notification is a cosmetic loss, never a reason to skip the restore.
notify() {
    (( NOTIFY == 1 )) || return 0
    local message=$1
    "$OSASCRIPT" -e "display notification \"${message//\"/\\\"}\" \
with title \"Clamshell\"" >/dev/null 2>&1 || true
}

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

# Whether the lid (clamshell) is shut. An unreadable state is reported as "open",
# so a broken probe can never blank a screen the user is looking at.
lid_closed() {
    local state
    state=$("$IOREG" -r -k AppleClamshellState -d 1 2>/dev/null \
        | sed -nE 's/.*"AppleClamshellState" *= *(Yes|No).*/\1/p' | head -1)
    [[ "$state" == "Yes" ]]
}

# Whether any display other than the built-in panel is connected. Read from the
# JSON report because its keys are stable across localisations. An unreadable or
# empty report counts as "attached", which skips the blanking.
external_display_attached() {
    local report total internal
    report=$("$SYSTEM_PROFILER" -json SPDisplaysDataType 2>/dev/null) || return 0
    total=$(printf '%s' "$report" | grep -o 'spdisplays_connection_type' | wc -l | tr -d ' ')
    internal=$(printf '%s' "$report" | grep -o 'spdisplays_internal' | wc -l | tr -d ' ')
    (( total == 0 )) && return 0
    (( total > internal ))
}

# Whether the panel is currently lit. powerd holds a "display is on" assertion
# exactly while it is. Anything that is not a recognised assertions report counts
# as lit, so a failed query can only cause a redundant blank.
display_is_on() {
    local report
    report=$("$PMSET" -g assertions 2>/dev/null) || return 0
    [[ "$report" == *"Assertion status system-wide:"* ]] || return 0
    [[ "$report" == *"display is on"* ]]
}

# Whether the built-in panel has to be blanked right now: a shut lid, still lit,
# with no external display attached. Ordered cheapest probe first, and any probe
# failure means "leave the screen alone".
should_blank_for_lid() {
    lid_closed || return 1
    display_is_on || return 1
    external_display_attached && return 1
    return 0
}

# Blank the built-in panel for a shut lid. Runs on every pass, because opening the
# lid and closing it again re-lights the panel without touching this job.
blank_display_for_lid() {
    should_blank_for_lid || return 0
    "$PMSET" displaysleepnow 2>/dev/null || true
    log_line "blanked the built-in display for a shut lid"
}

# Restore sleep and clean up.
#
# On success the state file and this job are removed, so the session is really
# over, and a notification tells the user sleep is back on. On failure nothing
# is cleared: the pending trigger has to stay visible (and retryable) rather
# than leave sleep disabled with no trace, which would let the battery drain to
# zero unnoticed.
#
# Args:
#   $1: Human-readable reason the session ended, used in the notification.
#
# Returns: 0 when sleep was restored and cleaned up, 1 otherwise.
restore_sleep() {
    local reason=${1:-"the timer finished"}
    if ! sudo -n "$HELPER" off 2>/dev/null; then
        ATTEMPTS=$((ATTEMPTS + 1))
        log_line "failed to restore sleep (attempt $ATTEMPTS/$MAX_ATTEMPTS)"
        if (( ATTEMPTS >= MAX_ATTEMPTS )); then
            log_line "giving up after $ATTEMPTS attempts; state kept for 'clamshell off'"
            notify "Could not restore sleep; run \`clamshell off\`."
            return 1
        fi
        return 2
    fi
    [[ -n "${STATE:-}" ]] && rm -f "$STATE"
    launchctl remove "$LABEL" 2>/dev/null || true
    log_line "sleep restored"
    notify "Sleep restored: ${reason}."
    return 0
}

# Why the session is ending, for the notification text. The floor is checked
# when a floor is configured; otherwise the deadline is the only trigger.
end_reason() {
    if floor_hit; then
        local percent
        percent=$(percent_now)
        printf 'battery reached %s%%' "${percent:-the floor}"
    else
        printf 'the timer finished'
    fi
}

main() {
    DEADLINE="${1:?deadline required}"
    FLOOR="${2:-0}"
    STATE="${3:-}"
    local outcome
    while true; do
        if deadline_hit || floor_hit; then
            outcome=0
            restore_sleep "$(end_reason)" || outcome=$?
            if (( outcome == 0 )); then
                exit 0
            fi
            if (( outcome == 1 )); then
                # Out of retries: stop, but leave the state file in place so
                # `clamshell status` still reports the pending restore.
                exit 1
            fi
        fi
        blank_display_for_lid
        sleep "$INTERVAL"
    done
}

if [[ "${CLAMSHELL_TIMER_LIB:-}" != "1" ]]; then
    main "$@"
fi
