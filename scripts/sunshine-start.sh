#!/bin/bash
# Launch Sunshine for the connect-time virtual-display model.
#
# Unlike the MVP, this NO LONGER creates a virtual display at startup. The
# display is created by sunshine-connect.sh when a client connects and torn
# down by sunshine-disconnect.sh. Sunshine caches output_name (a string) at
# startup and resolves the matching output when capture begins, so the
# deterministic name Virtual-SunshineHeadless is written here and the output
# is created later by the connect hook.
set -u
LOG="$HOME/.local/share/sunshine-headless.log"
CONF="$HOME/.config/sunshine/sunshine.conf"
PHYS_FILE="$HOME/.local/share/sunshine-physical-outputs.list"
HEADLESS_NAME="Virtual-SunshineHeadless"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=display-backend.sh
source "$DIR/display-backend.sh"

mkdir -p "$(dirname "$LOG")"
log "=== sunshine-start (KDE, connect-time display) backend=$DISPLAY_BACKEND ==="

# --- Reconcile: recover from a disconnect hook that never ran ---------------
# Re-enable any physical output left disabled by a crashed session and tear
# down a stray virtual, so we never boot into a blind/headless state.
destroy_virtual_display
if [ -s "$PHYS_FILE" ]; then
    while read -r name; do
        [ -n "$name" ] && kscreen-doctor "output.$name.enable" >> "$LOG" 2>&1
    done < "$PHYS_FILE"
    rm -f "$PHYS_FILE"
    log "reconcile: re-enabled physical outputs from previous session"
fi

# --- Pin output_name + capture (output created later by the connect hook) ---
if grep -q '^output_name *=' "$CONF"; then
    sed -i "s/^output_name *=.*/output_name = $HEADLESS_NAME/" "$CONF"
else
    echo "output_name = $HEADLESS_NAME" >> "$CONF"
fi
if grep -q '^capture *=' "$CONF"; then
    sed -i "s/^capture *=.*/capture = kwin/" "$CONF"
else
    echo "capture = kwin" >> "$CONF"
fi
log "conf set: output_name=$HEADLESS_NAME capture=kwin"

# KWIN_DRM_NO_DIRECT_SCANOUT=1 prevents Plasma 6 fullscreen direct-scanout
# cropping seen on the client.
export KWIN_DRM_NO_DIRECT_SCANOUT=1
exec sunshine
