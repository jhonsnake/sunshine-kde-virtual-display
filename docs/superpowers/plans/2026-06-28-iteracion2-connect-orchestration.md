# Iteración 2 — Orquestación connect/disconnect (KDE) — Plan de implementación

> **Para workers agénticos:** SUB-SKILL REQUERIDA: usar superpowers:subagent-driven-development (recomendado) o superpowers:executing-plans para implementar tarea por tarea. Los pasos usan checkbox (`- [ ]`).

**Goal:** Ligar el display virtual al ciclo de vida del cliente (crear-al-conectar a la resolución pedida, destruir-al-desconectar) dejando el monitor físico en modo headless mientras hay sesión.

**Architecture:** Hooks `global_prep_cmd` do/undo de Sunshine. `connect` crea el virtual con `krfb-virtualmonitor` a la resolución del cliente, inhibe idle/sleep y deshabilita los outputs físicos (KWin reubica solo ventanas + cursor). `disconnect` re-habilita el físico (siempre primero), destruye el virtual y libera el inhibidor. Enfoque A validado por un spike-gate; fallback C (DPMS-off) si el spike falla.

**Tech Stack:** bash, `krfb-virtualmonitor`, `kscreen-doctor`, `python3` (parseo JSON), `systemd-inhibit`, Sunshine (capture=kwin, encoder=nvenc), KDE Plasma 6 / Wayland.

## Global Constraints

- **Atribución:** NUNCA referenciar Claude / Claude Code / Anthropic en commits, código, comentarios ni `Co-Authored-By`. Autoría = `jhonsnake <jhonprada@gmail.com>` (fijada por-repo).
- **Idioma del repo:** comentarios de scripts y README en **inglés** (consistente con el código existente). Specs/planes/HANDOFF en español.
- **Nombre determinista del display:** `Virtual-SunshineHeadless` (de `--name SunshineHeadless`).
- **Regla de oro:** ningún camino de código puede dejar el PC sin ningún output habilitado. `disconnect` re-habilita el físico ANTES que nada; `connect` no deshabilita el físico si el virtual no quedó habilitado.
- **Estado en disco:** `~/.local/share/sunshine-physical-outputs.list` (outputs físicos deshabilitados) y `~/.local/share/sunshine-inhibit.pid` (PID del inhibidor). Log único: `~/.local/share/sunshine-headless.log`.
- **Sunshine cachea `output_name` al arrancar** (el string); resuelve el output por nombre al iniciar captura. El virtual debe existir con ese nombre cuando la captura arranca (lo crea el hook `do`).
- **Entorno:** GPU NVIDIA → `encoder=nvenc`; `sudo -A` con kdialog disponible en esta máquina.

---

### Task 1: Spike-gate — validar enfoque A (deshabilitar físico + reubicación KWin)

**El resultado de esta tarea decide si el resto del plan se implementa tal cual (A) o se replantea a fallback C.** Es disruptivo (apaga el monitor); se corre CON el usuario presente. Lleva auto-revert temporizado.

**Files:**
- Create: `scripts/spike-validate-A.sh`

**Interfaces:**
- Consumes: `display-backend.sh` (existente): `create_virtual_display`, `get_virtual_display_name`, `destroy_virtual_display`.
- Produces: veredicto (texto) PASS/FAIL para Spike-2. No lo consume otra tarea; informa la decisión humana.

- [ ] **Step 1: Escribir el script del spike**

```bash
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
```

- [ ] **Step 2: Verificar sintaxis**

Run: `bash -n scripts/spike-validate-A.sh`
Expected: sin salida (OK).

- [ ] **Step 3: Ejecutar el spike (CON el usuario, cliente conectado mirando)**

Run: `chmod +x scripts/spike-validate-A.sh && bash scripts/spike-validate-A.sh`
Expected (PASS de Spike-2): `Enabled outputs with only-virtual:` lista **solo** `Virtual-SunshineHeadless`; durante los 5s el escritorio + cursor + ventanas se ven en el virtual (en el cliente); tras el auto-revert, DP-1 vuelve con sus ventanas.
Expected (FAIL): KWin rechaza deshabilitar el último físico (DP-1 sigue `enabled`), o la pantalla queda negra sin reubicar. → cambiar a fallback C antes de seguir.

