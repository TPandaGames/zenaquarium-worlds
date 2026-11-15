#!/usr/bin/env bash
# ZenAquarium Worlds - Linux installer (per-user, no root needed except for system packages)
#
#   ./install.sh                 install (installs missing dependencies with sudo if needed)
#   ./install.sh --autostart     also start the wallpaper at login
#   ./install.sh --no-deps       skip dependency installation
#   ./install.sh --no-start      don't launch it after installing
#   ./install.sh --uninstall     remove everything this script installed
set -euo pipefail

APP_ID="zenaquarium-worlds"
APP_NAME="ZenAquarium Worlds"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
INSTALL_DIR="$DATA_HOME/$APP_ID"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/$APP_ID"
DESKTOP_FILE="$DATA_HOME/applications/$APP_ID.desktop"
AUTOSTART_FILE="$CONFIG_HOME/autostart/$APP_ID.desktop"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"

DO_AUTOSTART=0; DO_DEPS=1; DO_START=1; DO_UNINSTALL=0

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --autostart) DO_AUTOSTART=1 ;;
    --no-deps)   DO_DEPS=0 ;;
    --no-start)  DO_START=0 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    -h|--help)   sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $arg (try --help)" ;;
  esac
done

# ------------------------------------------------------------------ uninstall
if [ "$DO_UNINSTALL" = 1 ]; then
  say "Uninstalling $APP_NAME"
  if [ -x "$LAUNCHER" ]; then "$LAUNCHER" quit >/dev/null 2>&1 || true; sleep 1; fi
  rm -rf "$INSTALL_DIR"
  rm -f "$LAUNCHER" "$DESKTOP_FILE" "$AUTOSTART_FILE" "$ICON_DIR/$APP_ID.svg"
  rm -rf "$CONFIG_HOME/$APP_ID"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA_HOME/applications" >/dev/null 2>&1 || true
  say "Removed. Your normal wallpaper is back."
  exit 0
fi

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root (it installs into your home directory)"
[ "$(uname -s)" = "Linux" ] || die "this installer is for Linux"
command -v python3 >/dev/null 2>&1 || NEED_PYTHON=1

# ------------------------------------------------------------------ locate payload
PY_SRC="$SCRIPT_DIR/zenaquarium_wallpaper.py"
SVG_SRC="$SCRIPT_DIR/$APP_ID.svg"
HTML_SRC=""
for c in "$SCRIPT_DIR/wallpaper.html" "$SCRIPT_DIR/../examples/zenaquarium_worlds_live_wallpaper.html"; do
  [ -f "$c" ] && { HTML_SRC="$c"; break; }
done
[ -f "$PY_SRC" ]   || die "missing $PY_SRC"
[ -f "$SVG_SRC" ]  || die "missing $SVG_SRC"
[ -n "$HTML_SRC" ] || die "missing wallpaper.html (expected next to this script or in ../examples/)"

# ------------------------------------------------------------------ dependencies
py_has() { python3 - "$@" >/dev/null 2>&1 <<'EOF'
import sys, gi
mods = sys.argv[1:]
for m in mods:
    ns, ver = m.split(":")
    gi.require_version(ns, ver)
EOF
}

webkit_ok()   { py_has Gtk:3.0 WebKit2:4.1 || py_has Gtk:3.0 WebKit2:4.0; }

