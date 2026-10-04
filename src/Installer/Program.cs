using System;
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
            bool auto = false, shortcut = true;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--dir" && i + 1 < args.Length) dir = args[++i];
                else if (args[i] == "--novr") novr = true;
                else if (args[i] == "--no-novr") novr = false;
                else if (args[i] == "--auto") auto = true;
                else if (args[i] == "--no-shortcut") shortcut = false;
            }
            Application.Run(new InstallerForm(dir, novr, auto, shortcut));
        }
    }
}
