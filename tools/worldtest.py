"""Dev: exercise the world-sync module in a running game (no launcher attached).

Plays the part of the launcher: sends amp_w batches as if another player sent them, and watches the
"[AMP]w" lines our game sends out when local things change.
"""
import os
import re
import socket
import struct
import time

HLA = os.environ.get("HLA_DIR", r"D:\SteamLibrary\steamapps\common\Half-Life Alyx")
VS = os.path.join(HLA, "game", "hlvr", "scripts", "vscripts", "alyxmp")


def cmnd(t):
    p = t.encode() + b"\0"
    return b"CMND" + struct.pack(">IHH", 0x00D30000, 12 + len(p), 0) + p


s = socket.create_connection(("127.0.0.1", 29000))
s.settimeout(0.05)
buf = b""


def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        try:
            c = s.recv(1 << 20)
            if c:
                buf += c
        except socket.timeout:
            pass


def run(cmds, wait=0.6):
    global buf
    buf = b""
    for c in cmds:
        s.sendall(cmnd(c))
    pump(wait)
    return buf.decode("utf-8", "replace")


def lua(action, idx=0, wait=0.6):
    open(VS + r"\probe_targets_cfg.lua", "w").write(f'AMP_TEST_ACTION = "{action}"\nAMP_TEST_IDX = {idx}\n')
    return run(["script_reload_code alyxmp/probe_targets_cfg", "script_reload_code alyxmp/probe_targets"], wait)


def lines(text, tag):
    return [l for l in re.findall(r"\[AMP[^\]]*\][^\n\x00]*", text) if l.startswith(tag)]


pump(1.0)
run(["amp_cfg mp 1", "amp_cfg role client", "amp_cfg id 2"])
out = lua("list")
info = {}
for l in lines(out, "[AMP-T]"):
    parts = l.split()
    info[parts[1]] = parts[2:]
print("targets:", info)
prop = int(info["prop"][0])
zombie = int(info["zombie"][0])
trig = info["trigger"][0]

# 1) a remote player moves a physics object: ours should freeze and follow, then rest where they left it
q = lua("query", prop)
m = re.search(r"pos Vector \S+ \[([-\d.]+) ([-\d.]+) ([-\d.]+)\]", q)
x0, y0, z0 = (float(v) for v in m.groups())
for i in range(20):
    run([f"amp_w ~ 1 p {prop} {x0:.1f} {y0:.1f} {z0 + 30 + i * 2:.1f} 0 {i * 9} 0"], 0.05)
mid = lua("query", prop)
run([f"amp_w ~ 1 pr {prop} {x0 + 20:.1f} {y0:.1f} {z0 + 2:.1f} 0 180 0"], 0.3)
end = lua("query", prop, 1.0)
print("1) remote prop  mid:", lines(mid, "[AMP-T] q")[-1][30:], "\n            end:", lines(end, "[AMP-T] q")[-1][30:])

# 2) host says the zombie has 20 hp
run([f"amp_w ~ 1 nh {zombie} 20"], 0.4)
print("2) npc health :", lines(lua("query", zombie), "[AMP-T] q")[-1][30:])

# 3) we hurt the zombie locally -> we must report the damage for the host
out = lua("hurt", zombie, 0.6)
print("3) damage sent:", lines(out, "[AMP]w nd"))

# 4) we push a prop locally -> we stream it, then report it at rest
out = lua("push", prop, 2.5)
ws = lines(out, "[AMP]w p ")
print(f"4) local prop : {len(ws)} updates, rest:", lines(out, "[AMP]w pr")[:1])

# 5) a remote story trigger
run([f"amp_w ~ 1 tg {trig}"], 0.5)
print("5) trigger    :", lines(lua("query", int(trig[1:])), "[AMP-T] q")[-1])
s.close()
