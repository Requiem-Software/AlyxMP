using System;
using System.Drawing;
using System.Linq;
using System.Net;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace AlyxMP
{
    sealed class MainForm : Form
    {
        readonly string hla;
        readonly Settings settings;
        readonly GameLink game;
        readonly Session session;

        readonly TextBox nameBox = Theme.TextBox();
        readonly TextBox portBox = Theme.TextBox();
        readonly TextBox hostPwBox = Theme.TextBox();
        readonly CheckBox upnpCheck = Theme.Check("Open the port on my router automatically (UPnP)");
        readonly Button hostButton = Theme.Button("START HOSTING", true);
        readonly Label shareLabel = Theme.Label("", Theme.UiBold, Theme.Accent);
        readonly Button copyButton = Theme.Button("Copy");
        readonly LinkLabel publicIpLink = new LinkLabel { Text = "show my public IP", AutoSize = true };
        readonly TextBox joinBox = Theme.TextBox();
        readonly TextBox joinPwBox = Theme.TextBox();
        readonly Button joinButton = Theme.Button("JOIN", true);
        readonly CheckBox novrCheck = Theme.Check("Play without a VR headset (NoVR: mouse && keyboard)");
        readonly CheckBox windowedCheck = Theme.Check("Windowed");
        readonly Button launchButton = Theme.Button("LAUNCH HALF-LIFE: ALYX", true);
        readonly Button resyncButton = Theme.Button("RESYNC MY WORLD");
        readonly Button leaveButton = Theme.Button("LEAVE SESSION");
        readonly ListView playerList = new ListView();
        readonly RichTextBox chatBox = Theme.LogBox();
        readonly TextBox chatInput = Theme.TextBox();
        readonly Button chatSend = Theme.Button("Send");
        readonly RichTextBox logBox = Theme.LogBox();
        readonly Label gameStatus = Theme.Label("", Theme.UiBold);
        readonly Label modStatus = Theme.Label("", Theme.UiBold);
        readonly Label sessionStatus = Theme.Label("", Theme.UiBold);
        readonly Timer refresh = new Timer { Interval = 500 };

        readonly StartupAction startup;
        readonly ChatOverlay chatOverlay;
        readonly SettingsOverlay settingsOverlay;
        int mappedPort;
        string shareAddress;
        bool suppressAutoLaunch;

        public MainForm(string hla, Settings settings, GameLink game, StartupAction startup)
        {
            this.startup = startup ?? new StartupAction();
            this.hla = hla;
            this.settings = settings;
            this.game = game;
            session = new Session(game, hla) { Prefs = settings };
            HlaUi.Init(hla);

            Text = "Alyx Multiplayer";
            Theme.Apply(this);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch (Exception) { }

            BuildLayout();
            Theme.ScaleLayout(this, new Size(900, 640));
            foreach (ColumnHeader col in playerList.Columns) col.Width = Theme.Px(col.Width);
            LoadSettings();

            game.Log += msg => Ui(() => AddLog(msg, Theme.Muted));
            session.Log += msg => Ui(() => AddLog(msg, Theme.Text));
            session.Chat += (name, text) => Ui(() => Theme.AppendLine(chatBox, $"{name}: {text}", Theme.Text));
            session.Changed += () => Ui(RefreshState);
            refresh.Tick += (s, e) => RefreshState();
            refresh.Start();
            chatOverlay = new ChatOverlay(text => session.SendChat(text), () => session.Active);
            settingsOverlay = new SettingsOverlay(settings, ModFiles.NoVRInstalled(hla), OnSettingChanged);

            AddLog($"Alyx MP {ModFiles.Version} - Half-Life: Alyx at {hla}", Theme.Muted);
            if (!ModFiles.ModInstalled(hla))
                AddLog("The mod's game files are missing. Run AlyxMP-Setup.exe again.", Theme.Bad);
            if (!ModFiles.NoVRInstalled(hla))
            {
                novrCheck.Checked = false;
                novrCheck.Enabled = false;
                novrCheck.Text = "Play without a VR headset (NoVR isn't installed)";
            }
            RefreshState();
            Shown += (s, e) => RunStartupAction();
        }

        /// <summary>A switch in the in-game settings menu (F10) was flipped.</summary>
        void OnSettingChanged(string what)
        {
            session.ApplyPrefs();
            try
            {
                // these change game files, which the game reads when it starts
                if (ModFiles.NoVRInstalled(hla))
                {
                    ModFiles.SetAutoReload(hla, settings.AutoReload);
                    ModFiles.SetHud(hla, settings.Hl2Hud);
                }
            }
            catch (Exception e)
            {
                AddLog("Couldn't change the game files: " + e.Message, Theme.Bad);
            }
        }

        void RunStartupAction()
        {
            var a = startup;
            if (!string.IsNullOrWhiteSpace(a.Name)) nameBox.Text = a.Name;
            if (a.NoUpnp) upnpCheck.Checked = false;
            suppressAutoLaunch = a.NoLaunch;
            if (a.HostPort > 0)
            {
                portBox.Text = a.HostPort.ToString();
                if (a.Password != null) hostPwBox.Text = a.Password;
                ToggleHost();
            }
            else if (!string.IsNullOrWhiteSpace(a.Join))
            {
                joinBox.Text = a.Join;
                if (a.Password != null) joinPwBox.Text = a.Password;
                DoJoin();
            }
        }

        // ------------------------------------------------------------------ layout

        void BuildLayout()
        {
            var title = Theme.Label("ALYX MULTIPLAYER", Theme.Title, Theme.Accent);
            title.Location = new Point(18, 10);
            var version = Theme.Label("v" + ModFiles.Version, Theme.Ui, Theme.Muted);
            version.Location = new Point(400, 32);
            gameStatus.Location = new Point(22, 58);
            modStatus.Location = new Point(300, 58);
            sessionStatus.Location = new Point(520, 58);
            Controls.AddRange(new Control[] { title, version, gameStatus, modStatus, sessionStatus });

            var nameLabel = Theme.Label("YOUR NAME", Theme.Header, Theme.Accent);
            nameLabel.Location = new Point(20, 92);
            nameBox.SetBounds(110, 89, 200, 22);
            nameBox.MaxLength = 20;
            Controls.AddRange(new Control[] { nameLabel, nameBox });

            // host
            var host = Theme.Section("Host a game", new Rectangle(20, 122, 410, 186));
            var portLabel = Theme.Label("Port");
            portLabel.Location = new Point(14, 34);
            portBox.SetBounds(50, 31, 64, 22);
            var pwLabel = Theme.Label("Password (optional)");
            pwLabel.Location = new Point(130, 34);
            hostPwBox.SetBounds(250, 31, 146, 22);
            upnpCheck.Location = new Point(14, 62);
            hostButton.SetBounds(14, 88, 382, 34);
            hostButton.Click += (s, e) => ToggleHost();
            shareLabel.Location = new Point(14, 132);
            copyButton.SetBounds(330, 152, 66, 24);
            copyButton.Visible = false;
            copyButton.Click += (s, e) => { if (shareAddress != null) Clipboard.SetText(shareAddress); };
            publicIpLink.Location = new Point(14, 157);
            publicIpLink.LinkColor = Theme.Accent;
            publicIpLink.ActiveLinkColor = Theme.Text;
            publicIpLink.BackColor = Color.Transparent;
            publicIpLink.Visible = false;
            publicIpLink.LinkClicked += (s, e) => ShowPublicIp();
            host.Controls.AddRange(new Control[] { portLabel, portBox, pwLabel, hostPwBox, upnpCheck, hostButton, shareLabel, copyButton, publicIpLink });
            Controls.Add(host);

            // join
            var join = Theme.Section("Join a game", new Rectangle(20, 316, 410, 104));
            var addrLabel = Theme.Label("Address");
            addrLabel.Location = new Point(14, 34);
            joinBox.SetBounds(80, 31, 316, 22);
            var jpwLabel = Theme.Label("Password");
            jpwLabel.Location = new Point(14, 66);
            joinPwBox.SetBounds(80, 63, 150, 22);
            joinButton.SetBounds(246, 60, 150, 32);
            joinButton.Click += (s, e) => DoJoin();
            joinBox.KeyDown += (s, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; DoJoin(); } };
            join.Controls.AddRange(new Control[] { addrLabel, joinBox, jpwLabel, joinPwBox, joinButton });
            Controls.Add(join);

            // game
            var gameBox = Theme.Section("Game", new Rectangle(20, 428, 410, 192));
            novrCheck.Location = new Point(14, 32);
            windowedCheck.Location = new Point(14, 56);
            launchButton.SetBounds(14, 80, 382, 38);
            launchButton.Click += (s, e) => LaunchGame();
            resyncButton.SetBounds(14, 126, 186, 30);
            resyncButton.Click += (s, e) => session.Resync();
            leaveButton.SetBounds(210, 126, 186, 30);
            leaveButton.Click += (s, e) => LeaveSession();
            var hint = Theme.Label("Resync loads the host's latest save if your world got out of step.", Theme.Ui, Theme.Muted);
            hint.Location = new Point(14, 166);
            gameBox.Controls.AddRange(new Control[] { novrCheck, windowedCheck, launchButton, resyncButton, leaveButton, hint });
            Controls.Add(gameBox);

            // players
            var playersBox = Theme.Section("Players", new Rectangle(450, 92, 430, 170));
            playerList.SetBounds(10, 26, 410, 134);
            playerList.View = View.Details;
            playerList.FullRowSelect = true;
            playerList.HeaderStyle = ColumnHeaderStyle.Nonclickable;
            playerList.BorderStyle = BorderStyle.None;
            playerList.BackColor = Theme.Field;
            playerList.ForeColor = Theme.Text;
            playerList.OwnerDraw = true;
            playerList.Columns.Add("Name", 190);
            playerList.Columns.Add("Level", 150);
            playerList.Columns.Add("Ping", 66);
            playerList.DrawColumnHeader += (s, e) =>
            {
                using (var b = new SolidBrush(Theme.PanelHi)) e.Graphics.FillRectangle(b, e.Bounds);
                TextRenderer.DrawText(e.Graphics, e.Header.Text, Theme.UiBold, Rectangle.Inflate(e.Bounds, -4, 0), Theme.Accent,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
            };
            playerList.DrawItem += (s, e) => { };
            playerList.DrawSubItem += (s, e) =>
            {
                var color = e.ColumnIndex == 0 && e.Item.Tag is PlayerView pv && pv.IsYou ? Theme.Accent : Theme.Text;
                TextRenderer.DrawText(e.Graphics, e.SubItem.Text, Theme.Ui, Rectangle.Inflate(e.Bounds, -4, 0), color,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
            };
            playersBox.Controls.Add(playerList);
            Controls.Add(playersBox);

            // chat
            var chat = Theme.Section("Chat", new Rectangle(450, 272, 430, 168));
            chatBox.SetBounds(10, 26, 410, 100);
            chatInput.SetBounds(10, 134, 330, 22);
            chatInput.MaxLength = 120;
            chatSend.SetBounds(346, 132, 74, 26);
            chatSend.Click += (s, e) => SendChat();
            chatInput.KeyDown += (s, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; SendChat(); } };
            chat.Controls.AddRange(new Control[] { chatBox, chatInput, chatSend });
            Controls.Add(chat);

            // log
            var log = Theme.Section("Log", new Rectangle(450, 450, 430, 170));
            logBox.SetBounds(10, 26, 410, 134);
            log.Controls.Add(logBox);
            Controls.Add(log);
        }

        void LoadSettings()
        {
            nameBox.Text = settings.Name;
            portBox.Text = settings.Port.ToString();
            upnpCheck.Checked = settings.Upnp;
            joinBox.Text = settings.JoinAddress;
            novrCheck.Checked = settings.NoVR;
            windowedCheck.Checked = settings.Windowed;
        }

        void SaveSettings()
        {
            settings.Name = nameBox.Text.Trim();
            if (int.TryParse(portBox.Text, out var port) && port > 0 && port < 65536) settings.Port = port;
            settings.Upnp = upnpCheck.Checked;
            settings.JoinAddress = joinBox.Text.Trim();
            if (novrCheck.Enabled) settings.NoVR = novrCheck.Checked;
            settings.Windowed = windowedCheck.Checked;
            settings.Save();
        }

        // ------------------------------------------------------------------ actions

        void ToggleHost()
        {
            if (session.Active)
            {
                LeaveSession();
                return;
            }
            if (!int.TryParse(portBox.Text, out var port) || port < 1 || port > 65535)
            {
                AddLog("Enter a port number between 1 and 65535.", Theme.Bad);
                return;
            }
            SaveSettings();
            session.Host(nameBox.Text, port, hostPwBox.Text);
            var lan = Upnp.LocalIp();
            ShowShare($"{lan}:{port}", IsPrivate(lan) ? "Same network: " : "Friends join with: ");
            if (upnpCheck.Checked)
            {
                AddLog("Asking your router to open port " + port + "...", Theme.Muted);
                Task.Run(() =>
                {
                    var ip = Upnp.Open(port, out var error);
                    Ui(() =>
                    {
                        if (ip != null && ip != "?")
                        {
                            mappedPort = port;
                            ShowShare($"{ip}:{port}", "Friends join with: ");
                            AddLog($"Port {port} is open. Friends can join with {ip}:{port}", Theme.Good);
                        }
                        else
                        {
                            AddLog($"Couldn't open the port automatically ({error ?? "no external IP"}). " +
                                   $"Forward TCP port {port} to {lan} in your router, or play over a VPN like Tailscale/ZeroTier/Radmin.", Theme.Bad);
                            publicIpLink.Visible = true;
                        }
                    });
                });
            }
            else
            {
                AddLog($"Friends on your network can join with {lan}:{port}. For internet play forward TCP port {port} to this PC.", Theme.Muted);
                publicIpLink.Visible = true;
            }
            if (!GamePaths.GameRunning() && !suppressAutoLaunch) LaunchGame();
        }

        static bool IsPrivate(string ip)
        {
            var p = ip.Split('.');
            if (p.Length != 4 || !int.TryParse(p[0], out var a) || !int.TryParse(p[1], out var b)) return true;
            return a == 10 || a == 127 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 100 && b >= 64 && b <= 127);
        }

        void ShowShare(string address, string prefix)
        {
            shareAddress = address;
            shareLabel.Text = prefix + address;
            copyButton.Visible = true;
        }

        void ShowPublicIp()
        {
            publicIpLink.Enabled = false;
            Task.Run(() =>
            {
                string ip = null;
                try
                {
                    ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                    using (var wc = new WebClient()) ip = wc.DownloadString("https://api.ipify.org").Trim();
                }
                catch (Exception) { }
                Ui(() =>
                {
                    publicIpLink.Enabled = true;
                    if (ip == null) { AddLog("Couldn't look up your public IP.", Theme.Bad); return; }
                    publicIpLink.Visible = false;
                    ShowShare($"{ip}:{settings.Port}", "Internet: ");
                    AddLog($"Your public address is {ip}:{settings.Port} (works once the port is forwarded).", Theme.Muted);
                });
            });
        }

        void DoJoin()
        {
            if (session.Active)
            {
                AddLog("Leave the current session first.", Theme.Bad);
                return;
            }
            SaveSettings();
            session.Join(nameBox.Text, joinBox.Text, joinPwBox.Text);
            if (!GamePaths.GameRunning() && !suppressAutoLaunch) LaunchGame();
        }

        void LeaveSession()
        {
            session.Stop();
            if (mappedPort != 0)
            {
                var p = mappedPort;
                mappedPort = 0;
                Task.Run(() => Upnp.Close(p));
            }
            shareLabel.Text = "";
            shareAddress = null;
            copyButton.Visible = false;
            publicIpLink.Visible = false;
        }

        void LaunchGame()
        {
            if (GamePaths.GameRunning())
            {
                if (!game.Connected)
                    AddLog("Half-Life: Alyx is already running but wasn't started from here, so the mod can't talk to it. Close the game and press Launch.", Theme.Bad);
                else
                    AddLog("The game is already running.", Theme.Muted);
                return;
            }
            SaveSettings();
            try
            {
                if (ModFiles.ModInstalled(hla)) ModFiles.EnsureHook(hla);
                if (ModFiles.NoVRInstalled(hla))
                {
                    ModFiles.EnsureNoVRSearchPaths(hla);
                    ModFiles.EnsureNoVRUseHook(hla);
                    ModFiles.SetHud(hla, settings.Hl2Hud);
                    ModFiles.SetAutoReload(hla, settings.AutoReload);
                }
            }
            catch (Exception e)
            {
                AddLog("Couldn't check the game files: " + e.Message, Theme.Bad);
            }
            var screen = Screen.PrimaryScreen.Bounds;
            var opts = new LaunchOptions
            {
                NoVR = novrCheck.Enabled && novrCheck.Checked,
                Windowed = windowedCheck.Checked,
                Width = screen.Width,
                Height = screen.Height,
                VConPort = settings.VConPort,
                Extra = settings.ExtraArgs,
            };
            try
            {
                var args = GameLink.Launch(hla, opts);
                AddLog("Starting Half-Life: Alyx " + args, Theme.Muted);
            }
            catch (Exception e)
            {
                AddLog("Couldn't start the game through Steam: " + e.Message, Theme.Bad);
            }
        }

        void SendChat()
        {
            var text = chatInput.Text.Trim();
            if (text.Length == 0) return;
            if (!session.Active)
            {
                AddLog("Host or join a game to chat.", Theme.Muted);
                return;
            }
            session.SendChat(text);
            chatInput.Clear();
        }

        // ------------------------------------------------------------------ status

        void RefreshState()
        {
            bool running = GamePaths.GameRunning();
            if (!running) SetStatus(gameStatus, "Game: not running", Theme.Muted);
            else if (!game.Connected) SetStatus(gameStatus, "Game: running (not linked)", Theme.Bad);
            else if (game.Map == null || game.Map == "startup") SetStatus(gameStatus, "Game: main menu", Theme.Text);
            else SetStatus(gameStatus, "Game: " + game.Map, Theme.Good);

            if (!game.Connected) SetStatus(modStatus, "Mod: -", Theme.Muted);
            else if (game.ModReady) SetStatus(modStatus, "Mod: loaded " + game.ModVersion, Theme.Good);
            else SetStatus(modStatus, "Mod: loading...", Theme.Text);

            SetStatus(sessionStatus, session.Status, session.Active ? Theme.Good : Theme.Muted);

            hostButton.Text = session.Active && session.IsHost ? "STOP HOSTING" : "START HOSTING";
            hostButton.Enabled = !session.Active || session.IsHost;
            joinButton.Enabled = !session.Active;
            leaveButton.Enabled = session.Active;
            resyncButton.Enabled = session.Active;
            resyncButton.Text = session.IsHost ? "SEND MY WORLD TO ALL" : "RESYNC MY WORLD";
            launchButton.Enabled = !running;
            launchButton.Text = running ? "GAME IS RUNNING" : "LAUNCH HALF-LIFE: ALYX";

            var rows = session.Players;
            if (playerList.Items.Count != rows.Count || rows.Where((p, i) => !SameRow(playerList.Items[i], p)).Any())
            {
                playerList.BeginUpdate();
                playerList.Items.Clear();
                foreach (var p in rows)
                {
                    var name = p.Name + (p.IsYou && p.IsHost ? " (you, host)" : p.IsYou ? " (you)" : p.IsHost ? " (host)" : "");
                    var item = new ListViewItem(new[] { name, p.Map ?? "-", p.Ping >= 0 ? p.Ping + " ms" : "" }) { Tag = p };
                    playerList.Items.Add(item);
                }
                playerList.EndUpdate();
            }
        }

        static bool SameRow(ListViewItem item, PlayerView p) =>
            item.Tag is PlayerView old && old.Id == p.Id && old.Name == p.Name && old.Map == p.Map && old.Ping == p.Ping && old.IsHost == p.IsHost;

        static void SetStatus(Label label, string text, Color color)
        {
            if (label.Text != text) label.Text = text;
            if (label.ForeColor != color) label.ForeColor = color;
        }

        void AddLog(string text, Color color) =>
            Theme.AppendLine(logBox, DateTime.Now.ToString("HH:mm:ss  ") + text, color);

        void Ui(Action a)
        {
            if (IsDisposed || !IsHandleCreated) return;
            try { BeginInvoke(a); } catch (Exception) { }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            SaveSettings();
            refresh.Stop();
            LeaveSession();
            session.Dispose();
            chatOverlay.Dispose();
            settingsOverlay.Dispose();
            base.OnFormClosing(e);
        }
    }
}
