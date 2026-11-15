#!/usr/bin/env python3
"""ZenAquarium Worlds - live wallpaper host for Linux.

Shows the ZenAquarium page in a WebKitGTK view that is placed on the desktop layer:
  * X11 (and XWayland):   a borderless window with the _NET_WM_WINDOW_TYPE_DESKTOP hint, kept below
  * Wayland (wlroots/KDE): a gtk-layer-shell BACKGROUND surface (needs the gtk-layer-shell library)

Control a running instance from the command line, e.g.:
    zenaquarium-worlds scene koi
    zenaquarium-worlds pause | resume | cycle on | status | quit
"""
import argparse
import importlib
import json
import os
import signal
import socket
import sys

APP_NAME = "ZenAquarium Worlds"
APP_ID = "zenaquarium-worlds"
SCENES = (("reef", "Coral Reef"), ("abyss", "Deep Sea"), ("koi", "Koi Pond"))
SCENE_IDS = [s for s, _ in SCENES]

APP_DIR = os.path.dirname(os.path.realpath(__file__))
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), APP_ID)
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
SOCK_PATH = os.path.join(RUNTIME_DIR, "%s-%d.sock" % (APP_ID, os.getuid()))


# ----------------------------------------------------------------- config
def load_config():
    cfg = {"scene": "reef", "cycle": False}
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            cfg.update(json.load(f))
    except (OSError, ValueError):
        pass
    if cfg.get("scene") not in SCENE_IDS:
        cfg["scene"] = "reef"
    return cfg


def save_config(cfg):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
    except OSError:
        pass


