#!/usr/bin/env bash
# ZenAquarium Worlds - Linux installer (Electron build, per-user, no root except for system libraries)
#
#   curl -fsSL https://github.com/TPandaGames/zenaquarium-worlds/releases/latest/download/install.sh | bash
#
#   ./install.sh                 check requirements, then install the latest release
#   ./install.sh --check         only check requirements (downloads nothing) and report
#   ./install.sh --autostart     also start the wallpaper at login
#   ./install.sh --appimage FILE install from a local AppImage instead of downloading
#   ./install.sh --version v2.0.0  install a specific release
#   ./install.sh --no-deps       never install system libraries (just report what is missing)
#   ./install.sh --no-start      don't launch it afterwards
#   ./install.sh --uninstall     remove everything this script installed
set -euo pipefail

APP_ID="zenaquarium-worlds"
APP_NAME="ZenAquarium Worlds"
REPO="TPandaGames/zenaquarium-worlds"
ASSET="ZenAquarium-Worlds-x86_64.AppImage"
NEED_MB=700            # unpacked app + temporary AppImage
MIN_GLIBC="2.28"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
INSTALL_DIR="$DATA_HOME/$APP_ID"
APP_DIR="$INSTALL_DIR/app"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/$APP_ID"
DESKTOP_FILE="$DATA_HOME/applications/$APP_ID.desktop"
AUTOSTART_FILE="$CONFIG_HOME/autostart/$APP_ID.desktop"
ICON_DIR="$DATA_HOME/icons/hicolor/512x512/apps"

DO_AUTOSTART=0; DO_DEPS=1; DO_START=1; DO_UNINSTALL=0; DO_CHECK=0; LOCAL_APPIMAGE=""; VERSION=""

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { printf '  \033[33m!\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --autostart) DO_AUTOSTART=1 ;;
    --no-deps)   DO_DEPS=0 ;;
    --no-start)  DO_START=0 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    --check)     DO_CHECK=1 ;;
    --appimage)  shift; LOCAL_APPIMAGE="${1:-}"; [ -n "$LOCAL_APPIMAGE" ] || die "--appimage needs a file" ;;
    --version)   shift; VERSION="${1:-}"; [ -n "$VERSION" ] || die "--version needs a tag, e.g. v2.0.0" ;;
    -h|--help)   sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

if [ -n "$VERSION" ]; then URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
else URL="https://github.com/$REPO/releases/latest/download/$ASSET"; fi

# ------------------------------------------------------------------ requirement checks (run BEFORE any download)
# Shared libraries Electron needs at runtime (soname -> checked with ldconfig)
SONAMES="libgtk-3.so.0 libnss3.so libnssutil3.so libgbm.so.1 libasound.so.2 libXss.so.1 libXtst.so.6 libatk-bridge-2.0.so.0 libatspi.so.0 libxkbcommon.so.0 libdrm.so.2 libcups.so.2"

ldcache() {
  local l; l="$(command -v ldconfig 2>/dev/null || true)"
  [ -n "$l" ] || for c in /sbin/ldconfig /usr/sbin/ldconfig; do [ -x "$c" ] && { l="$c"; break; }; done
  [ -n "$l" ] && "$l" -p 2>/dev/null || true
}

missing_sonames() {
  local cache so out=""
  cache="$(ldcache)"
  [ -n "$cache" ] || return 0     # cannot tell - the post-install ldd check will catch real problems
  for so in $SONAMES; do
    # here-string, not a pipe: `grep -q` exits early and pipefail would report a false "missing"
    grep -qF -- "$so" <<<"$cache" || out="$out $so"
  done
  printf '%s' "$out"
}

free_mb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}'; }

preflight() {
  local bad=0 warns=0 f
  say "Checking requirements"

  [ "$(uname -s)" = "Linux" ] && pass "Linux" || { fail "this installer is for Linux"; bad=1; }

  case "$(uname -m)" in
    x86_64|amd64) pass "CPU architecture: x86_64" ;;
    *) fail "CPU architecture $(uname -m) - only x86_64 builds are published for now"; bad=1 ;;
  esac

  if [ "$(id -u)" -eq 0 ]; then fail "running as root - run as your normal user (it installs into your home directory)"; bad=1
  else pass "running as user $(id -un)"; fi

  local glibc; glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
  if [ -z "$glibc" ]; then note "could not detect glibc (musl/Alpine is not supported)"; warns=1
  elif [ "$(printf '%s\n%s\n' "$MIN_GLIBC" "$glibc" | sort -V | head -n1)" = "$MIN_GLIBC" ]; then pass "glibc $glibc (needs $MIN_GLIBC+)"
  else fail "glibc $glibc is too old (needs $MIN_GLIBC+)"; bad=1; fi

  # disk space in the places we write
  mkdir -p "$INSTALL_DIR" 2>/dev/null || true
  for d in "$INSTALL_DIR" "${TMPDIR:-/tmp}"; do
    f="$(free_mb "$d")"
    if [ -z "$f" ]; then note "could not measure free space in $d"
    elif [ "$f" -ge "$NEED_MB" ]; then pass "free space in $d: ${f} MB (needs ~${NEED_MB} MB)"
    else fail "only ${f} MB free in $d (needs ~${NEED_MB} MB)"; bad=1; fi
  done

  # download tooling + network (only when we actually have to download)
  if [ -z "$LOCAL_APPIMAGE" ]; then
    if command -v curl >/dev/null 2>&1; then
      pass "curl is installed"
      if curl -fsSIL --max-time 15 -o /dev/null "$URL" 2>/dev/null; then pass "release is reachable on GitHub"
      else fail "cannot reach $URL (offline, blocked, or that release does not exist)"; bad=1; fi
    else
      fail "curl is not installed (sudo apt install curl / dnf install curl / pacman -S curl)"; bad=1
    fi
  else
    if [ -f "$LOCAL_APPIMAGE" ]; then pass "using local AppImage: $LOCAL_APPIMAGE"; else fail "file not found: $LOCAL_APPIMAGE"; bad=1; fi
  fi

  # graphical session
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then pass "graphical session (${XDG_SESSION_TYPE:-x11/wayland})"
  else note "no graphical session detected - fine for installing, but the wallpaper can only start inside a desktop session"; fi

  # system libraries
  local miss; miss="$(missing_sonames)"
  if [ -z "$miss" ]; then pass "required system libraries are present"
  elif [ "$DO_DEPS" = 1 ]; then note "missing system libraries:$miss  (will be installed with your package manager)"
  else fail "missing system libraries:$miss  (re-run without --no-deps to install them)"; bad=1; fi

  PREFLIGHT_MISSING="$miss"
  return $bad
}

