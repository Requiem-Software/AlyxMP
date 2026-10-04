using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace AlyxMP
{
    /// <summary>Finds Steam and the Half-Life: Alyx install.</summary>
    static class GamePaths
    {
        public const int AppId = 546560;

        public static string SteamDir()
        {
            var keys = new[]
            {
                (Registry.CurrentUser, @"Software\Valve\Steam", "SteamPath"),
                (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
                (Registry.LocalMachine, @"SOFTWARE\Valve\Steam", "InstallPath"),
            };
            foreach (var (hive, key, value) in keys)
            {
                try
                {
                    using (var k = hive.OpenSubKey(key))
                    {
                        if (k?.GetValue(value) is string s && Directory.Exists(s))
                            return Path.GetFullPath(s.Replace('/', '\\'));
                    }
                }
                catch (Exception) { }
            }
            const string fallback = @"C:\Program Files (x86)\Steam";
            return Directory.Exists(fallback) ? fallback : null;
        }

        public static string SteamExe()
        {
            var dir = SteamDir();
            var exe = dir == null ? null : Path.Combine(dir, "steam.exe");
            return exe != null && File.Exists(exe) ? exe : null;
        }

        public static List<string> LibraryFolders()
        {
            var result = new List<string>();
            var steam = SteamDir();
            if (steam == null) return result;
            result.Add(steam);
            try
            {
                var vdf = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
                if (!File.Exists(vdf)) return result;
                foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                {
                    var p = m.Groups[1].Value.Replace(@"\\", @"\");
                    if (!result.Exists(r => SamePath(r, p))) result.Add(p);
                }
            }
            catch (Exception) { }
            return result;
        }

        public static string FindHla()
        {
            foreach (var lib in LibraryFolders())
            {
                try
                {
                    var dir = Path.Combine(lib, "steamapps", "common", "Half-Life Alyx");
                    var manifest = Path.Combine(lib, "steamapps", $"appmanifest_{AppId}.acf");
                    if (File.Exists(manifest))
                    {
                        var m = Regex.Match(File.ReadAllText(manifest), "\"installdir\"\\s+\"([^\"]+)\"");
                        if (m.Success) dir = Path.Combine(lib, "steamapps", "common", m.Groups[1].Value);
                    }
                    if (IsValidHla(dir)) return dir;
                }
                catch (Exception) { }
            }
            return null;
        }

        public static bool IsValidHla(string dir)
        {
            if (string.IsNullOrWhiteSpace(dir)) return false;
            try
            {
                return File.Exists(Path.Combine(dir, "game", "hlvr", "pak01_dir.vpk"))
                    && File.Exists(Path.Combine(dir, "game", "bin", "win64", "hlvr.exe"));
            }
            catch (Exception) { return false; }
        }

        public static string Hlvr(string hla) => Path.Combine(hla, "game", "hlvr");

        /// <summary>Steam build id of the installed game, used to warn about mismatched versions.</summary>
        public static string BuildId(string hla)
        {
            try
            {
                var manifest = Path.GetFullPath(Path.Combine(hla, "..", "..", $"appmanifest_{AppId}.acf"));
                if (!File.Exists(manifest)) return "?";
                var m = Regex.Match(File.ReadAllText(manifest), "\"buildid\"\\s+\"(\\d+)\"");
                return m.Success ? m.Groups[1].Value : "?";
            }
            catch (Exception) { return "?"; }
        }

        public static bool GameRunning()
        {
            var procs = Process.GetProcessesByName("hlvr");
            foreach (var p in procs) p.Dispose();
            return procs.Length > 0;
        }

        static bool SamePath(string a, string b)
        {
            try
            {
                return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception) { return false; }
        }
    }
}
