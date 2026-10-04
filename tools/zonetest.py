"""Dev: run the loading-zone flow against the game: arm + enter a trigger, show host status, then go."""
import os
import re
import socket
import struct
import subprocess
import sys
import time

HERE = sys.argv[1] if len(sys.argv) > 1 else "a2_quarantine_entrance"
NEXT = sys.argv[2] if len(sys.argv) > 2 else "a2_pistol"
TARGET = sys.argv[3] if len(sys.argv) > 3 else "to_tunnels"
CAP = os.environ.get("TEMP", ".")  # where screenshots go


def cmnd(t):
    p = t.encode() + b"\0"
    return b"CMND" + struct.pack(">IHH", 0x00D30000, 12 + len(p), 0) + p


class Con:
    def __init__(self):
        self.buf = b""
        self.connect()

    def connect(self):
        for _ in range(60):
            try:
                self.s = socket.create_connection(("127.0.0.1", 29000), timeout=2)
                self.s.settimeout(0.05)
                return
            except OSError:
                time.sleep(1)
        raise SystemExit("no vconsole")

    def send(self, t):
        try:
            self.s.sendall(cmnd(t))
        except OSError:
            self.connect()
            self.s.sendall(cmnd(t))

    def pump(self, sec):
        end = time.time() + sec
        while time.time() < end:
            try:
                c = self.s.recv(1 << 20)
                if c:
                    self.buf += c
            except socket.timeout:
                pass
            except OSError:
                time.sleep(0.5)
                self.connect()

    def wait_for(self, pattern, sec):
        end = time.time() + sec
        while time.time() < end:
            self.pump(0.5)
            if re.search(pattern, self.buf):
                return True
        return False


def capture(name):
    subprocess.run(["powershell", "-ExecutionPolicy", "Bypass", "-File", "tools/capture.ps1", "-Process", "hlvr", "-Out", CAP + "\\" + name + ".png"], capture_output=True)


c = Con()
c.pump(1.5)
c.buf = b""
c.send("amp_hello")
print("mod ready:", c.wait_for((r"\[AMP\]s " + HERE).encode(), 20))
c.send("script_reload_code alyxmp/settarget")
c.send("amp_cfg mp 1")
c.send("amp_p 7 Bob")
c.pump(0.5)
c.send("script_reload_code alyxmp/probe_walkzone")
c.pump(2.0)
c.send("script_reload_code alyxmp/probe_walkzone")
c.pump(2.5)
zones = re.findall(rb"\[AMP\]z (\S+)", c.buf)
print("walk:", [m.decode() for m in re.findall(rb"\[AMP-W\] \w+", c.buf)], "zones:", [z.decode() for z in zones])
zid = zones[-1].decode() if zones else None
if not zid or zid == "-":
    raise SystemExit("not in a zone")
c.send(f"amp_zs {zid} 1 2 Bob")
c.pump(1.0)
capture("zone_wait")
c.buf = b""
c.send(f"amp_go {zid}")
print("going:", c.wait_for(rb"\[AMP\]going", 5))
print("new level ready:", c.wait_for((r"\[AMP\]ready " + NEXT).encode(), 90))
capture("zone_after")
for m in re.findall(rb"\[AMP\](?:going|chl|err|ready|hello)[^\n\x00]*", c.buf):
    print("  ", m.decode()[:120])
