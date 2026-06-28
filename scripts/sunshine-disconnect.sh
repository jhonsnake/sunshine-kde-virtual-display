#!/bin/bash
# global_prep_cmd "undo": the client disconnected. Restore local use.
# ORDER MATTERS: re-enable the physical output(s) FIRST so a failure in any
# later step never leaves the machine blind.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=display-backend.sh
source "$DIR/display-backend.sh"

PHYS_FILE="$HOME/.local/share/sunshine-physical-outputs.list"
INHIBIT_PIDFILE="$HOME/.local/share/sunshine-inhibit.pid"

# --- 1. re-enable physical outputs (fallback to DP-1) -----------------------
if [ -s "$PHYS_FILE" ]; then
    while read -r name; do
        [ -n "$name" ] && kscreen-doctor "output.$name.enable" >> "$LOG" 2>&1
    done < "$PHYS_FILE"
else
    kscreen-doctor "output.DP-1.enable" >> "$LOG" 2>&1
fi
rm -f "$PHYS_FILE"
sleep 0.5

# --- 2. destroy the virtual -> KWin returns windows to the physical output --
destroy_virtual_display

# --- 3. release the idle/sleep inhibitor ------------------------------------
[ -f "$INHIBIT_PIDFILE" ] && kill "$(cat "$INHIBIT_PIDFILE")" 2>/dev/null
rm -f "$INHIBIT_PIDFILE"

log "disconnect: physical restored, virtual destroyed, inhibitor released"
