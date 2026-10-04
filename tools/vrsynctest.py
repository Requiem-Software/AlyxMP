"""Dev helper: test the VR <-> NoVR join path (SyncMap) without a headset.

  python vrsynctest.py client [--addr 127.0.0.1:27420]
      plays a VR friend joining a hosting launcher: sends a few world events, then asks to join as a VR
      player and prints the SyncMap (level + journal) the host answers with.

  python vrsynctest.py host [--port 27421] [--map a1_intro_world] [--pos X Y Z] [--journal LINE ...]
      plays a NoVR host for a launcher that joins it in "VR": answers its sync request with SyncMap.
"""
import argparse
import socket
import struct
import threading
import time

HELLO, WELCOME, REJECT, JOINED, LEFT, ROSTER, STATE, SHOT, ZONE, ZONESTATUS, ZONEGO, SYNCREQ, SYNCDATA, KILL, CHAT, PING, PONG, NOTICE, WORLD, SYNCMAP = range(1, 21)
PROTO = 3

ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["client", "host"])
ap.add_argument("--addr", default="127.0.0.1:27420")
ap.add_argument("--port", type=int, default=27421)
ap.add_argument("--map", default="a1_intro_world")
ap.add_argument("--pos", type=float, nargs=3, default=[-256.0, 1984.0, 150.0])
ap.add_argument("--journal", nargs="*", default=[])
ap.add_argument("--secs", type=float, default=60)
a = ap.parse_args()


def framer(sock):
    lock = threading.Lock()

    def send(t, payload):
        if isinstance(payload, str):
            payload = payload.encode()
        with lock:
            sock.sendall(struct.pack("<BI", t, len(payload)) + payload)
    return send


def frames(sock):
    buf = b""
    while True:
        try:
            chunk = sock.recv(1 << 20)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        while len(buf) >= 5:
            t, ln = struct.unpack("<BI", buf[:5])
            if len(buf) < 5 + ln:
                break
            yield t, buf[5:5 + ln]
            buf = buf[5 + ln:]


def state(map_, x, y, z, flags, t0):
    return f"{map_} {time.time() - t0:.3f} {x:.1f} {y:.1f} {z:.1f} 90 0 64 {flags} 0"


if a.mode == "client":
    host, port = a.addr.rsplit(":", 1)
    s = socket.create_connection((host, int(port)))
    send = framer(s)
    send(HELLO, f"{PROTO}\t0.4.0\tVR_Friend\t\t0\t-")
    t0 = time.time()
    got = {}

    def reader():
        for t, body in frames(s):
            if t == WELCOME:
                got["id"] = int(body)
                print("[vr] welcomed as", got["id"])
            elif t == PING:
                send(PONG, body)
            elif t == SYNCMAP:
                text = body.decode()
                lines = text.split("\n")
                print(f"[vr] SyncMap: level {lines[0]!r}, {len(lines) - 1} journal lines")
                for l in lines[1:]:
                    print("      ", l)
                got["map"] = True
            elif t == SYNCDATA:
                print(f"[vr] got a SAVE ({len(body)} bytes) - wrong for a VR player on a NoVR host")
                got["save"] = True
            elif t in (NOTICE, REJECT):
                print("[vr]", body.decode())
    threading.Thread(target=reader, daemon=True).start()
    while "id" not in got and time.time() - t0 < 10:
        time.sleep(0.1)
    x, y, z = a.pos
    for i in range(10):
        send(STATE, state(a.map, x + 40, y, z, 1, t0))   # flags 1 = VR
        time.sleep(0.05)
    # things this player did in the level (the host journals them)
    for p in ["pr 89bc22@-230,2004,152 -231.9 2013.8 150.1 0.0 12.0 0.0", "us 9e6d10@-224,1997,177",
              "p 3b72ae@-212,1923,189 -212.0 1923.0 190.0 0 0 0", "pr 89bc22@-230,2004,152 -240.0 2020.0 150.1 0.0 45.0 0.0",
              "tg b37065@642,-1765,-170"]:
        send(WORLD, p)
        time.sleep(0.05)
    time.sleep(0.5)
    send(SYNCREQ, "join\t1")
    while time.time() - t0 < 15 and "map" not in got and "save" not in got:
        send(STATE, state(a.map, x + 40, y, z, 1, t0))
        time.sleep(0.1)
    s.close()
else:
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(1)
    print("[host] waiting for the launcher on port", a.port)
    c, _ = srv.accept()
    send = framer(c)
    t0 = time.time()
    x, y, z = a.pos
    done = {}

    def reader():
        for t, body in frames(c):
            if t == HELLO:
                print("[host] hello:", body.decode().split("\t")[:3])
                send(WELCOME, "2")
                send(JOINED, "1\tFake_Host")
            elif t == SYNCREQ:
                print("[host] sync request:", repr(body.decode()))
                send(SYNCMAP, "\n".join([a.map] + a.journal))
                done["sent"] = time.time()
            elif t == WORLD:
                print("[host] world from launcher:", body.decode())
            elif t == PONG:
                pass
    threading.Thread(target=reader, daemon=True).start()
    while time.time() - t0 < a.secs:
        try:
            send(STATE, f"1\t{state(a.map, x, y, z, 0, t0)}")
        except OSError:
            break
        time.sleep(0.05)
    c.close()
