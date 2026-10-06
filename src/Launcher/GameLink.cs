using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace AlyxMP
{
    sealed class LaunchOptions
    {
        public bool NoVR = true;
        public bool Windowed = true;
        public int Width, Height;
        public int VConPort = 29000;
        public string Extra = "";
    }

    /// <summary>
    /// Talks to the running game: reads the mod's "[AMP]" lines and a few engine messages from VConsole,
    /// and sends console commands back. Events fire on the VConsole reader thread.
    /// </summary>
    sealed class GameLink : IDisposable
    {
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out ClientRect r);
        [StructLayout(LayoutKind.Sequential)] struct ClientRect { public int Left, Top, Right, Bottom; }

        /// <summary>Pixel size of the game's picture (its window's client area), or empty if it isn't running.</summary>
        public static Size GameClientSize()
        {
            try
            {
                foreach (var p in Process.GetProcessesByName("hlvr"))
                {
                    using (p)
                    {
                        var h = p.MainWindowHandle;
                        if (h != IntPtr.Zero && GetClientRect(h, out var r) && r.Right > 0 && r.Bottom > 0)
                            return new Size(r.Right - r.Left, r.Bottom - r.Top);
                    }
                }
            }
            catch (Exception) { }
            return Size.Empty;
        }

        public event Action<string> Log;
        public event Action StatusChanged;
        public event Action<string> Hello;            // mod (re)loaded on a map
        public event Action<string> MapReady;         // mod finished precaching: puppets can spawn
        public event Action<PlayerState> State;       // local player, ~20 Hz while moving
        public event Action<string> Zone;             // loading zone the local player stands in, or "-"
        public event Action<int> Shot;                // local player fired (weapon code)
        public event Action<string> Kill;             // NPC killed locally: "idx class x y z"
        public event Action Died;
        public event Action Transition;               // a level change started
        public event Action<string> SaveWritten;      // full path of a save that just finished
        public event Action<string> SaveLoaded;       // a save was restored (death reload, manual load...); arg = map
        public event Action<string> World;            // world-sync payload from the in-game mod
        public event Action<bool> Menu;               // the in-game settings menu opened / closed
        public event Action<string, string> Setting;  // a switch in that menu was flipped: amp_cfg key, value

        readonly string hla;
        readonly VConClient vcon;
        string pendingSave;
        bool restoringSave;
        DateTime lastRepair = DateTime.MinValue;

        public string Map { get; private set; }
        public bool ModReady { get; private set; }
        /// <summary>The game runs in VR (not NoVR), as the mod reported.</summary>
        public bool IsVR { get; private set; }
        public string ModVersion { get; private set; }
        public bool Connected => vcon.Connected;
        public bool InLevel => Connected && ModReady && Map != null && Map != "startup";

        public GameLink(string hla, int vconPort)
        {
            this.hla = hla;
            vcon = new VConClient(vconPort);
            vcon.Line += OnLine;
            vcon.ConnectionChanged += up =>
            {
                Map = null;
                ModReady = false;
                if (up) vcon.Send("amp_hello");
                Log?.Invoke(up ? "Connected to the game." : "Lost connection to the game.");
                StatusChanged?.Invoke();
            };
        }

        public void Start() => vcon.Start();

        public bool Send(string command) => vcon.Send(command);

        void OnLine(string line)
        {
            if (line.StartsWith("[AMP]"))
            {
                HandleMod(line.Substring(5));
                return;
            }
            if (line.StartsWith("Saving game to "))
            {
                var m = Regex.Match(line, @"Saving game to (.+?\.sav)");
                if (m.Success) pendingSave = Path.Combine(GamePaths.Hlvr(hla), m.Groups[1].Value);
            }
            else if (line.StartsWith("ExecuteSave("))
            {
                if (pendingSave != null) SaveWritten?.Invoke(pendingSave);
                pendingSave = null;
            }
            else if (line.Contains("Restoring Save ("))
            {
                restoringSave = true;
            }
            else if (line.StartsWith("Unknown command: amp_"))
            {
                RepairMod();
            }
            else if (line.StartsWith("Loading map") || line.StartsWith("CHANGE LEVEL"))
            {
                ModReady = false;
                StatusChanged?.Invoke();
            }
            else if (line.Contains("Script Runtime Error") || line.Contains("alyxmp\\") || line.Contains("alyxmp/"))
            {
                Log?.Invoke("[game] " + line);
            }
        }

        void HandleMod(string msg)
        {
            int sp = msg.IndexOf(' ');
            string verb = sp < 0 ? msg : msg.Substring(0, sp);
            string rest = sp < 0 ? "" : msg.Substring(sp + 1);
            var p = rest.Split(' ');
            switch (verb)
            {
                case "s":
                    var st = Clean.State(rest);
                    if (st == null) return;
                    if (st.Map != Map) { Map = st.Map; StatusChanged?.Invoke(); }
                    State?.Invoke(st);
                    break;
                case "hello":
                    // proto version map vr ready
                    ModVersion = p.Length > 1 ? p[1] : "?";
                    Map = p.Length > 2 ? Clean.Map(p[2]) : null;
                    ModReady = p.Length > 4 && p[4] == "1";
                    IsVR = p.Length > 3 && p[3] == "1";
                    if (p[0] != Session.Proto.ToString())
                        Log?.Invoke($"The game is running mod protocol {p[0]} but this launcher speaks {Session.Proto} - reinstall Alyx MP.");
                    StatusChanged?.Invoke();
                    Hello?.Invoke(Map);
                    if (ModReady) MapReady?.Invoke(Map);
                    break;
                case "ready":
                    Map = p.Length > 0 ? Clean.Map(p[0]) : Map;
                    ModReady = true;
                    StatusChanged?.Invoke();
                    MapReady?.Invoke(Map);
                    if (restoringSave && Map != "startup")
                    {
                        restoringSave = false;
                        SaveLoaded?.Invoke(Map);
                    }
                    break;
                case "z":
                    var z = Clean.Zone(p[0]);
                    if (z != null) Zone?.Invoke(z);
                    break;
                case "f":
                    if (int.TryParse(p[0], out var w) && w >= 0 && w <= 3) Shot?.Invoke(w);
                    break;
                case "k":
                    var k = Clean.Kill(rest);
                    if (k != null) Kill?.Invoke(k);
                    break;
                case "died":
                    Died?.Invoke();
                    break;
                case "chl":
                case "going":
                    Transition?.Invoke();
                    break;
                case "err":
                    Log?.Invoke("[mod] " + rest);
                    break;
                case "menu":
                    Menu?.Invoke(p[0] == "1");
                    break;
                case "cfg":
                    if (p.Length == 2 && (p[1] == "0" || p[1] == "1")) Setting?.Invoke(p[0], p[1]);
                    break;
                case "w":
                    var world = Clean.World(rest);
                    if (world != null) World?.Invoke(world);
                    break;
            }
        }

        /// <summary>The game is running without our Lua (fresh install, or the map loaded before the hook existed).</summary>
        void RepairMod()
        {
            if ((DateTime.UtcNow - lastRepair).TotalSeconds < 10) return;
            lastRepair = DateTime.UtcNow;
            if (!ModFiles.ModInstalled(hla))
            {
                Log?.Invoke("Alyx MP's game files are missing - run the installer again.");
                return;
            }
            vcon.Send("script_reload_code alyxmp/main");
        }

        public static string Launch(string hla, LaunchOptions o)
        {
            var args = new List<string>();
            if (o.NoVR) args.AddRange(new[] { "-novr", "+vr_enable_fake_vr", "1", "-defaultmenu" });
            else args.AddRange(new[] { "+hlvr_auto_dismiss_loading", "1" });
            args.AddRange(new[] { "-console", "-vconsole", "-vconport", o.VConPort.ToString(), "-novid" });
            if (o.Windowed && o.Width > 0 && o.Height > 0)
                args.AddRange(new[] { "-window", "-w", o.Width.ToString(), "-h", o.Height.ToString() });
            else if (!o.Windowed)
                args.Add("-fullscreen");
            if (!string.IsNullOrWhiteSpace(o.Extra)) args.Add(o.Extra.Trim());
            var joined = string.Join(" ", args);

            var steam = GamePaths.SteamExe();
            if (steam != null)
            {
                Process.Start(new ProcessStartInfo(steam, $"-applaunch {GamePaths.AppId} {joined}") { UseShellExecute = false });
                return joined;
            }
            // no steam.exe found: the steam:// handler works too but makes Steam ask for confirmation
            Process.Start(new ProcessStartInfo($"steam://run/{GamePaths.AppId}//{joined}/") { UseShellExecute = true });
            return joined;
        }

        public void Dispose() => vcon.Dispose();
    }
}
