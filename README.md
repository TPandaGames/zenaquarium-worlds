# ZenAquarium Worlds

A living, interactive **live wallpaper for Windows 11** with three animated worlds, drawn procedurally on an HTML5 canvas. No image or video files — everything is generated in real time.

| 🐠 Coral Reef | 🪼 Deep Sea | 🎏 Koi Pond |
|---|---|---|
| Bright tropical tank: corals, swaying anemones, clownfish, tangs, butterflyfish, parrotfish and a shimmering chromis school | Dark abyss: pulsing jellyfish, anglerfish with glowing lures, lanternfish schools, bioluminescent tube worms, a glowing vent | Top-down pond: undulating koi in six patterns, lily pads and lotus flowers, drifting petals, caustic light |

## Install (Windows 11)

1. Download **`ZenAquariumWorlds-Setup.exe`** from the [latest release](../../releases/latest).
2. Run it and click **Install & Launch**. (SmartScreen may warn about an unknown publisher because the exe is unsigned — choose *More info → Run anyway*.)
3. Use the fish icon in the system tray to switch worlds, pause, or exit.

Or from PowerShell, download and launch the installer in one line:

```powershell
irm https://github.com/TPandaGames/zenaquarium-worlds/releases/latest/download/ZenAquariumWorlds-Setup.exe -OutFile "$env:TEMP\ZenAquariumWorlds-Setup.exe"; & "$env:TEMP\ZenAquariumWorlds-Setup.exe"
```

Installs for the current user only (no administrator rights). Uninstall from **Settings → Apps → ZenAquarium Worlds**.

**Requirements:** Windows 11 x64 with the Microsoft Edge WebView2 Runtime (included with Windows 11). Tested on Windows 11 24H2; the code also has a path for the older desktop layout but it is untested.

### Tray menu
- Switch between **Coral Reef / Deep Sea / Koi Pond**
- **Fish in tank ▸** submenu: add or remove fish in bulk, or pick a species (e.g. *Clownfish ▸ Add one / Remove one*) — the list always matches the current world (up to 60 in the tank)
- **Auto-rotate worlds** every 3 minutes
- **Mouse interaction** — click the desktop to drop food, move the cursor to attract or startle the fish
- **Pause animation** (also pauses automatically while a full-screen app covers the desktop)
- **Start with Windows**, **Uninstall**, **Exit**

**Control bar on the desktop:** move your cursor to the top-right corner of the desktop and the bar fades in — switch worlds, `−` / `+` fish count, Feed, and settings. Click its buttons normally; click anywhere else on the bare desktop to drop food.

> Only one live-wallpaper app can own the desktop layer at a time. Exit other live-wallpaper software before running this one.

## Install (Linux)

The Linux version is an **Electron** app, so it runs on any distro with a graphical session. It is published as an AppImage and a `.deb`.

> **Status: experimental.** Install, run, command-line control, uninstall and the `.deb` were tested on Debian 13 (trixie) under WSLg, and the window is correctly marked as a desktop-layer window. Behaviour behind the icons on a real GNOME / KDE / XFCE desktop, and the tray icon, have not been tested on real hardware.

**One-line installer** — paste into a terminal:

```bash
curl -fsSL https://github.com/TPandaGames/zenaquarium-worlds/releases/latest/download/install.sh | bash
```

Add `-s -- --autostart` to also start it at login: `curl -fsSL .../install.sh | bash -s -- --autostart`. Needs `curl` (minimal installs may not have it: `sudo apt install curl`, `sudo dnf install curl`, `sudo pacman -S curl`).

The script downloads the AppImage, unpacks it (so **FUSE is not required**), installs any missing system libraries with your package manager (apt, dnf, pacman or zypper — `sudo` is only used for that), puts the app in `~/.local/share/zenaquarium-worlds`, and adds a `zenaquarium-worlds` command plus an app-menu entry. Options: `--autostart`, `--no-deps`, `--no-start`, `--version v2.0.0`, `--appimage FILE`, `--uninstall`.