install_deps() {
  local id="" like=""
  if [ -r /etc/os-release ]; then . /etc/os-release; id="${ID:-}"; like="${ID_LIKE:-}"; fi
  local fam="$id $like"
  local SUDO=""
  [ "$(id -u)" -eq 0 ] || { command -v sudo >/dev/null 2>&1 && SUDO="sudo" || die "need sudo to install packages; install them manually and re-run with --no-deps"; }

  local required=() optional=() mgr=""
  case "$fam" in
    *debian*|*ubuntu*|*mint*|*pop*)
      mgr="apt"
      required=(python3 python3-gi gir1.2-gtk-3.0)
      optional=(gir1.2-ayatanaappindicator3-0.1 gir1.2-gtklayershell-0.1)
      ;;
    *fedora*|*rhel*|*centos*)
      mgr="dnf"
      required=(python3 python3-gobject gtk3 webkit2gtk4.1)
      optional=(libayatana-appindicator-gtk3 gtk-layer-shell)
      ;;
    *arch*|*manjaro*|*endeavour*)
      mgr="pacman"
      required=(python python-gobject gtk3 webkit2gtk-4.1)
      optional=(libayatana-appindicator gtk-layer-shell)
      ;;
    *suse*)
      mgr="zypper"
      required=(python3 python3-gobject typelib-1_0-Gtk-3_0 typelib-1_0-WebKit2-4_1)
      optional=(typelib-1_0-AyatanaAppindicator3-0_1 typelib-1_0-GtkLayerShell-0_1)
      ;;
    *) warn "unrecognised distro ('$fam'); install these manually: Python 3, PyGObject, GTK 3, WebKit2GTK 4.1 (+ optional AppIndicator, gtk-layer-shell)"; return 0 ;;
  esac

  say "Installing dependencies with $mgr"
  case "$mgr" in
    apt)
      $SUDO apt-get update -y
      # Debian 13 / Ubuntu 24.04+ ship WebKit2 4.1; older releases only have 4.0
      if apt-cache show gir1.2-webkit2-4.1 >/dev/null 2>&1; then required+=(gir1.2-webkit2-4.1); else required+=(gir1.2-webkit2-4.0); fi
      $SUDO apt-get install -y "${required[@]}"
      for p in "${optional[@]}"; do $SUDO apt-get install -y "$p" || warn "optional package $p not available"; done ;;
    dnf)
      $SUDO dnf install -y "${required[@]}"
      for p in "${optional[@]}"; do $SUDO dnf install -y "$p" || warn "optional package $p not available"; done ;;
    pacman)
      $SUDO pacman -S --needed --noconfirm "${required[@]}"
      for p in "${optional[@]}"; do $SUDO pacman -S --needed --noconfirm "$p" || warn "optional package $p not available"; done ;;
    zypper)
      $SUDO zypper --non-interactive install "${required[@]}"
      for p in "${optional[@]}"; do $SUDO zypper --non-interactive install "$p" || warn "optional package $p not available"; done ;;
  esac
}

if [ "$DO_DEPS" = 1 ]; then
  if [ -n "${NEED_PYTHON:-}" ] || ! webkit_ok; then
    install_deps
  else
    say "Dependencies already present"
  fi
fi
command -v python3 >/dev/null 2>&1 || die "python3 not found"
webkit_ok || die "GTK3 + WebKit2GTK Python bindings are still missing. Install them (see README) or re-run without --no-deps."

# ------------------------------------------------------------------ install files
say "Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$ICON_DIR" "$(dirname "$DESKTOP_FILE")"
install -m 0644 "$HTML_SRC" "$INSTALL_DIR/wallpaper.html"
install -m 0755 "$PY_SRC"   "$INSTALL_DIR/zenaquarium_wallpaper.py"
install -m 0644 "$SVG_SRC"  "$INSTALL_DIR/$APP_ID.svg"
install -m 0644 "$SVG_SRC"  "$ICON_DIR/$APP_ID.svg"

cat > "$LAUNCHER" <<EOF
#!/bin/sh
exec python3 "$INSTALL_DIR/zenaquarium_wallpaper.py" "\$@"
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
case "$DESK" in
  *GNOME*|*Unity*)
    if [ "$SESSION" = "wayland" ]; then
      warn "GNOME on Wayland has no layer-shell support, so the wallpaper runs through XWayland and may appear as a normal window."
      warn "For a true desktop-layer wallpaper, log in with 'GNOME on Xorg' (or use KDE/Sway/Hyprland/XFCE/Cinnamon/MATE)."
    fi ;;
esac

say "Installed $APP_NAME"
echo "  Start:      $APP_ID            (or pick it from your app menu)"
echo "  Switch:     $APP_ID scene koi  (reef | abyss | koi)"
echo "  Control:    $APP_ID pause | resume | cycle on | status | quit"
echo "  Uninstall:  $SCRIPT_DIR/install.sh --uninstall"

if [ "$DO_START" = 1 ]; then
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    say "Starting wallpaper"
    nohup "$LAUNCHER" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  else
    warn "no graphical session detected - not starting. Run '$APP_ID' from your desktop session."
  fi
fi
