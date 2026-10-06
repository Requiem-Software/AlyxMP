using System;
using System.Diagnostics;
using System.Threading;
using System.Windows.Forms;

namespace AlyxMP
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Theme.Init();
            string dir = null;
            bool? novr = null;
            bool auto = false, shortcut = true, update = false;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--dir" && i + 1 < args.Length) dir = args[++i];
                else if (args[i] == "--novr") novr = true;
                else if (args[i] == "--no-novr") novr = false;
                else if (args[i] == "--auto") auto = true;
                else if (args[i] == "--no-shortcut") shortcut = false;
                else if (args[i] == "--update") update = true;
            }
            if (update)
            {
                // the launcher started us and is closing: install over it once it's gone, leave NoVR and the
                // shortcuts as they are, then open it again
                auto = true;
                novr = false;
                shortcut = false;
                for (int i = 0; i < 60 && Process.GetProcessesByName("AlyxMP").Length > 0; i++) Thread.Sleep(250);
            }
            Application.Run(new InstallerForm(dir, novr, auto, shortcut, update));
        }
    }
}
