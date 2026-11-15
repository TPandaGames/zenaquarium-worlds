using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ZenAquariumWorlds
{
    static class App
    {
        public const string Name = "ZenAquarium Worlds";
        public const string FolderName = "ZenAquariumWorlds";
        public const string ExeName = "ZenAquariumWorlds.exe";
        public const string RunKeyValue = "ZenAquariumWorlds";
        public const string SettingsKey = @"Software\ZenAquariumWorlds";
        public const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\ZenAquariumWorlds";
        public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        public static readonly string[] Payload =
        {
            "wallpaper.html",
            "Microsoft.Web.WebView2.Core.dll",
            "Microsoft.Web.WebView2.WinForms.dll",
            "WebView2Loader.dll"
        };

        public static string InstallDir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), FolderName); }
        }
        public static string InstalledExe { get { return Path.Combine(InstallDir, ExeName); } }
        public static string ShortcutPath
        {
            get
            {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), Name + ".lnk");
            }
        }
        public static bool RunningFromInstallDir()
        {
            string here = Path.GetDirectoryName(Application.ExecutablePath) ?? "";
            return string.Equals(here.TrimEnd('\\'), InstallDir.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        }

        public static Icon MakeIcon(int size = 64)
        {
            using (var bmp = new Bitmap(size, size))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    float s = size / 64f;
                    using (var bg = new LinearGradientBrush(new Rectangle(0, 0, size, size), Color.FromArgb(34, 211, 238), Color.FromArgb(37, 99, 235), 90f))
                    using (var path = RoundRect(2 * s, 2 * s, 60 * s, 60 * s, 14 * s))
                        g.FillPath(bg, path);
                    using (var white = new SolidBrush(Color.White))
                    {
                        g.FillEllipse(white, 14 * s, 22 * s, 32 * s, 20 * s);
                        g.FillPolygon(white, new[] { new PointF(42 * s, 32 * s), new PointF(54 * s, 22 * s), new PointF(54 * s, 42 * s) });
                    }
                    using (var dark = new SolidBrush(Color.FromArgb(30, 64, 175)))
                        g.FillEllipse(dark, 19 * s, 28 * s, 5 * s, 5 * s);
                }
                return Icon.FromHandle(bmp.GetHicon());
            }
        }
        static GraphicsPath RoundRect(float x, float y, float w, float h, float r)
        {
            var p = new GraphicsPath();
            p.AddArc(x, y, r * 2, r * 2, 180, 90);
            p.AddArc(x + w - r * 2, y, r * 2, r * 2, 270, 90);
            p.AddArc(x + w - r * 2, y + h - r * 2, r * 2, r * 2, 0, 90);
            p.AddArc(x, y + h - r * 2, r * 2, r * 2, 90, 90);
            p.CloseFigure();
            return p;
        }

        public static string GetSetting(string name, string def)
        {
            try { using (var k = Registry.CurrentUser.OpenSubKey(SettingsKey)) { var v = k == null ? null : k.GetValue(name); return v == null ? def : v.ToString(); } }
            catch { return def; }
        }
        public static void SetSetting(string name, string value)
        {
            try { using (var k = Registry.CurrentUser.CreateSubKey(SettingsKey)) k.SetValue(name, value); } catch { }
        }
        public static bool GetBool(string name, bool def) { return GetSetting(name, def ? "1" : "0") == "1"; }
        public static void SetBool(string name, bool v) { SetSetting(name, v ? "1" : "0"); }

        public static void SetAutostart(bool on)
        {
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (on) k.SetValue(RunKeyValue, "\"" + InstalledExe + "\" --wallpaper");
                    else k.DeleteValue(RunKeyValue, false);
                }
            }
            catch { }
        }
        public static bool GetAutostart()
        {
            try { using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue(RunKeyValue) != null; }
            catch { return false; }
        }

        public static void KillOtherInstances()
        {
            int me = Process.GetCurrentProcess().Id;
            foreach (var p in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(ExeName)))
            {
                if (p.Id == me) continue;
                try { p.Kill(); p.WaitForExit(3000); } catch { }
            }
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "";

            if (mode == "--uninstall") return Installer.Uninstall(args.Length > 1 && args[1] == "--silent");
            if (mode == "--install-silent") { Installer.Install(true, true, false); return 0; }
            if (mode == "--wallpaper" || (mode == "" && App.RunningFromInstallDir()))
                return RunHost();

            Application.Run(new SetupForm());
            return 0;
        }

        // Kept in its own non-inlined method so setup mode never loads the WebView2 assemblies
        [MethodImpl(MethodImplOptions.NoInlining)]
        static int RunHost()
        {
            return HostRunner.Run();
        }
    }

    // ------------------------------------------------------------------ installer
    static class Installer
    {
        public static void Install(bool autostart, bool shortcut, bool launch)
        {
            App.KillOtherInstances();
            Directory.CreateDirectory(App.InstallDir);

            var asm = Assembly.GetExecutingAssembly();
            foreach (var f in App.Payload)
            {
                using (var s = asm.GetManifestResourceStream("payload." + f))
                {
                    if (s == null) throw new InvalidOperationException("Missing installer payload: " + f);
                    using (var o = File.Create(Path.Combine(App.InstallDir, f))) s.CopyTo(o);
                }
            }
            // Copy this executable in as the installed wallpaper host
            string self = Application.ExecutablePath;
            if (!string.Equals(Path.GetFullPath(self), Path.GetFullPath(App.InstalledExe), StringComparison.OrdinalIgnoreCase))
                File.Copy(self, App.InstalledExe, true);

            if (shortcut) CreateShortcut();
            App.SetAutostart(autostart);
            RegisterUninstall();

            if (launch)
                Process.Start(new ProcessStartInfo(App.InstalledExe, "--wallpaper") { WorkingDirectory = App.InstallDir, UseShellExecute = false });
        }

        static void CreateShortcut()
        {
            try
            {
                Type t = Type.GetTypeFromProgID("WScript.Shell");
                object sh = Activator.CreateInstance(t);
                object lnk = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { App.ShortcutPath });
                Type lt = lnk.GetType();
                Action<string, object> set = (n, v) => lt.InvokeMember(n, BindingFlags.SetProperty, null, lnk, new object[] { v });
                set("TargetPath", App.InstalledExe);
                set("Arguments", "--wallpaper");
                set("WorkingDirectory", App.InstallDir);
                set("Description", "ZenAquarium Worlds live wallpaper");
                set("IconLocation", App.InstalledExe + ",0");
                lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
            }
            catch { }
        }

        static void RegisterUninstall()
        {
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey(App.UninstallKey))
                {
                    k.SetValue("DisplayName", App.Name);
                    k.SetValue("DisplayVersion", "1.0.0");
                    k.SetValue("Publisher", "ZenAquarium");
                    k.SetValue("InstallLocation", App.InstallDir);
                    k.SetValue("DisplayIcon", App.InstalledExe);
                    k.SetValue("UninstallString", "\"" + App.InstalledExe + "\" --uninstall");
                    k.SetValue("QuietUninstallString", "\"" + App.InstalledExe + "\" --uninstall --silent");
                    k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                }
            }
            catch { }
        }

        public static int Uninstall(bool silent)
        {
            if (!silent)
            {
                var r = MessageBox.Show("Remove " + App.Name + " and restore your normal desktop wallpaper?", App.Name + " Uninstall",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                if (r != DialogResult.Yes) return 1;
            }
            App.KillOtherInstances();
            App.SetAutostart(false);
            try { if (File.Exists(App.ShortcutPath)) File.Delete(App.ShortcutPath); } catch { }
            try { Registry.CurrentUser.DeleteSubKeyTree(App.UninstallKey, false); } catch { }
            try { Registry.CurrentUser.DeleteSubKeyTree(App.SettingsKey, false); } catch { }
            NativeMethods.RefreshDesktopWallpaper();

            // This exe lives in the folder being removed, so delete it from a helper after we exit
            try
            {
                var psi = new ProcessStartInfo("cmd.exe", "/c ping 127.0.0.1 -n 3 >nul & rmdir /s /q \"" + App.InstallDir + "\"")
                { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden };
                Process.Start(psi);
            }
            catch { }
            if (!silent) MessageBox.Show(App.Name + " has been removed.", App.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }
    }

    class SetupForm : Form
    {
        readonly CheckBox _auto = new CheckBox();
        readonly CheckBox _short = new CheckBox();
        readonly Button _install = new Button();

        public SetupForm()
        {
            Text = App.Name + " Setup";
            Icon = App.MakeIcon(32);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(460, 300);
            BackColor = Color.FromArgb(10, 22, 36);
            ForeColor = Color.White;
            Font = new Font("Segoe UI", 9.5f);

            var title = new Label { Text = "ZenAquarium Worlds", Font = new Font("Segoe UI Semibold", 18f), AutoSize = true, Location = new Point(24, 20) };
            var sub = new Label
            {
                Text = "Three living worlds as your desktop wallpaper:\r\nCoral Reef  •  Deep Sea  •  Koi Pond",
                ForeColor = Color.FromArgb(150, 220, 235), AutoSize = true, Location = new Point(26, 62)
            };
            var info = new Label
            {
                Text = "Installs for the current user only (no administrator rights needed). " +
                       "The wallpaper runs behind your desktop icons and can be controlled from the system tray.",
                ForeColor = Color.FromArgb(190, 200, 210), Location = new Point(26, 108), Size = new Size(410, 50)
            };
            _auto.Text = "Start automatically when I sign in to Windows";
            _auto.Checked = true; _auto.AutoSize = true; _auto.Location = new Point(28, 168);
            _short.Text = "Add a Start menu shortcut";
            _short.Checked = true; _short.AutoSize = true; _short.Location = new Point(28, 196);

            _install.Text = File.Exists(App.InstalledExe) ? "Update && Launch" : "Install && Launch";
            _install.Size = new Size(150, 36); _install.Location = new Point(286, 246);
            _install.FlatStyle = FlatStyle.Flat; _install.BackColor = Color.FromArgb(6, 182, 212); _install.ForeColor = Color.White;
            _install.FlatAppearance.BorderSize = 0;
            _install.Click += OnInstall;

            var cancel = new Button
            {
                Text = "Cancel", Size = new Size(90, 36), Location = new Point(186, 246), FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(40, 55, 72), ForeColor = Color.White
            };
            cancel.FlatAppearance.BorderSize = 0;
            cancel.Click += (s, e) => Close();

            Controls.AddRange(new Control[] { title, sub, info, _auto, _short, _install, cancel });
            AcceptButton = _install; CancelButton = cancel;
        }

        void OnInstall(object sender, EventArgs e)
        {
            try
            {
                _install.Enabled = false; _install.Text = "Installing...";
                Application.DoEvents();
                if (!HostRunner.WebView2Available())
                {
                    var r = MessageBox.Show(
                        "The Microsoft Edge WebView2 Runtime was not found. It is included with Windows 11 and Microsoft Edge, " +
                        "but appears to be missing on this PC.\r\n\r\nOpen the download page now?",
                        App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                    if (r == DialogResult.Yes) Process.Start("https://developer.microsoft.com/microsoft-edge/webview2/");
                }
                Installer.Install(_auto.Checked, _short.Checked, true);
                MessageBox.Show("Installed! Your live wallpaper is starting.\r\n\r\nLook for the fish icon in the system tray (near the clock) to switch worlds, pause or exit.\r\n" +
                                "To remove it later: Settings → Apps → " + App.Name + ".", App.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
                Close();
            }
            catch (Exception ex)
            {
                MessageBox.Show("Installation failed:\r\n" + ex.Message, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
                _install.Enabled = true; _install.Text = "Retry";
            }
        }
    }

    // ------------------------------------------------------------------ native
    static class NativeMethods
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        public delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll")] public static extern IntPtr SetParent(IntPtr child, IntPtr newParent);
        [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT pt);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT pt);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int id, LowLevelMouseProc proc, IntPtr hMod, uint threadId);
        [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SystemParametersInfo(uint action, uint param, string value, uint flags);

        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        public struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public IntPtr extra; }

        public const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
        public const long WS_CHILD = 0x40000000L, WS_POPUP = 0x80000000L, WS_VISIBLE = 0x10000000L;
        public const long WS_EX_TOOLWINDOW = 0x80L, WS_EX_NOACTIVATE = 0x08000000L;
        public const uint SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40, SWP_FRAMECHANGED = 0x20;
        public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);

        public static string ClassOf(IntPtr h)
        {
            var sb = new StringBuilder(128);
            GetClassName(h, sb, sb.Capacity);
            return sb.ToString();
        }

        public static void RefreshDesktopWallpaper()
        {
            // Passing a null path reloads the user's current wallpaper (SPI_SETDESKWALLPAPER, SPIF_UPDATEINIFILE)
            try { SystemParametersInfo(0x0014, 0, null, 0x01); } catch { }
        }
    }

    // ------------------------------------------------------------------ host
    static class HostRunner
    {
        public static bool WebView2Available()
        {
            try { return !string.IsNullOrEmpty(Microsoft.Web.WebView2.Core.CoreWebView2Environment.GetAvailableBrowserVersionString()); }
            catch { return false; }
        }

        public static int Run()
        {
            bool created;
            using (var mutex = new System.Threading.Mutex(true, "ZenAquariumWorlds.Host.Singleton", out created))
            {
                if (!created) return 0; // already running
                if (!WebView2Available())
                {
                    MessageBox.Show("The Microsoft Edge WebView2 Runtime is required but was not found.\r\n" +
                                    "Install it from https://developer.microsoft.com/microsoft-edge/webview2/ and start " + App.Name + " again.",
                                    App.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }
                Application.Run(new HostForm());
                return 0;
            }
        }
    }

    class HostForm : Form
    {
        Microsoft.Web.WebView2.WinForms.WebView2 _web;
        NotifyIcon _tray;
        Timer _timer;
        IntPtr _parent = IntPtr.Zero;
        IntPtr _hook = IntPtr.Zero;
        NativeMethods.LowLevelMouseProc _hookProc; // keep a reference so the delegate isn't collected
        Rectangle _bounds;
        bool _userPaused, _autoPaused, _pageReady;
        string _scene;
        bool _cycle, _mouse;
        DateTime _lastMove = DateTime.MinValue;
        bool _overDesktop;

        readonly Dictionary<string, ToolStripMenuItem> _sceneItems = new Dictionary<string, ToolStripMenuItem>();
        ToolStripMenuItem _miCycle, _miMouse, _miPause, _miAuto;

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= (int)(NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_NOACTIVATE);
                return cp;
            }
        }
        protected override bool ShowWithoutActivation { get { return true; } }

        public HostForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(2, 11, 22);
            Text = App.Name + " Wallpaper";

            _scene = App.GetSetting("Scene", "reef");
            _cycle = App.GetBool("Cycle", false);
            _mouse = App.GetBool("Mouse", true);

            _bounds = Screen.PrimaryScreen.Bounds;
            Bounds = _bounds;

            _web = new Microsoft.Web.WebView2.WinForms.WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(2, 11, 22) };
            Controls.Add(_web);

            BuildTray();
            Load += (s, e) => { var _ = InitWebAsync(); };
            Shown += (s, e) => AttachToDesktop();
            FormClosing += (s, e) => Cleanup();

            Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (s, e) => { _bounds = Screen.PrimaryScreen.Bounds; AttachToDesktop(); };

            _timer = new Timer { Interval = 2000 };
            _timer.Tick += (s, e) => Tick();
            _timer.Start();
        }

        async System.Threading.Tasks.Task InitWebAsync()
        {
            try
            {
                string data = Path.Combine(App.InstallDir, "WebView2Data");
                Directory.CreateDirectory(data);
                var env = await Microsoft.Web.WebView2.Core.CoreWebView2Environment.CreateAsync(null, data);
                await _web.EnsureCoreWebView2Async(env);
                var st = _web.CoreWebView2.Settings;
                st.AreDefaultContextMenusEnabled = false;
                st.AreDevToolsEnabled = false;
                st.IsStatusBarEnabled = false;
                st.IsZoomControlEnabled = false;
                st.AreBrowserAcceleratorKeysEnabled = false;
                st.IsBuiltInErrorPageEnabled = false;
                _web.CoreWebView2.NavigationCompleted += (s, e) => { _pageReady = true; PushState(); };

                string html = Path.Combine(App.InstallDir, "wallpaper.html");
                if (!File.Exists(html))
                {
                    // Running outside the install folder (e.g. --wallpaper from the setup exe): extract to temp
                    html = Path.Combine(Path.GetTempPath(), "zenaquarium_wallpaper.html");
                    using (var rs = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.wallpaper.html"))
                    using (var o = File.Create(html)) rs.CopyTo(o);
                }
                string url = new Uri(html).AbsoluteUri + "?wallpaper=1&scene=" + _scene;
                _web.CoreWebView2.Navigate(url);
                InstallMouseHook();
            }
            catch (Exception ex)
            {
                MessageBox.Show("Could not start the wallpaper:\r\n" + ex.Message, App.Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
                Application.Exit();
            }
        }

        void Js(string script)
        {
            try { if (_web != null && _web.CoreWebView2 != null && _pageReady) _web.CoreWebView2.ExecuteScriptAsync(script); } catch { }
        }
        void PushState()
        {
            Js("zen.cycle(" + (_cycle ? "true" : "false") + ");");
            Js("zen.pause(" + ((_userPaused || _autoPaused) ? "true" : "false") + ");");
        }

        // ---------------------------------------------------- attach behind icons
        void AttachToDesktop()
        {
            try
            {
                IntPtr progman = NativeMethods.FindWindow("Progman", null);
                IntPtr res;
                NativeMethods.SendMessageTimeout(progman, 0x052C, IntPtr.Zero, IntPtr.Zero, 0, 1000, out res);

                IntPtr workerw = IntPtr.Zero;
                NativeMethods.EnumWindows((h, l) =>
                {
                    IntPtr dv = NativeMethods.FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null);
                    if (dv != IntPtr.Zero)
                        workerw = NativeMethods.FindWindowEx(IntPtr.Zero, h, "WorkerW", null);
                    return true;
                }, IntPtr.Zero);

                IntPtr h2 = Handle;
                long style = NativeMethods.GetWindowLongPtr(h2, NativeMethods.GWL_STYLE).ToInt64();
                style = (style & ~NativeMethods.WS_POPUP) | NativeMethods.WS_CHILD | NativeMethods.WS_VISIBLE;
                NativeMethods.SetWindowLongPtr(h2, NativeMethods.GWL_STYLE, new IntPtr(style));

                IntPtr insertAfter = NativeMethods.HWND_BOTTOM;
                if (workerw != IntPtr.Zero)
                {
                    // Classic layout (Windows 10 / Windows 11 before 24H2): live behind icons in the spare WorkerW
                    _parent = workerw;
                }
                else
                {
                    // Windows 11 24H2+: icons (SHELLDLL_DefView) are a child of Progman; sit directly beneath them
                    _parent = progman;
                    IntPtr defView = NativeMethods.FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
                    if (defView != IntPtr.Zero) insertAfter = defView;
                }

                NativeMethods.SetParent(h2, _parent);
                var pt = new NativeMethods.POINT { X = _bounds.X, Y = _bounds.Y };
                NativeMethods.ScreenToClient(_parent, ref pt);
                NativeMethods.SetWindowPos(h2, insertAfter, pt.X, pt.Y, _bounds.Width, _bounds.Height,
                    NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW | NativeMethods.SWP_FRAMECHANGED);
            }
            catch { }
        }

        // ---------------------------------------------------- mouse forwarding
        void InstallMouseHook()
        {
            if (_hook != IntPtr.Zero) return;
            _hookProc = MouseProc;
            _hook = NativeMethods.SetWindowsHookEx(14, _hookProc, NativeMethods.GetModuleHandle(null), 0);
        }

        IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            try
            {
                if (nCode >= 0 && _mouse && _pageReady)
                {
                    int msg = wParam.ToInt32();
                    if (msg == 0x0200 || msg == 0x0201) // WM_MOUSEMOVE / WM_LBUTTONDOWN
                    {
                        bool click = msg == 0x0201;
                        if (click || (DateTime.UtcNow - _lastMove).TotalMilliseconds > 33)
                        {
                            if (!click) _lastMove = DateTime.UtcNow;
                            var ms = (NativeMethods.MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(NativeMethods.MSLLHOOKSTRUCT));
                            bool over = IsDesktopAt(ms.pt) && !_userPaused && !_autoPaused;
                            if (over)
                            {
                                double fx = (ms.pt.X - _bounds.X) / (double)_bounds.Width;
                                double fy = (ms.pt.Y - _bounds.Y) / (double)_bounds.Height;
                                if (fx >= 0 && fx <= 1 && fy >= 0 && fy <= 1)
                                {
                                    Js("zen.mouse(" + fx.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture) + "," +
                                       fy.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture) + "," + (click ? "true" : "false") + ");");
                                    _overDesktop = true;
                                }
                            }
                            else if (_overDesktop)
                            {
                                _overDesktop = false;
                                Js("zen.mouse(-1,-1,false);");
                            }
                        }
                    }
                }
            }
            catch { }
            return NativeMethods.CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        static bool IsDesktopAt(NativeMethods.POINT pt)
        {
            IntPtr w = NativeMethods.WindowFromPoint(pt);
            if (w == IntPtr.Zero) return false;
            IntPtr root = NativeMethods.GetAncestor(w, 2 /* GA_ROOT */);
            string c = NativeMethods.ClassOf(root == IntPtr.Zero ? w : root);
            return c == "Progman" || c == "WorkerW";
        }

        // ---------------------------------------------------- periodic upkeep
        void Tick()
        {
            // Re-attach if Explorer restarted
            if (_parent == IntPtr.Zero || !NativeMethods.IsWindow(_parent) || NativeMethods.GetParent(Handle) != _parent)
                AttachToDesktop();

            bool covered = false;
            try
            {
                IntPtr fg = NativeMethods.GetForegroundWindow();
                if (fg != IntPtr.Zero && fg != Handle && NativeMethods.IsWindowVisible(fg) && !NativeMethods.IsIconic(fg))
                {
                    string c = NativeMethods.ClassOf(fg);
                    if (c != "Progman" && c != "WorkerW" && c != "Shell_TrayWnd" && c != "Windows.UI.Core.CoreWindow" && c != "XamlExplorerHostIslandWindow")
                    {
                        NativeMethods.RECT r;
                        if (NativeMethods.GetWindowRect(fg, out r))
                            covered = r.Left <= _bounds.Left + 2 && r.Top <= _bounds.Top + 2 && r.Right >= _bounds.Right - 2 && r.Bottom >= _bounds.Bottom - 2;
                    }
                }
            }
            catch { }
            if (covered != _autoPaused)
            {
                _autoPaused = covered;
                PushState();
            }
        }

        // ---------------------------------------------------- tray menu
        void BuildTray()
        {
            var menu = new ContextMenuStrip();
            var header = new ToolStripMenuItem(App.Name) { Enabled = false };
            menu.Items.Add(header);
            menu.Items.Add(new ToolStripSeparator());

            AddScene(menu, "reef", "🐠  Coral Reef");
            AddScene(menu, "abyss", "🪼  Deep Sea");
            AddScene(menu, "koi", "🎏  Koi Pond");
            menu.Items.Add(new ToolStripSeparator());

            _miCycle = new ToolStripMenuItem("Auto-rotate worlds (3 min)") { Checked = _cycle, CheckOnClick = true };
            _miCycle.Click += (s, e) => { _cycle = _miCycle.Checked; App.SetBool("Cycle", _cycle); Js("zen.cycle(" + (_cycle ? "true" : "false") + ");"); };
            menu.Items.Add(_miCycle);

            _miMouse = new ToolStripMenuItem("Mouse interaction (feed & scare fish)") { Checked = _mouse, CheckOnClick = true };
            _miMouse.Click += (s, e) => { _mouse = _miMouse.Checked; App.SetBool("Mouse", _mouse); if (!_mouse) Js("zen.mouse(-1,-1,false);"); };
            menu.Items.Add(_miMouse);

            _miPause = new ToolStripMenuItem("Pause animation") { CheckOnClick = true };
            _miPause.Click += (s, e) => { _userPaused = _miPause.Checked; PushState(); };
            menu.Items.Add(_miPause);

            menu.Items.Add(new ToolStripSeparator());
            _miAuto = new ToolStripMenuItem("Start with Windows") { Checked = App.GetAutostart(), CheckOnClick = true };
            _miAuto.Click += (s, e) => App.SetAutostart(_miAuto.Checked);
            menu.Items.Add(_miAuto);

            var mi = new ToolStripMenuItem("Uninstall...");
            mi.Click += (s, e) =>
            {
                try { Process.Start(new ProcessStartInfo(Application.ExecutablePath, "--uninstall") { UseShellExecute = false }); } catch { }
            };
            menu.Items.Add(mi);

            var exit = new ToolStripMenuItem("Exit wallpaper");
            exit.Click += (s, e) => Close();
            menu.Items.Add(exit);

            _tray = new NotifyIcon { Icon = App.MakeIcon(32), Text = App.Name, ContextMenuStrip = menu, Visible = true };
            _tray.DoubleClick += (s, e) => { _userPaused = !_userPaused; _miPause.Checked = _userPaused; PushState(); };
            UpdateSceneChecks();
        }

        void AddScene(ContextMenuStrip menu, string id, string label)
        {
            var item = new ToolStripMenuItem(label);
            item.Click += (s, e) =>
            {
                _scene = id; App.SetSetting("Scene", id);
                Js("zen.setScene('" + id + "');");
                UpdateSceneChecks();
            };
            _sceneItems[id] = item;
            menu.Items.Add(item);
        }
        void UpdateSceneChecks()
        {
            foreach (var kv in _sceneItems) kv.Value.Checked = kv.Key == _scene;
        }

        // ---------------------------------------------------- shutdown
        bool _cleaned;
        void Cleanup()
        {
            if (_cleaned) return;
            _cleaned = true;
            try { _timer.Stop(); } catch { }
            try { if (_hook != IntPtr.Zero) NativeMethods.UnhookWindowsHookEx(_hook); } catch { }
            try { _tray.Visible = false; _tray.Dispose(); } catch { }
            try { Hide(); NativeMethods.SetParent(Handle, IntPtr.Zero); } catch { }
            NativeMethods.RefreshDesktopWallpaper();
        }
    }
}
