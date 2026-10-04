using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace AlyxMP
{
    /// <summary>
    /// In-game chat: while Half-Life: Alyx is the foreground window, Y is registered as a hotkey (and only
    /// then, so Y keeps working everywhere else). Pressing it pops a small chat box over the game; Enter
    /// sends, Esc cancels, and focus goes back to the game either way.
    /// </summary>
    sealed class ChatOverlay : Form
    {
        const int HotkeyId = 0xA17;
        const int WM_HOTKEY = 0x0312;
        const uint MOD_NOREPEAT = 0x4000;
        const uint VK_Y = 0x59;

        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT r);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);

        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

        readonly Action<string> send;
        readonly Func<bool> enabled;
        readonly TextBox input = Theme.TextBox();
        readonly Timer poll = new Timer { Interval = 250 };
        bool registered;
        IntPtr gameWindow;
        uint gamePid;

        public ChatOverlay(Action<string> send, Func<bool> enabled)
        {
            this.send = send;
            this.enabled = enabled;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Theme.Panel;
            Opacity = 0.92;
            Size = new Size(Theme.Px(340), Theme.Px(26));
            var label = Theme.Label("SAY:", Theme.UiBold, Theme.Accent);
            label.Location = new Point(Theme.Px(6), Theme.Px(5));
            input.SetBounds(Theme.Px(42), Theme.Px(3), Theme.Px(292), Theme.Px(20));
            input.MaxLength = 120;
            input.KeyDown += OnKey;
            Controls.Add(label);
            Controls.Add(input);
            Deactivate += (s, e) => Dismiss(false);
            poll.Tick += (s, e) => UpdateHotkey();
            CreateHandle();
            poll.Start();
        }

        void UpdateHotkey()
        {
            bool want = enabled() && !Visible && GameIsForeground();
            if (want == registered) return;
            if (want) registered = RegisterHotKey(Handle, HotkeyId, MOD_NOREPEAT, VK_Y);
            else
            {
                UnregisterHotKey(Handle, HotkeyId);
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
            gameWindow = fg;
            return true;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY && (int)m.WParam == HotkeyId)
            {
                Open();
                return;
            }
            base.WndProc(ref m);
        }

        void Open()
        {
            UnregisterHotKey(Handle, HotkeyId);
            registered = false;
            // bottom-left of the game's picture, above where NoVR draws its health
            if (GetClientRect(gameWindow, out var rc))
            {
                var pt = new POINT { X = rc.Left, Y = rc.Bottom };
                ClientToScreen(gameWindow, ref pt);
                // just under the chat feed the mod draws on the left middle of the screen
                var top = new POINT { X = rc.Left, Y = rc.Top };
                ClientToScreen(gameWindow, ref top);
                int w = rc.Right - rc.Left, h = rc.Bottom - rc.Top;
                Location = new Point(top.X + (int)(w * 0.02), top.Y + (int)(h * 0.80));
            }
            input.Text = "";
            Show();
            Activate();
            SetForegroundWindow(Handle);
            input.Focus();
        }

        void OnKey(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter)
            {
                e.SuppressKeyPress = true;
                var text = input.Text.Trim();
                if (text.Length > 0) send(text);
                Dismiss(true);
            }
            else if (e.KeyCode == Keys.Escape)
            {
                e.SuppressKeyPress = true;
                Dismiss(true);
            }
        }

        void Dismiss(bool refocusGame)
        {
            if (!Visible) return;
            Hide();
            if (refocusGame && gameWindow != IntPtr.Zero) SetForegroundWindow(gameWindow);
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            poll.Stop();
            if (registered) UnregisterHotKey(Handle, HotkeyId);
            base.OnFormClosing(e);
        }
    }
}
