#!/usr/bin/env bash
# ZenAquarium Worlds - Linux installer (Electron build, per-user, no root except for system libraries)
#
#   curl -fsSL https://github.com/TPandaGames/zenaquarium-worlds/releases/latest/download/install.sh | bash
#
#   ./install.sh                 install the latest release
#   ./install.sh --autostart     also start the wallpaper at login
#   ./install.sh --appimage FILE install from a local AppImage instead of downloading
#   ./install.sh --version v2.0.0  install a specific release
#   ./install.sh --no-deps       skip installing system libraries
#   ./install.sh --no-start      don't launch it afterwards
#   ./install.sh --uninstall     remove everything this script installed
set -euo pipefail

APP_ID="zenaquarium-worlds"
APP_NAME="ZenAquarium Worlds"
REPO="TPandaGames/zenaquarium-worlds"
ASSET="ZenAquarium-Worlds-x86_64.AppImage"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
INSTALL_DIR="$DATA_HOME/$APP_ID"
APP_DIR="$INSTALL_DIR/app"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/$APP_ID"
DESKTOP_FILE="$DATA_HOME/applications/$APP_ID.desktop"
AUTOSTART_FILE="$CONFIG_HOME/autostart/$APP_ID.desktop"
ICON_DIR="$DATA_HOME/icons/hicolor/512x512/apps"

DO_AUTOSTART=0; DO_DEPS=1; DO_START=1; DO_UNINSTALL=0; LOCAL_APPIMAGE=""; VERSION=""

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --autostart) DO_AUTOSTART=1 ;;
    --no-deps)   DO_DEPS=0 ;;
    --no-start)  DO_START=0 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    --appimage)  shift; LOCAL_APPIMAGE="${1:-}"; [ -n "$LOCAL_APPIMAGE" ] || die "--appimage needs a file" ;;
    --version)   shift; VERSION="${1:-}"; [ -n "$VERSION" ] || die "--version needs a tag, e.g. v2.0.0" ;;
    -h|--help)   sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# ------------------------------------------------------------------ uninstall
if [ "$DO_UNINSTALL" = 1 ]; then
  say "Uninstalling $APP_NAME"
  if [ -x "$LAUNCHER" ]; then "$LAUNCHER" quit >/dev/null 2>&1 || true; sleep 1; fi
  rm -rf "$INSTALL_DIR" "$CONFIG_HOME/$APP_NAME"
  rm -f "$LAUNCHER" "$DESKTOP_FILE" "$AUTOSTART_FILE" "$ICON_DIR/$APP_ID.png"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA_HOME/applications" >/dev/null 2>&1 || true
  say "Removed. Your normal wallpaper is back."
  exit 0
fi

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root (it installs into your home directory)"
[ "$(uname -s)" = "Linux" ] || die "this installer is for Linux"
case "$(uname -m)" in x86_64|amd64) ;; *) die "only x86_64 builds are published for now (this machine is $(uname -m))" ;; esac

# ------------------------------------------------------------------ system libraries Electron needs
missing_libs() {
  # $1: path to the electron binary
  command -v ldd >/dev/null 2>&1 || return 0
  ldd "$1" 2>/dev/null | awk '/not found/ {print $1}'
}

install_deps() {
  local id="" like=""
  if [ -r /etc/os-release ]; then . /etc/os-release; id="${ID:-}"; like="${ID_LIKE:-}"; fi
  local fam="$id $like" SUDO=""
  [ "$(id -u)" -eq 0 ] || { command -v sudo >/dev/null 2>&1 && SUDO="sudo" || { warn "sudo not found - install Electron's system libraries manually (see README)"; return 0; }; }
  case "$fam" in
    *debian*|*ubuntu*|*mint*|*pop*)
      say "Installing system libraries with apt"
      $SUDO apt-get update -y
      local asound="libasound2"; apt-cache show libasound2t64 >/dev/null 2>&1 && asound="libasound2t64"
      local gtk="libgtk-3-0"; apt-cache show libgtk-3-0t64 >/dev/null 2>&1 && gtk="libgtk-3-0t64"
      local atk="libatk-bridge2.0-0"; apt-cache show libatk-bridge2.0-0t64 >/dev/null 2>&1 && atk="libatk-bridge2.0-0t64"
      $SUDO apt-get install -y "$gtk" libnss3 libgbm1 "$asound" libxss1 libxtst6 "$atk" libxkbcommon0 libdrm2 ca-certificates curl xdg-utils
      ;;
    *fedora*|*rhel*|*centos*)
      say "Installing system libraries with dnf"
      $SUDO dnf install -y gtk3 nss mesa-libgbm alsa-lib libXScrnSaver libXtst at-spi2-atk libxkbcommon libdrm curl xdg-utils ;;
    *arch*|*manjaro*|*endeavour*)
      say "Installing system libraries with pacman"
      $SUDO pacman -S --needed --noconfirm gtk3 nss mesa alsa-lib libxss libxtst at-spi2-core libxkbcommon libdrm curl xdg-utils ;;
    *suse*)
      say "Installing system libraries with zypper"
      $SUDO zypper --non-interactive install gtk3 mozilla-nss libgbm1 alsa libXss1 libXtst6 at-spi2-core libxkbcommon0 libdrm2 curl xdg-utils ;;
    *) warn "unrecognised distro ('$fam') - if it fails to start, install GTK 3, NSS, GBM, ALSA, libXss, libXtst and AT-SPI" ;;
  esac
}

