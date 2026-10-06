using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

namespace AlyxMP
{
    sealed class InstallOptions
    {
        public string GameDir;
        public bool InstallNoVR;
        public bool DesktopShortcut;
    }

    /// <summary>
    /// Installs the mod into a Half-Life: Alyx folder. The Lua scripts and the launcher are embedded in
    /// this exe as "payload/..." resources; NoVR is downloaded from its official GitHub repository the same
    /// way NoVR's own launcher does it.
    /// </summary>
    sealed class InstallerCore
    {
        const string ShortcutName = "Alyx Multiplayer.lnk";

        public event Action<string> Log;
        public event Action<double, string> Progress;

        void Step(double fraction, string text)
        {
            Progress?.Invoke(fraction, text);
            Log?.Invoke(text);
        }

        public static bool CanWrite(string dir)
        {
            try
            {
                var probe = Path.Combine(dir, ".alyxmp_write_test");
                File.WriteAllText(probe, "x");
                File.Delete(probe);
                return true;
            }
            catch (Exception) { return false; }
        }

        static void EnsureNotRunning()
        {
            if (GamePaths.GameRunning())
                throw new InvalidOperationException("Close Half-Life: Alyx first, then try again.");
            if (Process.GetProcessesByName("AlyxMP").Length > 0)
                throw new InvalidOperationException("Close the Alyx Multiplayer launcher first, then try again.");
        }

        // ------------------------------------------------------------------ install

