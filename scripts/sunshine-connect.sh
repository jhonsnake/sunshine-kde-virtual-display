#!/bin/bash
# global_prep_cmd "do": a Moonlight/Artemis client connected.
# 1. create the virtual display at the client's requested resolution
# 2. inhibit idle/sleep for the session
# 3. go headless: disable the physical output(s); KWin relocates every window
#    and the cursor onto the only output left alive (the virtual one).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=display-backend.sh
source "$DIR/display-backend.sh"

PHYS_FILE="$HOME/.local/share/sunshine-physical-outputs.list"
INHIBIT_PIDFILE="$HOME/.local/share/sunshine-inhibit.pid"

W="${SUNSHINE_CLIENT_WIDTH:-1920}"; H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
RES="${W}x${H}"
log "connect: client requested ${RES} @ ${SUNSHINE_CLIENT_FPS:-?}fps"

# --- 1. create virtual at client resolution --------------------------------
destroy_virtual_display; sleep 0.3
if ! create_virtual_display "$RES" "SunshineHeadless"; then
    log "connect: ${RES} failed, retrying at 1920x1080"
    create_virtual_display "1920x1080" "SunshineHeadless" || {
        log "connect ERROR: no virtual display; leaving physical ON"; exit 0; }
fi
HEADLESS="$(get_virtual_display_name)"

# Ensure the virtual is actually enabled BEFORE blinding the physical output.
_is_enabled() { kscreen-doctor -j | python3 -c \
  "import sys,json;sys.exit(0 if any(o['name']=='$1' and o.get('enabled') for o in json.load(sys.stdin)['outputs']) else 1)"; }
_is_enabled "$HEADLESS" || { kscreen-doctor "output.$HEADLESS.enable" >> "$LOG" 2>&1; sleep 0.5; }
if ! _is_enabled "$HEADLESS"; then
    log "connect ERROR: virtual $HEADLESS not enabled; leaving physical ON"
    exit 0
fi
log "connect: virtual ready $HEADLESS @ $RES"

# --- 2. inhibit idle/sleep --------------------------------------------------
# Kill any inhibitor left by a prior connect that never got a disconnect, so a
# reconnect doesn't leak a permanent sleep block.
[ -f "$INHIBIT_PIDFILE" ] && kill "$(cat "$INHIBIT_PIDFILE")" 2>/dev/null
systemd-inhibit --what=idle:sleep:handle-lid-switch --who=sunshine \
    --why="remote streaming session" --mode=block sleep infinity \
    >/dev/null 2>&1 &
echo "$!" > "$INHIBIT_PIDFILE"

# --- 3. go headless: record + disable physical outputs ----------------------
# Snapshot the currently-enabled physical outputs. On a reconnect the physical
# output is already disabled, so this snapshot is empty — do NOT overwrite the
# record from the first connect, or disconnect won't know what to re-enable.
SNAP="$(kscreen-doctor -j | python3 -c "
import sys,json
for o in json.load(sys.stdin)['outputs']:
    if o.get('enabled') and o['name'] != '$HEADLESS':
        print(o['name'])
")"
[ -n "$SNAP" ] && printf '%s\n' "$SNAP" > "$PHYS_FILE"

while read -r name; do
    [ -n "$name" ] && kscreen-doctor "output.$name.disable" >> "$LOG" 2>&1
done < "$PHYS_FILE"

log "connect: headless on $HEADLESS, disabled [$(tr '\n' ' ' < "$PHYS_FILE" 2>/dev/null)]"
