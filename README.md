# ZenAquarium Worlds

A living, interactive **live wallpaper for Windows 11** with three animated worlds, drawn procedurally on an HTML5 canvas. No image or video files — everything is generated in real time.

| 🐠 Coral Reef | 🪼 Deep Sea | 🎏 Koi Pond |
|---|---|---|
| Bright tropical tank: corals, swaying anemones, clownfish, tangs, butterflyfish, parrotfish and a shimmering chromis school | Dark abyss: pulsing jellyfish, anglerfish with glowing lures, lanternfish schools, bioluminescent tube worms, a glowing vent | Top-down pond: undulating koi in six patterns, lily pads and lotus flowers, drifting petals, caustic light |

## Install (Windows 11)

1. Download **`ZenAquariumWorlds-Setup.exe`** from the [latest release](../../releases/latest).
2. Run it and click **Install & Launch**. (SmartScreen may warn about an unknown publisher because the exe is unsigned — choose *More info → Run anyway*.)
3. Use the fish icon in the system tray to switch worlds, pause, or exit.

Installs for the current user only (no administrator rights). Uninstall from **Settings → Apps → ZenAquarium Worlds**.

**Requirements:** Windows 11 x64 with the Microsoft Edge WebView2 Runtime (included with Windows 11). Tested on Windows 11 24H2; the code also has a path for the older desktop layout but it is untested.

### Tray menu
- Switch between **Coral Reef / Deep Sea / Koi Pond**
- **Auto-rotate worlds** every 3 minutes
- **Mouse interaction** — click the desktop to drop food, move the cursor to attract or startle the fish
- **Pause animation** (also pauses automatically while a full-screen app covers the desktop)
- **Start with Windows**, **Uninstall**, **Exit**

> Only one live-wallpaper app can own the desktop layer at a time. Exit other live-wallpaper software before running this one.

## Use in a browser or another wallpaper engine

[`examples/zenaquarium_worlds_live_wallpaper.html`](examples/zenaquarium_worlds_live_wallpaper.html) is fully self-contained (no CDN, works offline). Open it in any browser, or add it to Lively Wallpaper / Wallpaper Engine.

- `1` `2` `3` switch worlds · `F` or click feeds the fish · double-click taps the glass
- Deep link a world: `?scene=abyss` or `#koi`

## Build from source

Requires the .NET SDK. The installer targets .NET Framework 4.8, so the finished exe needs no extra runtime.

```
cd installer
dotnet build -c Release
```

The output is `installer/bin/Release/net48/ZenAquariumWorlds-Setup.exe`. The wallpaper page and WebView2 libraries are embedded in it.

### How it works
The host is a small WinForms app that embeds the page in a WebView2 control and parents that window into the desktop (`Progman` / `WorkerW`) behind the icons — handling both the classic layout and the Windows 11 24H2 layout. A low-level mouse hook forwards cursor movement and clicks to the page when the pointer is over the bare desktop.

## Project layout
```
examples/   the wallpaper page (HTML + canvas, no dependencies)
installer/  C# installer + wallpaper host (embeds the page)
```
