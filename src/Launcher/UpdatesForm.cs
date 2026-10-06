using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Windows.Forms;

namespace AlyxMP
{
    /// <summary>The update log: what changed in each version, plus the automatic updates switch.</summary>
    sealed class UpdatesForm : Form
    {
        public UpdatesForm(Settings settings, IList<Release> releases, Release newer, string error, Action update)
        {
            Text = "Alyx Multiplayer - Updates";
            Theme.Apply(this);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = false;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent;

            var title = Theme.Label("UPDATES", Theme.Title, Theme.Accent);
            title.Location = new Point(16, 10);
            string state = newer != null ? $"You have v{ModFiles.Version}. v{newer.Version} is out."
                : releases.Count > 0 ? $"You have v{ModFiles.Version}, the latest version."
                : $"You have v{ModFiles.Version}.";
            var status = Theme.Label(state, Theme.UiBold, newer != null ? Theme.Accent : Theme.Text);
            status.Location = new Point(20, 52);

            var log = Theme.LogBox();
            log.Font = Theme.Ui;
            log.Dock = DockStyle.Fill;
            var logFrame = new Panel { Bounds = new Rectangle(20, 80, 540, 266), BackColor = Theme.Field, Padding = new Padding(10, 8, 4, 8) };
            logFrame.Controls.Add(log);
            if (releases.Count == 0)
                Theme.AppendLine(log, "Couldn't get the update log from GitHub" + (error != null ? ": " + error : "."), Theme.Bad);
            foreach (var r in releases)
            {
                var date = r.Published == default(DateTime) ? "" : "   " + r.Published.ToLocalTime().ToString("MMMM d, yyyy", CultureInfo.InvariantCulture);
                var mark = r.Version == Updater.Current ? "   (yours)" : "";
                AppendStyled(log, "v" + r.Version + date + mark, Theme.UiBold, Theme.Accent);
                foreach (var line in Updater.NoteLines(r))
                    AppendStyled(log, line.Key, line.Value ? Theme.UiBold : Theme.Ui, line.Value ? Theme.Text : Theme.Muted);
                AppendStyled(log, "", Theme.Ui, Theme.Text);
            }
            log.SelectionStart = 0;
            log.ScrollToCaret();

            var auto = Theme.Check("Update automatically", settings.AutoUpdate);
            auto.Location = new Point(20, 358);
            auto.CheckedChanged += (s, e) =>
            {
                settings.AutoUpdate = auto.Checked;
                settings.Save();
            };
            var autoHint = Theme.Label("Installs new versions by itself when the game isn't running.", Theme.Ui, Theme.Muted);
            autoHint.Location = new Point(40, 382);

            var close = Theme.Button("Close");
            close.SetBounds(460, 412, 100, 32);
            close.Click += (s, e) => Close();
            Controls.AddRange(new Control[] { title, status, logFrame, auto, autoHint, close });
            if (newer != null)
            {
                var go = Theme.Button("UPDATE TO v" + newer.Version, true);
                go.SetBounds(270, 412, 180, 32);
                go.Click += (s, e) => { Close(); update(); };
                Controls.Add(go);
            }
            CancelButton = close;
            Theme.ScaleLayout(this, new Size(580, 462));
        }

        static void AppendStyled(RichTextBox box, string text, Font font, Color color)
        {
            box.SelectionStart = box.TextLength;
            box.SelectionLength = 0;
            box.SelectionFont = font;
            box.SelectionColor = color;
            box.AppendText(text + Environment.NewLine);
        }
    }
}