# ------------------------------------------------------------------ get the AppImage
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "$LOCAL_APPIMAGE" ]; then
  [ -f "$LOCAL_APPIMAGE" ] || die "file not found: $LOCAL_APPIMAGE"
  cp "$LOCAL_APPIMAGE" "$TMP/app.AppImage"
else
  command -v curl >/dev/null 2>&1 || die "curl is required (sudo apt install curl / dnf install curl / pacman -S curl)"
  if [ -n "$VERSION" ]; then URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
  else URL="https://github.com/$REPO/releases/latest/download/$ASSET"; fi
  say "Downloading $ASSET"
  curl -fL --progress-bar -o "$TMP/app.AppImage" "$URL" || die "download failed: $URL"
fi
chmod +x "$TMP/app.AppImage"

# ------------------------------------------------------------------ unpack (no FUSE needed)
say "Unpacking"
( cd "$TMP" && ./app.AppImage --appimage-extract >/dev/null ) || die "could not unpack the AppImage"
[ -x "$TMP/squashfs-root/$APP_ID" ] || die "unexpected AppImage layout (no $APP_ID binary)"

if [ "$DO_DEPS" = 1 ]; then
  if [ -n "$(missing_libs "$TMP/squashfs-root/$APP_ID")" ]; then install_deps; else say "System libraries already present"; fi
  still="$(missing_libs "$TMP/squashfs-root/$APP_ID" | tr '\n' ' ')"
  [ -z "$still" ] || warn "still missing libraries: $still"
fi

# ------------------------------------------------------------------ install
say "Installing to $INSTALL_DIR"
[ -x "$LAUNCHER" ] && "$LAUNCHER" quit >/dev/null 2>&1 || true
rm -rf "$APP_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$ICON_DIR" "$(dirname "$DESKTOP_FILE")"
mv "$TMP/squashfs-root" "$APP_DIR"
chmod -R u+rwX "$APP_DIR"

ICON_SRC=""
for c in "$APP_DIR/$APP_ID.png" "$APP_DIR/usr/share/icons/hicolor/512x512/apps/$APP_ID.png" "$APP_DIR/.DirIcon"; do
  [ -f "$c" ] && { ICON_SRC="$c"; break; }
done
[ -n "$ICON_SRC" ] && cp -L "$ICON_SRC" "$ICON_DIR/$APP_ID.png" || warn "icon not found in the AppImage"

cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Launcher for $APP_NAME (installed by install.sh)
export ZQ_LAUNCHER="$LAUNCHER"
exec "$APP_DIR/$APP_ID" --no-sandbox "\$@"
EOF
chmod 0755 "$LAUNCHER"

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Interactive live wallpaper: Coral Reef, Deep Sea and Koi Pond
Exec=$LAUNCHER
Icon=$APP_ID
Terminal=false
Categories=Utility;Graphics;
StartupNotify=false
EOF

if [ "$DO_AUTOSTART" = 1 ]; then
  mkdir -p "$(dirname "$AUTOSTART_FILE")"
  cp "$DESKTOP_FILE" "$AUTOSTART_FILE"
  printf 'X-GNOME-Autostart-enabled=true\nX-GNOME-Autostart-Delay=3\n' >> "$AUTOSTART_FILE"
  say "Will start automatically at login"
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA_HOME/applications" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache  >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$DATA_HOME/icons/hicolor" >/dev/null 2>&1 || true
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR is not on your PATH - add it to run '$APP_ID' from a terminal" ;; esac

# ------------------------------------------------------------------ session notes
SESSION="${XDG_SESSION_TYPE:-unknown}"; DESK="${XDG_CURRENT_DESKTOP:-unknown}"
if [ "$SESSION" = "wayland" ]; then
  warn "Wayland session: the wallpaper runs through XWayland. KDE Plasma and Cinnamon handle this well; GNOME may show it as a normal window - log in with 'GNOME on Xorg' for a true wallpaper."
fi
case "$DESK" in *GNOME*) warn "GNOME hides tray icons unless the 'AppIndicator and KStatusNotifierItem Support' extension is enabled - the command line still works." ;; esac

say "Installed $APP_NAME"
echo "  Start:      $APP_ID            (or pick it from your app menu)"
echo "  Switch:     $APP_ID scene koi  (reef | abyss | koi)"
echo "  Control:    $APP_ID fish more | feed | pause | resume | cycle on | status | quit"
echo "  Uninstall:  curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash -s -- --uninstall"

if [ "$DO_START" = 1 ]; then
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    say "Starting wallpaper"
    nohup "$LAUNCHER" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  else
    warn "no graphical session detected - not starting. Run '$APP_ID' from your desktop session."
  fi
fi
