using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace AlyxMP
{
    /// <summary>A published version of the mod, from the GitHub releases page.</summary>
    sealed class Release
    {
        public string Tag;
        public Version Version;
        public DateTime Published;
        public string Notes = "";       // markdown
        public string SetupUrl;         // its AlyxMP-Setup.exe
        public long SetupSize;
    }

    /// <summary>
    /// Checks GitHub for newer versions and installs them: downloads that version's AlyxMP-Setup.exe and
    /// runs it with --update, which waits for the launcher to close, installs over this version and starts
    /// the launcher again.
    /// </summary>
    static class Updater
    {
        const string ReleasesApi = "https://api.github.com/repos/Requiem-Software/AlyxMP/releases?per_page=30";
        const string SetupAsset = "AlyxMP-Setup.exe";

        public static Version Current => ParseVersion(ModFiles.Version);

        static Version ParseVersion(string s)
        {
            s = (s ?? "").Trim().TrimStart('v', 'V');
            int end = s.IndexOfAny(new[] { '-', '+', ' ' });
            if (end >= 0) s = s.Substring(0, end);
            return Version.TryParse(s, out var v) ? v : null;
        }

        static WebClient Client()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var wc = new WebClient { Encoding = Encoding.UTF8 };
            wc.Headers[HttpRequestHeader.UserAgent] = "AlyxMP-Launcher/" + ModFiles.Version;
            return wc;
        }

        static string Str(Dictionary<string, object> d, string key) => d.TryGetValue(key, out var v) ? v as string : null;
        static bool Flag(Dictionary<string, object> d, string key) => d.TryGetValue(key, out var v) && v is bool b && b;

        /// <summary>Every published version, newest first.</summary>
        public static List<Release> FetchReleases()
        {
            string json;
            using (var wc = Client())
            {
                wc.Headers[HttpRequestHeader.Accept] = "application/vnd.github+json";
                json = wc.DownloadString(ReleasesApi);
            }
            var list = new List<Release>();
            var items = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(json) as object[];
            foreach (var r in (items ?? new object[0]).OfType<Dictionary<string, object>>())
            {
                if (Flag(r, "draft") || Flag(r, "prerelease")) continue;
                var version = ParseVersion(Str(r, "tag_name"));
                if (version == null) continue;
                var rel = new Release { Tag = Str(r, "tag_name"), Version = version, Notes = Str(r, "body") ?? "" };
                DateTime.TryParse(Str(r, "published_at"), CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out rel.Published);
                if (r.TryGetValue("assets", out var a) && a is object[] assets)
                    foreach (var asset in assets.OfType<Dictionary<string, object>>())
                        if (string.Equals(Str(asset, "name"), SetupAsset, StringComparison.OrdinalIgnoreCase))
                        {
                            rel.SetupUrl = Str(asset, "browser_download_url");
                            try { rel.SetupSize = Convert.ToInt64(asset["size"], CultureInfo.InvariantCulture); } catch (Exception) { }
                        }
                list.Add(rel);
            }
            return list.OrderByDescending(x => x.Version).ToList();
        }

        /// <summary>The newest version, if it's newer than this one and has a setup to install it with.</summary>
        public static Release Newer(IEnumerable<Release> releases)
        {
            var current = Current;
            var top = releases.FirstOrDefault(r => r.SetupUrl != null);
            return top != null && current != null && top.Version > current ? top : null;
        }

        public static async Task<string> Download(Release r, Action<int> percent)
        {
            var path = Path.Combine(Path.GetTempPath(), "AlyxMP-Setup-" + r.Tag + ".exe");
            var part = path + ".part";
            using (var wc = Client())
            {
                wc.DownloadProgressChanged += (s, e) => percent?.Invoke(e.ProgressPercentage);
                await wc.DownloadFileTaskAsync(new Uri(r.SetupUrl), part);
            }
            if (r.SetupSize > 0 && new FileInfo(part).Length != r.SetupSize)
                throw new InvalidOperationException("the download was incomplete");
            File.Copy(part, path, true);
            File.Delete(part);
            return path;
        }

        /// <summary>Starts setup in update mode. The launcher has to close right after.</summary>
        public static void StartSetup(string setup, string hla)
        {
            Process.Start(new ProcessStartInfo(setup, $"--update --dir \"{hla}\"") { UseShellExecute = true });
        }

        /// <summary>Release notes as plain lines: (text, isHeading).</summary>
        public static IEnumerable<KeyValuePair<string, bool>> NoteLines(Release r)
        {
            foreach (var raw in r.Notes.Replace("\r", "").Split('\n'))
            {
                var line = raw.Trim().Replace("**", "").Replace("`", "");
                // the download instructions are for the GitHub page
                if (line.StartsWith("Download ", StringComparison.OrdinalIgnoreCase) && line.Contains(SetupAsset)) continue;
                if (line.StartsWith("#")) yield return new KeyValuePair<string, bool>(line.TrimStart('#').Trim(), true);
                else if (line.StartsWith("- ") || line.StartsWith("* ")) yield return new KeyValuePair<string, bool>("•  " + line.Substring(2), false);
                else if (line.Length > 0) yield return new KeyValuePair<string, bool>(line, false);
            }
        }
    }
}