# --------------------------------------------------------- remote control
def send_command(cmd, timeout=2.0):
    """Send one command to a running instance. Returns the reply or None if none is running."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(SOCK_PATH)
        s.sendall((cmd + "\n").encode())
        return s.recv(4096).decode().strip()
    except (OSError, socket.timeout):
        return None
    finally:
        s.close()


def find_html():
    for name in ("wallpaper.html", os.path.join("..", "examples", "zenaquarium_worlds_live_wallpaper.html")):
        p = os.path.normpath(os.path.join(APP_DIR, name))
        if os.path.exists(p):
            return p
    return None


# ------------------------------------------------- pick a display backend
def choose_backend():
    """Decide X11 vs native Wayland *before* GTK opens the display."""
    if os.environ.get("GDK_BACKEND"):
        return
    session = os.environ.get("XDG_SESSION_TYPE", "").lower()
    wayland = session == "wayland" or bool(os.environ.get("WAYLAND_DISPLAY"))
    if not wayland:
        return
    desktop = (os.environ.get("XDG_CURRENT_DESKTOP", "") + os.environ.get("DESKTOP_SESSION", "")).lower()
    try:
        import gi
        has_layer = bool(gi.Repository.get_default().enumerate_versions("GtkLayerShell"))
    except Exception:
        has_layer = False
    # GNOME's compositor has no layer-shell; everything else with the library can use it natively.
    if not has_layer or "gnome" in desktop or "unity" in desktop:
        if os.environ.get("DISPLAY"):
            os.environ["GDK_BACKEND"] = "x11"


def main_gui(args):
    choose_backend()
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    try:
        gi.require_version("WebKit2", "4.1")
    except ValueError:
        gi.require_version("WebKit2", "4.0")
    from gi.repository import Gdk, GLib, Gtk, WebKit2

    layer = None
    try:
        gi.require_version("GtkLayerShell", "0.1")
        from gi.repository import GtkLayerShell as layer
    except (ValueError, ImportError):
        layer = None

    indicator = None
    for ns in ("AyatanaAppIndicator3", "AppIndicator3"):
        try:
            gi.require_version(ns, "0.1")
            indicator = importlib.import_module("gi.repository." + ns)
            break
        except (ValueError, ImportError):
            continue

    html = find_html()
    if not html:
        print("error: wallpaper.html not found next to %s" % APP_DIR, file=sys.stderr)
        return 1

    cfg = load_config()
    if args.scene:
        cfg["scene"] = args.scene

    class Wallpaper(Gtk.Window):
        def __init__(self):
            super().__init__(title=APP_NAME + " Wallpaper")
            self.cfg = cfg
            self.user_paused = False
            self.ready = False
            self.building_menu = False

            self.set_decorated(False)
            self.set_accept_focus(False)
            self.set_focus_on_map(False)
            self.set_skip_taskbar_hint(True)
            self.set_skip_pager_hint(True)
            self.set_keep_below(True)
            self.set_type_hint(Gdk.WindowTypeHint.DESKTOP)
            self.stick()

            display = Gdk.Display.get_default()
            self.use_layer = False
            if layer is not None and "Wayland" in type(display).__name__:
                try:
                    if layer.is_supported():
                        layer.init_for_window(self)
                        layer.set_layer(self, layer.Layer.BACKGROUND)
                        for edge in (layer.Edge.TOP, layer.Edge.BOTTOM, layer.Edge.LEFT, layer.Edge.RIGHT):
                            layer.set_anchor(self, edge, True)
                        layer.set_exclusive_zone(self, -1)
                        self.use_layer = True
                except Exception as e:  # fall back to a plain window
                    print("layer-shell unavailable: %s" % e, file=sys.stderr)

            mon = display.get_primary_monitor() or display.get_monitor(0)
            geo = mon.get_geometry()
            self.set_default_size(geo.width, geo.height)
            if not self.use_layer:
                self.move(geo.x, geo.y)
                self.resize(geo.width, geo.height)

            ctx = WebKit2.WebContext.get_default()
            self.view = WebKit2.WebView.new_with_context(ctx)
            st = self.view.get_settings()
            st.set_enable_javascript(True)
            st.set_allow_file_access_from_file_urls(True)
            st.set_allow_universal_access_from_file_urls(True)
            st.set_enable_write_console_messages_to_stdout(False)
            try:
                st.set_hardware_acceleration_policy(WebKit2.HardwareAccelerationPolicy.ALWAYS)
            except Exception:
                pass
            try:
                self.view.set_background_color(Gdk.RGBA(0.008, 0.043, 0.086, 1.0))
            except Exception:
                pass
            self.view.connect("context-menu", lambda *a: True)
            self.view.connect("load-changed", self.on_load)
            self.add(self.view)

            url = "file://%s?wallpaper=1&scene=%s" % (html, self.cfg["scene"])
            self.view.load_uri(url)

            self.connect("destroy", lambda *_: self.shutdown())
            self.show_all()
            self.build_tray()

        # ---- page control
        def js(self, code):
            if not self.ready:
                return
            try:
                self.view.run_javascript(code, None, None, None)
            except Exception:
                pass

        def on_load(self, view, event):
            if event == WebKit2.LoadEvent.FINISHED:
                self.ready = True
                self.push_state()

        def push_state(self):
            self.js("zen.cycle(%s);" % ("true" if self.cfg.get("cycle") else "false"))
            self.js("zen.pause(%s);" % ("true" if self.user_paused else "false"))

        def set_scene(self, scene):
            if scene not in SCENE_IDS:
                return False
            self.cfg["scene"] = scene
            save_config(self.cfg)
            self.js("zen.setScene('%s');" % scene)
            self.sync_menu()
            return True

        def set_cycle(self, on):
            self.cfg["cycle"] = bool(on)
            save_config(self.cfg)
            self.js("zen.cycle(%s);" % ("true" if on else "false"))
            self.sync_menu()

        def set_paused(self, paused):
            self.user_paused = bool(paused)
            self.js("zen.pause(%s);" % ("true" if paused else "false"))
            self.sync_menu()

        def shutdown(self):
            try:
                os.unlink(SOCK_PATH)
            except OSError:
                pass
            Gtk.main_quit()

        # ---- tray
        def build_tray(self):
            self.indicator = None
            if indicator is None:
                print("note: no AppIndicator library found - tray icon disabled "
                      "(use the `zenaquarium-worlds` command to control it)", file=sys.stderr)
                return
            ind = indicator.Indicator.new(APP_ID, APP_ID, indicator.IndicatorCategory.APPLICATION_STATUS)
            icon_dirs = [os.path.join(os.path.dirname(APP_DIR), "icons", "hicolor", "scalable", "apps"), APP_DIR]
            for d in icon_dirs:
                if os.path.exists(os.path.join(d, APP_ID + ".svg")):
                    ind.set_icon_theme_path(d)
                    break
            ind.set_status(indicator.IndicatorStatus.ACTIVE)

            menu = Gtk.Menu()
            title = Gtk.MenuItem(label=APP_NAME)
            title.set_sensitive(False)
            menu.append(title)
            menu.append(Gtk.SeparatorMenuItem())

            self.scene_items = {}
            group = None
            for sid, label in SCENES:
                item = Gtk.RadioMenuItem.new_with_label_from_widget(group, label)
                group = group or item
                item.connect("toggled", self.on_scene_toggled, sid)
                menu.append(item)
                self.scene_items[sid] = item

            menu.append(Gtk.SeparatorMenuItem())
            self.cycle_item = Gtk.CheckMenuItem(label="Auto-rotate worlds (3 min)")
            self.cycle_item.connect("toggled", lambda w: None if self.building_menu else self.set_cycle(w.get_active()))
            menu.append(self.cycle_item)
            self.pause_item = Gtk.CheckMenuItem(label="Pause animation")
            self.pause_item.connect("toggled", lambda w: None if self.building_menu else self.set_paused(w.get_active()))
            menu.append(self.pause_item)
            menu.append(Gtk.SeparatorMenuItem())
            quit_item = Gtk.MenuItem(label="Quit wallpaper")
            quit_item.connect("activate", lambda *_: self.shutdown())
            menu.append(quit_item)
            menu.show_all()
            ind.set_menu(menu)
            self.indicator = ind
            self.sync_menu()

        def on_scene_toggled(self, item, sid):
            if self.building_menu or not item.get_active():
                return
            self.set_scene(sid)

        def sync_menu(self):
            if not getattr(self, "indicator", None):
                return
            self.building_menu = True
            for sid, item in self.scene_items.items():
                item.set_active(sid == self.cfg["scene"])
            self.cycle_item.set_active(bool(self.cfg.get("cycle")))
            self.pause_item.set_active(self.user_paused)
            self.building_menu = False

    win = Wallpaper()

    # ---- control socket
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o600)
    srv.listen(4)
    srv.setblocking(False)

    def handle(conn):
        try:
            conn.settimeout(1.0)
            line = conn.recv(256).decode().strip().split()
            cmd = line[0] if line else ""
            arg = line[1] if len(line) > 1 else ""
            reply = "ok"
            if cmd == "ping":
                reply = "pong"
            elif cmd == "scene":
                reply = "ok" if win.set_scene(arg) else "error: scene must be one of " + ", ".join(SCENE_IDS)
            elif cmd == "cycle":
                win.set_cycle(arg in ("on", "1", "true"))
            elif cmd == "pause":
                win.set_paused(True)
            elif cmd == "resume":
                win.set_paused(False)
            elif cmd == "toggle-pause":
                win.set_paused(not win.user_paused)
            elif cmd == "status":
                reply = "scene=%s cycle=%s paused=%s" % (win.cfg["scene"], win.cfg.get("cycle"), win.user_paused)
            elif cmd == "quit":
                conn.sendall(b"ok\n")
                GLib.idle_add(win.shutdown)
                return
            else:
                reply = "error: unknown command"
            conn.sendall((reply + "\n").encode())
        except OSError:
            pass
        finally:
            conn.close()

    def on_conn(fd, cond):
        try:
            conn, _ = srv.accept()
            handle(conn)
        except OSError:
            pass
        return True

    GLib.io_add_watch(srv.fileno(), GLib.IO_IN, on_conn)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, lambda: (win.shutdown(), False)[1])
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda: (win.shutdown(), False)[1])

    Gtk.main()
    return 0


def main():
    p = argparse.ArgumentParser(prog="zenaquarium-worlds", description=__doc__.split("\n")[0])
    p.add_argument("command", nargs="?", default="run",
                   choices=["run", "scene", "cycle", "pause", "resume", "toggle-pause", "status", "quit"],
                   help="run (default) starts the wallpaper; the others control a running instance")
    p.add_argument("value", nargs="?", help="scene name (reef|abyss|koi) or on|off for 'cycle'")
    p.add_argument("--scene", choices=SCENE_IDS, help="world to start with")
    args = p.parse_args()

    if args.command == "run":
        reply = send_command("ping")
        if reply == "pong":
            if args.scene:
                send_command("scene " + args.scene)
            print("%s is already running." % APP_NAME)
            return 0
        return main_gui(args)

    cmd = args.command
    if cmd in ("scene", "cycle"):
        if not args.value:
            p.error("'%s' needs a value" % cmd)
        cmd += " " + args.value
    reply = send_command(cmd)
    if reply is None:
        print("%s is not running. Start it with: zenaquarium-worlds" % APP_NAME, file=sys.stderr)
        return 1
    print(reply)
    return 0 if not reply.startswith("error") else 2


if __name__ == "__main__":
    sys.exit(main())
