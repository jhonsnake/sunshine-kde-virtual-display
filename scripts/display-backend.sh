#!/bin/bash
# Swappable virtual-display backend for KDE Plasma 6 / Wayland (KWin).
#
# KWin has no command to spawn a headless output on demand, so display creation
# is abstracted behind three functions with two interchangeable implementations
# selected via DISPLAY_BACKEND:
#
#   krfb (default) — krfb-virtualmonitor creates a virtual output at the
#                    *compositor* level. Userspace only, no kernel module.
#                    Sunshine must capture it with `capture = kwin` (the kms
#                    backend can't see compositor-level outputs).
#   evdi (fallback)— EVDI creates a real DRM connector via the kernel module.
#                    Sunshine captures it with the normal `capture = kms`.
#                    Needs evdi-dkms (recompiled per kernel); NVIDIA untested.
#
# Public interface (consumed by sunshine-start.sh):
#   create_virtual_display <WxH> <name-hint>  -> creates the output
#   get_virtual_display_name                  -> echoes the name KWin assigned
#   destroy_virtual_display                   -> tears it down
#
# State shared between functions via these files:
LOG="${LOG:-$HOME/.local/share/sunshine-headless.log}"
DISPLAY_BACKEND="${DISPLAY_BACKEND:-krfb}"
VDISPLAY_PIDFILE="$HOME/.local/share/sunshine-vdisplay.pid"
VDISPLAY_NAMEFILE="$HOME/.local/share/sunshine-vdisplay.name"

log() { echo "$(date -Iseconds) [$DISPLAY_BACKEND] $*" >> "$LOG"; }

# --- helpers ----------------------------------------------------------------

# All current output names, one per line.
_kscreen_output_names() {
    kscreen-doctor -j 2>/dev/null \
        | python3 -c "import sys,json; [print(o['name']) for o in json.load(sys.stdin).get('outputs',[])]"
}

# ===========================================================================
# krfb backend (default)
# ===========================================================================

_krfb_create() {
    local res="$1" name_hint="$2"
    # Snapshot existing outputs so we can identify the *new* one afterwards —
    # the assigned name isn't predictable, so diffing the output list is the
    # robust way to discover it.
    local before after new
    before="$(_kscreen_output_names | sort)"

    # --desktopfile NONE keeps it headless (no tray entry); the VNC port is
    # incidental (localhost) — we only want the virtual output it spawns.
    krfb-virtualmonitor --resolution "$res" --name "$name_hint" \
        --password "" --desktopfile NONE --scale 1 --port 5921 \
        >> "$LOG" 2>&1 &
    echo $! > "$VDISPLAY_PIDFILE"

    # Wait for KWin to register the new output (poll up to ~4s).
    for _ in $(seq 1 20); do
        sleep 0.2
        after="$(_kscreen_output_names | sort)"
        new="$(comm -13 <(echo "$before") <(echo "$after") | head -n1)"
        [ -n "$new" ] && break
    done

    if [ -z "$new" ]; then
        log "ERROR: krfb-virtualmonitor did not produce a new output"
        return 1
    fi
    echo "$new" > "$VDISPLAY_NAMEFILE"
    log "created virtual output: $new (${res})"
}

_krfb_destroy() {
    [ -f "$VDISPLAY_PIDFILE" ] && kill "$(cat "$VDISPLAY_PIDFILE")" 2>/dev/null
    rm -f "$VDISPLAY_PIDFILE" "$VDISPLAY_NAMEFILE"
}

# ===========================================================================
# evdi backend (fallback)
# ===========================================================================

_evdi_create() {
    local res="$1"
    local before after new
    before="$(_kscreen_output_names | sort)"

    if ! lsmod | grep -q '^evdi'; then
        sudo modprobe evdi >> "$LOG" 2>&1 || { log "ERROR: cannot load evdi module"; return 1; }
    fi

    # EVDI exposes a fresh DRM connector; KWin enables it as a real output.
    for _ in $(seq 1 20); do
        sleep 0.2
        after="$(_kscreen_output_names | sort)"
        new="$(comm -13 <(echo "$before") <(echo "$after") | head -n1)"
        [ -n "$new" ] && break
    done

    if [ -z "$new" ]; then
        log "ERROR: evdi did not produce a new output (is evdi-dkms installed?)"
        return 1
    fi
    # Apply the requested mode on the real DRM connector.
    kscreen-doctor "output.$new.mode.$res" >> "$LOG" 2>&1
    echo "$new" > "$VDISPLAY_NAMEFILE"
    log "created EVDI output: $new (${res})"
}

_evdi_destroy() {
    rm -f "$VDISPLAY_NAMEFILE"
    # Leave the module loaded; unloading evdi mid-session can wedge KWin.
}

# ===========================================================================
# Public dispatch
# ===========================================================================

create_virtual_display() {
    case "$DISPLAY_BACKEND" in
        krfb) _krfb_create "$@" ;;
        evdi) _evdi_create "$@" ;;
        *)    log "ERROR: unknown DISPLAY_BACKEND '$DISPLAY_BACKEND'"; return 1 ;;
    esac
}

get_virtual_display_name() {
    [ -f "$VDISPLAY_NAMEFILE" ] && cat "$VDISPLAY_NAMEFILE"
}

destroy_virtual_display() {
    case "$DISPLAY_BACKEND" in
        krfb) _krfb_destroy ;;
        evdi) _evdi_destroy ;;
    esac
}
