#!/bin/bash
# Clamshell privileged helper.
#
# Tiny root-owned shim that toggles macOS "SleepDisabled" (pmset disablesleep).
# It accepts exactly one fixed argument, so the matching NOPASSWD sudoers rule
# grants no general root access. Installed by `clamshell install`.

set -euo pipefail

PMSET=${PMSET:-/usr/bin/pmset}
LOG=${LOG:-/var/log/clamshell-helper.log}
MAX_LOG_BYTES=${MAX_LOG_BYTES:-262144}

log() {
    # Keep the log bounded so a long-running install cannot grow it forever.
    # `mktemp` creates the staging file with O_EXCL under a randomised name, so a
    # predictable path cannot be pre-created as a symlink to a system file.
    # Every step tolerates failure: this runs under `set -e`, and a rotation
    # problem must not abort the helper before it records the current action.
    if [[ -f "$LOG" ]] && (( $(wc -c < "$LOG" 2>/dev/null || echo 0) > MAX_LOG_BYTES )); then
        local tmp=""
        if tmp=$(mktemp "${LOG}.XXXXXX" 2>/dev/null); then
            if tail -n 200 "$LOG" > "$tmp" 2>/dev/null; then
                # `mktemp` creates the file 0600, but the log is meant to be
                # world-readable like the postinstall-created original.
                if chmod 644 "$tmp" 2>/dev/null && mv "$tmp" "$LOG" 2>/dev/null; then
                    tmp=""
                fi
            fi
            [[ -z "$tmp" ]] || rm -f "$tmp" 2>/dev/null || true
        fi
    fi
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true
}

# Source with CLAMSHELL_HELPER_LIB=1 to reuse `log` in tests without touching
# pmset or the real log path.
if [[ "${CLAMSHELL_HELPER_LIB:-}" != "1" ]]; then
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
fi
