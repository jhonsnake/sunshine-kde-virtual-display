# Sunshine Virtual Display — KDE Plasma 6 / Wayland

Remote desktop on **KDE Plasma 6 (Wayland / KWin)** with a dedicated **virtual
display**: a headless monitor is created on demand and streamed to a
[Moonlight](https://moonlight-stream.org/) / **Artemis** client, leaving your
physical monitor free. Apollo-style virtual-display behaviour, built entirely
from userspace tools — no kernel module required.

> Origin note: this began as the KDE counterpart to my Hyprland setup,
> [sunshine-hyprland-virtual-display](https://github.com/jhonsnake/sunshine-hyprland-virtual-display).
> Hyprland creates headless outputs with `hyprctl`, which KWin has no equivalent
> for — so the display layer here is rebuilt around `krfb-virtualmonitor` and
> Sunshine's KWin capture.

## How it works

| Step | Tool |
|---|---|
| Create the virtual display | `krfb-virtualmonitor` (compositor-level output) |
| Let Sunshine capture it | `capture = kwin` |
| Discover the output name | `kscreen-doctor -j` |

Because `krfb-virtualmonitor` outputs live at the compositor level (not
DRM/KMS), Sunshine's default `kms` capture can't see them — it **must** use
`capture = kwin`. The output name is written into `sunshine.conf` *before*
Sunshine launches, since Sunshine caches `output_name` at startup.

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

## Setup

```bash
# 1. Config (save your existing sunshine.conf first if you have one)
mkdir -p ~/.config/sunshine
cp config/sunshine.conf ~/.config/sunshine/sunshine.conf

# 2. Scripts on PATH
mkdir -p ~/.local/bin
cp scripts/display-backend.sh scripts/sunshine-start.sh ~/.local/bin/
chmod +x ~/.local/bin/sunshine-start.sh

# 3. Launch on login
cp autostart/sunshine-headless.desktop ~/.config/autostart/
```

Then open `https://localhost:47990`, set your Sunshine credentials, and pair
your client.

## Usage

```bash
~/.local/bin/sunshine-start.sh                         # default: krfb, 1920x1080
RES=2560x1440 ~/.local/bin/sunshine-start.sh           # custom resolution
DISPLAY_BACKEND=evdi ~/.local/bin/sunshine-start.sh    # fallback backend
```

## Status

Verified on KDE Plasma 6 Wayland (NVIDIA / nvenc):

- `krfb-virtualmonitor` creates the virtual output at the requested resolution;
  `kscreen-doctor -j` lists it; teardown removes it cleanly.
- Sunshine with `capture = kwin` locates the output **by name** and starts a
  PipeWire screencast at the right resolution:
  ```
  Info: Screencasting with KWin ScreenCast
  Info: [kwingrab] Screencasting output name Virtual-SunshineHeadless resolution 1920x1080
  Info: [pipewire] Streaming display 'Virtual-SunshineHeadless' ... resolution: 1920x1080
  ```

Not yet covered: migrating windows onto the virtual display and turning the
physical monitor off on connect (planned).

## Known gotcha

KWin direct scanout on Plasma 6 crops fullscreen content on the client. The
launcher exports `KWIN_DRM_NO_DIRECT_SCANOUT=1` to avoid it.

## License

MIT
