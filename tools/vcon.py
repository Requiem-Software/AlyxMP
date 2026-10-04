"""Dev helper: talk to Half-Life: Alyx over the VConsole2 TCP protocol (launch the game with -vconsole).

usage: python vcon.py [--port 29000] [--wait SECONDS] [--grep TEXT] [--raw] "cmd1" "cmd2" ...
"""
import argparse
import socket
import struct
import time

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=29000)
ap.add_argument("--wait", type=float, default=2.0)
ap.add_argument("--grep", default=None)
ap.add_argument("--raw", action="store_true", help="dump non-PRNT chunks too")
ap.add_argument("cmds", nargs="*")
a = ap.parse_args()


def cmnd(text):
    payload = text.encode("utf-8") + b"\0"
    return b"CMND" + struct.pack(">IHH", 0x00D30000, 12 + len(payload), 0) + payload


s = socket.create_connection(("127.0.0.1", a.port), timeout=5)
s.settimeout(0.1)
for c in a.cmds:
    s.sendall(cmnd(c))

buf = b""
end = time.time() + a.wait
while time.time() < end:
    try:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    except socket.timeout:
        pass
    while len(buf) >= 12:
        typ, ver, ln, handle = struct.unpack(">4sIHH", buf[:12])
        if ln < 12 or len(buf) < ln:
            break
        body, buf = buf[12:ln], buf[ln:]
        t = typ.decode("ascii", "replace")
        if t == "PRNT":
            # channel id (4) + 24 bytes of metadata, then a NUL-terminated message
            msg = body[28:].split(b"\0", 1)[0].decode("utf-8", "replace").rstrip("\n")
            for line in msg.splitlines() or [""]:
                if a.grep is None or a.grep in line:
                    print(line)
        elif a.raw:
            print(f"<{t} v={ver:#010x} len={ln} h={handle}> {body[:64]!r}")
s.close()
