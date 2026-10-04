using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace AlyxMP
{
    /// <summary>
    /// Client for the VConsole2 protocol Half-Life: Alyx exposes on TCP 29000 when launched with -vconsole
    /// (-netconport exists in the binary but never opens a socket). Every packet is a 12 byte big-endian
    /// header - 4cc type, u32 version, u16 total length, u16 handle - and a payload. We only use PRNT
    /// (console output) and CMND (run a command). The game ignores CMND packets unless they carry the
    /// protocol version from its AINF packet.
    /// </summary>
    sealed class VConClient : IDisposable
    {
        const string BacklogEnd = "End VConsole Buffered Messages";

        public event Action<string> Line;
        public event Action<bool> ConnectionChanged;

        readonly int port;
        readonly object sendLock = new object();
        Thread thread;
        volatile bool stop;
        NetworkStream stream;
        TcpClient client;
        uint version = 0x00D30000;

        public bool Connected { get; private set; }

        public VConClient(int port) { this.port = port; }

        public void Start()
        {
            thread = new Thread(Run) { IsBackground = true, Name = "VConsole" };
            thread.Start();
        }

        void Run()
        {
            while (!stop)
            {
                try
                {
                    using (var c = new TcpClient())
                    {
                        c.NoDelay = true;
                        c.Connect("127.0.0.1", port);
                        var s = c.GetStream();
                        lock (sendLock) { client = c; stream = s; }
                        Connected = true;
                        ConnectionChanged?.Invoke(true);
                        ReadLoop(s);
                    }
                }
                catch (Exception) { }
                finally
                {
                    lock (sendLock) { client = null; stream = null; }
                    if (Connected)
                    {
                        Connected = false;
                        ConnectionChanged?.Invoke(false);
                    }
                }
                for (int i = 0; i < 10 && !stop; i++) Thread.Sleep(100);
            }
        }

        void ReadLoop(NetworkStream s)
        {
            var header = new byte[12];
            var connectedAt = DateTime.UtcNow;
            bool pastBacklog = false;
            while (!stop)
            {
                ReadExact(s, header, 12);
                uint ver = (uint)(header[4] << 24 | header[5] << 16 | header[6] << 8 | header[7]);
                int len = header[8] << 8 | header[9];
                if (len < 12) throw new IOException("bad VConsole packet");
                var body = new byte[len - 12];
                ReadExact(s, body, body.Length);

                var type = Encoding.ASCII.GetString(header, 0, 4);
                if (type == "AINF")
                {
                    version = ver;
                }
                else if (type == "PRNT" && body.Length > 28)
                {
                    // channel id, flags and colour come first; the message text starts at byte 28
                    int end = Array.IndexOf(body, (byte)0, 28);
                    if (end < 0) end = body.Length;
                    var text = Encoding.UTF8.GetString(body, 28, end - 28);
                    foreach (var raw in text.Split('\n'))
                    {
                        var line = raw.TrimEnd('\r');
                        // on connect the game replays everything it printed while nobody listened; skip it
                        if (!pastBacklog)
                        {
                            if (line.Contains(BacklogEnd)) { pastBacklog = true; continue; }
                            if ((DateTime.UtcNow - connectedAt).TotalSeconds < 5) continue;
                            pastBacklog = true;
                        }
                        if (line.Length > 0) Line?.Invoke(line);
                    }
                }
            }
        }

        static void ReadExact(Stream s, byte[] buf, int count)
        {
            int got = 0;
            while (got < count)
            {
                int n = s.Read(buf, got, count - got);
                if (n <= 0) throw new EndOfStreamException();
                got += n;
            }
        }

        public bool Send(string command)
        {
            var payload = Encoding.UTF8.GetBytes(command + "\0");
            int total = 12 + payload.Length;
            if (total > 65535) return false;
            var packet = new byte[total];
            Encoding.ASCII.GetBytes("CMND", 0, 4, packet, 0);
            packet[4] = (byte)(version >> 24);
            packet[5] = (byte)(version >> 16);
            packet[6] = (byte)(version >> 8);
            packet[7] = (byte)version;
            packet[8] = (byte)(total >> 8);
            packet[9] = (byte)total;
            Buffer.BlockCopy(payload, 0, packet, 12, payload.Length);
            lock (sendLock)
            {
                if (stream == null) return false;
                try
                {
                    stream.Write(packet, 0, packet.Length);
                    return true;
                }
                catch (Exception)
                {
                    try { client?.Close(); } catch (Exception) { }
                    return false;
                }
            }
        }

        public void Dispose()
        {
            stop = true;
            lock (sendLock)
            {
                try { client?.Close(); } catch (Exception) { }
            }
        }
    }
}