        public void Install(InstallOptions o, CancellationToken cancel)
        {
            var hla = o.GameDir;
            if (!GamePaths.IsValidHla(hla)) throw new InvalidOperationException("That folder doesn't contain Half-Life: Alyx.");
            EnsureNotRunning();

            double modStart = 0;
            if (o.InstallNoVR)
            {
                InstallNoVR(hla, cancel);
                modStart = 0.9;
            }

            Step(modStart, "Installing Alyx Multiplayer...");
            var written = ExtractPayload(hla);
            Log?.Invoke($"  {written} mod files installed");

            Step(modStart + (1 - modStart) * 0.6, "Hooking the mod into the game...");
            ModFiles.EnsureHook(hla);
            if (ModFiles.NoVRInstalled(hla))
            {
                ModFiles.EnsureNoVRSearchPaths(hla);
                ModFiles.EnsureNoVRUseHook(hla);
                ModFiles.EnsureHud(hla);
            }

            Step(modStart + (1 - modStart) * 0.8, "Creating shortcuts...");
            var exe = ModFiles.LauncherExe(hla);
            TryShortcut(Path.Combine(StartMenuDir(), ShortcutName), exe);
            if (o.DesktopShortcut)
                TryShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), ShortcutName), exe);

            Step(1, "Done! Alyx Multiplayer is installed.");
        }

        int ExtractPayload(string hla)
        {
            var asm = Assembly.GetExecutingAssembly();
            int count = 0;
            foreach (var res in asm.GetManifestResourceNames())
            {
                var name = res.Replace('\\', '/');
                if (!name.StartsWith("payload/")) continue;
                var rel = name.Substring("payload/".Length);
                string target;
                if (rel.StartsWith("launcher/")) target = Path.Combine(ModFiles.LauncherDir(hla), rel.Substring("launcher/".Length));
                else if (rel.StartsWith("game/")) target = Path.Combine(hla, rel.Replace('/', Path.DirectorySeparatorChar));
                else continue;
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                using (var src = asm.GetManifestResourceStream(res))
                using (var dst = File.Create(target))
                    src.CopyTo(dst);
                count++;
            }
            if (count == 0) throw new InvalidOperationException("This installer is missing its files - download it again.");
            File.WriteAllText(Path.Combine(ModFiles.LauncherDir(hla), "README.txt"),
                "Alyx Multiplayer " + ModFiles.Version + Environment.NewLine +
                "Start AlyxMP.exe, host or join a game, then launch Half-Life: Alyx from it." + Environment.NewLine +
                "To uninstall, run AlyxMP-Setup.exe and press Uninstall." + Environment.NewLine);
            return count;
        }

        void InstallNoVR(string hla, CancellationToken cancel)
        {
            var zipPath = Path.Combine(Path.GetTempPath(), "alyxmp_hla_novr_main.zip");
            Step(0, "Downloading HLA NoVR from github.com/HLANoVR/HLA-NoVR ...");
            Download(ModFiles.NoVRZipUrl, zipPath, 0, 0.7, cancel);

            Step(0.7, "Installing HLA NoVR...");
            var files = new List<string>();
            using (var zip = ZipFile.OpenRead(zipPath))
            {
                var entries = zip.Entries.Where(e => e.Name.Length > 0).ToList();
                int done = 0;
                foreach (var e in entries)
                {
                    cancel.ThrowIfCancellationRequested();
                    // "HLA-NoVR-main/game/hlvr/..." -> "game/hlvr/..."
                    var full = e.FullName.Replace('\\', '/');
                    int slash = full.IndexOf('/');
                    if (slash < 0) continue;
                    var rel = full.Substring(slash + 1);
                    if (!rel.StartsWith("game/")) continue;
                    // NoVR replaces gameinfo.gi wholesale; we add its search paths to the current one instead
                    if (rel.Equals("game/hlvr/gameinfo.gi", StringComparison.OrdinalIgnoreCase)) continue;
                    if (rel.Contains("..")) continue;
                    var target = Path.Combine(hla, rel.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    e.ExtractToFile(target, true);
                    files.Add(rel);
                    done++;
                    if (done % 5 == 0) Progress?.Invoke(0.7 + 0.2 * done / entries.Count, $"Installing HLA NoVR... {done}/{entries.Count}");
                }
            }
            try { File.Delete(zipPath); } catch (Exception) { }
            ModFiles.EnsureNoVRSearchPaths(hla);
            ModFiles.EnsureNoVRUseHook(hla);
            Directory.CreateDirectory(ModFiles.LauncherDir(hla));
            File.WriteAllLines(ModFiles.NoVRFileList(hla), files);
            Log?.Invoke($"  NoVR installed ({files.Count} files, version {ModFiles.NoVRVersion(hla)})");
        }

        void Download(string url, string path, double from, double to, CancellationToken cancel)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.UserAgent = "AlyxMP-Installer/" + ModFiles.Version;
            req.AllowAutoRedirect = true;
            req.Timeout = 30000;
            req.ReadWriteTimeout = 60000;
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var src = resp.GetResponseStream())
            using (var dst = File.Create(path))
            {
                long total = resp.ContentLength;
                long got = 0;
                var buf = new byte[1 << 16];
                var lastReport = DateTime.MinValue;
                int n;
                while ((n = src.Read(buf, 0, buf.Length)) > 0)
                {
                    cancel.ThrowIfCancellationRequested();
                    dst.Write(buf, 0, n);
                    got += n;
                    if ((DateTime.UtcNow - lastReport).TotalMilliseconds > 200)
                    {
                        lastReport = DateTime.UtcNow;
                        double f = total > 0 ? (double)got / total : Math.Min(0.95, got / 150e6);
                        var label = total > 0
                            ? $"Downloading HLA NoVR... {got / 1048576} / {total / 1048576} MB"
                            : $"Downloading HLA NoVR... {got / 1048576} MB";
                        Progress?.Invoke(from + (to - from) * f, label);
                    }
                }
            }
        }

        // ------------------------------------------------------------------ uninstall

        public void Uninstall(string hla, bool removeNoVR)
        {
            if (!GamePaths.IsValidHla(hla)) throw new InvalidOperationException("That folder doesn't contain Half-Life: Alyx.");
            EnsureNotRunning();

            Step(0.1, "Removing Alyx Multiplayer...");
            List<string> novrFiles = null;
            if (removeNoVR && File.Exists(ModFiles.NoVRFileList(hla)))
                novrFiles = File.ReadAllLines(ModFiles.NoVRFileList(hla)).Where(l => l.Trim().Length > 0).ToList();

            DeleteDir(ModFiles.ScriptsDir(hla));
            ModFiles.RemoveHook(hla);
            ModFiles.RemoveNoVRUseHook(hla);
            ModFiles.RemoveHud(hla);
            ModFiles.RemoveAutoReload(hla);
            DeleteDir(ModFiles.LauncherDir(hla));
            foreach (var dir in new[] { StartMenuDir(), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) })
            {
                try { File.Delete(Path.Combine(dir, ShortcutName)); } catch (Exception) { }
            }

            if (removeNoVR)
            {
                Step(0.5, "Removing HLA NoVR...");
                if (novrFiles != null)
                {
                    foreach (var rel in novrFiles)
                    {
                        if (rel.Contains("..") || !rel.StartsWith("game/")) continue;
                        if (rel.Equals("game/hlvr/cfg/skill_manifest.cfg", StringComparison.OrdinalIgnoreCase)) continue;
                        try { File.Delete(Path.Combine(hla, rel.Replace('/', Path.DirectorySeparatorChar))); } catch (Exception) { }
                    }
                }
                DeleteDir(Path.Combine(hla, "game", "novr"));
                DeleteDir(Path.Combine(hla, "game", "novr_viewmodels"));
                DeleteDir(Path.Combine(hla, "game", "hlvr_addons", "novr"));
                ModFiles.RemoveNoVRSearchPaths(hla);
                var cfg = ModFiles.SkillManifest(hla);
                if (File.Exists(cfg))
                {
                    var keep = File.ReadAllLines(cfg).Where(l => l.Trim() != ModFiles.NoVRHookLine && !l.Trim().StartsWith("exec skill")).ToList();
                    if (keep.All(string.IsNullOrWhiteSpace)) File.Delete(cfg);
                    else File.WriteAllLines(cfg, keep);
                }
            }
            Step(1, "Uninstalled. Your saves were not touched.");
        }

        static void DeleteDir(string dir)
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
        }

        // ------------------------------------------------------------------ shortcuts

        static string StartMenuDir() => Environment.GetFolderPath(Environment.SpecialFolder.Programs);

        void TryShortcut(string lnk, string target)
        {
            try
            {
                var type = Type.GetTypeFromProgID("WScript.Shell");
                dynamic shell = Activator.CreateInstance(type);
                dynamic sc = shell.CreateShortcut(lnk);
                sc.TargetPath = target;
                sc.WorkingDirectory = Path.GetDirectoryName(target);
                sc.Description = "Play Half-Life: Alyx with friends";
                sc.IconLocation = target + ",0";
                sc.Save();
                Marshal.FinalReleaseComObject(sc);
                Marshal.FinalReleaseComObject(shell);
            }
            catch (Exception e)
            {
                Log?.Invoke("  couldn't create shortcut " + Path.GetFileName(lnk) + ": " + e.Message);
            }
        }
    }
}
