"""Dev helper: a fake host for testing the launcher's *client* side on one PC.

Accepts one launcher connection, welcomes it, pretends to be a host player standing/walking near the
given position, and after a few seconds sends a save file (like a real host does when you join) so the
client launcher has to write it, load it and place the player next to the host.

usage: python fakehost.py --save PATH.sav [--port 27421] [--map a1_intro_world] [--pos X Y Z] [--secs 40]
"""
import argparse
import math
import socket
import struct
import threading
import time

HELLO, WELCOME, REJECT, JOINED, LEFT, ROSTER, STATE, SHOT, ZONE, ZONESTATUS, ZONEGO, SYNCREQ, SYNCDATA, KILL, CHAT, PING, PONG, NOTICE = range(1, 19)
NAMES = ["?", "HELLO", "WELCOME", "REJECT", "JOINED", "LEFT", "ROSTER", "STATE", "SHOT", "ZONE", "ZONESTATUS", "ZONEGO",
         "SYNCREQ", "SYNCDATA", "KILL", "CHAT", "PING", "PONG", "NOTICE"]

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=27421)
ap.add_argument("--save", required=True)
ap.add_argument("--map", default="a1_intro_world")
ap.add_argument("--pos", type=float, nargs=3, default=[-150.0, 2110.0, 150.1])
ap.add_argument("--secs", type=float, default=40)
ap.add_argument("--sync-at", type=float, default=4.0, help="send the save this many seconds after the welcome (-1: only on request)")
ap.add_argument("--zone", default=None, help="claim to stand in this loading zone id")
a = ap.parse_args()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", a.port))
srv.listen(1)
print(f"[host] listening on 127.0.0.1:{a.port}")
c, addr = srv.accept()
c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
print("[host] client connected from", addr)
lock = threading.Lock()


def send(t, payload):
    if isinstance(payload, str):
        payload = payload.encode()
    with lock:
        c.sendall(struct.pack("<BI", t, len(payload)) + payload)


counts = {}
sync_requested = threading.Event()
client_zone = ["-"]


def reader():
    buf = b""
    while True:
        try:
            chunk = c.recv(1 << 20)
        except OSError:
            return
        if not chunk:
            print("[host] client disconnected")
            return
        buf += chunk
        while len(buf) >= 5:
            t, ln = struct.unpack("<BI", buf[:5])
            if len(buf) < 5 + ln:
                break
            body, buf = buf[5:5 + ln], buf[5 + ln:]
            counts[NAMES[t]] = counts.get(NAMES[t], 0) + 1
            if t == HELLO:
                print("[host] hello:", body.decode().split("\t")[:3])
            elif t == SYNCREQ:
                print("[host] client asks for the world:", body.decode())
                sync_requested.set()
            elif t == ZONE:
                client_zone[0] = body.decode()
                print("[host] client zone:", client_zone[0])
            elif t in (CHAT,):
                print("[host] chat:", body.decode())
            elif t == STATE and counts[NAMES[t]] % 40 == 1:
                print("[host] client state:", body.decode())


threading.Thread(target=reader, daemon=True).start()
time.sleep(0.3)
send(WELCOME, "2")
send(JOINED, "1\tFake_Host")
send(ZONESTATUS, "-")
send(CHAT, "1\twelcome to the fake host")
t0 = time.time()
sent_sync = False
x0, y0, z0 = a.pos
while time.time() - t0 < a.secs:
    t = time.time() - t0
    x = x0 + math.sin(t * 0.8) * 60
    send(STATE, f"1\t{a.map} {t:.3f} {x:.1f} {y0:.1f} {z0:.1f} 230 0 64 0 0")
    if not sent_sync and ((a.sync_at >= 0 and t > a.sync_at) or sync_requested.is_set()):
        data = open(a.save, "rb").read()
        print(f"[host] sending save {a.save} ({len(data)} bytes)")
        send(SYNCDATA, data)
        sent_sync = True
    if a.zone:
        ready = 2 if client_zone[0] == a.zone else 1
        send(ZONESTATUS, f"{a.zone}\t{ready}\t2\t" + ("" if ready == 2 else "Client"))
        if ready == 2:
            print("[host] both in the zone -> ZONEGO")
            send(ZONEGO, a.zone)
            a.zone = None
    if int(t * 20) % 40 == 0:
        send(PING, str(int(time.time() * 1000)))
    time.sleep(0.05)
print("[host] done; received:", counts)
c.close()
