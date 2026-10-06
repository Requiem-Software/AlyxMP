using System;
using System.Collections.Generic;
using System.IO;

namespace AlyxMP
{
    /// <summary>Remembered launcher choices, stored as key=value lines in %APPDATA%\AlyxMP\settings.txt.</summary>
    sealed class Settings
    {
        static readonly string FilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AlyxMP", "settings.txt");

        public string Name = Environment.UserName;
        public string JoinAddress = "";
        public int Port = Session.DefaultPort;
        public bool Upnp = true;
        public bool NoVR = true;
        public bool Windowed = true;
        public int VConPort = 29000;
        public string ExtraArgs = "";
        public string GameDir = "";
        public bool AutoUpdate;             // install new versions by themselves (Updater)

        // in-game settings menu (F10)
        public bool AutoReload = true;      // NoVR: guns reload by themselves when the magazine runs dry
        public bool Hl2Hud = true;          // NoVR: Half-Life 2's HUD instead of NoVR's own
        public bool NameTags = true;
        public bool InteractDot = true;
        public bool TurnCarried = true;     // NoVR: hold the right mouse button to turn what you carry
        public bool PlayerList = true;
        public bool ChatFeed = true;
        public bool ZoneOutlines = true;

        public static Settings Load()
        {
            var s = new Settings();
            try
            {
                if (!File.Exists(FilePath)) return s;
                var d = new Dictionary<string, string>();
                foreach (var line in File.ReadAllLines(FilePath))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0) d[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
                }
                string v;
                if (d.TryGetValue("name", out v) && v.Length > 0) s.Name = v;
                if (d.TryGetValue("join", out v)) s.JoinAddress = v;
                if (d.TryGetValue("port", out v) && int.TryParse(v, out var port)) s.Port = port;
                if (d.TryGetValue("upnp", out v)) s.Upnp = v == "1";
                if (d.TryGetValue("novr", out v)) s.NoVR = v == "1";
                if (d.TryGetValue("windowed", out v)) s.Windowed = v == "1";
                if (d.TryGetValue("vconport", out v) && int.TryParse(v, out var vp)) s.VConPort = vp;
                if (d.TryGetValue("extra", out v)) s.ExtraArgs = v;
                if (d.TryGetValue("gamedir", out v)) s.GameDir = v;
                if (d.TryGetValue("autoupdate", out v)) s.AutoUpdate = v == "1";
                if (d.TryGetValue("autoreload", out v)) s.AutoReload = v == "1";
                if (d.TryGetValue("hl2hud", out v)) s.Hl2Hud = v == "1";
                if (d.TryGetValue("nametags", out v)) s.NameTags = v == "1";
                if (d.TryGetValue("interactdot", out v)) s.InteractDot = v == "1";
                if (d.TryGetValue("turncarried", out v)) s.TurnCarried = v == "1";
                if (d.TryGetValue("playerlist", out v)) s.PlayerList = v == "1";
                if (d.TryGetValue("chatfeed", out v)) s.ChatFeed = v == "1";
                if (d.TryGetValue("zoneoutlines", out v)) s.ZoneOutlines = v == "1";
            }
            catch (Exception) { }
            return s;
        }

        /// <summary>The in-game switches, as the mod's amp_cfg keys.</summary>
        public IEnumerable<KeyValuePair<string, string>> GameConfig()
        {
            yield return new KeyValuePair<string, string>("tags", NameTags ? "1" : "0");
            yield return new KeyValuePair<string, string>("dot", InteractDot ? "1" : "0");
            yield return new KeyValuePair<string, string>("turn", TurnCarried ? "1" : "0");
            yield return new KeyValuePair<string, string>("list", PlayerList ? "1" : "0");
            yield return new KeyValuePair<string, string>("feed", ChatFeed ? "1" : "0");
            yield return new KeyValuePair<string, string>("zones", ZoneOutlines ? "1" : "0");
            yield return new KeyValuePair<string, string>("autoreload", AutoReload ? "1" : "0");
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                File.WriteAllLines(FilePath, new[]
                {
                    "name=" + Name,
                    "join=" + JoinAddress,
                    "port=" + Port,
                    "upnp=" + (Upnp ? "1" : "0"),
                    "novr=" + (NoVR ? "1" : "0"),
                    "windowed=" + (Windowed ? "1" : "0"),
                    "vconport=" + VConPort,
                    "extra=" + ExtraArgs,
                    "gamedir=" + GameDir,
                    "autoupdate=" + (AutoUpdate ? "1" : "0"),
                    "autoreload=" + (AutoReload ? "1" : "0"),
                    "hl2hud=" + (Hl2Hud ? "1" : "0"),
                    "nametags=" + (NameTags ? "1" : "0"),
                    "interactdot=" + (InteractDot ? "1" : "0"),
                    "turncarried=" + (TurnCarried ? "1" : "0"),
                    "playerlist=" + (PlayerList ? "1" : "0"),
                    "chatfeed=" + (ChatFeed ? "1" : "0"),
                    "zoneoutlines=" + (ZoneOutlines ? "1" : "0"),
                });
            }
            catch (Exception) { }
        }
    }
}
