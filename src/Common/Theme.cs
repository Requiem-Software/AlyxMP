using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace AlyxMP
{
    /// <summary>
    /// Look borrowed from Half-Life 2's VGUI: dark panels, Tahoma, orange highlights. Layouts are written
    /// in 1080p/96-DPI pixels and multiplied by <see cref="Scale"/>, which follows both Windows' DPI setting
    /// and the screen's resolution (so a 1440p monitor at 100% still gets a readable window).
    /// </summary>
    static class Theme
    {
        public static readonly Color Back = Color.FromArgb(36, 37, 34);
        public static readonly Color Panel = Color.FromArgb(50, 51, 47);
        public static readonly Color PanelHi = Color.FromArgb(66, 67, 62);
        public static readonly Color Field = Color.FromArgb(24, 25, 23);
        public static readonly Color Border = Color.FromArgb(92, 93, 86);
        public static readonly Color Text = Color.FromArgb(226, 226, 218);
        public static readonly Color Muted = Color.FromArgb(150, 150, 140);
        public static readonly Color Accent = Color.FromArgb(255, 157, 0);
        public static readonly Color AccentDim = Color.FromArgb(196, 120, 0);
        public static readonly Color Good = Color.FromArgb(132, 214, 112);
        public static readonly Color Bad = Color.FromArgb(232, 96, 72);

        public static float Scale { get; private set; } = 1f;
        public static Font Ui, UiBold, Header, Big, Title, Mono;

        /// <summary>Call once before creating any form.</summary>
        public static void Init()
        {
            float dpi = 96f;
            try
            {
                using (var g = Graphics.FromHwnd(IntPtr.Zero)) dpi = g.DpiX;
            }
            catch (Exception) { }
            float byDpi = dpi / 96f;
            float byScreen = Screen.PrimaryScreen.Bounds.Height / 1080f;
            Scale = Math.Max(1f, Math.Min(3f, Math.Max(byDpi, byScreen)));

            // sizes in pixels so Windows doesn't scale them a second time
            Ui = PxFont("Tahoma", 11.5f, FontStyle.Regular);
            UiBold = PxFont("Tahoma", 11.5f, FontStyle.Bold);
            Header = PxFont("Tahoma", 11.5f, FontStyle.Bold);
            Big = PxFont("Tahoma", 13.5f, FontStyle.Bold);
            Title = PxFont("Trebuchet MS", 29f, FontStyle.Bold);
            Mono = PxFont("Consolas", 11.5f, FontStyle.Regular);
        }

        static Font PxFont(string family, float px, FontStyle style) => new Font(family, px * Scale, style, GraphicsUnit.Pixel);

        public static int Px(float v) => (int)Math.Round(v * Scale);

        /// <summary>Size the form's client area and every control in it from the 1080p layout.</summary>
        public static void ScaleLayout(Form f, Size baseClientSize)
        {
            f.AutoScaleMode = AutoScaleMode.None;
            f.ClientSize = new Size(Px(baseClientSize.Width), Px(baseClientSize.Height));
            if (Math.Abs(Scale - 1f) < 0.01f) return;
            var factor = new SizeF(Scale, Scale);
            foreach (Control c in f.Controls) c.Scale(factor);
        }

        public static void Apply(Form f)
        {
            f.BackColor = Back;
            f.ForeColor = Text;
            f.Font = Ui;
        }

        public static Label Label(string text, Font font = null, Color? color = null)
        {
            return new Label
            {
                Text = text,
                AutoSize = true,
                Font = font ?? Ui,
                ForeColor = color ?? Text,
                BackColor = Color.Transparent,
            };
        }

        public static TextBox TextBox(string text = "")
        {
            return new TextBox
            {
                Text = text,
                BackColor = Field,
                ForeColor = Text,
                BorderStyle = BorderStyle.FixedSingle,
                Font = Ui,
            };
        }

        public static CheckBox Check(string text, bool on = false) => new ThemeCheckBox { Text = text, Checked = on };

        public static Button Button(string text, bool primary = false)
        {
            var b = new Button
            {
                Text = text,
                FlatStyle = FlatStyle.Flat,
                Font = primary ? Big : UiBold,
                BackColor = primary ? Accent : PanelHi,
                ForeColor = primary ? Color.FromArgb(26, 20, 8) : Text,
                Cursor = Cursors.Hand,
                UseVisualStyleBackColor = false,
            };
            b.FlatAppearance.BorderColor = primary ? AccentDim : Border;
            b.FlatAppearance.MouseOverBackColor = primary ? Color.FromArgb(255, 178, 50) : Color.FromArgb(84, 85, 79);
            b.FlatAppearance.MouseDownBackColor = primary ? AccentDim : Panel;
            b.EnabledChanged += (s, e) =>
            {
                b.BackColor = !b.Enabled ? Panel : (primary ? Accent : PanelHi);
                b.ForeColor = !b.Enabled ? Muted : (primary ? Color.FromArgb(26, 20, 8) : Text);
            };
            return b;
        }

        /// <summary>A bordered box with an orange caption, like the HL2 options dialogs.</summary>
        public static Panel Section(string caption, Rectangle bounds)
        {
            var p = new Panel { Bounds = bounds, BackColor = Panel };
            p.Paint += (s, e) =>
            {
                using (var pen = new Pen(Border))
                    e.Graphics.DrawRectangle(pen, 0, 0, p.Width - 1, p.Height - 1);
                TextRenderer.DrawText(e.Graphics, caption.ToUpperInvariant(), Header, new Point(Px(8), Px(6)), Accent);
            };
            return p;
        }

        public static RichTextBox LogBox()
        {
            return new RichTextBox
            {
                ReadOnly = true,
                BackColor = Field,
                ForeColor = Text,
                BorderStyle = BorderStyle.None,
                Font = Mono,
                DetectUrls = false,
                ScrollBars = RichTextBoxScrollBars.Vertical,
            };
        }

        public static void AppendLine(RichTextBox box, string text, Color color)
        {
            if (box.IsDisposed) return;
            if (box.TextLength > 200_000)
            {
                box.Select(0, box.TextLength / 2);
                box.SelectedText = "";
            }
            box.SelectionStart = box.TextLength;
            box.SelectionLength = 0;
            box.SelectionColor = color;
            box.AppendText(text + Environment.NewLine);
            box.SelectionColor = box.ForeColor;
            box.ScrollToCaret();
        }

        public static ProgressBar Progress()
        {
            return new ProgressBar { Style = ProgressBarStyle.Continuous, Minimum = 0, Maximum = 1000 };
        }
    }

    /// <summary>
    /// The stock flat checkbox is nearly invisible on a dark background. This one draws a clear box that
    /// fills orange with a check mark when on.
    /// </summary>
    sealed class ThemeCheckBox : CheckBox
    {
        bool hover;

        public ThemeCheckBox()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.SupportsTransparentBackColor, true);
            AutoSize = true;
            Font = Theme.Ui;
            ForeColor = Theme.Text;
            BackColor = Color.Transparent;
            Cursor = Cursors.Hand;
        }

        int BoxSize => Theme.Px(16);
        int Gap => Theme.Px(8);

        public override Size GetPreferredSize(Size proposedSize)
        {
            var text = TextRenderer.MeasureText(Text, Font);
            return new Size(BoxSize + Gap + text.Width + Theme.Px(2), Math.Max(BoxSize, text.Height) + Theme.Px(4));
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            var bg = Parent?.BackColor ?? Theme.Panel;
            g.Clear(bg);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int s = BoxSize;
            var box = new Rectangle(0, (Height - s) / 2, s - 1, s - 1);
            bool on = Checked;
            var fill = !Enabled ? Theme.Panel : on ? Theme.Accent : Theme.Field;
            var edge = !Enabled ? Theme.Border : on ? Theme.AccentDim : hover ? Theme.Accent : Color.FromArgb(150, 150, 140);
            using (var b = new SolidBrush(fill)) g.FillRectangle(b, box);
            using (var p = new Pen(edge, Math.Max(1f, Theme.Scale * 1.4f))) g.DrawRectangle(p, box);
            if (on)
            {
                using (var p = new Pen(Enabled ? Color.FromArgb(26, 20, 8) : Theme.Muted, Math.Max(2f, Theme.Scale * 2.2f)))
                {
                    p.StartCap = p.EndCap = LineCap.Round;
                    g.DrawLines(p, new[]
                    {
                        new PointF(box.Left + s * 0.22f, box.Top + s * 0.52f),
                        new PointF(box.Left + s * 0.42f, box.Top + s * 0.72f),
                        new PointF(box.Left + s * 0.78f, box.Top + s * 0.28f),
                    });
                }
            }
            var textRect = new Rectangle(s + Gap, 0, Width - s - Gap, Height);
            TextRenderer.DrawText(g, Text, Font, textRect, Enabled ? ForeColor : Theme.Muted,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
            if (Focused && ShowFocusCues)
                ControlPaint.DrawFocusRectangle(g, new Rectangle(textRect.Left - 2, 1, Math.Min(textRect.Width, TextRenderer.MeasureText(Text, Font).Width) + 4, Height - 2));
        }
    }
}
