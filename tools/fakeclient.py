"""Dev helper: a fake remote player that joins a hosting launcher over TCP, exactly like a friend's launcher
would, then walks/runs/shoots around the host's position.

usage: python fakeclient.py [--addr 127.0.0.1:27420] [--secs 20] [--name Fake_Friend] [--sync]
  --sync   ask the host for its world (the host should save and send it back)
"""
import argparse
import math
import socket
import struct
import threading
import time

HELLO, WELCOME, REJECT, JOINED, LEFT, ROSTER, STATE, SHOT, ZONE, ZONESTATUS, ZONEGO, SYNCREQ, SYNCDATA, KILL, CHAT, PING, PONG, NOTICE = range(1, 19)
NAMES = {v: k for k, v in dict(HELLO=1, WELCOME=2, REJECT=3, JOINED=4, LEFT=5, ROSTER=6, STATE=7, SHOT=8, ZONE=9, ZONESTATUS=10,
                                ZONEGO=11, SYNCREQ=12, SYNCDATA=13, KILL=14, CHAT=15, PING=16, PONG=17, NOTICE=18).items()}

ap = argparse.ArgumentParser()
ap.add_argument("--addr", default="127.0.0.1:27420")
ap.add_argument("--secs", type=float, default=20)
ap.add_argument("--name", default="Fake_Friend")
ap.add_argument("--password", default="")
ap.add_argument("--weapon", type=int, default=3)
ap.add_argument("--sync", action="store_true")
ap.add_argument("--chat", default="hello from the fake client")
a = ap.parse_args()

host, port = a.addr.rsplit(":", 1)
s = socket.create_connection((host, int(port)))
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
lock = threading.Lock()


def send(t, payload):
    if isinstance(payload, str):
        payload = payload.encode()
    with lock:
        s.sendall(struct.pack("<BI", t, len(payload)) + payload)


host_state = {}
counts = {}
my_id = [None]


def reader():
    buf = b""
    while True:
        try:
            chunk = s.recv(1 << 20)
        except OSError:
            return
        if not chunk:
            print("[fake] connection closed by host")
            return
        buf += chunk
        while len(buf) >= 5:
            t, ln = struct.unpack("<BI", buf[:5])
            if len(buf) < 5 + ln:
                break
            body, buf = buf[5:5 + ln], buf[5 + ln:]
            counts[t] = counts.get(t, 0) + 1
            if t == WELCOME:
                my_id[0] = int(body)
                print("[fake] welcomed, my id =", my_id[0])
            elif t == REJECT:
                print("[fake] rejected:", body.decode())
            elif t in (JOINED, LEFT, NOTICE, CHAT, ZONESTATUS, ZONEGO):
                print(f"[fake] {NAMES[t]}: {body.decode()!r}")
            elif t == STATE:
                pid, st = body.decode().split("\t", 1)
                if pid == "1":
                    host_state["parts"] = st.split(" ")
            elif t == PING:
                send(PONG, body)
            elif t == SYNCDATA:
                print(f"[fake] got the host's save: {len(body)} bytes, starts with {body[:8]!r}")


threading.Thread(target=reader, daemon=True).start()
send(HELLO, "\t".join(["2", "0.2.0", a.name, a.password, "25487405", "-"]))

deadline = time.time() + 10
while "parts" not in host_state and time.time() < deadline:
    time.sleep(0.1)
if "parts" not in host_state:
    raise SystemExit("[fake] never received the host's position - is the host's game in a level?")
p = host_state["parts"]
mapname = p[0]
hx, hy, hz, hyaw = float(p[2]), float(p[3]), float(p[4]), math.radians(float(p[5]))
cx, cy = hx + math.cos(hyaw) * 170, hy + math.sin(hyaw) * 170
print(f"[fake] host is on {mapname} at {hx:.0f},{hy:.0f},{hz:.0f}")

send(CHAT, a.chat)
if a.sync:
    send(SYNCREQ, "test")

t0 = time.time()
last_shot = 0
while time.time() - t0 < a.secs:
    t = time.time() - t0
    phase = int(t // 4) % 3          # run, stand+shoot, walk
    speed = (200, 0, 80)[phase]
    ang = t * max(speed, 1) / 70.0
    x, y = (cx + math.cos(ang) * 70, cy + math.sin(ang) * 70) if speed else (cx, cy)
    yaw = math.degrees(ang) + 90 if speed else math.degrees(hyaw) + 180
    weapon = a.weapon if phase != 2 else 0
    send(STATE, f"{mapname} {t:.3f} {x:.1f} {y:.1f} {hz:.1f} {yaw:.1f} 0 64 0 {weapon}")
    if phase == 1 and t - last_shot > 0.25:
        last_shot = t
        send(SHOT, str(weapon))
    time.sleep(0.05)
print("[fake] done; messages received:", {NAMES.get(k, k): v for k, v in counts.items()})
s.close()
