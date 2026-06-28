#!/bin/bash
# Spike: validate approach A on KDE Plasma 6 / Wayland.
# Spike-2 (the risky one): can KWin disable the only physical output, leaving
# only the krfb virtual output alive, and relocate windows + cursor onto it?
# Auto-reverts after 6s no matter what (trap) so the session is never stranded.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/.local/share/sunshine-headless.log"
source "$DIR/display-backend.sh"

PHYS="$(kscreen-doctor -j | python3 -c "import sys,json;[print(o['name']) for o in json.load(sys.stdin)['outputs'] if o.get('enabled')]")"
echo "Physical outputs enabled now: $PHYS"

cleanup() {
    echo ">> auto-revert: re-enabling physical + destroying virtual"
    for n in $PHYS; do kscreen-doctor "output.$n.enable" >/dev/null 2>&1; done
    destroy_virtual_display
}
trap cleanup EXIT

destroy_virtual_display; sleep 0.3
create_virtual_display "1280x720" "SunshineHeadless" || { echo "FAIL: no virtual"; exit 1; }
HEADLESS="$(get_virtual_display_name)"
echo "virtual created: $HEADLESS"
# ensure virtual enabled
kscreen-doctor "output.$HEADLESS.enable" >/dev/null 2>&1; sleep 0.5

echo ">> disabling physical outputs (screen will go dark ~6s)..."
for n in $PHYS; do kscreen-doctor "output.$n.disable" >> "$LOG" 2>&1; done
sleep 1
# Did KWin keep a compositor alive on the virtual only?
ENABLED_AFTER="$(kscreen-doctor -j | python3 -c "import sys,json;[print(o['name']) for o in json.load(sys.stdin)['outputs'] if o.get('enabled')]" 2>/dev/null)"
echo "Enabled outputs with only-virtual: [$ENABLED_AFTER]"
sleep 5   # window to eyeball: does the client see the desktop on the virtual?
echo ">> reverting now"
# trap handles revert
