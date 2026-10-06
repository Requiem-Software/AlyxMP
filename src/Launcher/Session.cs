using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace AlyxMP
{
    sealed class Player
    {
        public int Id;
        public string Name;
        public Connection Conn;          // host side: that client's connection
        public bool IsLocal;
        public PlayerState Last;
        public DateTime LastStateAt;
        public DateTime LastForwardAt;
        public string Zone = "-";
        public int PingMs = -1;
        public bool WantsSync;
        public bool WantsMapSync;        // host side: a VR player waiting for the level + journal
        public bool IsVR;                // host side: as their last sync request / state said
        public string RosterMap;         // client side: what the host last told us

        public string Map => Last?.Map ?? RosterMap;
        public bool InLevel(DateTime now) =>
            Last != null && Last.Map != "startup" && !Last.Dead && (now - LastStateAt).TotalSeconds < 3;
    }

    sealed class PlayerView
    {
        public int Id;
        public string Name;
        public string Map;
        public int Ping;
        public bool IsYou;
        public bool IsHost;
    }

    /// <summary>
    /// One multiplayer session, hosting or joined. The host is the authority: everyone's position is
    /// relayed through it, it decides when a loading zone fires, and its save file is what late joiners
    /// and respawning players load. All session state lives on one worker thread; network, game and UI
    /// events are queued onto it.
    /// </summary>
    sealed class Session : IDisposable
    {
        public const int Proto = 3;
        public const int DefaultPort = 27420;
        public const int MaxPlayers = 8;
        const string SyncSave = "amp_sync";
        const string ClientSaveDir = "amp_mp";

        public event Action Changed;
        public event Action<string> Log;
        public event Action<string, string> Chat;

        readonly GameLink game;
        readonly string hla;
        readonly BlockingCollection<Action> queue = new BlockingCollection<Action>();
        readonly Dictionary<int, Player> players = new Dictionary<int, Player>();
        readonly Dictionary<Connection, DateTime> unnamed = new Dictionary<Connection, DateTime>();
        readonly Timer ticker;
        readonly Timer worldFlush;
        readonly List<string> worldOut = new List<string>();
        int ticks;
        string myName = "Player";

        // host
        TcpListener listener;
        int nextId = 2;
        string password = "";
        string zoneStatus = "-";
        string zoneGoSent;
        bool saving;
        DateTime saveStartedAt;

        // host: what happened in the current level, for players who can't load the host's save
        // (VR players joining a NoVR host). Replayed in order on top of a fresh load of the level.
        readonly List<KeyValuePair<int, string>> journal = new List<KeyValuePair<int, string>>();
        string journalMap;
        const int JournalMax = 1500;
        static readonly HashSet<string> JournalKinds = new HashSet<string> { "tg", "io", "us", "pg", "bk", "kd", "pr", "ai" };

        // level changes: whoever finishes loading first waits (paused) for the others
        bool levelChange;
        string levelFrom;
        bool holding;
        DateTime holdSince;
        string holdWaiting = "";
        readonly Dictionary<int, string> arrived = new Dictionary<int, string>();   // host: who's loaded where
        const int HoldTimeout = 75;
        DateTime nextAutosave;
        const int AutosaveMinutes = 5;

        // client
        Connection server;
        string pendingMap;
        List<KeyValuePair<int, string>> pendingJournal;
        bool syncing;
        DateTime syncStartedAt;
        DateTime? mismatchSince;
        bool placeAfterLoad;
        DateTime quietUntil;             // level change / save load in progress
        DateTime welcomedAt;

        public bool IsHost { get; private set; }
        public bool Active { get; private set; }
        public int MyId { get; private set; }
        public string Status { get; private set; } = "Not in a session";
        public IReadOnlyList<PlayerView> Players { get; private set; } = new List<PlayerView>();

        public Session(GameLink game, string hla)
        {
            this.game = game;
            this.hla = hla;
            new Thread(Work) { IsBackground = true, Name = "session" }.Start();
            ticker = new Timer(_ => Post(Tick), null, 1000, 1000);

            game.Hello += map => Post(ApplyMpConfig);
            game.MapReady += map => Post(() => OnMapReady(map));
            game.State += st => Post(() => OnLocalState(st));
            game.Shot += w => Post(() => OnLocalShot(w));
            game.Zone += z => Post(() => OnLocalZone(z));
            game.Kill += k => Post(() => OnLocalKill(k));
            game.Died += () => Post(OnLocalDied);
            game.Transition += () => Post(OnLocalTransition);
            game.SaveWritten += path => Post(() => OnSaveWritten(path));
            game.SaveLoaded += map => Post(OnLocalSaveLoaded);
            game.World += payload => Post(() => OnLocalWorld(payload));
            worldFlush = new Timer(_ => Post(FlushWorld), null, 15, 15);
        }

        void Work()
        {
            foreach (var action in queue.GetConsumingEnumerable())
            {
                try { action(); }
                catch (Exception e) { Log?.Invoke("Internal error: " + e.Message); }
            }
        }

        void Post(Action a)
        {
            try { queue.Add(a); } catch (InvalidOperationException) { }
        }

        Player Me => players.TryGetValue(MyId, out var p) ? p : null;
        Player HostPlayer => players.TryGetValue(1, out var p) ? p : null;
        static string Text(byte[] b) => Encoding.UTF8.GetString(b);

        // ------------------------------------------------------------------ public API (any thread)

        public void Host(string name, int port, string pw) => Post(() => DoHost(name, port, pw));
        public void Join(string name, string address, string pw) => Post(() => DoJoin(name, address, pw));
        public void Stop() => Post(DoStop);
        public void SendChat(string text) => Post(() => DoChat(text));
        public void Resync() => Post(DoResync);

        // ------------------------------------------------------------------ session start/stop

        void DoHost(string name, int port, string pw)
        {
            DoStop();
            myName = Clean.Name(name);
            password = pw ?? "";
            try
            {
                listener = new TcpListener(IPAddress.Any, port);
                listener.Start();
            }
            catch (Exception e)
            {
                listener = null;
                Log?.Invoke($"Couldn't open port {port}: {e.Message}");
                return;
            }
            IsHost = true;
            Active = true;
            MyId = 1;
            nextId = 2;
            players[1] = new Player { Id = 1, Name = myName, IsLocal = true };
            var l = listener;
            new Thread(() =>
            {
                while (true)
                {
                    TcpClient c;
                    try { c = l.AcceptTcpClient(); }
                    catch (Exception) { return; }
                    Post(() => OnAccepted(c));
                }
            }) { IsBackground = true, Name = "accept" }.Start();
            Status = $"Hosting on port {port}";
            Log?.Invoke($"Hosting on port {port}. Waiting for players...");
            ApplyMpConfig();
            Publish();
        }

        void DoJoin(string name, string address, string pw)
        {
            DoStop();
            myName = Clean.Name(name);
            if (!TryParseAddress(address, out var host, out var port))
            {
                Log?.Invoke("Enter the host's address, like 81.2.3.4:27420");
                return;
            }
            Status = $"Connecting to {host}:{port}...";
            Log?.Invoke(Status);
            Publish();
            Task.Run(() =>
            {
                var c = new TcpClient();
                try
                {
                    var t = c.ConnectAsync(host, port);
                    if (!t.Wait(8000)) throw new TimeoutException("no answer (is the host's port open?)");
                }
                catch (Exception e)
                {
                    c.Close();
                    var why = (e as AggregateException)?.InnerException?.Message ?? e.Message;
                    Post(() =>
                    {
                        Log?.Invoke($"Couldn't connect to {host}:{port}: {why}");
                        Status = "Not in a session";
                        Publish();
                    });
                    return;
                }
                Post(() => OnConnected(c, pw));
            });
        }

        void DoStop()
        {
            if (!Active && listener == null && server == null) return;
            try { listener?.Stop(); } catch (Exception) { }
            listener = null;
            foreach (var p in players.Values) p.Conn?.Close();
            foreach (var c in unnamed.Keys.ToList()) c.Close();
            unnamed.Clear();
            server?.Close();
            server = null;
            players.Clear();
            Active = false;
            IsHost = false;
            MyId = 0;
            saving = syncing = placeAfterLoad = false;
            if (holding)
            {
                holding = false;
                Freeze(false);
                game.Send("amp_hold 0");
            }
            zoneStatus = "-";
            zoneGoSent = null;
            game.Send("amp_cfg mp 0");
            game.Send("amp_clear");
            Status = "Not in a session";
            Publish();
        }

        static bool TryParseAddress(string s, out string host, out int port)
        {
            host = null;
            port = DefaultPort;
            s = (s ?? "").Trim();
            if (s.Length == 0) return false;
            int colon = s.LastIndexOf(':');
            if (colon > 0 && s.IndexOf(':') == colon)
            {
                if (!int.TryParse(s.Substring(colon + 1), out port) || port < 1 || port > 65535) return false;
                s = s.Substring(0, colon);
            }
            host = s;
            return host.Length > 0;
        }

        /// <summary>Tell the in-game mod we're in a session and who else is here.</summary>
        DateTime nextSizeCheck;
        Size sentSize;

        void SendScreenSize(bool force)
        {
            nextSizeCheck = DateTime.UtcNow.AddSeconds(2);
            var size = GameLink.GameClientSize();
            if (size.IsEmpty || (!force && size == sentSize)) return;
            if (game.Send($"amp_cfg sw {size.Width}") && game.Send($"amp_cfg sh {size.Height}")) sentSize = size;
        }

        /// <summary>The launcher's settings; the in-game switches are sent to the mod from here.</summary>
        public Settings Prefs { get; set; }

        /// <summary>Send the settings menu's in-game switches (any thread).</summary>
        public void ApplyPrefs() => Post(SendPrefs);

        void SendPrefs()
        {
            var prefs = Prefs;
            if (prefs == null) return;
            foreach (var kv in prefs.GameConfig()) game.Send($"amp_cfg {kv.Key} {kv.Value}");
        }

        void ApplyMpConfig()
        {
            SendScreenSize(true);
            SendPrefs();
            // VR: HLA waits on "press trigger to start" after loads; joining and respawning load, so skip it
            if (game.IsVR) game.Send("hlvr_auto_dismiss_loading 1");
            // in a shared game nobody's world may stop: opening the console (NoVR binds it to C) mustn't pause
            game.Send("sv_pause_on_console_open 0");
            if (!Active)
            {
                game.Send("amp_cfg mp 0");
                return;
            }
            game.Send("amp_cfg mp 1");
            game.Send($"amp_cfg role {(IsHost ? "host" : "client")}");
            game.Send($"amp_cfg id {MyId}");
            foreach (var p in players.Values)
                if (p.Id != MyId) game.Send($"amp_p {p.Id} {p.Name}");
            game.Send("amp_zs " + zoneStatus.Replace('\t', ' '));
        }

        void Note(string text)
        {
            Log?.Invoke(text);
            game.Send("amp_msg 5 " + Clean.Chat(text).Replace(' ', '_'));
        }

        // ------------------------------------------------------------------ host: connections

        void OnAccepted(TcpClient c)
        {
            if (!IsHost)
            {
                c.Close();
                return;
            }
            var conn = new Connection(c);
            conn.Received += (cn, t, b) => Post(() => OnHostReceive(cn, t, b));
            conn.Closed += cn => Post(() => OnHostClosed(cn));
            unnamed[conn] = DateTime.UtcNow;
            conn.Start();
        }

        void Reject(Connection conn, string why)
        {
            conn.Send(Msg.Reject, why);
            Task.Delay(500).ContinueWith(_ => conn.Close());
        }

        void OnHostReceive(Connection conn, Msg type, byte[] body)
        {
            if (!IsHost) return;
            var p = conn.Tag as Player;
            if (p == null)
            {
                if (type != Msg.Hello)
                {
                    conn.Close();
                    return;
                }
                unnamed.Remove(conn);
                var f = Text(body).Split('\t');
                if (f.Length < 4 || f[0] != Proto.ToString())
                {
                    Reject(conn, $"Version mismatch - the host is running Alyx MP {ModFiles.Version}. Update to the same version.");
                    return;
                }
                if (password.Length > 0 && f[3] != password)
                {
                    Reject(conn, "Wrong password.");
                    return;
                }
                if (players.Count >= MaxPlayers)
                {
                    Reject(conn, "The game is full.");
                    return;
                }
                var np = new Player { Id = nextId++, Name = UniqueName(Clean.Name(f[2])), Conn = conn };
                conn.Tag = np;
                players[np.Id] = np;
                conn.Send(Msg.Welcome, np.Id.ToString());
                foreach (var o in players.Values)
                    if (o != np) conn.Send(Msg.PlayerJoined, $"{o.Id}\t{o.Name}");
                Broadcast(Msg.PlayerJoined, $"{np.Id}\t{np.Name}", np);
                conn.Send(Msg.ZoneStatus, zoneStatus);
                game.Send($"amp_p {np.Id} {np.Name}");
                Note($"{np.Name} joined the game");
                if (f.Length > 4 && f[4] != GamePaths.BuildId(hla))
                    Log?.Invoke($"Heads up: {np.Name} has a different Half-Life: Alyx build ({f[4]} vs {GamePaths.BuildId(hla)}). Saves may not load for them.");
                if (f.Length > 5 && f[5] != (ModFiles.NoVRInstalled(hla) ? ModFiles.NoVRVersion(hla) : "-"))
                    Log?.Invoke($"Heads up: {np.Name} has a different NoVR version ({f[5]}).");
                SendRoster();
                Publish();
                return;
            }

            var now = DateTime.UtcNow;
            switch (type)
            {
                case Msg.State:
                    var st = Clean.State(Text(body));
                    if (st == null) return;
                    p.Last = st;
                    p.LastStateAt = now;
                    p.IsVR = st.VR;
                    ForwardState(p, st, now);
                    Broadcast(Msg.State, $"{p.Id}\t{st.Wire()}", p);
                    break;
                case Msg.Shot:
                    if (int.TryParse(Text(body), out var w) && w >= 0 && w <= 3)
                    {
                        game.Send($"amp_f {p.Id} {w}");
                        Broadcast(Msg.Shot, $"{p.Id}\t{w}", p);
                    }
                    break;
                case Msg.Zone:
                    var z = Clean.Zone(Text(body));
                    if (z == null) return;
                    p.Zone = z;
                    RecomputeZones();
                    break;
                case Msg.SyncRequest:
                    var req = Text(body).Split('\t');
                    if (req.Length > 1) p.IsVR = req[1] == "1";
                    WantSync(p);
                    if (!game.InLevel) conn.Send(Msg.Notice, "The host isn't in a level yet - you'll be brought in as soon as they are.");
                    break;
                case Msg.Kill:
                    var k = Clean.Kill(Text(body));
                    if (k == null) return;
                    game.Send("amp_k " + k);
                    Broadcast(Msg.Kill, $"{p.Id}\t{k}", p);
                    break;
                case Msg.Arrived:
                    var am = Clean.Map(Text(body));
                    if (am == null) return;
                    arrived[p.Id] = am;
                    CheckRelease();
                    break;
                case Msg.Chat:
                    var text = Clean.Chat(Text(body));
                    if (text.Length == 0) return;
                    if (text.StartsWith("/"))
                    {
                        HostCommand(p, text);
                        return;
                    }
                    ShowChat(p.Name, text);
                    Broadcast(Msg.Chat, $"{p.Id}\t{text}", p);
                    break;
                case Msg.World:
                    var wp = Clean.World(Text(body));
                    if (wp == null) return;
                    Broadcast(Msg.World, $"{p.Id}\t{wp}", p);
                    QueueWorld(p.Id, wp);
                    RecordJournal(p.Id, wp);
                    break;
                case Msg.Pong:
                    if (long.TryParse(Text(body), out var sent))
                        p.PingMs = (int)Math.Max(0, (Stopwatch.GetTimestamp() - sent) * 1000 / Stopwatch.Frequency);
                    break;
            }
        }

        void OnHostClosed(Connection conn)
        {
            unnamed.Remove(conn);
            if (!(conn.Tag is Player p) || !players.ContainsKey(p.Id)) return;
            players.Remove(p.Id);
            arrived.Remove(p.Id);
            CheckRelease();
            Broadcast(Msg.PlayerLeft, p.Id.ToString());
            game.Send($"amp_rm {p.Id}");
            if (IsHost) Note($"{p.Name} left the game");
            RecomputeZones();
            SendRoster();
            Publish();
        }

        string UniqueName(string name)
        {
            var taken = new HashSet<string>(players.Values.Select(p => p.Name), StringComparer.OrdinalIgnoreCase);
            if (!taken.Contains(name)) return name;
            for (int i = 2; ; i++)
                if (!taken.Contains(name + i)) return name + i;
        }

        void Broadcast(Msg type, string text, Player except = null)
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            foreach (var p in players.Values)
                if (p.Conn != null && p != except) p.Conn.Send(type, bytes);
        }

        void SendRoster()
        {
            if (!IsHost) return;
            var lines = players.Values.OrderBy(p => p.Id)
                .Select(p => $"{p.Id}\t{p.Name}\t{p.Map ?? "-"}\t{p.PingMs}");
            Broadcast(Msg.Roster, string.Join("\n", lines));
        }

        /// <summary>
        /// Everyone has to stand in the same changelevel trigger before the host lets the level change
        /// happen; the in-game mod keeps the triggers disabled meanwhile and shows who it's waiting for.
        /// </summary>
        void RecomputeZones()
        {
            if (!IsHost) return;
            var me = Me;
            var all = players.Values.ToList();
            var best = all.Where(p => p.Zone != "-" && p.Map == me?.Map)
                .GroupBy(p => p.Zone)
                .OrderByDescending(g => g.Count())
                .ThenByDescending(g => g.Any(p => p.IsLocal))
                .FirstOrDefault();
            string status;
            if (best == null)
            {
                status = "-";
                zoneGoSent = null;
            }
            else
            {
                int ready = best.Count();
                var waiting = all.Where(p => p.Zone != best.Key || p.Map != me?.Map).Select(p => p.Name);
                status = $"{best.Key}\t{ready}\t{all.Count}\t{string.Join(",", waiting)}";
                if (ready == all.Count && zoneGoSent != best.Key)
                {
                    zoneGoSent = best.Key;
                    Broadcast(Msg.ZoneGo, best.Key);
                    game.Send($"amp_go {best.Key}");
                    Log?.Invoke("Everyone is in the loading zone - loading the next area.");
                }
            }
            if (status == zoneStatus) return;
            zoneStatus = status;
            Broadcast(Msg.ZoneStatus, status);
            game.Send("amp_zs " + status.Replace('\t', ' '));
        }

        /// <summary>
        /// A NoVR host's save has no VR hands in it, and a VR player who loads it is stuck on "press
        /// trigger to start"; VR players get the level and the journal instead. Everyone else gets the save.
        /// </summary>
        void WantSync(Player p)
        {
            if (p.IsVR && !game.IsVR) p.WantsMapSync = true;
            else p.WantsSync = true;
        }

        void SendMapSync(Player p)
        {
            p.WantsMapSync = false;
            var sb = new StringBuilder(game.Map);
            int n = 0;
            if (journalMap == game.Map)
            {
                foreach (var e in journal)
                {
                    sb.Append('\n').Append(e.Key).Append(' ').Append(e.Value);
                    n++;
                }
            }
            p.Conn.Send(Msg.SyncMap, sb.ToString());
            Log?.Invoke($"{p.Name} plays in VR: they're loading {game.Map} and catching up on {n} things that happened here.");
        }

        void RecordJournal(int from, string payload)
        {
            if (!IsHost || game.Map == null) return;
            if (journalMap != game.Map)
            {
                journal.Clear();
                journalMap = game.Map;
            }
            var sp = payload.IndexOf(' ');
            if (sp <= 0 || !JournalKinds.Contains(payload.Substring(0, sp))) return;
            if (payload.StartsWith("pr ") || payload.StartsWith("ai "))
            {
                // only where each object came to rest (how far each wheel / lever got) matters
                var end = payload.IndexOf(' ', 3);
                if (end > 0)
                {
                    var key = payload.Substring(0, end + 1);
                    journal.RemoveAll(e => e.Value.StartsWith(key));
                }
            }
            journal.Add(new KeyValuePair<int, string>(from, payload));
            if (journal.Count > JournalMax) journal.RemoveRange(0, journal.Count - JournalMax);
        }

        void OnSaveWritten(string path)
        {
            if (!IsHost || !saving) return;
            if (!string.Equals(Path.GetFileNameWithoutExtension(path), SyncSave, StringComparison.OrdinalIgnoreCase)) return;
            saving = false;
            Task.Run(() =>
            {
                var data = ReadWhenStable(path);
                Post(() =>
                {
                    if (data == null)
                    {
                        Log?.Invoke("Couldn't read the save file to send to players.");
                        return;
                    }
                    var who = players.Values.Where(p => p.WantsSync && p.Conn != null).ToList();
                    foreach (var p in who)
                    {
                        p.WantsSync = false;
                        p.Conn.Send(Msg.SyncData, data);
                    }
                    if (who.Count > 0)
                        Log?.Invoke($"Sent your world ({data.Length / 1024} KB) to {string.Join(", ", who.Select(p => p.Name))}.");
                });
            });
        }

        /// <summary>Saves are written asynchronously after the console reports them; wait until the file settles.</summary>
        static byte[] ReadWhenStable(string path)
        {
            long last = -1;
            for (int i = 0; i < 60; i++)
            {
                Thread.Sleep(200);
                try
                {
                    var len = new FileInfo(path).Length;
                    if (len > 0 && len == last)
                    {
                        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                        {
                            var buf = new byte[fs.Length];
                            int got = 0;
                            while (got < buf.Length)
                            {
                                int n = fs.Read(buf, got, buf.Length - got);
                                if (n <= 0) break;
                                got += n;
                            }
                            if (got == buf.Length) return buf;
                        }
                    }
                    last = len;
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            return null;
        }

        // ------------------------------------------------------------------ client: connection

        void OnConnected(TcpClient c, string pw)
        {
            var conn = new Connection(c);
            server = conn;
            IsHost = false;
            Active = true;
            conn.Received += (cn, t, b) => Post(() => { if (cn == server) OnClientReceive(t, b); });
            conn.Closed += cn => Post(() => { if (cn == server) OnServerLost(); });
            conn.Start();
            var novr = ModFiles.NoVRInstalled(hla) ? ModFiles.NoVRVersion(hla) : "-";
            conn.Send(Msg.Hello, string.Join("\t", Proto, ModFiles.Version, myName, pw ?? "", GamePaths.BuildId(hla), novr));
            Status = "Connected, waiting for the host...";
            Publish();
        }

        void OnServerLost()
        {
            if (server == null) return;
            server = null;
            Log?.Invoke("Disconnected from the host.");
            game.Send("amp_msg 6 Disconnected_from_the_host");
            DoStop();
        }

        void OnClientReceive(Msg type, byte[] body)
        {
            var now = DateTime.UtcNow;
            var text = type == Msg.SyncData ? null : Text(body);
            var f = text?.Split('\t');
            int id = 0;
            if (f != null && f.Length > 1) int.TryParse(f[0], out id);
            switch (type)
            {
                case Msg.Welcome:
                    MyId = int.Parse(text);
                    players[MyId] = new Player { Id = MyId, Name = myName, IsLocal = true };
                    welcomedAt = now;
                    Status = "Connected";
                    Log?.Invoke("Joined the game.");
                    ApplyMpConfig();
                    Publish();
                    break;
                case Msg.Reject:
                    Log?.Invoke("The host refused the connection: " + text);
                    DoStop();
                    break;
                case Msg.PlayerJoined:
                    if (id == 0 || id == MyId || f.Length < 2) return;
                    var name = Clean.Name(f[1]);
                    players[id] = new Player { Id = id, Name = name };
                    game.Send($"amp_p {id} {name}");
                    if ((now - welcomedAt).TotalSeconds > 2) Note($"{name} joined the game");
                    Publish();
                    break;
                case Msg.PlayerLeft:
                    if (!int.TryParse(text, out id) || !players.TryGetValue(id, out var gone)) return;
                    players.Remove(id);
                    game.Send($"amp_rm {id}");
                    Note($"{gone.Name} left the game");
                    Publish();
                    break;
                case Msg.Roster:
                    foreach (var line in text.Split('\n'))
                    {
                        var r = line.Split('\t');
                        if (r.Length < 4 || !int.TryParse(r[0], out var rid) || !players.TryGetValue(rid, out var rp)) continue;
                        rp.RosterMap = Clean.Map(r[2]);
                        if (int.TryParse(r[3], out var ping)) rp.PingMs = ping;
                    }
                    Publish();
                    break;
                case Msg.State:
                    if (id == 0 || id == MyId || !players.TryGetValue(id, out var sp)) return;
                    var st = Clean.State(f[1]);
                    if (st == null) return;
                    sp.Last = st;
                    sp.LastStateAt = now;
                    ForwardState(sp, st, now);
                    break;
                case Msg.Shot:
                    if (id != 0 && id != MyId && int.TryParse(f[1], out var w) && w >= 0 && w <= 3)
                        game.Send($"amp_f {id} {w}");
                    break;
                case Msg.ZoneStatus:
                    var zs = text.Split('\t');
                    if (Clean.Zone(zs[0]) == null) return;
                    if (zs.Length == 4 && int.TryParse(zs[1], out var ready) && int.TryParse(zs[2], out var total))
                    {
                        var waiting = string.Join(",", zs[3].Split(',').Select(Clean.Name));
                        zoneStatus = $"{zs[0]}\t{ready}\t{total}\t{waiting}";
                    }
                    else zoneStatus = "-";
                    game.Send("amp_zs " + zoneStatus.Replace('\t', ' '));
                    break;
                case Msg.ZoneGo:
                    var z = Clean.Zone(text);
                    if (z == null || z == "-") return;
                    quietUntil = now.AddSeconds(45);
                    levelChange = true;
                    levelFrom = game.Map;
                    game.Send($"amp_go {z}");
                    break;
                case Msg.SyncData:
                    OnSyncData(body);
                    break;
                case Msg.SyncMap:
                    OnSyncMap(text);
                    break;
                case Msg.Kill:
                    var k = f.Length > 1 ? Clean.Kill(f[1]) : null;
                    if (k != null) game.Send("amp_k " + k);
                    break;
                case Msg.Chat:
                    if (id == 0 || f.Length < 2 || !players.TryGetValue(id, out var cp)) return;
                    var msg = Clean.Chat(f[1]);
                    if (msg.Length > 0) ShowChat(cp.Name, msg);
                    break;
                case Msg.Ping:
                    server?.Send(Msg.Pong, text);
                    break;
                case Msg.World:
                    var wp = f.Length > 1 ? Clean.World(f[1]) : null;
                    if (id != 0 && id != MyId && wp != null) QueueWorld(id, wp);
                    break;
                case Msg.Notice:
                    Note(Clean.Chat(text));
                    break;
                case Msg.Release:
                    ReleaseHold("Everyone's in - go!");
                    break;
                case Msg.Teleport:
                    var tp = text.Split(' ');
                    var nums = new double[4];
                    if (tp.Length == 4 && Enumerable.Range(0, 4).All(i => double.TryParse(tp[i], System.Globalization.NumberStyles.Float,
                            System.Globalization.CultureInfo.InvariantCulture, out nums[i]) && Math.Abs(nums[i]) < 1e6))
                        game.Send($"amp_near {Clean.F(nums[0])} {Clean.F(nums[1])} {Clean.F(nums[2])} {Clean.F(nums[3])}");
                    break;
            }
        }

        void RequestSync(string why)
        {
            if (syncing || server == null) return;
            syncing = true;
            syncStartedAt = DateTime.UtcNow;
            server.Send(Msg.SyncRequest, $"{why}\t{(game.IsVR ? 1 : 0)}");
            Log?.Invoke("Getting the host's world...");
            game.Send("amp_msg 6 Syncing_with_the_host...");
        }

        /// <summary>
        /// The host's save, loaded here, puts this player in the host's exact world: same level, enemies,
        /// doors and story progress. It goes in its own save folder so it never touches single-player saves.
        /// </summary>
        void OnSyncData(byte[] data)
        {
            var now = DateTime.UtcNow;
            try
            {
                var dir = Path.Combine(GamePaths.Hlvr(hla), "SAVE", ClientSaveDir);
                Directory.CreateDirectory(dir);
                File.WriteAllBytes(Path.Combine(dir, SyncSave + ".sav"), data);
            }
            catch (Exception e)
            {
                Log?.Invoke("Couldn't write the host's save: " + e.Message);
                syncing = false;
                return;
            }
            Log?.Invoke($"Loading the host's world ({data.Length / 1024} KB)...");
            game.Send($"save_set_subdirectory {ClientSaveDir}");
            game.Send("amp_unload");
            game.Send($"load {SyncSave}");
            placeAfterLoad = true;
            syncStartedAt = now;
            quietUntil = now.AddSeconds(60);
        }

        /// <summary>VR joining a NoVR host: load the level fresh (a proper VR player) and replay the journal.</summary>
        void OnSyncMap(string text)
        {
            var lines = text.Split('\n');
            var map = Clean.Map(lines[0].Trim());
            if (map == null || map == "startup")
            {
                syncing = false;
                return;
            }
            var entries = new List<KeyValuePair<int, string>>();
            for (int i = 1; i < lines.Length; i++)
            {
                var line = lines[i].TrimEnd('\r');
                var sp = line.IndexOf(' ');
                if (sp <= 0 || !int.TryParse(line.Substring(0, sp), out var from)) continue;
                var payload = Clean.World(line.Substring(sp + 1));
                if (payload != null) entries.Add(new KeyValuePair<int, string>(from, payload));
            }
            var now = DateTime.UtcNow;
            pendingMap = map;
            pendingJournal = entries;
            Log?.Invoke($"Loading {map} and catching up on {entries.Count} things the others did...");
            game.Send("amp_unload");
            game.Send($"map {map}");
            placeAfterLoad = true;
            syncStartedAt = now;
            quietUntil = now.AddSeconds(90);
        }

        // ------------------------------------------------------------------ local game events

        void OnLocalState(PlayerState st)
        {
            var me = Me;
            if (!Active || me == null) return;
            me.Last = st;
            me.LastStateAt = DateTime.UtcNow;
            if (IsHost) Broadcast(Msg.State, $"{me.Id}\t{st.Wire()}");
            else server?.Send(Msg.State, st.Wire());
        }

        void OnLocalShot(int weapon)
        {
            if (!Active) return;
            if (IsHost) Broadcast(Msg.Shot, $"{MyId}\t{weapon}");
            else server?.Send(Msg.Shot, weapon.ToString());
        }

        void OnLocalZone(string zone)
        {
            var me = Me;
            if (!Active || me == null) return;
            me.Zone = zone;
            if (IsHost) RecomputeZones();
            else server?.Send(Msg.Zone, zone);
        }

        void OnLocalKill(string kill)
        {
            if (!Active) return;
            if (IsHost) Broadcast(Msg.Kill, $"{MyId}\t{kill}");
            else server?.Send(Msg.Kill, kill);
        }

        void OnLocalDied()
        {
            if (!Active || IsHost) return;
            // respawn next to the host from their save instead of reloading an old autosave
            var host = HostPlayer;
            if (host == null || !host.InLevel(DateTime.UtcNow)) return;
            Task.Delay(2500).ContinueWith(_ => Post(() => RequestSync("died")));
        }

        /// <summary>
        /// The host reloaded a save (died, or loaded one by hand): everyone else is now ahead of the host's
        /// world, so bring them back in line. A joining player loading the host's save lands here too, harmlessly.
        /// </summary>
        void OnLocalSaveLoaded()
        {
            if (!Active || !IsHost) return;
            var others = players.Values.Where(p => p.Conn != null).ToList();
            if (others.Count == 0) return;
            foreach (var p in others) WantSync(p);
            Log?.Invoke("You loaded a save - sending your world to everyone so you stay together.");
        }

        void OnLocalTransition()
        {
            quietUntil = DateTime.UtcNow.AddSeconds(45);
            levelChange = true;
            levelFrom = game.Map;
        }

        /// <summary>
        /// Players load the next level at different speeds; whoever is in first would start the level's
        /// scripts and enemies without the others. So everyone pauses on arrival until the host has
        /// heard from all of them.
        /// </summary>
        void StartHold(string map)
        {
            holding = true;
            holdSince = DateTime.UtcNow;
            holdWaiting = string.Join(" ", players.Values.Where(p => !p.IsLocal).Select(p => p.Name));
            game.Send($"amp_hold 1 {holdWaiting}");
            Freeze(true);
            if (IsHost)
            {
                arrived[MyId] = map;
                CheckRelease();
            }
            else server?.Send(Msg.Arrived, map);
        }

        void CheckRelease()
        {
            if (!IsHost || !holding) return;
            var map = game.Map;
            if (map == null || !arrived.TryGetValue(MyId, out var mine) || mine != map) return;
            if (players.Values.Any(p => p.Conn != null && (!arrived.TryGetValue(p.Id, out var m) || m != map))) return;
            arrived.Clear();
            Broadcast(Msg.Release, "-");
            ReleaseHold("Everyone's in - go!");
        }

        void ReleaseHold(string why)
        {
            if (!holding) return;
            holding = false;
            Freeze(false);
            game.Send("amp_hold 0");
            Note(why);
            // everyone made it into the new level: that's a checkpoint
            if (IsHost) Autosave();
        }

        /// <summary>The host's world is the one everybody comes back to; HL:A's own rotating autosave keeps it.</summary>
        void Autosave()
        {
            nextAutosave = DateTime.UtcNow.AddMinutes(AutosaveMinutes);
            if (!IsHost || !game.InLevel || holding) return;
            game.Send("autosave");
            Log?.Invoke("Autosaved.");
        }

        void OnMapReady(string map)
        {
            if (Active && levelChange && map != null && map != "startup" && map != levelFrom)
            {
                levelChange = false;
                StartHold(map);
            }
            ApplyMpConfig();
            if (Active && map != "startup") game.Send("amp_msg 6 Press_Y_to_chat");
            if (!Active || IsHost || !placeAfterLoad) return;
            var host = HostPlayer;
            if (host?.Last == null || host.Last.Map != map) return;
            placeAfterLoad = false;
            syncing = false;
            mismatchSince = null;
            if (pendingJournal != null && map == pendingMap)
            {
                // "J": replayed in order, as a catch-up rather than as live events
                foreach (var e in pendingJournal) QueueWorld(e.Key, "J " + e.Value);
                pendingJournal = null;
            }
            var h = host.Last;
            game.Send($"amp_near {Clean.F(h.X)} {Clean.F(h.Y)} {Clean.F(h.Z)} {Clean.F(h.Yaw)}");
            Log?.Invoke("You're in the host's world.");
        }

        void ForwardState(Player p, PlayerState st, DateTime now)
        {
            // players on other levels only need occasional updates (for the HUD list)
            if (st.Map != game.Map && (now - p.LastForwardAt).TotalSeconds < 1) return;
            p.LastForwardAt = now;
            game.Send($"amp_s {p.Id} {st.Wire()}");
        }

        void ShowChat(string name, string text)
        {
            Chat?.Invoke(name.Replace('_', ' '), text);
            game.Send($"amp_chat {name} {text}");
        }

        void OnLocalWorld(string payload)
        {
            if (!Active || MyId == 0) return;
            if (IsHost)
            {
                Broadcast(Msg.World, $"{MyId}\t{payload}");
                RecordJournal(MyId, payload);
            }
            else server?.Send(Msg.World, payload);
        }

        /// <summary>World messages arrive in bursts; hand them to the game a few at a time per command.</summary>
        void QueueWorld(int from, string payload)
        {
            worldOut.Add($"{from} {payload}");
            if (worldOut.Count >= 24) FlushWorld();
        }

        void FlushWorld()
        {
            if (DateTime.UtcNow >= nextSizeCheck) SendScreenSize(false);
            if (worldOut.Count == 0) return;
            var sb = new StringBuilder("amp_w");
            foreach (var entry in worldOut)
            {
                if (sb.Length + entry.Length + 3 > 900)
                {
                    game.Send(sb.ToString());
                    sb.Clear().Append("amp_w");
                }
                sb.Append(" ~ ").Append(entry);
            }
            if (sb.Length > 5) game.Send(sb.ToString());
            worldOut.Clear();
        }

        // ------------------------------------------------------------------ UI actions

        void DoChat(string raw)
        {
            var text = Clean.Chat(raw);
            if (!Active || text.Length == 0) return;
            if (text.StartsWith("/"))
            {
                RunCommand(text.ToLowerInvariant());
                return;
            }
            ShowChat(myName, text);
            if (IsHost) Broadcast(Msg.Chat, $"{MyId}\t{text}");
            else server?.Send(Msg.Chat, text);
        }

        static readonly string[] CommandHelp =
        {
            "/tp <player> to <player>  -  teleport anyone to anyone (\"me\" works as a name)",
            "/tp <player>  -  teleport yourself to them",
            "/stuck  -  reload into the host's world, next to them",
            "/checkpoint  -  everyone back to the host's last checkpoint",
        };

        /// <summary>Chat commands typed here (in the launcher or with Y in game).</summary>
        void RunCommand(string cmd)
        {
            var verb = cmd.Split(' ')[0].ToLowerInvariant();
            switch (verb)
            {
                case "/stuck":
                    // load the host's current world (where they are in the story) and stand next to them
                    if (IsHost) Note("You're the host - everyone else follows your world. Use /checkpoint to restart from the last checkpoint.");
                    else
                    {
                        Note("Bringing you into the host's world...");
                        syncing = false;
                        RequestSync("stuck");
                    }
                    break;
                case "/tp":
                case "/checkpoint":
                    // the host knows where everyone is and can move anyone
                    if (IsHost) HostCommand(Me, cmd);
                    else server?.Send(Msg.Chat, cmd);
                    break;
                default:
                    foreach (var line in CommandHelp) Note(line);
                    break;
            }
        }

        void Reply(Player to, string text)
        {
            if (to == null || to.IsLocal) Note(text);
            else to.Conn?.Send(Msg.Notice, text);
        }

        void HostCommand(Player from, string cmd)
        {
            if (!IsHost || from == null) return;
            var verb = cmd.Split(' ')[0].ToLowerInvariant();
            var args = cmd.Length > verb.Length ? cmd.Substring(verb.Length).Trim() : "";
            switch (verb)
            {
                case "/checkpoint":
                    DoCheckpoint(from.Name);
                    break;
                case "/tp":
                    Teleport(from, args);
                    break;
                default:
                    foreach (var line in CommandHelp) Reply(from, line);
                    break;
            }
        }

        static string NameKey(string s) => new string((s ?? "").Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

        /// <summary>"me", an exact name, or the start of exactly one name (spaces, _ and case don't matter).</summary>
        Player FindPlayer(Player asking, string name)
        {
            var key = NameKey(name);
            if (key.Length == 0) return null;
            if (key == "me" || key == "myself") return asking;
            var exact = players.Values.FirstOrDefault(p => NameKey(p.Name) == key);
            if (exact != null) return exact;
            var starts = players.Values.Where(p => NameKey(p.Name).StartsWith(key)).ToList();
            return starts.Count == 1 ? starts[0] : null;
        }

        void Teleport(Player asking, string args)
        {
            var parts = System.Text.RegularExpressions.Regex.Split(args, @"\s+to\s+", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            string whoName, toName;
            if (parts.Length == 2) { whoName = parts[0]; toName = parts[1]; }
            else if (parts.Length == 1 && parts[0].Length > 0) { whoName = "me"; toName = parts[0]; }
            else
            {
                Reply(asking, "Use /tp <player> to <player>, or /tp <player> to go to them.");
                return;
            }
            var who = FindPlayer(asking, whoName);
            var to = FindPlayer(asking, toName);
            var names = string.Join(", ", players.Values.Select(p => p.Name.Replace('_', ' ')));
            if (who == null || to == null)
            {
                Reply(asking, $"No player called \"{(who == null ? whoName : toName)}\" - players: {names}");
                return;
            }
            if (who == to)
            {
                Reply(asking, "They're already there.");
                return;
            }
            var dest = to.Last;
            if (dest == null || dest.Dead || dest.Map == "startup")
            {
                Reply(asking, $"{to.Name.Replace('_', ' ')} isn't in a level right now.");
                return;
            }
            var whoMap = who.IsLocal ? game.Map : who.Map;
            if (whoMap != dest.Map)
            {
                Reply(asking, $"{who.Name.Replace('_', ' ')} and {to.Name.Replace('_', ' ')} are on different levels - {who.Name.Replace('_', ' ')} can type /stuck to come to the host.");
                return;
            }
            var spot = $"{Clean.F(dest.X)} {Clean.F(dest.Y)} {Clean.F(dest.Z)} {Clean.F(dest.Yaw)}";
            if (who.IsLocal) game.Send($"amp_near {spot}");
            else who.Conn?.Send(Msg.Teleport, spot);
            var msg = $"{asking.Name.Replace('_', ' ')} teleported {(who == asking ? "themselves" : who.Name.Replace('_', ' '))} to {to.Name.Replace('_', ' ')}";
            Note(msg);
            Broadcast(Msg.Notice, msg);
        }

        /// <summary>The host reloads its last checkpoint; loading a save sends that world to everyone.</summary>
        void DoCheckpoint(string who)
        {
            if (!IsHost) return;
            var msg = $"{who} restarted everyone from the last checkpoint";
            Note(msg);
            Broadcast(Msg.Notice, msg);
            game.Send("amp_unload");
            game.Send("load autosave");
        }

        void DoResync()
        {
            if (!Active) return;
            if (IsHost)
            {
                foreach (var p in players.Values) if (p.Conn != null) WantSync(p);
                Log?.Invoke("Sending your world to everyone...");
            }
            else
            {
                syncing = false;
                RequestSync("manual");
            }
        }

        // ------------------------------------------------------------------ periodic work

        /// <summary>
        /// Stop the world while we wait. NoVR (cheats are on there) stops time, which leaves the screen to
        /// the mod's own pause card; the engine's pause would add its plain "PAUSED" caption.
        /// </summary>
        void Freeze(bool on)
        {
            if (game.IsVR) game.Send(on ? "setpause" : "unpause");
            else game.Send(on ? "host_timescale 0" : "host_timescale 1");
        }

        void Tick()
        {
            if (!Active) return;
            var now = DateTime.UtcNow;
            ticks++;
            // the card is drawn while the game stands still; keep it up
            if (holding && ticks % 5 == 0) game.Send($"amp_hold 1 {holdWaiting}");
            if (IsHost) HostTick(now);
            else ClientTick(now);
            Publish();
        }

        void HostTick(DateTime now)
        {
            foreach (var kv in unnamed.ToList())
                if ((now - kv.Value).TotalSeconds > 10) kv.Key.Close();

            if (nextAutosave == default) nextAutosave = now.AddMinutes(AutosaveMinutes);
            else if (now >= nextAutosave && game.InLevel && !holding && !saving) Autosave();

            if (saving && (now - saveStartedAt).TotalSeconds > 20)
            {
                saving = false;
                Log?.Invoke("Saving the world for other players timed out - retrying.");
            }
            if (game.InLevel)
                foreach (var p in players.Values.Where(p => p.WantsMapSync && p.Conn != null).ToList()) SendMapSync(p);
            if (!saving && game.InLevel && players.Values.Any(p => p.WantsSync && p.Conn != null))
            {
                saving = true;
                saveStartedAt = now;
                game.Send($"save {SyncSave}");
            }
            if (ticks % 2 == 0)
            {
                var token = Stopwatch.GetTimestamp().ToString();
                Broadcast(Msg.Ping, token);
                SendRoster();
            }
            RecomputeZones();
            if (holding && (now - holdSince).TotalSeconds > HoldTimeout)
            {
                arrived.Clear();
                Broadcast(Msg.Release, "-");
                ReleaseHold("Stopped waiting for players who didn't load in.");
            }
            else CheckRelease();
        }

        void ClientTick(DateTime now)
        {
            if (MyId == 0) return;
            if (holding && (now - holdSince).TotalSeconds > HoldTimeout) ReleaseHold("Stopped waiting for the others to load.");
            if (syncing && (now - syncStartedAt).TotalSeconds > 90)
            {
                syncing = false;
                placeAfterLoad = false;
                Log?.Invoke("Syncing with the host took too long - will try again.");
            }
            var host = HostPlayer;
            if (host == null || !host.InLevel(now) || syncing || now < quietUntil || !game.Connected || !game.ModReady)
            {
                mismatchSince = null;
                return;
            }
            // main menu: join the host's world straight away
            if (game.Map == null || game.Map == "startup")
            {
                RequestSync("join");
                return;
            }
            // a different level than the host for a while (missed a level change, loaded another save...)
            if (game.Map != host.Last.Map)
            {
                mismatchSince = mismatchSince ?? now;
                if ((now - mismatchSince.Value).TotalSeconds > 8)
                {
                    mismatchSince = null;
                    RequestSync("map");
                }
            }
            else mismatchSince = null;
        }

        void Publish()
        {
            var host = IsHost ? MyId : 1;
            Players = players.Values.OrderBy(p => p.Id).Select(p => new PlayerView
            {
                Id = p.Id,
                Name = p.Name.Replace('_', ' '),
                Map = p.IsLocal ? game.Map : p.Map,
                Ping = p.IsLocal ? -1 : p.PingMs,
                IsYou = p.IsLocal,
                IsHost = p.Id == host,
            }).ToList();
            if (Active && IsHost) Status = $"Hosting - {players.Count} player{(players.Count == 1 ? "" : "s")}";
            else if (Active && MyId != 0) Status = $"Connected - {players.Count} player{(players.Count == 1 ? "" : "s")}";
            Changed?.Invoke();
        }

        public void Dispose()
        {
            ticker.Dispose();
            worldFlush.Dispose();
            var done = new ManualResetEventSlim();
            Post(() => { DoStop(); done.Set(); });
            done.Wait(2000);
            queue.CompleteAdding();
        }
    }
}
