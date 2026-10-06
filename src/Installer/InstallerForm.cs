using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AlyxMP
{
    sealed class InstallerForm : Form
    {
        readonly TextBox dirBox = Theme.TextBox();
        readonly Button browseButton = Theme.Button("Browse...");
        readonly Label dirStatus = Theme.Label("", Theme.UiBold);
        readonly CheckBox novrCheck = Theme.Check("Install HLA NoVR - play with mouse && keyboard, no VR headset needed");
        readonly Label novrNote = Theme.Label("", Theme.Ui, Theme.Muted);
        readonly CheckBox shortcutCheck = Theme.Check("Create a desktop shortcut", true);
        readonly Button installButton = Theme.Button("INSTALL", true);
        readonly Button uninstallButton = Theme.Button("Uninstall");
        readonly ProgressBar progress = Theme.Progress();
        readonly Label progressLabel = Theme.Label("", Theme.Ui, Theme.Muted);
        readonly RichTextBox logBox = Theme.LogBox();
        CancellationTokenSource cancel;
        bool busy;
        bool installed;
        readonly bool update;

        public InstallerForm(string presetDir, bool? presetNoVR, bool autoInstall = false, bool shortcut = true, bool update = false)
        {
            this.update = update;
            Text = "Alyx Multiplayer Setup";
            Theme.Apply(this);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch (Exception) { }

            var title = Theme.Label("ALYX MULTIPLAYER", Theme.Title, Theme.Accent);
            title.Location = new Point(18, 12);
            var sub = Theme.Label("SETUP  v" + ModFiles.Version, Theme.UiBold, Theme.Muted);
            sub.Location = new Point(400, 34);
            var blurb = Theme.Label("Adds online co-op to Half-Life: Alyx. Host a game, your friends join, and you play the\r\ncampaign together - everyone shows up as Alyx.", Theme.Ui, Theme.Text);
            blurb.Location = new Point(22, 62);
            Controls.AddRange(new Control[] { title, sub, blurb });

            var folder = Theme.Section("Half-Life: Alyx folder", new Rectangle(20, 104, 600, 84));
            dirBox.SetBounds(14, 30, 470, 22);
            dirBox.TextChanged += (s, e) => CheckDir();
            browseButton.SetBounds(492, 28, 94, 26);
            browseButton.Click += (s, e) => Browse();
            dirStatus.Location = new Point(14, 60);
            folder.Controls.AddRange(new Control[] { dirBox, browseButton, dirStatus });
            Controls.Add(folder);

            var options = Theme.Section("Options", new Rectangle(20, 198, 600, 100));
            novrCheck.Location = new Point(14, 28);
            novrNote.Location = new Point(32, 50);
            shortcutCheck.Location = new Point(14, 72);
            options.Controls.AddRange(new Control[] { novrCheck, novrNote, shortcutCheck });
            Controls.Add(options);

            installButton.SetBounds(20, 310, 460, 44);
            installButton.Click += (s, e) => OnInstallClicked();
            uninstallButton.SetBounds(490, 310, 130, 44);
            uninstallButton.Click += (s, e) => OnUninstallClicked();
            progress.SetBounds(20, 366, 600, 14);
            progressLabel.Location = new Point(20, 384);
            logBox.SetBounds(20, 404, 600, 82);
            Controls.AddRange(new Control[] { installButton, uninstallButton, progress, progressLabel, logBox });

            Theme.ScaleLayout(this, new Size(640, 500));

            dirBox.Text = presetDir ?? GamePaths.FindHla() ?? "";
            CheckDir();
            if (presetNoVR.HasValue) novrCheck.Checked = presetNoVR.Value;
            shortcutCheck.Checked = shortcut;
            // after "restart as administrator" setup carries on by itself
            if (autoInstall) Shown += (s, e) => OnInstallClicked();
        }

        string Dir => dirBox.Text.Trim().Trim('"');

        void CheckDir()
        {
            var dir = Dir;
            bool ok = GamePaths.IsValidHla(dir);
            if (ok)
            {
                dirStatus.Text = $"Found Half-Life: Alyx (build {GamePaths.BuildId(dir)})" + (ModFiles.ModInstalled(dir) ? " - Alyx MP is already installed, Install updates it" : "");
                dirStatus.ForeColor = Theme.Good;
                if (ModFiles.NoVRInstalled(dir))
                {
                    novrNote.Text = $"NoVR is already installed (version {ModFiles.NoVRVersion(dir)}). Tick to update it to the latest version.";
                    if (!busy && !installed) novrCheck.Checked = false;
                }
                else
                {
                    novrNote.Text = "Downloads about 140 MB from github.com/HLANoVR/HLA-NoVR (GPL-3.0, by the NoVR team). Alyx MP modifies it slightly.";
                    if (!busy && !installed) novrCheck.Checked = true;
                }
            }
            else
            {
                dirStatus.Text = dir.Length == 0 ? "Pick the folder Half-Life: Alyx is installed in." : "That folder doesn't contain Half-Life: Alyx (it should contain a \"game\" folder).";
                dirStatus.ForeColor = Theme.Bad;
                novrNote.Text = "";
            }
            uninstallButton.Enabled = ok && !busy && (ModFiles.ModInstalled(dir) || Directory.Exists(ModFiles.LauncherDir(dir)));
            if (!installed) installButton.Enabled = ok && !busy;
        }

        void Browse()
        {
            using (var dlg = new FolderBrowserDialog { Description = "Select your Half-Life Alyx folder (it contains a \"game\" folder)" })
            {
                if (GamePaths.IsValidHla(Dir)) dlg.SelectedPath = Dir;
                if (dlg.ShowDialog(this) == DialogResult.OK) dirBox.Text = dlg.SelectedPath;
            }
        }

        bool EnsureWritable(string dir)
        {
            if (InstallerCore.CanWrite(GamePaths.Hlvr(dir))) return true;
            var answer = MessageBox.Show(this,
                "Setup needs administrator rights to write to this folder. Restart setup as administrator?",
                "Alyx Multiplayer Setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer == DialogResult.Yes)
            {
                try
                {
                    Process.Start(new ProcessStartInfo(Application.ExecutablePath,
                        $"--dir \"{dir}\" {(novrCheck.Checked ? "--novr" : "--no-novr")} {(shortcutCheck.Checked ? "" : "--no-shortcut")} --auto{(update ? " --update" : "")}") { Verb = "runas", UseShellExecute = true });
                    Close();
                }
                catch (Exception) { }
            }
            return false;
        }

        void OnInstallClicked()
        {
            if (installed)
            {
                try { Process.Start(new ProcessStartInfo(ModFiles.LauncherExe(Dir)) { UseShellExecute = true, WorkingDirectory = ModFiles.LauncherDir(Dir) }); }
                catch (Exception e) { AddLog("Couldn't start the launcher: " + e.Message, Theme.Bad); return; }
                Close();
                return;
            }
            var dir = Dir;
            if (!GamePaths.IsValidHla(dir) || !EnsureWritable(dir)) return;
            var opts = new InstallOptions { GameDir = dir, InstallNoVR = novrCheck.Checked, DesktopShortcut = shortcutCheck.Checked };
            Run(core => core.Install(opts, cancel.Token), ok =>
            {
                if (!ok) return;
                installed = true;
                installButton.Text = "PLAY - OPEN ALYX MULTIPLAYER";
                installButton.Enabled = true;
                // updating from the launcher: straight back to it
                if (update) OnInstallClicked();
            });
        }

        void OnUninstallClicked()
        {
            var dir = Dir;
            if (!GamePaths.IsValidHla(dir)) return;
            if (MessageBox.Show(this, "Remove Alyx Multiplayer from Half-Life: Alyx?", "Uninstall", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
                return;
            bool removeNoVR = ModFiles.NoVRInstalled(dir) &&
                MessageBox.Show(this, "Also remove HLA NoVR?", "Uninstall", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
            if (!EnsureWritable(dir)) return;
            Run(core => core.Uninstall(dir, removeNoVR), ok => { installed = false; installButton.Text = "INSTALL"; });
        }

        void Run(Action<InstallerCore> work, Action<bool> done)
        {
            busy = true;
            cancel = new CancellationTokenSource();
            installButton.Enabled = uninstallButton.Enabled = browseButton.Enabled = dirBox.Enabled = false;
            novrCheck.Enabled = shortcutCheck.Enabled = false;
            var core = new InstallerCore();
            core.Log += msg => Ui(() => AddLog(msg, Theme.Text));
            core.Progress += (f, text) => Ui(() =>
            {
                progress.Value = Math.Max(0, Math.Min(1000, (int)(f * 1000)));
                progressLabel.Text = text;
            });
            Task.Run(() =>
            {
                bool ok = false;
                try
                {
                    work(core);
                    ok = true;
                }
                catch (OperationCanceledException) { Ui(() => AddLog("Cancelled.", Theme.Bad)); }
                catch (Exception e) { Ui(() => { AddLog(e.Message, Theme.Bad); progressLabel.Text = "Something went wrong - see above."; }); }
                Ui(() =>
                {
                    busy = false;
                    browseButton.Enabled = dirBox.Enabled = true;
                    novrCheck.Enabled = shortcutCheck.Enabled = true;
                    CheckDir();
                    done(ok);
                });
            });
        }

        void AddLog(string text, Color color) => Theme.AppendLine(logBox, text, color);

        void Ui(Action a)
        {
            if (IsDisposed || !IsHandleCreated) return;
            try { BeginInvoke(a); } catch (Exception) { }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (busy)
            {
                if (MessageBox.Show(this, "Setup is still working. Cancel it?", "Alyx Multiplayer Setup", MessageBoxButtons.YesNo) != DialogResult.Yes)
                {
                    e.Cancel = true;
                    return;
                }
                cancel?.Cancel();
            }
            base.OnFormClosing(e);
        }
    }
}
