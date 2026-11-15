'use strict';
/**
 * ZenAquarium Worlds - Electron host.
 *
 * Runs the wallpaper page in a frameless window that is placed on the desktop layer
 * (X11 `_NET_WM_WINDOW_TYPE_DESKTOP`, also used via XWayland on Wayland sessions),
 * with a tray menu and a command-line interface:
 *
 *   zenaquarium-worlds                      start the wallpaper
 *   zenaquarium-worlds scene koi            reef | abyss | koi
 *   zenaquarium-worlds fish more|fewer|+5|-3
 *   zenaquarium-worlds feed | pause | resume | cycle on|off | status | quit
 *
 * Flags: --windowed (normal window, for development), --scene=<id>
 */
const { app, BrowserWindow, Tray, Menu, nativeImage, ipcMain, screen, globalShortcut } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const net = require('net');

const APP_NAME = 'ZenAquarium Worlds';
const APP_ID = 'zenaquarium-worlds';
const SCENES = [['reef', 'Coral Reef'], ['abyss', 'Deep Sea'], ['koi', 'Koi Pond']];
const SCENE_IDS = SCENES.map((s) => s[0]);
const COMMANDS = ['scene', 'cycle', 'fish', 'feed', 'pause', 'resume', 'toggle-pause', 'status', 'quit'];

const SOCK = process.platform === 'win32'
  ? '\\\\.\\pipe\\' + APP_ID
  : path.join(process.env.XDG_RUNTIME_DIR || os.tmpdir(), APP_ID + '-' + (process.getuid ? process.getuid() : 'u') + '.sock');

// ---------------------------------------------------------------- arguments
const argv = process.argv.slice(app.isPackaged ? 1 : 2);
const flags = argv.filter((a) => a.startsWith('--'));
const positional = argv.filter((a) => !a.startsWith('--'));
const command = COMMANDS.includes(positional[0]) ? positional[0] : null;
const commandValue = command ? positional[1] : null;
const windowed = flags.includes('--windowed');
const sceneFlag = (flags.find((f) => f.startsWith('--scene=')) || '').slice(8);

// The wallpaper only ever loads its own bundled page, so the Chromium sandbox helper
// (which needs setuid root and is often unavailable) is not needed.
app.commandLine.appendSwitch('no-sandbox');
// Window types only exist on X11. On Wayland sessions run through XWayland unless asked otherwise.
if (process.platform === 'linux' && !process.env.ZQ_WAYLAND) app.commandLine.appendSwitch('ozone-platform', 'x11');
if (process.env.ZQ_NO_GPU) app.disableHardwareAcceleration();

// ------------------------------------------------------------ CLI (client)
function runClient(cmd, value) {
  const line = value ? cmd + ' ' + value : cmd;
  let out = '';
  const sock = net.createConnection(SOCK);
  sock.setTimeout(4000, () => { sock.destroy(); });
  sock.on('connect', () => sock.write(line + '\n'));
  sock.on('data', (d) => { out += d; });
  sock.on('end', () => { process.stdout.write(out); app.exit(out.startsWith('error') ? 2 : 0); });
  sock.on('error', () => {
    process.stderr.write(APP_NAME + ' is not running. Start it with: zenaquarium-worlds\n');
    app.exit(1);
  });
  sock.on('close', () => { setTimeout(() => app.exit(out ? 0 : 1), 50); });
}

if (command) {
  runClient(command, commandValue);
} else {
  startApp();
}

