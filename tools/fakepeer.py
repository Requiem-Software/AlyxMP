"""Dev helper: pretend to be a remote player so the in-game puppet can be tested with one PC.

Reads the local player's position from the mod's "[AMP]s" lines, then streams amp_s / amp_f updates over
VConsole for a fake player that runs through a scripted routine in front of the camera:
idle+shooting, walking armed, running armed, crouched armed, unarmed walk, unarmed run, crouch.

usage: python fakepeer.py [--weapon 1|2|3] [--shots N] [--ahead 170]
"""
import argparse
import math
import random
import socket
import struct
import time

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=29000)
ap.add_argument("--ahead", type=float, default=170, help="center of the routine this far in front of the player")
ap.add_argument("--weapon", type=int, default=1)
ap.add_argument("--shots", type=int, default=0, help="screenshots spread over the run")
ap.add_argument("--name", default="Test_Bot")
ap.add_argument("--id", type=int, default=2)
ap.add_argument("--jitter", type=float, default=0.0, help="random extra send delay to mimic internet jitter (s)")
ap.add_argument("--only", default=None, help="run just one phase by name")
a = ap.parse_args()

VERSION = 0x00D30000
# name, seconds, speed (u/s), weapon?, crouch?, fire rate (shots/s)
PHASES = [
    ("idle_fire", 3.0, 0, True, False, 3),
    ("walk_armed", 3.0, 80, True, False, 0),
    ("run_armed", 3.0, 200, True, False, 0),
    ("crouch_armed", 2.5, 0, True, True, 2),
    ("walk", 3.0, 80, False, False, 0),
    ("run", 3.0, 200, False, False, 0),
    ("crouch", 2.0, 0, False, True, 0),
]
if a.only:
    PHASES = [p for p in PHASES if p[0] == a.only]


def cmnd(text):
    p = text.encode() + b"\0"
    return b"CMND" + struct.pack(">IHH", VERSION, 12 + len(p), 0) + p


s = socket.create_connection(("127.0.0.1", a.port))
s.settimeout(0.01)
buf = b""
lines = []
past_backlog = False
connected_at = time.time()


def pump():
    global buf, past_backlog
    try:
        while True:
            c = s.recv(1 << 20)
            if not c:
                break
            buf += c
    except (socket.timeout, BlockingIOError):
        pass
    while len(buf) >= 12:
        typ, ver, ln, h = struct.unpack(">4sIHH", buf[:12])
        if len(buf) < ln:
            break
        body, buf = buf[12:ln], buf[ln:]
        if typ == b"PRNT":
            msg = body[28:].split(b"\0", 1)[0].decode("utf-8", "replace")
            for line in msg.splitlines():
                if "End VConsole Buffered Messages" in line:
                    past_backlog = True
                elif past_backlog or time.time() - connected_at > 3:
                    lines.append(line)


s.sendall(cmnd("amp_hello"))
center = None
deadline = time.time() + 8
while time.time() < deadline and center is None:
    pump()
    for line in lines:
        if line.startswith("[AMP]s "):
            parts = line.split()
            mapname = parts[1]
            center = tuple(float(v) for v in parts[3:6])
            look = math.radians(float(parts[6]))
    lines.clear()
    time.sleep(0.05)
if center is None:
    raise SystemExit("no [AMP]s line seen - is alyxmp/main loaded?")
print("local player", mapname, center)
cx = center[0] + math.cos(look) * a.ahead
cy = center[1] + math.sin(look) * a.ahead
facing_player = math.degrees(look) + 180

s.sendall(cmnd("amp_cfg mp 1"))
s.sendall(cmnd(f"amp_p {a.id} {a.name}"))
s.sendall(cmnd(f"amp_msg 4 {a.name}_joined_the_game"))

t0 = time.time()
total = sum(p[1] for p in PHASES)
shot_times = [total * (i + 0.5) / a.shots for i in range(a.shots)] if a.shots else []
x, y = cx, cy
phase_start = 0.0
last_fire = 0.0
for name, secs, speed, armed, crouch, rate in PHASES:
    print("phase", name)
    t_phase = time.time()
    while time.time() - t_phase < secs:
        t = time.time() - t0
        pt = time.time() - t_phase
        if speed > 0:
            # strafe back and forth across the view so the side/forward cycles both show up
            ang = pt * speed / 70.0
            x = cx + math.cos(ang) * 70
            y = cy + math.sin(ang) * 70
            yaw = math.degrees(ang) + 90
        else:
            yaw = facing_player
        eyeh = 36 if crouch else 64
        flags = 2 if crouch else 0
        weapon = a.weapon if armed else 0
        s.sendall(cmnd(f"amp_s {a.id} {mapname} {t:.3f} {x:.1f} {y:.1f} {center[2]:.1f} {yaw:.1f} 0 {eyeh} {flags} {weapon}"))
        if rate and armed and t - last_fire >= 1.0 / rate:
            last_fire = t
            s.sendall(cmnd(f"amp_f {a.id} {weapon}"))
        if shot_times and t >= shot_times[0]:
            shot_times.pop(0)
            s.sendall(cmnd(f"png_screenshot amp_fake_{name}"))
        pump()
        for line in lines:
            if line.startswith("[AMP]err") or "Script Runtime Error" in line:
                print(line)
        lines.clear()
        time.sleep(0.05 + (random.random() * a.jitter if a.jitter else 0))
print("done")
