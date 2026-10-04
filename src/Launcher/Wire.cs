using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace AlyxMP
{
    enum Msg : byte
    {
        Hello = 1,       // C>H  proto \t modVersion \t name \t password \t gameBuild \t novr
        Welcome = 2,     // H>C  yourId
        Reject = 3,      // H>C  reason
        PlayerJoined = 4,// H>C  id \t name
        PlayerLeft = 5,  // H>C  id
        Roster = 6,      // H>C  lines of id \t name \t map \t ping
        State = 7,       // C>H  state ; H>C id \t state
        Shot = 8,        // C>H  weapon ; H>C id \t weapon
        Zone = 9,        // C>H  zoneId or -
        ZoneStatus = 10, // H>C  zoneId \t ready \t total \t waiting  (or just "-")
        ZoneGo = 11,     // H>C  zoneId
        SyncRequest = 12,// C>H  reason
        SyncData = 13,   // H>C  raw .sav bytes
        Kill = 14,       // C>H  kill ; H>C id \t kill
        Chat = 15,       // C>H  text ; H>C id \t text
        Ping = 16,       // H>C  token
        Pong = 17,       // C>H  token
        Notice = 18,     // H>C  text
        World = 19,      // C>H  payload ; H>C id \t payload   (world sync, interpreted by the in-game mod)
        SyncMap = 20,    // H>C  map, then lines of "id payload": a VR player can't load a NoVR host's save
                         //      (it has no VR hands), so they load the level fresh and replay these
        Arrived = 21,    // C>H  map   finished loading after a level change (and paused itself)
        Release = 22,    // H>C  -     everyone has arrived: unpause
        Teleport = 23,   // H>C  x y z yaw   go stand there (someone used /tp on you)
    }

    /// <summary>
    /// A framed TCP connection: 1 byte type, 4 byte little-endian length, payload. Reads run on their own
    /// thread; writes go through a queue so a slow peer (e.g. while receiving a save file) never blocks
    /// the session thread.
    /// </summary>
    sealed class Connection : IDisposable
    {
        public const int MaxSmall = 64 * 1024;
        public const int MaxFile = 64 * 1024 * 1024;

        readonly TcpClient tcp;
        readonly NetworkStream stream;
        readonly BlockingCollection<byte[]> outbox = new BlockingCollection<byte[]>();
        int closed;

        public event Action<Connection, Msg, byte[]> Received;
        public event Action<Connection> Closed;
        public string Remote { get; }
        public object Tag { get; set; }

        public Connection(TcpClient client)
        {
            tcp = client;
            tcp.NoDelay = true;
            stream = tcp.GetStream();
            Remote = tcp.Client.RemoteEndPoint?.ToString() ?? "?";
        }

        public void Start()
        {
            new Thread(ReadLoop) { IsBackground = true, Name = "net-read " + Remote }.Start();
            new Thread(WriteLoop) { IsBackground = true, Name = "net-write " + Remote }.Start();
        }

        void ReadLoop()
        {
            try
            {
                var header = new byte[5];
                while (true)
                {
                    ReadExact(header, 5);
                    var type = (Msg)header[0];
                    int len = BitConverter.ToInt32(header, 1);
                    int max = type == Msg.SyncData || type == Msg.SyncMap ? MaxFile : MaxSmall;
                    if (len < 0 || len > max) throw new InvalidDataException("oversized message");
                    var body = new byte[len];
                    ReadExact(body, len);
                    Received?.Invoke(this, type, body);
                }
            }
            catch (Exception) { }
            finally { Close(); }
        }

        void WriteLoop()
        {
            try
            {
                foreach (var packet in outbox.GetConsumingEnumerable())
                    stream.Write(packet, 0, packet.Length);
            }
            catch (Exception) { }
            finally { Close(); }
        }

        void ReadExact(byte[] buf, int count)
        {
            int got = 0;
            while (got < count)
            {
                int n = stream.Read(buf, got, count - got);
                if (n <= 0) throw new EndOfStreamException();
                got += n;
            }
        }

        public void Send(Msg type, byte[] payload)
        {
            if (closed != 0) return;
            var packet = new byte[5 + payload.Length];
            packet[0] = (byte)type;
            BitConverter.GetBytes(payload.Length).CopyTo(packet, 1);
            Buffer.BlockCopy(payload, 0, packet, 5, payload.Length);
            try { outbox.Add(packet); } catch (InvalidOperationException) { }
        }

        public void Send(Msg type, string text) => Send(type, Encoding.UTF8.GetBytes(text ?? ""));

        public void Close()
        {
            if (Interlocked.Exchange(ref closed, 1) != 0) return;
            outbox.CompleteAdding();
            try { tcp.Close(); } catch (Exception) { }
            Closed?.Invoke(this);
        }

        public void Dispose() => Close();
    }

    /// <summary>
    /// Everything a peer sends ends up inside a console command on other players' games, so it is parsed
    /// and rebuilt from validated pieces here - never forwarded as raw text.
    /// </summary>
    static class Clean
    {
        static readonly Regex MapRx = new Regex(@"^[a-z0-9_]{1,64}$");
        static readonly Regex ZoneRx = new Regex(@"^-?\d{1,6}_-?\d{1,6}_-?\d{1,6}$");
        static readonly Regex ClassRx = new Regex(@"^[a-z0-9_]{1,48}$");
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        public static string Name(string s)
        {
            var sb = new StringBuilder();
            foreach (var ch in (s ?? "").Trim())
            {
                if (char.IsLetterOrDigit(ch) && ch < 128 || ch == '-' || ch == '.') sb.Append(ch);
                else if (ch == ' ' || ch == '_') sb.Append('_');
                if (sb.Length >= 20) break;
            }
            var r = sb.ToString().Trim('_');
            return r.Length == 0 ? "Player" : r;
        }

        public static string Chat(string s)
        {
            var sb = new StringBuilder();
            foreach (var ch in (s ?? "").Trim())
            {
                if (ch < 32 || ch > 126 || ch == ';' || ch == '"' || ch == '\\' || ch == '\'') continue;
                if (ch == '/' && sb.Length > 0 && sb[sb.Length - 1] == '/') continue;  // console comment
                sb.Append(ch);
                if (sb.Length >= 120) break;
            }
            return sb.ToString();
        }

        public static string Map(string s) => s != null && MapRx.IsMatch(s) ? s : null;

        static readonly Regex WorldRx = new Regex(@"^[A-Za-z0-9 _.,:|+\-*/=#@]{1,480}$");

        /// <summary>World-sync payloads go into console commands as-is, so only plain tokens are allowed.</summary>
        public static string World(string s) => s != null && WorldRx.IsMatch(s) && !s.Contains("//") ? s : null;

        public static string Zone(string s) => s == "-" || (s != null && ZoneRx.IsMatch(s)) ? s : null;

        static bool Num(string s, out double v) =>
            double.TryParse(s, NumberStyles.Float, Inv, out v) && !double.IsNaN(v) && !double.IsInfinity(v) && Math.Abs(v) < 1e6;

        /// <summary>map st x y z yaw pitch eyeh flags weapon</summary>
        public static PlayerState State(string raw)
        {
            var p = (raw ?? "").Split(' ');
            if (p.Length != 10) return null;
            var map = Map(p[0]);
            if (map == null) return null;
            var n = new double[7];
            for (int i = 0; i < 7; i++) if (!Num(p[i + 1], out n[i])) return null;
            if (!int.TryParse(p[8], out var flags) || flags < 0 || flags > 255) return null;
            if (!int.TryParse(p[9], out var weapon) || weapon < 0 || weapon > 3) return null;
            return new PlayerState
            {
                Map = map, Time = n[0], X = n[1], Y = n[2], Z = n[3], Yaw = n[4], Pitch = n[5], EyeHeight = n[6],
                Flags = flags, Weapon = weapon,
            };
        }

        /// <summary>idx class x y z</summary>
        public static string Kill(string raw)
        {
            var p = (raw ?? "").Split(' ');
            if (p.Length != 5) return null;
            if (!int.TryParse(p[0], out var idx) || idx <= 0 || idx > 65535) return null;
            if (!ClassRx.IsMatch(p[1])) return null;
            for (int i = 2; i < 5; i++) if (!Num(p[i], out _)) return null;
            return string.Join(" ", p);
        }

        public static string F(double v) => v.ToString("0.###", Inv);
    }

    sealed class PlayerState
    {
        public string Map;
        public double Time, X, Y, Z, Yaw, Pitch, EyeHeight;
        public int Flags, Weapon;
        public bool Dead => (Flags & 4) != 0;
        public bool VR => (Flags & 1) != 0;

        /// <summary>The exact argument list amp_s expects after the player id.</summary>
        public string Wire() =>
            $"{Map} {Clean.F(Time)} {Clean.F(X)} {Clean.F(Y)} {Clean.F(Z)} {Clean.F(Yaw)} {Clean.F(Pitch)} {Clean.F(EyeHeight)} {Flags} {Weapon}";
    }
}