// -------------------------------------------------------------------- app
function startApp() {
  if (!app.requestSingleInstanceLock()) {
    console.log(APP_NAME + ' is already running.');
    if (sceneFlag && SCENE_IDS.includes(sceneFlag)) { runClient('scene', sceneFlag); return; }
    app.quit();
    return;
  }

  let cfg = { scene: 'reef', cycle: false, mouse: true, shortcuts: false };
  let win = null, tray = null, server = null;
  let pageReady = false, paused = false;
  let fishTotal = '0', species = [];
  let lastCursor = { x: -1, y: -1, inside: false };

  const cfgFile = () => path.join(app.getPath('userData'), 'config.json');
  function loadCfg() {
    try { Object.assign(cfg, JSON.parse(fs.readFileSync(cfgFile(), 'utf8'))); } catch (e) { /* first run */ }
    if (!SCENE_IDS.includes(cfg.scene)) cfg.scene = 'reef';
    if (sceneFlag && SCENE_IDS.includes(sceneFlag)) cfg.scene = sceneFlag;
  }
  function saveCfg() {
    try { fs.mkdirSync(app.getPath('userData'), { recursive: true }); fs.writeFileSync(cfgFile(), JSON.stringify(cfg)); } catch (e) { /* ignore */ }
  }

  // ---- talking to the page
  function js(code) {
    if (!win || win.isDestroyed() || !pageReady) return;
    win.webContents.executeJavaScript(code).catch(() => {});
  }
  function pushState() {
    js('zen.cycle(' + (cfg.cycle ? 'true' : 'false') + ');');
    js('zen.pause(' + (paused ? 'true' : 'false') + ');');
    js('zen.state();');
  }
  const setScene = (id) => {
    if (!SCENE_IDS.includes(id)) return false;
    cfg.scene = id; saveCfg(); js("zen.setScene('" + id + "');"); rebuildMenu(); return true;
  };
  const setCycle = (on) => { cfg.cycle = !!on; saveCfg(); js('zen.cycle(' + (cfg.cycle ? 'true' : 'false') + ');'); rebuildMenu(); };
  const setPaused = (p) => { paused = !!p; js('zen.pause(' + (paused ? 'true' : 'false') + ');'); rebuildMenu(); };
  const changeFish = (d) => js('zen.fish(' + (parseInt(d, 10) || 0) + ');');
  const changeSpecies = (id, d) => { if (/^[A-Za-z0-9]+$/.test(id)) js("zen.species('" + id + "'," + (d | 0) + ');'); };
  const feed = () => js('zen.feed();');

  // The page reports "scene|total|id:name:count;id:name:count" whenever the tank changes
  ipcMain.on('zen:state', (event, msg) => {
    try {
      const parts = String(msg).split('|');
      if (parts.length < 3) return;
      if (SCENE_IDS.includes(parts[0]) && parts[0] !== cfg.scene) { cfg.scene = parts[0]; saveCfg(); }
      fishTotal = parts[1];
      species = parts[2].split(';').map((r) => r.split(':')).filter((r) => r.length === 3);
      rebuildMenu();
    } catch (e) { /* ignore malformed state */ }
  });

  // ---- window
  function createWindow() {
    const d = screen.getPrimaryDisplay();
    const b = d.bounds;
    const opts = {
      x: b.x, y: b.y, width: b.width, height: b.height,
      show: false, frame: false, skipTaskbar: true, hasShadow: false,
      backgroundColor: '#020b16', title: APP_NAME + ' Wallpaper',
      webPreferences: {
        preload: path.join(__dirname, 'preload.js'),
        contextIsolation: true, nodeIntegration: false, sandbox: false,
        backgroundThrottling: false, spellcheck: false
      }
    };
    if (windowed) {
      Object.assign(opts, { x: undefined, y: undefined, width: 1280, height: 720, frame: true, skipTaskbar: false, show: false });
    } else {
      Object.assign(opts, { resizable: false, movable: false, minimizable: false, maximizable: false, fullscreenable: false, focusable: false });
      if (process.platform === 'linux') opts.type = 'desktop';
    }
    win = new BrowserWindow(opts);
    win.setMenuBarVisibility(false);
    win.webContents.on('did-finish-load', () => { pageReady = true; pushState(); });
    win.webContents.on('context-menu', (e) => e.preventDefault());
    win.once('ready-to-show', () => { if (windowed) win.show(); else win.showInactive(); });
    win.on('closed', () => { win = null; pageReady = false; });
    win.loadFile(path.join(__dirname, 'wallpaper.html'), { query: { wallpaper: windowed ? '' : '1', scene: cfg.scene } });
  }

  function fitToDisplay() {
    if (!win || windowed) return;
    const b = screen.getPrimaryDisplay().bounds;
    win.setBounds({ x: b.x, y: b.y, width: b.width, height: b.height });
  }

  // ---- cursor tracking (so the fish notice the cursor and the control bar can appear)
  function pollCursor() {
    if (!cfg.mouse || !pageReady || paused || !win || windowed) return;
    const p = screen.getCursorScreenPoint();
    const b = win.getBounds();
    const inside = p.x >= b.x && p.x < b.x + b.width && p.y >= b.y && p.y < b.y + b.height;
    if (inside) {
      if (Math.abs(p.x - lastCursor.x) + Math.abs(p.y - lastCursor.y) < 2 && lastCursor.inside) return;
      js('zen.mouse(' + ((p.x - b.x) / b.width).toFixed(4) + ',' + ((p.y - b.y) / b.height).toFixed(4) + ',false);');
    } else if (lastCursor.inside) {
      js('zen.mouse(-1,-1,false);');
    }
    lastCursor = { x: p.x, y: p.y, inside };
  }

  // ---- autostart (XDG)
  const autostartFile = path.join(os.homedir(), '.config', 'autostart', APP_ID + '.desktop');
  const isAutostart = () => fs.existsSync(autostartFile);
  function setAutostart(on) {
    try {
      if (on) {
        const exec = process.env.ZQ_LAUNCHER || process.env.APPIMAGE || process.execPath;
        fs.mkdirSync(path.dirname(autostartFile), { recursive: true });
        fs.writeFileSync(autostartFile,
          '[Desktop Entry]\nType=Application\nName=' + APP_NAME + '\nExec="' + exec + '" --no-sandbox\nIcon=' + APP_ID +
          '\nTerminal=false\nX-GNOME-Autostart-enabled=true\nX-GNOME-Autostart-Delay=3\n');
      } else {
        fs.rmSync(autostartFile, { force: true });
      }
    } catch (e) { /* ignore */ }
    rebuildMenu();
  }

  // ---- optional global shortcuts (X11 only)
  function applyShortcuts() {
    globalShortcut.unregisterAll();
    if (!cfg.shortcuts) return;
    const reg = (acc, fn) => { try { globalShortcut.register(acc, fn); } catch (e) { /* taken */ } };
    reg('Ctrl+Alt+F', feed);
    reg('Ctrl+Alt+=', () => changeFish(1));
    reg('Ctrl+Alt+-', () => changeFish(-1));
    reg('Ctrl+Alt+1', () => setScene('reef'));
    reg('Ctrl+Alt+2', () => setScene('abyss'));
    reg('Ctrl+Alt+3', () => setScene('koi'));
  }

  // ---- tray
  function buildTemplate() {
    const fishMenu = [
      { label: fishTotal + ' creatures in this world', enabled: false },
      { label: 'Add fish (mixed)', click: () => changeFish(2) },
      { label: 'Remove fish (mixed)', click: () => changeFish(-2) },
      { type: 'separator' }
    ];
    if (!species.length) fishMenu.push({ label: 'Waiting for the tank...', enabled: false });
    for (const [id, name, count] of species) {
      fishMenu.push({
        label: name + '  (' + count + ')',
        submenu: [
          { label: 'Add one', click: () => changeSpecies(id, 1) },
          { label: 'Remove one', click: () => changeSpecies(id, -1) }
        ]
      });
    }
    return [
      { label: APP_NAME, enabled: false },
      { type: 'separator' },
      ...SCENES.map(([id, label]) => ({ label, type: 'radio', checked: cfg.scene === id, click: () => setScene(id) })),
      { type: 'separator' },
      { label: 'Fish in tank', submenu: fishMenu },
      { label: 'Feed the fish', click: feed },
      { type: 'separator' },
      { label: 'Auto-rotate worlds (3 min)', type: 'checkbox', checked: cfg.cycle, click: (i) => setCycle(i.checked) },
      { label: 'Mouse interaction', type: 'checkbox', checked: cfg.mouse, click: (i) => { cfg.mouse = i.checked; saveCfg(); if (!cfg.mouse) js('zen.mouse(-1,-1,false);'); } },
      { label: 'Pause animation', type: 'checkbox', checked: paused, click: (i) => setPaused(i.checked) },
      { label: 'Global shortcuts (Ctrl+Alt+F / + / - / 1-3)', type: 'checkbox', checked: cfg.shortcuts, click: (i) => { cfg.shortcuts = i.checked; saveCfg(); applyShortcuts(); } },
      { type: 'separator' },
      { label: 'Start at login', type: 'checkbox', checked: isAutostart(), click: (i) => setAutostart(i.checked) },
      { label: 'Quit wallpaper', click: () => app.quit() }
    ];
  }
  function rebuildMenu() {
    if (!tray) return;
    tray.setContextMenu(Menu.buildFromTemplate(buildTemplate()));
  }
  function createTray() {
    let img = nativeImage.createFromPath(path.join(__dirname, 'assets', 'icon.png'));
    if (!img.isEmpty()) img = img.resize({ width: 22, height: 22 });
    tray = new Tray(img);
    tray.setToolTip(APP_NAME);
    rebuildMenu();
  }

  // ---- control socket (CLI)
  function handle(line) {
    const [cmd, arg = ''] = line.trim().split(/\s+/);
    switch (cmd) {
      case 'ping': return 'pong';
      case 'scene': return setScene(arg) ? 'ok' : 'error: scene must be one of ' + SCENE_IDS.join(', ');
      case 'cycle': setCycle(['on', '1', 'true'].includes(arg)); return 'ok';
      case 'feed': feed(); return 'ok';
      case 'pause': setPaused(true); return 'ok';
      case 'resume': setPaused(false); return 'ok';
      case 'toggle-pause': setPaused(!paused); return 'ok';
      case 'fish': {
        const words = { more: 2, add: 2, fewer: -2, less: -2, remove: -2 };
        const d = Object.prototype.hasOwnProperty.call(words, arg) ? words[arg] : parseInt(arg, 10);
        if (Number.isNaN(d)) return "error: use 'fish more', 'fish fewer' or 'fish +N' / 'fish -N'";
        changeFish(Math.max(-60, Math.min(60, d))); return 'ok';
      }
      case 'status':
        return 'scene=' + cfg.scene + ' cycle=' + cfg.cycle + ' paused=' + paused + ' fish=' + fishTotal +
          ' [' + species.map((s) => s[0] + '=' + s[2]).join(',') + ']';
      case 'quit': setTimeout(() => app.quit(), 50); return 'ok';
      default: return 'error: unknown command';
    }
  }
  function startServer() {
    if (process.platform !== 'win32') { try { fs.rmSync(SOCK, { force: true }); } catch (e) { /* ignore */ } }
    server = net.createServer((sock) => {
      let buf = '';
      sock.on('data', (d) => {
        buf += d;
        if (buf.includes('\n')) { let reply; try { reply = handle(buf); } catch (e) { reply = 'error: ' + e.message; } sock.end(reply + '\n'); }
      });
      sock.on('error', () => {});
    });
    server.listen(SOCK, () => { if (process.platform !== 'win32') { try { fs.chmodSync(SOCK, 0o600); } catch (e) { /* ignore */ } } });
    server.on('error', () => {});
  }

  // ---- lifecycle
  app.on('window-all-closed', (e) => { if (!windowed) e.preventDefault(); else app.quit(); });
  app.on('will-quit', () => {
    globalShortcut.unregisterAll();
    try { if (server) server.close(); if (process.platform !== 'win32') fs.rmSync(SOCK, { force: true }); } catch (e) { /* ignore */ }
  });
  app.on('second-instance', () => {});

  app.whenReady().then(() => {
    loadCfg();
    createWindow();
    createTray();
    startServer();
    applyShortcuts();
    setInterval(pollCursor, 60);
    screen.on('display-metrics-changed', fitToDisplay);
    screen.on('display-added', fitToDisplay);
    screen.on('display-removed', fitToDisplay);
    if (windowed) win.webContents.once('did-finish-load', () => {});
  });
}
