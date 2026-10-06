using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace AlyxMP
{
    /// <summary>
    /// Everything the mod touches inside the game folder. Shared by the installer and by the launcher,
    /// which re-applies the hook on start because NoVR updates and Steam file verification undo it.
    /// </summary>
    static class ModFiles
    {
        public const string Version = "0.5.3";
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

        // ---------------------------------------------------------------- our own search paths
        // Folders of loose files mounted ahead of every other path in gameinfo.gi, so their copies win
        // over NoVR's and the game's.

        static Regex SearchPathLine(string folder) =>
            new Regex(@"^[ \t]*Game[ \t]+" + Regex.Escape(folder) + @"[ \t]*\r?$", RegexOptions.Multiline);

        static void MountFirst(string hla, string folder)
        {
            var gi = GameInfo(hla);
            var text = File.ReadAllText(gi);
            if (SearchPathLine(folder).IsMatch(text)) return;
            var m = Regex.Match(text, @"^([ \t]*)Game([ \t]+)\S+[ \t]*\r?$", RegexOptions.Multiline);
            if (!m.Success) throw new InvalidDataException("Couldn't find the SearchPaths block in gameinfo.gi");
            var nl = text.Contains("\r\n") ? "\r\n" : "\n";
            var backup = gi + ".alyxmp_backup";
            if (!File.Exists(backup)) File.Copy(gi, backup);
            File.WriteAllText(gi, text.Insert(m.Index, $"{m.Groups[1].Value}Game{m.Groups[2].Value}{folder}{nl}"));
        }

        static void Unmount(string hla, string folder)
        {
            var gi = GameInfo(hla);
            if (!File.Exists(gi)) return;
            var text = File.ReadAllText(gi);
            var cleaned = Regex.Replace(text, @"^[ \t]*Game[ \t]+" + Regex.Escape(folder) + @"[ \t]*\r?\n", "", RegexOptions.Multiline);
            if (cleaned != text) File.WriteAllText(gi, cleaned);
        }

        // ---------------------------------------------------------------- HL2-style HUD for NoVR
        // game/alyxmp_hud holds NoVR's HUD files with Half-Life 2's exact layout, colours and fonts.

        public static string HudDir(string hla) => Path.Combine(hla, "game", "alyxmp_hud");
        const string HudFolder = "alyxmp_hud";

        public static void EnsureHud(string hla) => SetHuds(hla, true, false);

        /// <summary>Which HUD NoVR gets: the glow one, the Half-Life 2 style one, or its own.</summary>
        public static void SetHuds(string hla, bool glow, bool hl2)
        {
            SetGlowHud(hla, glow);
            SetHud(hla, hl2 && !glow);
        }

        /// <summary>Mount (or unmount) the Half-Life 2 HUD; the game reads it when it starts.</summary>
        public static void SetHud(string hla, bool on)
        {
            if (!on || !Directory.Exists(HudDir(hla)))
            {
                Unmount(hla, HudFolder);
                return;
            }
            MountFirst(hla, HudFolder);
            UseHl2Font(hla);
        }

        public static void RemoveHud(string hla)
        {
            Unmount(hla, HudFolder);
            try { if (Directory.Exists(HudDir(hla))) Directory.Delete(HudDir(hla), true); } catch (Exception) { }
            Unmount(hla, GlowHudFolder);
            try { if (Directory.Exists(GlowHudDir(hla))) Directory.Delete(GlowHudDir(hla), true); } catch (Exception) { }
        }

        // ---------------------------------------------------------------- glow HUD for NoVR
        // game/alyxmp_glowhud holds NoVR's HUD files restyled (glowing numbers, no boxes) and the fonts they use
        // (tools/make_glow_hud.py builds both). NoVR's own HUD files sit in its VPK and the game takes a
        // packed file over a loose one, so ours go into a VPK too. Fonts are the other way round: the
        // game only picks them up loose, from panorama/fonts. All of it is read when the game starts.

        public static string GlowHudDir(string hla) => Path.Combine(hla, "game", "alyxmp_glowhud");
        const string GlowHudFolder = "alyxmp_glowhud";

        public static void SetGlowHud(string hla, bool on)
        {
            var dir = GlowHudDir(hla);
            var files = new Dictionary<string, byte[]>();
            if (on)
                foreach (var sub in new[] { "scripts", "resource" })
                {
                    if (!Directory.Exists(Path.Combine(dir, sub))) continue;
                    foreach (var f in Directory.GetFiles(Path.Combine(dir, sub)))
                        files[sub + "/" + Path.GetFileName(f).ToLowerInvariant()] = File.ReadAllBytes(f);
                }
            if (files.Count == 0)
            {
                Unmount(hla, GlowHudFolder);
                return;
            }
            Vpk.Write(Path.Combine(dir, "pak01_dir.vpk"), files);
            MountFirst(hla, GlowHudFolder);
        }

        // ---------------------------------------------------------------- auto reload for NoVR
        // NoVR's guns never reload on their own: its weapon scripts set item_flags 6, i.e. no auto-reload
        // (2) and no auto-switch when empty (4). With auto reload on, copies without the no-auto-reload
        // flag are mounted ahead of NoVR. Weapon scripts are read when the game starts.

        public static string AutoReloadDir(string hla) => Path.Combine(hla, "game", "alyxmp_autoreload");
        const string AutoReloadFolder = "alyxmp_autoreload";
        static readonly string[] Guns = { "weapon_pistol", "weapon_shotgun", "weapon_smg1", "weapon_ar2" };

        public static void SetAutoReload(string hla, bool on)
        {
            if (!on || !NoVRInstalled(hla))
            {
                Unmount(hla, AutoReloadFolder);
                return;
            }
            var novr = new Vpk(Path.Combine(hla, "game", "novr", "pak01_dir.vpk"));
            var files = new Dictionary<string, byte[]>();
            foreach (var gun in Guns)
            {
                var data = novr.Read($"scripts/{gun}.txt");
                if (data == null) continue;
                var text = Encoding.UTF8.GetString(data).TrimStart('\uFEFF');
                text = Regex.Replace(text, @"(""item_flags""\s+"")(\d+)("")",
                    m => m.Groups[1].Value + (int.Parse(m.Groups[2].Value) & ~2) + m.Groups[3].Value);
                files[$"scripts/{gun}.txt"] = Encoding.UTF8.GetBytes(text);
            }
            // the game takes a file from a VPK over a loose one, wherever it's mounted: NoVR's packed
            // scripts would win over loose copies, so ours go in a VPK too
            var dir = AutoReloadDir(hla);
            Directory.CreateDirectory(dir);
            try { if (Directory.Exists(Path.Combine(dir, "scripts"))) Directory.Delete(Path.Combine(dir, "scripts"), true); } catch (Exception) { }
            Vpk.Write(Path.Combine(dir, "pak01_dir.vpk"), files);
            MountFirst(hla, AutoReloadFolder);
        }

        public static void RemoveAutoReload(string hla)
        {
            Unmount(hla, AutoReloadFolder);
            try { if (Directory.Exists(AutoReloadDir(hla))) Directory.Delete(AutoReloadDir(hla), true); } catch (Exception) { }
        }

        /// <summary>
        /// HL2's HUD digits come from its HALFLIFE2.ttf; NoVR maps that font name to HL:A's own font, whose
        /// digits are hearts. If Half-Life 2 is installed, use its font file from there.
        /// </summary>
        static void UseHl2Font(string hla)
        {
            var scheme = Path.Combine(HudDir(hla), "resource", "clientscheme.res");
            if (!File.Exists(scheme)) return;
            string font = null;
            foreach (var lib in GamePaths.LibraryFolders())
            {
                var f = Path.Combine(lib, "steamapps", "common", "Half-Life 2", "hl2", "resource", "halflife2.ttf");
                if (File.Exists(f)) { font = f; break; }
            }
            if (font == null) return;
            var copy = Path.Combine(HudDir(hla), "resource", "hl2_halflife2.ttf");
            try { File.Copy(font, copy, true); } catch (IOException) { return; }
            var text = File.ReadAllText(scheme);
            var patched = text.Replace("\"resource/HALFLIFE2.vfont\"", "\"resource/hl2_halflife2.ttf\"");
            if (patched != text) File.WriteAllText(scheme, patched);
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
