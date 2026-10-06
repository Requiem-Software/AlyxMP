using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace AlyxMP
{
    /// <summary>
    /// Half-Life: Alyx's menu look for the overlays the launcher puts over the game: the game's own UI
    /// typeface (Raju, loaded from its Panorama fonts for this process only) in white on a dark,
    /// slightly see-through panel. Raju is a CFF OpenType font, which GDI+ can't load, so text goes
    /// through GDI.
    /// </summary>
    static class HlaUi
    {
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] static extern int AddFontResourceEx(string name, uint fl, IntPtr res);
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFont(int height, int width, int escapement, int orientation, int weight, uint italic,
            uint underline, uint strikeOut, uint charSet, uint outPrecision, uint clipPrecision, uint quality,
            uint pitchAndFamily, string face);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
        [DllImport("gdi32.dll")] static extern int SetBkMode(IntPtr hdc, int mode);
        [DllImport("gdi32.dll")] static extern uint SetTextColor(IntPtr hdc, int color);
        [DllImport("gdi32.dll")] static extern int SetTextCharacterExtra(IntPtr hdc, int extra);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int DrawText(IntPtr hdc, string text, int len, ref RECT rect, uint format);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

        const uint FR_PRIVATE = 0x10;
        const int WM_SETFONT = 0x30;
        public const uint AlignLeft = 0, AlignCenter = 1, AlignRight = 2, VCenter = 4;
        const uint SingleLine = 0x20, NoPrefix = 0x800, CalcRect = 0x400, EndEllipsis = 0x8000;

        public const int Regular = 400, Semibold = 600, Bold = 700;

        public static readonly Color Panel = Color.FromArgb(16, 18, 20);
        public static readonly Color Hover = Color.FromArgb(34, 37, 40);
        public static readonly Color Text = Color.FromArgb(238, 240, 242);
        public static readonly Color Dim = Color.FromArgb(142, 148, 154);
        public static readonly Color Rule = Color.FromArgb(54, 58, 62);
        public static readonly Color Accent = Color.FromArgb(255, 199, 92);

        static string face = "Segoe UI";   // until Raju is loaded
        static readonly Dictionary<long, IntPtr> fonts = new Dictionary<long, IntPtr>();

        /// <summary>Load the game's Raju fonts for this process. Safe to call more than once.</summary>
        public static void Init(string hla)
        {
            if (face == "Raju" || string.IsNullOrEmpty(hla)) return;
            var dir = Path.Combine(hla, "game", "hlvr", "panorama", "fonts");
            int loaded = 0;
            foreach (var f in new[] { "raju-regular.otf", "raju-semibold.otf", "raju-bold.otf" })
            {
                var path = Path.Combine(dir, f);
                try { if (File.Exists(path) && AddFontResourceEx(path, FR_PRIVATE, IntPtr.Zero) > 0) loaded++; }
                catch (Exception) { }
            }
            if (loaded > 0) face = "Raju";
        }

        /// <summary>A GDI font handle (cached for the life of the process).</summary>
        public static IntPtr Font(int px, int weight)
        {
            long key = ((long)px << 16) | (uint)weight;
            if (!fonts.TryGetValue(key, out var h))
            {
                // DEFAULT_CHARSET, CLEARTYPE_QUALITY
                h = CreateFont(-px, 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 5, 0, face);
                fonts[key] = h;
            }
            return h;
        }

        public static void Draw(Graphics g, string text, int px, int weight, Color color, Rectangle r,
            uint align = AlignLeft, int spacing = 0)
        {
            var hdc = g.GetHdc();
            try
            {
                var old = SelectObject(hdc, Font(px, weight));
                SetBkMode(hdc, 1);   // transparent
                SetTextColor(hdc, color.R | (color.G << 8) | (color.B << 16));
                SetTextCharacterExtra(hdc, spacing);
                var rc = new RECT { Left = r.Left, Top = r.Top, Right = r.Right, Bottom = r.Bottom };
                DrawText(hdc, text, text.Length, ref rc, align | SingleLine | NoPrefix | EndEllipsis);
                SetTextCharacterExtra(hdc, 0);
                SelectObject(hdc, old);
            }
            finally { g.ReleaseHdc(hdc); }
        }

        public static Size Measure(Graphics g, string text, int px, int weight, int spacing = 0)
        {
            var hdc = g.GetHdc();
            try
            {
                var old = SelectObject(hdc, Font(px, weight));
                SetTextCharacterExtra(hdc, spacing);
                var rc = new RECT();
                DrawText(hdc, text, text.Length, ref rc, SingleLine | NoPrefix | CalcRect);
                SetTextCharacterExtra(hdc, 0);
                SelectObject(hdc, old);
                return new Size(rc.Right - rc.Left, rc.Bottom - rc.Top);
            }
            finally { g.ReleaseHdc(hdc); }
        }

        /// <summary>Give a text box the Raju face (the edit control draws with GDI too).</summary>
        public static void UseFont(Control c, int px, int weight)
        {
            void apply() => SendMessage(c.Handle, WM_SETFONT, Font(px, weight), (IntPtr)1);
            if (c.IsHandleCreated) apply();
            c.HandleCreated += (s, e) => apply();
        }

        /// <summary>A pill switch like the game's settings toggles.</summary>
        public static void Toggle(Graphics g, Rectangle r, bool on, bool hot)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = Pill(r))
            {
                if (on)
                {
                    using (var b = new SolidBrush(Text)) g.FillPath(b, path);
                }
                else
                {
                    using (var p = new Pen(hot ? Text : Dim, Math.Max(1.5f, Theme.Scale * 1.5f))) g.DrawPath(p, path);
                }
            }
            int pad = Math.Max(3, r.Height / 6);
            int d = r.Height - pad * 2;
            var knob = new Rectangle(on ? r.Right - pad - d : r.Left + pad, r.Top + pad, d, d);
            using (var b = new SolidBrush(on ? Panel : (hot ? Text : Dim))) g.FillEllipse(b, knob);
            g.SmoothingMode = SmoothingMode.None;
        }

        static GraphicsPath Pill(Rectangle r)
        {
            var path = new GraphicsPath();
            int d = r.Height;
            path.AddArc(r.Left, r.Top, d, d, 90, 180);
            path.AddArc(r.Right - d, r.Top, d, d, 270, 180);
            path.CloseFigure();
            return path;
        }
    }
}