**Debian / Ubuntu `.deb`:** download `zenaquarium-worlds_*_amd64.deb` from the [latest release](../../releases/latest) and run `sudo apt install ./zenaquarium-worlds_*_amd64.deb`.

**AppImage only:** download `ZenAquarium-Worlds-x86_64.AppImage`, `chmod +x` it and run it.

Control a running wallpaper from any terminal:

```bash
zenaquarium-worlds scene koi                      # reef | abyss | koi
zenaquarium-worlds fish more | fewer | +5 | -3    # change the number of fish
zenaquarium-worlds feed                           # drop food
zenaquarium-worlds pause | resume | cycle on|off
zenaquarium-worlds status                         # scene, fish total and per-species counts
zenaquarium-worlds quit
```

The tray icon has the same controls: worlds, **Fish in tank ▸** (bulk add/remove, or per species — *Clownfish ▸ Add one / Remove one*), Feed, auto-rotate, mouse interaction, pause, optional global shortcuts (`Ctrl+Alt+F`, `Ctrl+Alt+=` / `-`, `Ctrl+Alt+1-3`) and start at login. Moving the cursor to the top-right corner of the desktop reveals the control bar.

- **X11 sessions (XFCE, Cinnamon, MATE, KDE, GNOME on Xorg…):** runs as a desktop-layer window (`_NET_WM_WINDOW_TYPE_DESKTOP`).
- **Wayland sessions:** runs through XWayland (set `ZQ_WAYLAND=1` to force native Wayland, where it becomes an ordinary window). KDE Plasma and Cinnamon handle the desktop layer well; GNOME on Wayland may show it as a normal window — choose "GNOME on Xorg" for a true wallpaper.
- **GNOME tray:** GNOME hides tray icons unless the *AppIndicator and KStatusNotifierItem Support* extension is enabled. The command line always works.
- The Chromium sandbox is disabled (`--no-sandbox`); the app only ever loads its own bundled page.

## Use in a browser or another wallpaper engine

[`examples/zenaquarium_worlds_live_wallpaper.html`](examples/zenaquarium_worlds_live_wallpaper.html) is fully self-contained (no CDN, works offline). Open it in any browser, or add it to Lively Wallpaper / Wallpaper Engine.

- `1` `2` `3` switch worlds · `F` or click feeds the fish · double-click taps the glass
- **Fish counter** in the top bar: `−` / `+` buttons (Shift-click for 5 at a time) or the `-` / `+` keys
- Deep link a world: `?scene=abyss` or `#koi`

## Build from source

Requires the .NET SDK. The installer targets .NET Framework 4.8, so the finished exe needs no extra runtime.

```
cd installer
dotnet build -c Release
```

The output is `installer/bin/Release/net48/ZenAquariumWorlds-Setup.exe`. The wallpaper page and WebView2 libraries are embedded in it.

### Build the Linux (Electron) packages

Requires Node.js 22.12+ on Linux (AppImage/deb can't be cross-built from Windows).

```bash
cd electron
npm install
npm run dist          # -> electron/dist/*.AppImage and *.deb
npm run windowed      # run it as a normal window for development
```

`npm run sync` (run automatically) copies the shared page from `examples/` into the app so there is a single source of truth.

### How it works (Windows)
The host is a small WinForms app that embeds the page in a WebView2 control and parents that window into the desktop (`Progman` / `WorkerW`) behind the icons — handling both the classic layout and the Windows 11 24H2 layout. A low-level mouse hook forwards cursor movement and clicks to the page when the pointer is over the bare desktop.

## Project layout
```
examples/   the wallpaper page (HTML + canvas, no dependencies)
installer/  C# installer + wallpaper host for Windows (embeds the page)
electron/   Electron wallpaper host for Linux (AppImage + deb)
linux/      install.sh - the one-line Linux installer
```
