# Sunshine Virtual Display — KDE Plasma 6 / Wayland

Remote desktop on **KDE Plasma 6 (Wayland / KWin)** with a dedicated **virtual
display**: a headless monitor is created on client connect and streamed to a
[Moonlight](https://moonlight-stream.org/) / **Artemis** client at the client's
requested resolution. The physical monitor is disabled for the duration of the
session so the machine runs fully headless. Everything returns on disconnect.
Apollo-style virtual-display behaviour, built entirely from userspace tools — no
kernel module required.

> Origin note: this began as the KDE counterpart to my Hyprland setup,
> [sunshine-hyprland-virtual-display](https://github.com/jhonsnake/sunshine-hyprland-virtual-display).
> Hyprland creates headless outputs with `hyprctl`, which KWin has no equivalent
> for — so the display layer here is rebuilt around `krfb-virtualmonitor` and
> Sunshine's KWin capture.

## How it works

The virtual display lifecycle is tied to the client connection via Sunshine's
`global_prep_cmd` (do/undo) hooks:

**On client connect** (`sunshine-connect.sh` — the `do` hook):

1. Reads `SUNSHINE_CLIENT_WIDTH` / `HEIGHT` (set by Sunshine) and creates a
   `krfb-virtualmonitor` output at exactly that resolution (`Virtual-SunshineHeadless`).
2. Acquires an idle/sleep inhibitor so the host doesn't suspend mid-stream.
3. Disables the physical output (`kscreen-doctor output.DP-1.disable`). KWin
   relocates all windows and the cursor to the virtual output automatically.
4. Sunshine finds `Virtual-SunshineHeadless` by name and starts the PipeWire
   screencast.

**On client disconnect** (`sunshine-disconnect.sh` — the `undo` hook):

1. Re-enables the physical output **first** (the machine is never left blind,
   even if a later step fails).
2. Destroys the `krfb-virtualmonitor` process. KWin moves windows back to the
   physical output.
3. Releases the idle/sleep inhibitor.

**At login / autostart** (`sunshine-start.sh`):

Reconciles any leftover state from a previous session (forces the physical
output enabled, kills orphaned `krfb-virtualmonitor` processes), writes
`sunshine.conf` with `output_name=Virtual-SunshineHeadless` and the
`global_prep_cmd` hooks, then launches Sunshine. The virtual output does
**not** need to exist at Sunshine startup; it only needs to exist with that
exact name when the `do` hook runs, which it always will.

| Step | Tool |
|---|---|
| Create the virtual display (at connect) | `krfb-virtualmonitor` (compositor-level output) |
| Let Sunshine capture it | `capture = kwin` |
| Discover the output name | diff of `kscreen-doctor -j` (always `Virtual-<hint>`) |
| Dynamic client resolution | `SUNSHINE_CLIENT_WIDTH` / `SUNSHINE_CLIENT_HEIGHT` env vars |

Because `krfb-virtualmonitor` outputs live at the compositor level (not
DRM/KMS), Sunshine's default `kms` capture can't see them — it **must** use
`capture = kwin`. The output name is written into `sunshine.conf` before
Sunshine launches; Sunshine caches `output_name` at startup and will find the
output by that name once the `do` hook creates it.

## Swappable display backend

Set `DISPLAY_BACKEND` before launching:

- **`krfb`** (default) — `krfb-virtualmonitor`, userspace only, `capture = kwin`.
- **`evdi`** (fallback) — kernel virtual display via `evdi-dkms`, a real DRM
  connector, `capture = kms`. Needs `evdi-dkms` (recompiled per kernel);
  NVIDIA untested.

`sunshine-start.sh` selects the matching capture method automatically.

## Requirements

KDE Plasma 6 on Wayland, plus:

```bash
# Arch / CachyOS
sudo pacman -S --needed krfb sunshine python jq libkscreen
# evdi fallback only:
# paru -S evdi-dkms
```

For NVIDIA `nvenc`, the proprietary driver (`nvidia-utils`) must be installed.
AMD/Intel: change `encoder = nvenc` to `encoder = vaapi` in `config/sunshine.conf`.

## Installation

The recommended way is to run the provided installer:

```bash
bash scripts/install.sh
```

The installer:
- Copies all scripts to `~/.local/bin` and marks them executable.
- Installs `autostart/sunshine-headless.desktop` to `~/.config/autostart`.
- Opens Sunshine's ports in UFW (if UFW is active).
- Writes `~/.config/sunshine/sunshine.conf` with the correct `global_prep_cmd`
  hooks (skips overwriting if the file already exists, and reminds you to check
  the `global_prep_cmd` section).
- Installs and enables a systemd unit for post-resume display recovery
  (`sunshine-after-sleep.sh`).
- Disables the upstream packaged Sunshine service if it is enabled (the autostart
  `.desktop` file handles launching instead).

Then open `https://localhost:47990`, set your Sunshine credentials, and pair
your client.

### Manual setup

If you prefer to do it by hand:

```bash
# 1. Config (save your existing sunshine.conf first if you have one)
mkdir -p ~/.config/sunshine
cp config/sunshine.conf ~/.config/sunshine/sunshine.conf

# 2. Scripts on PATH
mkdir -p ~/.local/bin
cp scripts/display-backend.sh scripts/sunshine-start.sh \
   scripts/sunshine-connect.sh scripts/sunshine-disconnect.sh \
   scripts/sunshine-after-sleep.sh ~/.local/bin/
chmod +x ~/.local/bin/sunshine-start.sh ~/.local/bin/sunshine-connect.sh \
         ~/.local/bin/sunshine-disconnect.sh ~/.local/bin/sunshine-after-sleep.sh

# 3. Launch on login
cp autostart/sunshine-headless.desktop ~/.config/autostart/
```

## Scripts

| Script | Role |
|---|---|
| `display-backend.sh` | Swappable backend: `create_virtual_display`, `get_virtual_display_name`, `destroy_virtual_display` |
| `sunshine-start.sh` | Login/autostart: reconcile state, write config, launch Sunshine |
| `sunshine-connect.sh` | `global_prep_cmd` **do**: create virtual display at client resolution, inhibit sleep, disable physical output |
| `sunshine-disconnect.sh` | `global_prep_cmd` **undo**: re-enable physical output, destroy virtual display, release inhibitor |
| `sunshine-after-sleep.sh` | Post-S3 resume: restore physical output state via `kscreen-doctor` |
| `install.sh` | One-shot installer (scripts, autostart, UFW, config, systemd unit) |

## Usage

Connect with Moonlight or Artemis at any resolution you like. The stream canvas
is created at the resolution your client requests. During the session the
physical monitor is off and the host is not usable locally; everything returns
when you disconnect.

```bash
# Run manually (normally started automatically at login)
~/.local/bin/sunshine-start.sh

# Test the display backend in isolation (create / discover / destroy)
source ~/.local/bin/display-backend.sh
create_virtual_display 1920x1080 SunshineHeadless && get_virtual_display_name && destroy_virtual_display

# Logs
tail -f ~/.local/share/sunshine-headless.log
```

## Status

Verified on KDE Plasma 6 Wayland (NVIDIA / nvenc):

- `krfb-virtualmonitor` creates the virtual output at the client's requested
  resolution; `kscreen-doctor -j` lists it; teardown removes it cleanly.
- Sunshine with `capture = kwin` locates the output **by name** and starts a
  PipeWire screencast at the right resolution:
  ```
  Info: Screencasting with KWin ScreenCast
  Info: [kwingrab] Screencasting output name Virtual-SunshineHeadless resolution 1920x1080
  Info: [pipewire] Streaming display 'Virtual-SunshineHeadless' ... resolution: 1920x1080
  ```
- Physical monitor is disabled on connect; KWin relocates windows and cursor to
  the virtual output without manual intervention.
- Physical monitor is restored on disconnect before the virtual output is
  destroyed, so the host is never left without a display.
- Post-S3 resume restores display state via `sunshine-after-sleep.sh`.

## Known gotcha

KWin direct scanout on Plasma 6 crops fullscreen content on the client. The
launcher exports `KWIN_DRM_NO_DIRECT_SCANOUT=1` to avoid it.

## Roadmap

- **Physical monitor preference GUI:** a small settings UI to let the user
  choose — without editing scripts — whether the physical monitor stays **off
  (headless, current default)** or remains **on and usable** while a client is
  connected. This would parametrize `sunshine-connect.sh` / `sunshine-disconnect.sh`
  via a preference file that the GUI writes.

## License

MIT