- [ ] **Step 4: Registrar el veredicto y decidir**

Si PASS → continuar Task 2 (enfoque A, tal cual el plan).
Si FAIL → PARAR. Replantear Tasks 4–5 a fallback C (DPMS-off + migración explícita por KWin scripting) antes de implementar. Documentar el veredicto en `HANDOFF.md`.

- [ ] **Step 5: Commit**

```bash
git add scripts/spike-validate-A.sh
git commit -m "test: add approach-A validation spike (KWin disable + window relocation)"
```

---

### Task 2: `sunshine-start.sh` — quitar creación al arranque + reconciliar

**Files:**
- Modify: `scripts/sunshine-start.sh` (reescritura completa)
- Test: verificación manual de estado

**Interfaces:**
- Consumes: `display-backend.sh`: `destroy_virtual_display`, `log`, `DISPLAY_BACKEND`.
- Produces: deja `~/.config/sunshine/sunshine.conf` con `output_name=Virtual-SunshineHeadless`, `capture=kwin`; lanza `sunshine` con `KWIN_DRM_NO_DIRECT_SCANOUT=1`. NO crea display.

- [ ] **Step 1: Reescribir `scripts/sunshine-start.sh`**

```bash
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
sed -i "s/^output_name *=.*/output_name = $HEADLESS_NAME/" "$CONF"
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
```

- [ ] **Step 2: Verificar sintaxis**

Run: `bash -n scripts/sunshine-start.sh`
Expected: sin salida.

- [ ] **Step 3: Verificación funcional (reconcile + arranque, sin cliente)**

Run:
```bash
pkill -x sunshine 2>/dev/null; sleep 1
cp scripts/*.sh ~/.local/bin/ && chmod +x ~/.local/bin/*.sh
nohup ~/.local/bin/sunshine-start.sh >/dev/null 2>&1 &
sleep 6
grep -E '^(output_name|capture)' ~/.config/sunshine/sunshine.conf
ss -tlpn | grep -E ':(47984|47989)'
kscreen-doctor -j | python3 -c "import sys,json;print([o['name'] for o in json.load(sys.stdin)['outputs']])"
```
Expected: `output_name = Virtual-SunshineHeadless`, `capture = kwin`; puertos escuchando; outputs = solo `['DP-1']` (NO se creó virtual al arrancar).

- [ ] **Step 4: Commit**

```bash
git add scripts/sunshine-start.sh
git commit -m "feat: move virtual display creation from startup to connect time"
```

---

### Task 3: `config/sunshine.conf` — registrar `global_prep_cmd`

**Files:**
- Modify: `config/sunshine.conf`

**Interfaces:**
- Produces: documenta el `global_prep_cmd`; el valor con rutas absolutas lo escribe `install.sh` (Task 8) en `~/.config/sunshine/sunshine.conf` porque Sunshine no expande `$HOME`.

- [ ] **Step 1: Editar `config/sunshine.conf`**

Añadir al final, como documentación del hook (rutas reales las pone install.sh):

```
# global_prep_cmd is written with absolute paths by install.sh, e.g.:
# global_prep_cmd = [{"do":"/home/<user>/.local/bin/sunshine-connect.sh","undo":"/home/<user>/.local/bin/sunshine-disconnect.sh","elevated":"false"}]
```

- [ ] **Step 2: Verificar que no rompe el formato actual**

Run: `grep -c 'global_prep_cmd' config/sunshine.conf`
Expected: `1` (solo el comentario).

- [ ] **Step 3: Commit**

```bash
git add config/sunshine.conf
git commit -m "docs: document global_prep_cmd hook in sunshine.conf"
```

---

### Task 4: `sunshine-connect.sh` — hook `do`

**Files:**
- Create: `scripts/sunshine-connect.sh`
- Test: verificación manual con auto-revert