install_deps() {
  local id="" like=""
  if [ -r /etc/os-release ]; then . /etc/os-release; id="${ID:-}"; like="${ID_LIKE:-}"; fi
  local fam="$id $like" SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "need sudo to install system libraries; install them manually (see README) and re-run with --no-deps"
    SUDO="sudo"
  fi
  case "$fam" in
    *debian*|*ubuntu*|*mint*|*pop*)
      say "Installing system libraries with apt"
      $SUDO apt-get update -y
      t64() { if apt-cache show "${1}t64" >/dev/null 2>&1; then printf '%s' "${1}t64"; else printf '%s' "$1"; fi; }
      $SUDO apt-get install -y "$(t64 libgtk-3-0)" libnss3 libgbm1 "$(t64 libasound2)" libxss1 libxtst6 \
        "$(t64 libatk-bridge2.0-0)" "$(t64 libatspi2.0-0)" "$(t64 libcups2)" libxkbcommon0 libdrm2 ca-certificates xdg-utils ;;
    *fedora*|*rhel*|*centos*)
      say "Installing system libraries with dnf"
      $SUDO dnf install -y gtk3 nss mesa-libgbm alsa-lib libXScrnSaver libXtst at-spi2-atk at-spi2-core cups-libs libxkbcommon libdrm xdg-utils ;;
    *arch*|*manjaro*|*endeavour*)
      say "Installing system libraries with pacman"
      $SUDO pacman -S --needed --noconfirm gtk3 nss mesa alsa-lib libxss libxtst at-spi2-core libcups libxkbcommon libdrm xdg-utils ;;
    *suse*)
      say "Installing system libraries with zypper"
      $SUDO zypper --non-interactive install gtk3 mozilla-nss libgbm1 alsa libXss1 libXtst6 at-spi2-core cups-libs libxkbcommon0 libdrm2 xdg-utils ;;
    *) die "unrecognised distro ('$fam'). Install GTK 3, NSS, GBM, ALSA, libXss, libXtst, AT-SPI, CUPS, xkbcommon and libdrm, then re-run with --no-deps" ;;
  esac
}

PREFLIGHT_MISSING=""
if preflight; then RESULT=0; else RESULT=1; fi

if [ "$DO_CHECK" = 1 ]; then
  echo
  if [ "$RESULT" = 0 ]; then say "All required checks passed."; exit 0
  else die "some requirements are not met (see the ✗ lines above)."; fi
fi
[ "$RESULT" = 0 ] || die "requirements not met - nothing was downloaded or changed. Fix the ✗ items above and run again."

# install missing system libraries first, then re-check, so a failure never costs a download
if [ -n "$PREFLIGHT_MISSING" ] && [ "$DO_DEPS" = 1 ]; then
  install_deps
  PREFLIGHT_MISSING="$(missing_sonames)"
  [ -z "$PREFLIGHT_MISSING" ] || die "still missing libraries after installing:$PREFLIGHT_MISSING - nothing was downloaded."
  pass "system libraries installed"
fi

# ------------------------------------------------------------------ get the AppImage
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "$LOCAL_APPIMAGE" ]; then
  cp "$LOCAL_APPIMAGE" "$TMP/app.AppImage"
else
  say "Downloading $ASSET"
  curl -fL --progress-bar -o "$TMP/app.AppImage" "$URL" || die "download failed: $URL"
fi
chmod +x "$TMP/app.AppImage"

# ------------------------------------------------------------------ unpack (no FUSE needed)
say "Unpacking"
( cd "$TMP" && ./app.AppImage --appimage-extract >/dev/null ) || die "could not unpack the AppImage"
[ -x "$TMP/squashfs-root/$APP_ID" ] || die "unexpected AppImage layout (no $APP_ID binary)"
if command -v ldd >/dev/null 2>&1; then
  still="$(ldd "$TMP/squashfs-root/$APP_ID" 2>/dev/null | awk '/not found/ {print $1}' | tr '\n' ' ')"
  [ -z "$still" ] || warn "libraries the app links against are still missing: $still"
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
