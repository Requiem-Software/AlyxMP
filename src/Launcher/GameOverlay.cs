using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace AlyxMP
{
    /// <summary>
    /// A small window the launcher pops over the game. Its key is registered as a hotkey only while
    /// Half-Life: Alyx is the foreground window, so the key keeps working everywhere else; when the
    /// overlay closes, focus goes back to the game.
    /// </summary>
    abstract class GameOverlay : Form
    {
        const int WM_HOTKEY = 0x0312;
        const uint MOD_NOREPEAT = 0x4000;

        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] protected static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);

        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

        readonly int hotkeyId;
        readonly uint key;
        readonly Func<bool> enabled;
        readonly Timer poll = new Timer { Interval = 250 };
        bool registered;
        uint gamePid;
        protected IntPtr GameWindow { get; private set; }

        protected GameOverlay(int hotkeyId, Keys key, Func<bool> enabled)
        {
            this.hotkeyId = hotkeyId;
            this.key = (uint)key;
            this.enabled = enabled;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = HlaUi.Panel;
            KeyPreview = true;
            Deactivate += (s, e) => Dismiss(false);
            poll.Tick += (s, e) => UpdateHotkey();
            CreateHandle();
            poll.Start();
        }

        /// <summary>Called when the hotkey is pressed over the game.</summary>
        protected abstract void OnOpen(Rectangle gameScreenRect);

        void UpdateHotkey()
        {
            bool want = enabled() && !Visible && GameIsForeground();
            if (want == registered) return;
            if (want) registered = RegisterHotKey(Handle, hotkeyId, MOD_NOREPEAT, key);
            else
            {
                UnregisterHotKey(Handle, hotkeyId);
                registered = false;
            }
        }

        bool GameIsForeground()
        {
            var fg = GetForegroundWindow();
            if (fg == IntPtr.Zero) return false;
            GetWindowThreadProcessId(fg, out var pid);
            if (pid == 0) return false;
            if (pid != gamePid)
            {
                try
                {
                    using (var p = Process.GetProcessById((int)pid))
                    {
                        if (!string.Equals(p.ProcessName, "hlvr", StringComparison.OrdinalIgnoreCase)) return false;
                    }
                }
                catch (Exception) { return false; }
                gamePid = pid;
            }
            GameWindow = fg;
            return true;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY && (int)m.WParam == hotkeyId)
            {
                UnregisterHotKey(Handle, hotkeyId);
                registered = false;
                var rect = Screen.PrimaryScreen.Bounds;
                if (GetClientRect(GameWindow, out var rc))
                {
                    var tl = new POINT { X = rc.Left, Y = rc.Top };
                    ClientToScreen(GameWindow, ref tl);
                    rect = new Rectangle(tl.X, tl.Y, rc.Right - rc.Left, rc.Bottom - rc.Top);
                }
                OnOpen(rect);
                Show();
                Activate();
                SetForegroundWindow(Handle);
                return;
            }
            base.WndProc(ref m);
        }

        protected void Dismiss(bool refocusGame)
        {
            if (!Visible) return;
            Hide();
            if (refocusGame && GameWindow != IntPtr.Zero) SetForegroundWindow(GameWindow);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            poll.Stop();
            if (registered) UnregisterHotKey(Handle, hotkeyId);
            base.OnFormClosing(e);
        }
    }
}
