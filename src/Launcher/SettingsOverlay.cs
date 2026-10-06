using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace AlyxMP
{
    /// <summary>
    /// The settings menu: F10 over the game. Mouse or arrow keys + Enter switch things; Esc or F10 closes.
    /// Most switches apply at once; the ones that change game files apply the next time the game starts.
    /// </summary>
    sealed class SettingsOverlay : GameOverlay
    {
        sealed class Item
        {
            public string Label, Help;
            public Func<bool> Get;
            public Action<bool> Set;
            public bool NeedsRestart, NoVROnly;
        }

        readonly Settings settings;
        readonly Action<string> changed;
        readonly List<Item> items = new List<Item>();
        readonly bool novrAvailable;
        int selected = -1, hover = -1;

        const int W = 540, Head = 104, RowH = 60, Foot = 58, Pad = 36;

        public SettingsOverlay(Settings settings, bool novrAvailable, Action<string> changed)
            : base(0xA18, Keys.F10, () => true)
        {
            this.settings = settings;
            this.changed = changed;
            this.novrAvailable = novrAvailable;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            Opacity = 0.96;

            Add("Auto reload", "Guns reload by themselves when the magazine runs dry",
                () => settings.AutoReload, v => settings.AutoReload = v, restart: true, novr: true);
            Add("Half-Life 2 HUD", "Health, suit and ammo the way Half-Life 2 shows them",
                () => settings.Hl2Hud, v => settings.Hl2Hud = v, restart: true, novr: true);
            Add("Name tags", "Names over the other players' heads",
                () => settings.NameTags, v => settings.NameTags = v);
            Add("Interaction dot", "A dot in the crosshair when E would do something",
                () => settings.InteractDot, v => settings.InteractDot = v, novr: true);
            Add("Turn carried objects", "Hold right-click while carrying something and move the mouse",
                () => settings.TurnCarried, v => settings.TurnCarried = v, novr: true);
            Add("Player list", "Who's playing and how far away they are, top left",
                () => settings.PlayerList, v => settings.PlayerList = v);
            Add("Chat messages", "Chat and session messages on the left of the screen",
                () => settings.ChatFeed, v => settings.ChatFeed = v);
            Add("Loading zone outlines", "Mark the spots where everyone gathers to change level",
                () => settings.ZoneOutlines, v => settings.ZoneOutlines = v);

            ClientSize = new Size(Theme.Px(W), Theme.Px(Head + RowH * items.Count + Foot));
            MouseMove += (s, e) => SetHover(RowAt(e.Location));
            MouseLeave += (s, e) => SetHover(-1);
            MouseClick += (s, e) => { var i = RowAt(e.Location); if (i >= 0) Flip(i); };
        }

        void Add(string label, string help, Func<bool> get, Action<bool> set, bool restart = false, bool novr = false) =>
            items.Add(new Item { Label = label, Help = help, Get = get, Set = set, NeedsRestart = restart, NoVROnly = novr });

        bool Usable(Item it) => !it.NoVROnly || novrAvailable;

        int RowAt(Point p)
        {
            int y = p.Y - Theme.Px(Head);
            if (y < 0) return -1;
            int i = y / Theme.Px(RowH);
            return i < items.Count ? i : -1;
        }

        void SetHover(int i)
        {
            if (i == hover) return;
            hover = i;
            Cursor = i >= 0 && Usable(items[i]) ? Cursors.Hand : Cursors.Default;
            Invalidate();
        }

        void Flip(int i)
        {
            var it = items[i];
            if (!Usable(it)) return;
            it.Set(!it.Get());
            settings.Save();
            changed?.Invoke(it.Label);
            Invalidate();
        }

        protected override void OnOpen(Rectangle game)
        {
            selected = -1;
            hover = -1;
            Location = new Point(game.Left + (game.Width - Width) / 2, game.Top + (game.Height - Height) / 2);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            switch (e.KeyCode)
            {
                case Keys.Escape:
                case Keys.F10:
                    Dismiss(true);
                    break;
                case Keys.Down:
                case Keys.S:
                    selected = (selected + 1) % items.Count;
                    Invalidate();
                    break;
                case Keys.Up:
                case Keys.W:
                    selected = selected <= 0 ? items.Count - 1 : selected - 1;
                    Invalidate();
                    break;
                case Keys.Enter:
                case Keys.Space:
                    if (selected >= 0) Flip(selected);
                    break;
                default:
                    base.OnKeyDown(e);
                    return;
            }
            e.Handled = e.SuppressKeyPress = true;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(HlaUi.Panel);
            int w = Width, m = Theme.Px(Pad);

            HlaUi.Draw(g, "SETTINGS", Theme.Px(34), HlaUi.Bold, HlaUi.Text,
                new Rectangle(m, Theme.Px(24), w - 2 * m, Theme.Px(40)), HlaUi.AlignLeft, Theme.Px(3));
            HlaUi.Draw(g, "ALYX MULTIPLAYER", Theme.Px(14), HlaUi.Semibold, HlaUi.Dim,
                new Rectangle(m + Theme.Px(2), Theme.Px(66), w - 2 * m, Theme.Px(20)), HlaUi.AlignLeft, Theme.Px(2));
            using (var rule = new Pen(HlaUi.Rule)) g.DrawLine(rule, m, Theme.Px(Head) - 1, w - m, Theme.Px(Head) - 1);

            for (int i = 0; i < items.Count; i++)
            {
                var it = items[i];
                bool usable = Usable(it);
                var row = new Rectangle(0, Theme.Px(Head + RowH * i), w, Theme.Px(RowH));
                bool hot = usable && (i == hover || i == selected);
                if (hot) using (var b = new SolidBrush(HlaUi.Hover)) g.FillRectangle(b, row);
                if (i == selected)
                    using (var b = new SolidBrush(HlaUi.Accent)) g.FillRectangle(b, 0, row.Top, Theme.Px(3), row.Height);

                var label = usable ? HlaUi.Text : HlaUi.Dim;
                HlaUi.Draw(g, it.Label, Theme.Px(21), HlaUi.Semibold, label,
                    new Rectangle(m, row.Top + Theme.Px(7), w - 2 * m - Theme.Px(70), Theme.Px(26)));
                var help = !usable ? "Only without a VR headset (NoVR)" : it.Help;
                HlaUi.Draw(g, help, Theme.Px(15), HlaUi.Regular, HlaUi.Dim,
                    new Rectangle(m, row.Top + Theme.Px(33), w - 2 * m - Theme.Px(70), Theme.Px(20)));
                if (it.NeedsRestart && usable)
                {
                    var tag = new Rectangle(m + HlaUi.Measure(g, it.Label, Theme.Px(21), HlaUi.Semibold).Width + Theme.Px(10),
                        row.Top + Theme.Px(11), Theme.Px(120), Theme.Px(18));
                    HlaUi.Draw(g, "RESTART", Theme.Px(12), HlaUi.Semibold, HlaUi.Accent, tag, HlaUi.AlignLeft, Theme.Px(1));
                }
                int tw = Theme.Px(46), th = Theme.Px(24);
                var toggle = new Rectangle(w - m - tw, row.Top + (row.Height - th) / 2, tw, th);
                if (usable) HlaUi.Toggle(g, toggle, it.Get(), hot);
            }

            int fy = Theme.Px(Head + RowH * items.Count);
            using (var rule = new Pen(HlaUi.Rule)) g.DrawLine(rule, m, fy, w - m, fy);
            HlaUi.Draw(g, "F10  CLOSE", Theme.Px(14), HlaUi.Semibold, HlaUi.Dim,
                new Rectangle(m, fy, w / 2, Theme.Px(Foot)), HlaUi.VCenter, Theme.Px(2));
            HlaUi.Draw(g, "RESTART  needs a game restart", Theme.Px(14), HlaUi.Regular, HlaUi.Dim,
                new Rectangle(w / 2, fy, w / 2 - m, Theme.Px(Foot)), HlaUi.VCenter | HlaUi.AlignRight);
            using (var edge = new Pen(HlaUi.Rule)) g.DrawRectangle(edge, 0, 0, w - 1, Height - 1);
        }
    }
}
