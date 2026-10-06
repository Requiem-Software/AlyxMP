using System;
using System.Drawing;
using System.Windows.Forms;

namespace AlyxMP
{
    /// <summary>
    /// In-game chat: Y over the game opens a slim chat line under the chat feed the mod draws on the
    /// left; Enter sends, Esc cancels.
    /// </summary>
    sealed class ChatOverlay : GameOverlay
    {
        readonly Action<string> send;
        readonly TextBox input = new TextBox();

        public ChatOverlay(Action<string> send, Func<bool> enabled) : base(0xA17, Keys.Y, enabled)
        {
            this.send = send;
            Opacity = 0.94;
            // Raju's line is 1.3 times its size (room for Devanagari); the box has to fit all of it
            int em = Theme.Px(18), box = (int)Math.Ceiling(em * 1.32) + 2;
            Size = new Size(Theme.Px(500), box + Theme.Px(14));
            input.BorderStyle = BorderStyle.None;
            input.BackColor = HlaUi.Panel;
            input.ForeColor = HlaUi.Text;
            input.MaxLength = 120;
            input.AutoSize = false;
            input.SetBounds(Theme.Px(64), (Height - box) / 2, Theme.Px(420), box);
            HlaUi.UseFont(input, em, HlaUi.Regular);
            input.KeyDown += OnKey;
            Controls.Add(input);
        }

        protected override void OnOpen(Rectangle game)
        {
            // just under the chat feed the mod draws on the left
            Location = new Point(game.Left + (int)(game.Height * 32 / 1080.0), game.Top + (int)(game.Height * 0.765));
            input.Text = "";
            input.Focus();
        }

        protected override void OnActivated(EventArgs e)
        {
            base.OnActivated(e);
            input.Focus();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            HlaUi.Draw(g, "SAY", Theme.Px(14), HlaUi.Semibold, HlaUi.Dim,
                new Rectangle(Theme.Px(16), 0, Theme.Px(48), Height), HlaUi.VCenter, Theme.Px(2));
            using (var p = new Pen(HlaUi.Rule)) g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
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
    }
}
