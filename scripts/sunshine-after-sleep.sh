#!/bin/bash
# Runs after S3 resume. In the connect-time-display model the virtual only
# exists during a session, so the job here is to leave the PHYSICAL output
# healthy: force DPMS on and nudge KWin to repaint. Needs the user session env
# (WAYLAND_DISPLAY, XDG_RUNTIME_DIR) — provided by the systemd unit.
LOG="$HOME/.local/share/sunshine-headless.log"
sleep 1
kscreen-doctor --dpms on  >> "$LOG" 2>&1 || true
kscreen-doctor --dpms off >> "$LOG" 2>&1 || true
sleep 0.3
kscreen-doctor --dpms on  >> "$LOG" 2>&1 || true
echo "$(date -Iseconds) after_sleep: dpms refresh done" >> "$LOG"
