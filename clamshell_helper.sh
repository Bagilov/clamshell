#!/bin/bash
# Clamshell privileged helper.
#
# Tiny root-owned shim that toggles macOS "SleepDisabled" (pmset disablesleep).
# It accepts exactly one fixed argument, so the matching NOPASSWD sudoers rule
# grants no general root access. Installed by `clamshell install`.

set -euo pipefail

PMSET=/usr/bin/pmset
LOG=/var/log/clamshell-helper.log
MAX_LOG_BYTES=262144

log() {
    # Keep the log bounded so a long-running install cannot grow it forever.
    if [[ -f "$LOG" ]] && (( $(wc -c < "$LOG" 2>/dev/null || echo 0) > MAX_LOG_BYTES )); then
        tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" || true
    fi
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true
}

case "${1:-}" in
    on)
        "$PMSET" disablesleep 1
        log "on"
        ;;
    off)
        "$PMSET" disablesleep 0
        log "off"
        ;;
    *)
        echo "usage: clamshell-helper {on|off}" >&2
        exit 2
        ;;
esac
