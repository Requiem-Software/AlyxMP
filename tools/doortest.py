"""Dev: measure door sync. Logs a door's yaw over time and every world-sync message, with timestamps.

  python tools/doortest.py open DOOR HANDLE        press E on the handle locally, record what we send
  python tools/doortest.py replay DOOR FILE        replay recorded messages as player 1, log our door
  python tools/doortest.py reset DOOR YAW          put the door back (closed) for the next run
"""
import json
import os
import re
import socket
import struct
import sys
import time

HLA = os.environ.get("HLA_DIR", r"D:\SteamLibrary\steamapps\common\Half-Life Alyx")
VS = os.path.join(HLA, "game", "hlvr", "scripts", "vscripts", "alyxmp")
OUT = os.path.join(os.environ.get("TEMP", "."), "door_sent.json")


def cmnd(t):
    p = t.encode() + b"\0"
    return b"CMND" + struct.pack(">IHH", 0x00D30000, 12 + len(p), 0) + p


s = socket.create_connection(("127.0.0.1", 29000))
s.settimeout(0.01)
pending = [b""]
LINE = re.compile(rb"\[AMP[^\]]*\].*")


def lines_for(sec):
    """(time, line) for every [AMP...] console line that arrives within sec seconds"""
    out, end = [], time.time() + sec
    while time.time() < end:
        try:
            c = s.recv(1 << 20)
        except socket.timeout:
            continue
        now = time.time()
        parts = re.split(rb"[\n\x00]", pending[0] + c)
        pending[0] = parts.pop()  # incomplete tail
        for part in parts:
            m = LINE.search(part)
            if m:
                out.append((now, m.group(0).decode("utf-8", "replace")))
    return out


def lua(code):
    open(os.path.join(VS, "probe_tmp.lua"), "w").write(code)
    s.sendall(cmnd("script_reload_code alyxmp/probe_tmp"))


def start_log(door, secs, press=0):
    lua(f"""
local door = EntIndexToHScript({door})
local p = Entities:GetLocalPlayer()
local t0 = Time()
local logger = Entities:FindByName(nil, "amp_dlogger") or SpawnEntityFromTableSynchronous("info_target", {{ targetname = "amp_dlogger" }})
logger:SetThink(function()
    local t = Time() - t0
    if t > {secs} then return nil end
    print(string.format("[AMP-L] %.3f yaw %.1f", t, door:GetAngles().y))
    return 0.05
end, "amp_dlog", 0)
if {press} > 0 then
    DoEntFireByInstanceHandle(EntIndexToHScript({press}), "RunScriptFile", "useextra", 0, p, p)
end
""")


def yaws_of(got, t0):
    out = []
    for t, l in got:
        m = re.match(r"\[AMP-L\] (\S+) yaw (\S+)", l)
        if m:
            out.append((float(m.group(1)), float(m.group(2))))
    return out


lines_for(0.5)
for c in ["amp_cfg mp 1", "amp_cfg role client", "amp_cfg id 2"]:
    s.sendall(cmnd(c))
mode, door = sys.argv[1], int(sys.argv[2])

if mode == "open":
    handle = int(sys.argv[3])
    t0 = time.time()
    start_log(door, 5, handle)
    got = lines_for(5.5)
    sent = [(round(t - t0, 3), l[len("[AMP]w "):]) for t, l in got if l.startswith("[AMP]w ")]
    json.dump(sent, open(OUT, "w"))
    kinds = {}
    for _, m in sent:
        kinds[m.split()[0]] = kinds.get(m.split()[0], 0) + 1
    print(f"{len(sent)} messages sent {kinds}  (saved to {OUT})")
    for t, m in sent[:4]:
        print(f"  t={t:.2f}s  {m[:90]}")
    if len(sent) > 4:
        print(f"  ... t={sent[-1][0]:.2f}s  {sent[-1][1][:90]}")
    ys = yaws_of(got, t0)
    print("local door yaw:", " ".join(f"{t:.1f}:{y:.0f}" for t, y in ys[::4]))
elif mode == "replay":
    sent = json.load(open(sys.argv[3]))
    start_log(door, 5)
    t0 = time.time()
    got = []
    for t, m in sent:
        while time.time() - t0 < t:
            got += lines_for(0.004)
        s.sendall(cmnd("amp_w ~ 1 " + m))
    got += lines_for(max(0.5, 5.3 - (time.time() - t0)))
    ys = yaws_of(got, t0)
    print(f"replayed {len(sent)} messages; our door's yaw over time:")
    print(" ".join(f"{t:.1f}:{y:.0f}" for t, y in ys[::3]))
    errs = [l for _, l in got if l.startswith("[AMP]err")]
    if errs:
        print("errors:", errs[:3])
elif mode == "reset":
    yaw = float(sys.argv[3])
    lua(f"""
local d = EntIndexToHScript({door})
d:SetAngles(0, {yaw}, 0)
d:SetAbsAngles(0, {yaw}, 0)
print("[AMP-L] reset " .. tostring(d:GetAngles()))
""")
    print([l for _, l in lines_for(1.0) if "reset" in l])
