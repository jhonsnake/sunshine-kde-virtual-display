#!/bin/bash
# global_prep_cmd "do": a Moonlight/Artemis client connected.
# 1. create the virtual display at the client's requested resolution
# 2. inhibit idle/sleep for the session
# 3. go headless: disable the physical output(s); KWin relocates every window
#    and the cursor onto the only output left alive (the virtual one).
#
# Plasma 6.8 fix: `kscreen-doctor -j` no longer reports an "enabled" key per
# output, so the old `o.get('enabled')` checks were always false. Enabled state
# is now derived as: "enabled" key if present, otherwise connected AND
# priority > 0 (disabled outputs report priority 0).
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

# --- output-state helpers ---------------------------------------------------
# Modes:  is-enabled <name>        exit 0 if that output is enabled
#         physical-enabled <virt>  enabled outputs other than <virt>
#         physical-connected <virt> connected non-virtual outputs
KS_PY='
import sys, json
mode = sys.argv[1]
name = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    outs = json.load(sys.stdin)["outputs"]
except Exception:
    sys.exit(2)

def enabled(o):
    if "enabled" in o:
        return bool(o["enabled"])
    return bool(o.get("connected", True)) and o.get("priority", 0) > 0

def is_virtual(o):
    return "Virtual-" in o.get("name", "")

if mode == "is-enabled":
    sys.exit(0 if any(o.get("name") == name and enabled(o) for o in outs) else 1)
elif mode == "physical-enabled":
    for o in outs:
        if o.get("name") != name and not is_virtual(o) and enabled(o):
            print(o["name"])
elif mode == "physical-connected":
    for o in outs:
        if o.get("name") != name and not is_virtual(o) and o.get("connected", True):
            print(o["name"])
'
_ks() { kscreen-doctor -j 2>/dev/null | python3 -c "$KS_PY" "$@"; }

# Fallback if JSON is unusable: human-readable `kscreen-doctor -o`.
_enabled_text() {
    kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -E "^Output: [0-9]+ $1( |$)" | grep -qw enabled
}

_is_enabled() { _ks is-enabled "$1" || _enabled_text "$1"; }

# Ensure the virtual is actually enabled BEFORE blinding the physical output.
# Poll up to ~5s: the output can take a moment to settle after creation.
_is_enabled "$HEADLESS" || kscreen-doctor "output.$HEADLESS.enable" >> "$LOG" 2>&1
VIRT_OK=0
for _ in $(seq 1 10); do
    if _is_enabled "$HEADLESS"; then VIRT_OK=1; break; fi
    sleep 0.5
done

if [ "$VIRT_OK" -ne 1 ]; then
    log "connect ERROR: virtual $HEADLESS not enabled; leaving physical ON"
    {
        echo "--- DIAG: kscreen-doctor -j entry for $HEADLESS"
        kscreen-doctor -j 2>&1 | python3 -c "
import sys, json
name = sys.argv[1]
try:
    outs = json.load(sys.stdin)['outputs']
except Exception as e:
    print('JSON parse failed:', e); sys.exit()
for o in outs:
    if o.get('name') == name:
        print({k: v for k, v in o.items() if k != 'modes'})
" "$HEADLESS"
        echo "--- DIAG: kscreen-doctor -o"
        kscreen-doctor -o 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^Output:'
        echo "--- DIAG end"
    } >> "$LOG" 2>&1
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
SNAP="$(_ks physical-enabled "$HEADLESS")"
if [ -z "$SNAP" ] && [ ! -s "$PHYS_FILE" ]; then
    # Nothing detected and no earlier record: fall back to every connected
    # non-virtual output so we still go headless (and disconnect can restore).
    SNAP="$(_ks physical-connected "$HEADLESS")"
fi
[ -n "$SNAP" ] && printf '%s\n' "$SNAP" > "$PHYS_FILE"

while read -r name; do
    [ -n "$name" ] && kscreen-doctor "output.$name.disable" >> "$LOG" 2>&1
done < "$PHYS_FILE"

log "connect: headless on $HEADLESS, disabled [$(tr '\n' ' ' < "$PHYS_FILE" 2>/dev/null)]"
