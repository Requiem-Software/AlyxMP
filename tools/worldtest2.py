"""Dev: world-sync checks for pickups, breakables, doors and enemy steering (no launcher attached)."""
import os
import re
import shutil
import socket
import struct
import time

HLA = os.environ.get("HLA_DIR", r"D:\SteamLibrary\steamapps\common\Half-Life Alyx")
VS = os.path.join(HLA, "game", "hlvr", "scripts", "vscripts", "alyxmp")
shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe_targets.lua"), os.path.join(VS, "probe_targets.lua"))


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


def run(cmds, wait=0.5):
    global buf
    buf = b""
    for c in cmds:
        s.sendall(cmnd(c))
    pump(wait)
    return buf.decode("utf-8", "replace")


def lua(action, idx=0, wait=0.5):
    open(VS + r"\probe_targets_cfg.lua", "w").write(f'AMP_TEST_ACTION = "{action}"\nAMP_TEST_IDX = {idx}\n')
    return run(["script_reload_code alyxmp/probe_targets_cfg", "script_reload_code alyxmp/probe_targets"], wait)


def grab(text, pat):
    return re.findall(pat, text)


def q(idx):
    return (grab(lua("query", idx, 0.3), r"\[AMP-T\] q [^\n\x00]*") or ["?"])[-1]


pump(1.0)
run(["amp_cfg mp 1", "amp_cfg role client", "amp_cfg id 2"])

# pickups: an item next to us vanishes -> we report it; a reported item vanishes here
lua("bring", 423, 0.8)
out = lua("kill", 423, 0.8)
print("pg send   :", grab(out, r"\[AMP\]w pg[^\n\x00]*"))
run(["amp_w ~ 1 pg 1490 item_hlvr_crafting_currency_small"], 0.4)
print("pg recv   :", q(1490))
run(["amp_w ~ 1 pg 1500 item_healthvial"], 0.4)
print("pg wrong class (must stay):", q(1500))

# breakables
out = lua("smash", 1174, 0.8)
print("bk send   :", grab(out, r"\[AMP\]w bk[^\n\x00]*"), q(1174))
out = run(["amp_w ~ 1 bk 1151"], 0.8)
print("bk recv   :", q(1151), "echo:", grab(out, r"\[AMP\]w bk[^\n\x00]*"))
out = lua("smash", 1518, 0.8)
print("crate send:", grab(out, r"\[AMP\]w (?:bk|pg)[^\n\x00]*"), q(1518))
out = run(["amp_w ~ 1 bk 1303"], 0.8)
print("crate recv:", q(1303), "echo:", grab(out, r"\[AMP\]w bk[^\n\x00]*"))

# door: another player swings door 1082 open
d = q(1082)
print("door before:", d)
m = re.search(r"pos Vector \S+ \[([-\d.]+) ([-\d.]+) ([-\d.]+)\]", d)
x, y, z = (float(v) for v in m.groups())
for i in range(16):
    run([f"amp_w ~ 1 p 1082 {x:.1f} {y:.1f} {z:.1f} 0 {i * 6} 0"], 0.066)
out = run([f"amp_w ~ 1 pr 1082 {x:.1f} {y:.1f} {z:.1f} 0 90 0"], 1.5)
open(VS + r"\probe_jit.lua", "w").write('local e = EntIndexToHScript(1082) print("[AMP-J] door ang " .. tostring(e:GetAngles()))\n')
print("door after :", grab(run(["script_reload_code alyxmp/probe_jit"], 0.3), r"\[AMP-J\][^\n\x00]*"), "echo:", grab(out, r"\[AMP\]w p[^\n\x00]*")[:3])
s.close()