**Interfaces:**
- Consumes: env de Sunshine `SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS`; `display-backend.sh`: `create_virtual_display`, `get_virtual_display_name`, `destroy_virtual_display`, `log`, `LOG`.
- Produces: escribe `~/.local/share/sunshine-physical-outputs.list` y `~/.local/share/sunshine-inhibit.pid`; deja el virtual habilitado y los físicos deshabilitados.

- [ ] **Step 1: Escribir `scripts/sunshine-connect.sh`**

```bash
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
systemd-inhibit --what=idle:sleep:handle-lid-switch --who=sunshine \
    --why="remote streaming session" --mode=block sleep infinity \
    >/dev/null 2>&1 &
echo $! > "$INHIBIT_PIDFILE"

# --- 3. go headless: record + disable physical outputs ----------------------
kscreen-doctor -j | python3 -c "
import sys,json
for o in json.load(sys.stdin)['outputs']:
    if o.get('enabled') and o['name'] != '$HEADLESS':
        print(o['name'])
" > "$PHYS_FILE"

while read -r name; do
    [ -n "$name" ] && kscreen-doctor "output.$name.disable" >> "$LOG" 2>&1
done < "$PHYS_FILE"

log "connect: headless on $HEADLESS, disabled [$(tr '\n' ' ' < "$PHYS_FILE")]"
```

- [ ] **Step 2: Verificar sintaxis**

Run: `bash -n scripts/sunshine-connect.sh`
Expected: sin salida.

- [ ] **Step 3: Verificación funcional simulada (CON usuario; auto-revert manual)**

Run (simula una conexión a 1280x720, espera 6s, restaura):
```bash
cp scripts/sunshine-connect.sh ~/.local/bin/ && chmod +x ~/.local/bin/sunshine-connect.sh
SUNSHINE_CLIENT_WIDTH=1280 SUNSHINE_CLIENT_HEIGHT=720 ~/.local/bin/sunshine-connect.sh
sleep 6
# revert inline (disconnect aún no existe en esta tarea):
for n in $(cat ~/.local/share/sunshine-physical-outputs.list); do kscreen-doctor "output.$n.enable"; done
source ~/.local/bin/display-backend.sh; destroy_virtual_display
kill "$(cat ~/.local/share/sunshine-inhibit.pid)" 2>/dev/null
```
Expected: durante los 6s, `kscreen-doctor -j` muestra `Virtual-SunshineHeadless` (1280x720) como único enabled y DP-1 disabled; el archivo `.list` contiene `DP-1`; tras revertir, DP-1 vuelve.

- [ ] **Step 4: Commit**

```bash
git add scripts/sunshine-connect.sh
git commit -m "feat: add connect hook (virtual at client res + headless)"
```

---

### Task 5: `sunshine-disconnect.sh` — hook `undo`

**Files:**
- Create: `scripts/sunshine-disconnect.sh`

**Interfaces:**
- Consumes: `~/.local/share/sunshine-physical-outputs.list`, `~/.local/share/sunshine-inhibit.pid`; `display-backend.sh`: `destroy_virtual_display`, `log`, `LOG`.
- Produces: re-habilita físicos, destruye virtual, libera inhibidor, limpia archivos de estado.

- [ ] **Step 1: Escribir `scripts/sunshine-disconnect.sh`**

```bash
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
```

- [ ] **Step 2: Verificar sintaxis**

Run: `bash -n scripts/sunshine-disconnect.sh`
Expected: sin salida.

- [ ] **Step 3: Verificación funcional (par connect→disconnect completo, CON usuario)**

Run:
```bash
cp scripts/sunshine-disconnect.sh ~/.local/bin/ && chmod +x ~/.local/bin/sunshine-disconnect.sh
SUNSHINE_CLIENT_WIDTH=1600 SUNSHINE_CLIENT_HEIGHT=900 ~/.local/bin/sunshine-connect.sh
sleep 4
~/.local/bin/sunshine-disconnect.sh
kscreen-doctor -j | python3 -c "import sys,json;print([(o['name'],o.get('enabled')) for o in json.load(sys.stdin)['outputs']])"
ls ~/.local/share/sunshine-physical-outputs.list 2>&1
```
Expected: tras disconnect, solo `[('DP-1', True)]`; el `.list` ya no existe; sin proceso `systemd-inhibit` huérfano (`pgrep -af 'systemd-inhibit.*sunshine'` vacío).

