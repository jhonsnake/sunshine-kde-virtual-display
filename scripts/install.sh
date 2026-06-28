#!/bin/bash
# Install the KDE virtual-display + Sunshine orchestration.
set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

command -v kscreen-doctor      >/dev/null || err "kscreen-doctor required (KDE Plasma)"
command -v krfb-virtualmonitor >/dev/null || err "krfb-virtualmonitor required (pkg: krfb)"
command -v sunshine            >/dev/null || err "sunshine required"
command -v python3             >/dev/null || err "python3 required"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
info "Installing scripts to ~/.local/bin"
mkdir -p ~/.local/bin
cp "$DIR"/scripts/{display-backend,sunshine-start,sunshine-connect,sunshine-disconnect,sunshine-after-sleep}.sh ~/.local/bin/
chmod +x ~/.local/bin/{display-backend,sunshine-start,sunshine-connect,sunshine-disconnect,sunshine-after-sleep}.sh

info "Installing autostart entry"
mkdir -p ~/.config/autostart
cp "$DIR"/autostart/sunshine-headless.desktop ~/.config/autostart/

mkdir -p ~/.config/sunshine
CONF=~/.config/sunshine/sunshine.conf
if [ ! -f "$CONF" ]; then
    info "Writing sunshine.conf"
    cp "$DIR"/config/sunshine.conf "$CONF"
else
    warn "sunshine.conf exists — leaving it, will only set global_prep_cmd"
fi

info "Wiring global_prep_cmd"
LINE='global_prep_cmd = [{"do":"'"$HOME"'/.local/bin/sunshine-connect.sh","undo":"'"$HOME"'/.local/bin/sunshine-disconnect.sh","elevated":"false"}]'
if grep -q '^global_prep_cmd' "$CONF"; then
    sed -i "\|^global_prep_cmd|c\\$LINE" "$CONF"
else
    echo "$LINE" >> "$CONF"
fi

if systemctl is-active --quiet ufw; then
    info "Opening Sunshine ports in UFW (LAN only)"
    LAN="$(ip route | awk '/proto kernel/ && /src/ {print $1; exit}')"
    sudo -A ufw allow from "$LAN" to any port 47984:48010 proto tcp comment 'Sunshine TCP'
    sudo -A ufw allow from "$LAN" to any port 47998:48010 proto udp comment 'Sunshine UDP'
    sudo -A ufw allow from "$LAN" to any port 5353 proto udp comment 'mDNS discovery'
fi

info "Installing post-resume unit"
sudo -A sed "s/__USER__/$USER/g; s/__UID__/$(id -u)/g" "$DIR"/scripts/sunshine-after-sleep.service \
  | sudo -A tee /etc/systemd/system/sunshine-after-sleep.service >/dev/null
sudo -A systemctl daemon-reload
sudo -A systemctl enable sunshine-after-sleep.service

# Disable the upstream packaged service so it doesn't grab the ports.
systemctl --user disable --now app-dev.lizardbyte.app.Sunshine.service 2>/dev/null || true

info "Done. Log out/in (or run ~/.local/bin/sunshine-start.sh), then pair at https://localhost:47990"
