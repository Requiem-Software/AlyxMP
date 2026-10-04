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
            }
            catch (Exception) { }
            return s;
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
                });
            }
            catch (Exception) { }
        }
    }
}