- [ ] **Step 4: Commit**

```bash
git add scripts/sunshine-disconnect.sh
git commit -m "feat: add disconnect hook (restore physical, teardown virtual)"
```

---

### Task 6: Integración end-to-end con cliente real (valida Spike-1)

**Files:**
- Modify: `config/sunshine.conf` → escribir `global_prep_cmd` real en `~/.config/sunshine/sunshine.conf` (manual aquí; lo automatiza install.sh en Task 8)
- Test: prueba con Artemis/Moonlight

**Interfaces:**
- Consumes: Tasks 2,4,5 instalados en `~/.local/bin`.

- [ ] **Step 1: Inyectar el `global_prep_cmd` real y reiniciar Sunshine**

```bash
CONF=~/.config/sunshine/sunshine.conf
LINE='global_prep_cmd = [{"do":"'"$HOME"'/.local/bin/sunshine-connect.sh","undo":"'"$HOME"'/.local/bin/sunshine-disconnect.sh","elevated":"false"}]'
grep -q '^global_prep_cmd' "$CONF" && sed -i "\|^global_prep_cmd|c\\$LINE" "$CONF" || echo "$LINE" >> "$CONF"
pkill -x sunshine; sleep 1; nohup ~/.local/bin/sunshine-start.sh >/dev/null 2>&1 &
```

- [ ] **Step 2: Conectar desde el cliente y verificar (manual)**

Desde Artemis/Moonlight, fijar resolución del cliente (p. ej. 1920x1080) y abrir "Desktop".
Expected (Spike-1 PASS): el stream arranca; `journalctl --user -u app-dev.lizardbyte.app.Sunshine.service` muestra `Screencasting ... output name Virtual-SunshineHeadless` a la resolución del cliente; la pantalla local se apaga; el escritorio se ve en el cliente.

- [ ] **Step 3: Verificar la adopción de resolución**

Cambiar la resolución en el cliente (p. ej. a 1280x720), reconectar.
Expected: el log muestra `connect: client requested 1280x720` y el screencast a 1280x720.

- [ ] **Step 4: Verificar el cierre del bug del cursor**

Desconectar. Expected: la pantalla física vuelve, las ventanas regresan a DP-1, y el cursor ya **no** puede ir a ningún monitor fantasma (`kscreen-doctor` lista solo DP-1).

- [ ] **Step 5: Commit (si hubo ajustes de scripts durante la prueba)**

```bash
git add -A && git commit -m "fix: end-to-end adjustments from real-client test" || echo "nada que commitear"
```

---

### Task 7: `sunshine-after-sleep.sh` — recuperación post-S3

**Files:**
- Create: `scripts/sunshine-after-sleep.sh`
- Create: `scripts/sunshine-after-sleep.service` (unit system, instalada por Task 8)

**Interfaces:**
- Consumes: nada del proyecto en runtime (corre tras resume).
- Produces: deja DP-1 con DPMS on y repintado tras suspensión.

- [ ] **Step 1: Escribir `scripts/sunshine-after-sleep.sh`**

```bash
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
```

- [ ] **Step 2: Escribir la unit `scripts/sunshine-after-sleep.service`**

```ini
[Unit]
Description=Refresh display after resume (sunshine headless)
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
User=__USER__
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_RUNTIME_DIR=/run/user/__UID__
ExecStart=/home/__USER__/.local/bin/sunshine-after-sleep.sh

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

- [ ] **Step 3: Verificar sintaxis del script**

Run: `bash -n scripts/sunshine-after-sleep.sh`
Expected: sin salida.

- [ ] **Step 4: Verificación funcional (manual, requiere suspender el equipo)**

Run: instalar temporalmente y suspender:
```bash
cp scripts/sunshine-after-sleep.sh ~/.local/bin/ && chmod +x ~/.local/bin/sunshine-after-sleep.sh
sudo -A sed "s/__USER__/$USER/g; s/__UID__/$(id -u)/g" scripts/sunshine-after-sleep.service \
  | sudo -A tee /etc/systemd/system/sunshine-after-sleep.service >/dev/null
