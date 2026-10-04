using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace AlyxMP
{
    /// <summary>Optional command line: --name N --host [port] | --join ADDRESS [--password PW] [--no-upnp] [--no-launch]</summary>
    sealed class StartupAction
    {
        public string Name, Join, Password;
        public int HostPort;
        public bool NoUpnp, NoLaunch;

        public static StartupAction Parse(string[] args)
        {
            var a = new StartupAction();
            for (int i = 0; i < args.Length; i++)
            {
                string Next() => i + 1 < args.Length ? args[++i] : "";
                switch (args[i])
                {
                    case "--name": a.Name = Next(); break;
                    case "--join": a.Join = Next(); break;
                    case "--password": a.Password = Next(); break;
                    case "--no-upnp": a.NoUpnp = true; break;
                    case "--no-launch": a.NoLaunch = true; break;
                    case "--host":
                        a.HostPort = Session.DefaultPort;
                        if (i + 1 < args.Length && int.TryParse(args[i + 1], out var port)) { a.HostPort = port; i++; }
                        break;
                }
            }
            return a;
        }
    }

    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Theme.Init();
            using (var mutex = new Mutex(true, "AlyxMP.Launcher.SingleInstance", out bool first))
            {
                if (!first)
                {
                    MessageBox.Show("Alyx Multiplayer is already open.", "Alyx Multiplayer", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                var settings = Settings.Load();
                var hla = FindGame(settings);
                if (hla == null) return;

                // NoVR updates and Steam's file verification can undo these; put them back
                try
                {
                    if (ModFiles.ModInstalled(hla)) ModFiles.EnsureHook(hla);
                    if (ModFiles.NoVRInstalled(hla))
                    {
                        ModFiles.EnsureNoVRSearchPaths(hla);
                        ModFiles.EnsureNoVRUseHook(hla);
                    }
                }
                catch (Exception) { }

                using (var game = new GameLink(hla, settings.VConPort))
                {
                    var form = new MainForm(hla, settings, game, StartupAction.Parse(args));
                    game.Start();
                    Application.Run(form);
                }
            }
        }

        static string FindGame(Settings s)
        {
            // the installer puts us in <Half-Life Alyx>\AlyxMP\
            var parent = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
            if (GamePaths.IsValidHla(parent)) return parent;
            if (GamePaths.IsValidHla(s.GameDir)) return s.GameDir;
            var found = GamePaths.FindHla();
            if (found != null) return found;

            using (var dlg = new FolderBrowserDialog { Description = "Select your Half-Life Alyx folder (the one that contains \"game\")" })
            {
                while (dlg.ShowDialog() == DialogResult.OK)
                {
                    if (GamePaths.IsValidHla(dlg.SelectedPath))
                    {
                        s.GameDir = dlg.SelectedPath;
                        s.Save();
                        return dlg.SelectedPath;
                    }
                    MessageBox.Show("That folder doesn't contain Half-Life: Alyx.", "Alyx Multiplayer", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
            return null;
        }
    }
}
