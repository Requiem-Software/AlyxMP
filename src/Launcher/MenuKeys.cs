using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace AlyxMP
{
    /// <summary>
    /// The keyboard side of the in-game settings menu (the mod draws it and runs it with the mouse).
    /// The game keeps ESC to itself - its binds never see the key - so while Half-Life: Alyx is in front and
    /// in a level, ESC here tells the mod to open or close the menu, and while the menu is open the rest of
    /// the keyboard is kept from the game (Alt combinations, the Windows keys and screenshots still work).
    /// That's a low-level keyboard hook on a thread of its own (so a busy launcher can't get it dropped by
    /// Windows); ESC is also a hotkey, in case Windows drops the hook anyway.
    /// The game only ever gets whole key presses: a key whose press was kept from it doesn't get its
    /// release either, and a key it saw go down gets its release even while the menu is open. A release
    /// without its press can leave the game's input stuck (its trigger fires on its own).
    /// </summary>
    sealed class MenuKeys : NativeWindow, IDisposable
    {
        const int WM_HOTKEY = 0x0312, WM_MENUKEY = 0x8019, HotkeyId = 0xA19, WH_KEYBOARD_LL = 13, WM_QUIT = 0x0012;
        const uint MOD_NOREPEAT = 0x4000;
        const int LLKHF_ALTDOWN = 0x20, LLKHF_UP = 0x80;
        const int VK_ESCAPE = 0x1B, VK_CONTROL = 0x11, VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_MENU = 0x12, VK_LMENU = 0xA4,
            VK_RMENU = 0xA5, VK_SNAPSHOT = 0x2C, VK_F12 = 0x7B;

        delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
        [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public int vkCode, scanCode, flags, time; public IntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }

        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr hMod, uint thread);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

        readonly Func<bool> enabled;
        readonly Action toggle;
        readonly System.Windows.Forms.Timer poll = new System.Windows.Forms.Timer { Interval = 250 };
        readonly IntPtr window;
        volatile bool open;
        volatile uint gamePid;
        bool registered;
        Hook hook;

        /// <param name="enabled">whether ESC is the menu's (in a level, NoVR)</param>
        /// <param name="toggle">tell the mod to open or close the menu (amp_menu)</param>
        public MenuKeys(Func<bool> enabled, Action toggle)
        {
            this.enabled = enabled;
            this.toggle = toggle;
            CreateHandle(new CreateParams());
            window = Handle;
            poll.Tick += (s, e) => Update();
            poll.Start();
        }

        /// <summary>The mod says the menu opened or closed.</summary>
        public void SetOpen(bool on) => open = on;

        void Update()
        {
            // the menu goes with the level or the game; ESC is its key wherever the game is in front
            bool on = enabled();
            if (!on) open = false;
            if (on && hook == null) hook = new Hook(this);
            else if (!on && hook != null)
            {
                hook.Stop();
                hook = null;
            }
            bool want = on && GameIsForeground();
            if (want && !registered) registered = RegisterHotKey(Handle, HotkeyId, MOD_NOREPEAT, VK_ESCAPE);
            else if (!want && registered)
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
            if (pid == gamePid) return true;
            try
            {
                using (var p = Process.GetProcessById((int)pid))
                    if (!string.Equals(p.ProcessName, "hlvr", StringComparison.OrdinalIgnoreCase)) return false;
            }
            catch (Exception) { return false; }
            gamePid = pid;
            return true;
        }

        // (on the hook's thread: quick)
        bool GameInFront()
        {
            GetWindowThreadProcessId(GetForegroundWindow(), out var pid);
            return pid != 0 && pid == gamePid;
        }

        /// <summary>One run of the keyboard hook (a level), with a message loop on a thread of its own.</summary>
        sealed class Hook
        {
            readonly MenuKeys owner;
            readonly HookProc proc;
            readonly HashSet<int> seenDown = new HashSet<int>();    // keys the game saw go down (and not up yet)
            readonly HashSet<int> kept = new HashSet<int>();        // keys whose press was kept from the game
            readonly Thread thread;
            volatile uint threadId;
            IntPtr handle;

            public Hook(MenuKeys owner)
            {
                this.owner = owner;
                proc = OnKey;
                thread = new Thread(Loop) { IsBackground = true, Name = "Menu keys" };
                thread.Start();
            }

            public void Stop()
            {
                for (int i = 0; i < 50 && threadId == 0; i++) Thread.Sleep(2);     // (it has only just started)
                PostThreadMessage(threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            }

            void Loop()
            {
                handle = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
                threadId = GetCurrentThreadId();
                if (handle == IntPtr.Zero) return;
                while (GetMessage(out _, IntPtr.Zero, 0, 0) > 0) { }
                UnhookWindowsHookEx(handle);
            }

            IntPtr OnKey(int code, IntPtr wParam, IntPtr lParam)
            {
                if (code < 0) return CallNextHookEx(handle, code, wParam, lParam);
                var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
                int vk = k.vkCode;
                if ((k.flags & LLKHF_UP) != 0)
                {
                    seenDown.Remove(vk);
                    if (kept.Remove(vk)) return (IntPtr)1;      // the game never saw it go down
                    return CallNextHookEx(handle, code, wParam, lParam);
                }
                if (kept.Contains(vk)) return (IntPtr)1;            // a kept press, repeating (even once the menu's closed)
                if (!owner.GameInFront()) return CallNextHookEx(handle, code, wParam, lParam);
                bool alt = (k.flags & LLKHF_ALTDOWN) != 0;
                if (vk == VK_ESCAPE && !alt && (GetAsyncKeyState(VK_CONTROL) & 0x8000) == 0)
                {
                    // ESC opens / closes the menu
                    kept.Add(vk);
                    PostMessage(owner.window, WM_MENUKEY, IntPtr.Zero, IntPtr.Zero);
                    return (IntPtr)1;
                }
                bool passThrough = alt || vk == VK_LWIN || vk == VK_RWIN || vk == VK_MENU || vk == VK_LMENU ||
                    vk == VK_RMENU || vk == VK_SNAPSHOT || vk == VK_F12;
                if (owner.open && !passThrough)
                {
                    // a key held from before the menu opened only repeats here: its release still goes through
                    if (!seenDown.Contains(vk)) kept.Add(vk);
                    return (IntPtr)1;
                }
                seenDown.Add(vk);
                return CallNextHookEx(handle, code, wParam, lParam);
            }
        }

        protected override void WndProc(ref Message m)
        {
            if ((m.Msg == WM_HOTKEY && (int)m.WParam == HotkeyId) || m.Msg == WM_MENUKEY)
            {
                toggle();
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            poll.Stop();
            poll.Dispose();
            if (registered) UnregisterHotKey(Handle, HotkeyId);
            hook?.Stop();
            hook = null;
            DestroyHandle();
        }
    }
}