sudo -A systemctl daemon-reload && sudo -A systemctl enable sunshine-after-sleep.service
systemctl suspend
```
Expected: tras reanudar, el log tiene `after_sleep: dpms refresh done` y la pantalla repinta sin negro; un cliente que conecta ve frames reales.

- [ ] **Step 5: Commit**

```bash
git add scripts/sunshine-after-sleep.sh scripts/sunshine-after-sleep.service
git commit -m "feat: add post-resume display refresh (S3)"
```

---

### Task 8: `install.sh` — instalador KDE

**Files:**
- Create: `scripts/install.sh`

**Interfaces:**
- Consumes: todos los scripts de `scripts/` y `config/sunshine.conf`, `autostart/sunshine-headless.desktop`.
- Produces: instala scripts en `~/.local/bin`, autostart, abre puertos UFW, escribe `global_prep_cmd`, instala la unit de after-sleep.

- [ ] **Step 1: Escribir `scripts/install.sh`**

```bash
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
```

- [ ] **Step 2: Verificar sintaxis**

Run: `bash -n scripts/install.sh`
Expected: sin salida.

- [ ] **Step 3: Verificación funcional (ejecución real del instalador)**

Run: `chmod +x scripts/install.sh && scripts/install.sh`
Expected: scripts en `~/.local/bin`, `.desktop` en autostart, `global_prep_cmd` en la conf, unit `sunshine-after-sleep.service` enabled, reglas UFW presentes (`sudo -A ufw status | grep Sunshine`).

- [ ] **Step 4: Commit**

```bash
git add scripts/install.sh
git commit -m "feat: add KDE installer (scripts, autostart, ufw, prep-cmd, resume unit)"
```

---

### Task 9: Documentación — README + HANDOFF

**Files:**
- Modify: `README.md`
- Modify: `HANDOFF.md` (local, no se commitea)

**Interfaces:** ninguna.

- [ ] **Step 1: Actualizar `README.md`** (en inglés) con el modelo connect-time: resolución dinámica del cliente, comportamiento headless, `install.sh`, y la nota de la GUI futura.

- [ ] **Step 2: Actualizar `HANDOFF.md`** (español) marcando la iteración 2 como hecha/verificada, con el veredicto del spike y el backlog (GUI, install unificado).

- [ ] **Step 3: Commit (solo README; HANDOFF está en .git/info/exclude)**

```bash
git add README.md
git commit -m "docs: document connect-time model, dynamic resolution and installer"
```

---

## Self-Review

**Cobertura del spec:**
- Bug cursor fantasma → Tasks 4/5 (crear/destruir por conexión) + Task 6 step 4. ✓
- Migrar sesión + físico desactivado → Task 4 (disable físico, KWin reubica) validado en Task 1. ✓
- Resolución del cliente → Task 4 (SUNSHINE_CLIENT_WIDTH/HEIGHT) + Task 6 step 3. ✓
- Restricción output_name cache → Task 2 + Task 6 (Spike-1). ✓
- Regla de oro / errores → Task 5 (enable primero), Task 2 (reconcile), Task 4 (guard virtual enabled). ✓
- After-sleep → Task 7. ✓
- install.sh + autostart + UFW → Task 8. ✓
- GUI futura → Task 9 (documentada como backlog). ✓
- Spike-gate A/C → Task 1. ✓

**Placeholders:** ninguno; todo el código de scripts está completo. Las verificaciones manuales (apagan el monitor / suspenden) están marcadas como tales con auto-revert/seguridad — son inherentes al dominio, no placeholders.

**Consistencia de tipos/nombres:** `Virtual-SunshineHeadless` y la interfaz `create_virtual_display`/`get_virtual_display_name`/`destroy_virtual_display` se usan idénticas en Tasks 1,2,4,5. Archivos de estado `sunshine-physical-outputs.list` y `sunshine-inhibit.pid` con las mismas rutas en Tasks 4,5,2. ✓
