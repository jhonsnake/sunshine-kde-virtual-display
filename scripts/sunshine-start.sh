#!/bin/bash
# Create a virtual display on KDE Plasma 6 / Wayland and launch Sunshine on it.
#
# Sunshine reads `output_name` ONCE at process startup and caches it, so the
# virtual output must exist AND its name must be in sunshine.conf BEFORE we exec
# sunshine. The compositor-specific work is delegated to display-backend.sh.
#
# Backend is swappable via DISPLAY_BACKEND (krfb default, evdi fallback); the
# matching capture method is selected automatically.

set -u
RES="${RES:-1920x1080}"
LOG="$HOME/.local/share/sunshine-headless.log"
CONF="$HOME/.config/sunshine/sunshine.conf"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=display-backend.sh
source "$DIR/display-backend.sh"

mkdir -p "$(dirname "$LOG")"
log "=== sunshine-start backend=$DISPLAY_BACKEND res=$RES ==="

# --- Clean any leftover virtual display from a previous session -------------
destroy_virtual_display
sleep 0.3

# --- Create the virtual display ---------------------------------------------
if ! create_virtual_display "$RES" "SunshineHeadless"; then
    log "ERROR: could not create virtual display; launching sunshine on default output"
    exec sunshine
fi

HEADLESS="$(get_virtual_display_name)"
log "virtual display ready: $HEADLESS"

# --- Pick the capture method that matches the backend -----------------------
# krfb output lives at the compositor level -> kms can't see it, use kwin.
# evdi output is a real DRM connector       -> the normal kms backend works.
case "$DISPLAY_BACKEND" in
    evdi) CAPTURE=kms ;;
    *)    CAPTURE=kwin ;;
esac

# --- Patch sunshine.conf BEFORE launching (output_name is cached at start) --
sed -i "s/^output_name *=.*/output_name = $HEADLESS/" "$CONF"
if grep -q '^capture *=' "$CONF"; then
    sed -i "s/^capture *=.*/capture = $CAPTURE/" "$CONF"
else
    echo "capture = $CAPTURE" >> "$CONF"
fi
log "sunshine.conf set: output_name=$HEADLESS capture=$CAPTURE"

# --- Launch Sunshine --------------------------------------------------------
# KWIN_DRM_NO_DIRECT_SCANOUT=1 prevents the Plasma 6 direct-scanout cropping
# of fullscreen content seen on the client.
export KWIN_DRM_NO_DIRECT_SCANOUT=1
exec sunshine
