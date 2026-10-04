using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace AlyxMP
{
    /// <summary>
    /// Everything the mod touches inside the game folder. Shared by the installer and by the launcher,
    /// which re-applies the hook on start because NoVR updates and Steam file verification undo it.
    /// </summary>
    static class ModFiles
    {
        public const string Version = "0.4.0";
        public const string HookLine = "script_reload_code alyxmp/main";
        public const string NoVRHookLine = "script_reload_code novr";
        public const string NoVRZipUrl = "https://github.com/HLANoVR/HLA-NoVR/archive/refs/heads/main.zip";
        /// <summary>First line of NoVR's useextra.lua: tells the mod what the player used, so the others use it too.</summary>
        public const string UseHookLine = "if AMP_OnUseExtra then AMP_OnUseExtra(thisEntity) end -- Alyx MP";

        public static string ScriptsDir(string hla) => Path.Combine(GamePaths.Hlvr(hla), "scripts", "vscripts", "alyxmp");
        public static string SkillManifest(string hla) => Path.Combine(GamePaths.Hlvr(hla), "cfg", "skill_manifest.cfg");
        public static string GameInfo(string hla) => Path.Combine(GamePaths.Hlvr(hla), "gameinfo.gi");
        public static string LauncherDir(string hla) => Path.Combine(hla, "AlyxMP");
        public static string LauncherExe(string hla) => Path.Combine(LauncherDir(hla), "AlyxMP.exe");
        public static string NoVRFileList(string hla) => Path.Combine(LauncherDir(hla), "novr_files.txt");

        public static bool ModInstalled(string hla) => File.Exists(Path.Combine(ScriptsDir(hla), "main.lua"));

        // ---------------------------------------------------------------- skill_manifest.cfg hook
        // The engine executes cfg/skill_manifest.cfg on every map load; NoVR loads itself the same way.

        public static bool HookPresent(string hla)
        {
            var f = SkillManifest(hla);
            return File.Exists(f) && File.ReadAllLines(f).Any(l => l.Trim() == HookLine);
        }

        public static void EnsureHook(string hla)
        {
            var f = SkillManifest(hla);
            var lines = File.Exists(f) ? File.ReadAllLines(f).ToList() : new List<string>();
            if (lines.Any(l => l.Trim() == HookLine)) return;
            Directory.CreateDirectory(Path.GetDirectoryName(f));
            // keep our line after NoVR's so NoVR has set the player up before we run
            lines.Add(HookLine);
            File.WriteAllLines(f, lines);
        }

        public static void RemoveHook(string hla)
        {
            var f = SkillManifest(hla);
            if (!File.Exists(f)) return;
            var lines = File.ReadAllLines(f).Where(l => l.Trim() != HookLine).ToList();
            if (lines.All(string.IsNullOrWhiteSpace)) File.Delete(f);
            else File.WriteAllLines(f, lines);
        }

        // ---------------------------------------------------------------- NoVR

        public static bool NoVRInstalled(string hla) =>
            File.Exists(Path.Combine(GamePaths.Hlvr(hla), "scripts", "vscripts", "novr.lua"))
            && File.Exists(Path.Combine(hla, "game", "novr", "pak01_dir.vpk"));

        /// <summary>The build stamp NoVR prints in its corner, e.g. "Sep 20 16:07".</summary>
        public static string NoVRVersion(string hla)
        {
            try
            {
                var f = Path.Combine(GamePaths.Hlvr(hla), "scripts", "vscripts", "version.lua");
                if (!File.Exists(f)) return null;
                var m = Regex.Match(File.ReadAllText(f), "NoVR Version: ([^\"]+)\"");
                return m.Success ? m.Groups[1].Value.Trim() : "?";
            }
            catch (Exception) { return "?"; }
        }

        static string UseExtra(string hla) => Path.Combine(GamePaths.Hlvr(hla), "scripts", "vscripts", "useextra.lua");

        /// <summary>
        /// NoVR runs useextra.lua on whatever the player presses E on; that's where its story handling
        /// lives. A line at the top reports each use to the mod, which replays it in the other games.
        /// </summary>
        public static void EnsureNoVRUseHook(string hla)
        {
            var f = UseExtra(hla);
            if (!File.Exists(f)) return;
            var text = File.ReadAllText(f);
            if (text.Contains(UseHookLine)) return;
            var nl = text.Contains("\r\n") ? "\r\n" : "\n";
            File.WriteAllText(f, UseHookLine + nl + text);
        }

        public static void RemoveNoVRUseHook(string hla)
        {
            var f = UseExtra(hla);
            if (!File.Exists(f)) return;
            var text = File.ReadAllText(f);
            var cleaned = Regex.Replace(text, "^" + Regex.Escape(UseHookLine) + @"\r?\n", "", RegexOptions.Multiline);
            if (cleaned != text) File.WriteAllText(f, cleaned);
        }

        static readonly Regex NoVRSearchPath = new Regex(@"^[ \t]*Game[ \t]+novr(_viewmodels)?[ \t]*\r?$", RegexOptions.Multiline);

        public static bool NoVRSearchPathsPresent(string hla)
        {
            var gi = GameInfo(hla);
            return File.Exists(gi) && NoVRSearchPath.Matches(File.ReadAllText(gi)).Count >= 2;
        }

        /// <summary>
        /// NoVR ships a whole replacement gameinfo.gi; we only insert its two search paths into the
        /// game's own file so a game update doesn't get rolled back.
        /// </summary>
        public static void EnsureNoVRSearchPaths(string hla)
        {
            var gi = GameInfo(hla);
            var text = File.ReadAllText(gi);
            if (NoVRSearchPath.Matches(text).Count >= 2) return;
            text = NoVRSearchPath.Replace(text, "").Replace("\r\n\r\n\r\n", "\r\n\r\n");
            var m = Regex.Match(text, @"^([ \t]*)Game([ \t]+)hlvr[ \t]*\r?$", RegexOptions.Multiline);
            if (!m.Success) throw new InvalidDataException("Couldn't find the SearchPaths block in gameinfo.gi");
            var nl = text.Contains("\r\n") ? "\r\n" : "\n";
            var indent = m.Groups[1].Value;
            var insert = $"{indent}Game{m.Groups[2].Value}novr_viewmodels{nl}{indent}Game{m.Groups[2].Value}novr{nl}";
            var backup = gi + ".alyxmp_backup";
            if (!File.Exists(backup)) File.Copy(gi, backup);
            File.WriteAllText(gi, text.Insert(m.Index, insert));
        }

        public static void RemoveNoVRSearchPaths(string hla)
        {
            var gi = GameInfo(hla);
            if (!File.Exists(gi)) return;
            var text = File.ReadAllText(gi);
            var cleaned = Regex.Replace(text, @"^[ \t]*Game[ \t]+novr(_viewmodels)?[ \t]*\r?\n", "", RegexOptions.Multiline);
            if (cleaned != text) File.WriteAllText(gi, cleaned);
        }
    }
}
