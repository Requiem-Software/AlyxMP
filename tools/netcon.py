"""Dev helper: send console commands to Half-Life: Alyx over -netconport and print what comes back.

usage: python netcon.py [--port 2121] [--pass PW] [--wait SECONDS] [--grep TEXT] "cmd1" "cmd2" ...
"""
import argparse
import socket
import time

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=2121)
ap.add_argument("--pass", dest="pw", default=None)
ap.add_argument("--wait", type=float, default=2.0)
ap.add_argument("--grep", default=None)
ap.add_argument("cmds", nargs="*")
a = ap.parse_args()

s = socket.create_connection(("127.0.0.1", a.port), timeout=5)
s.settimeout(0.2)
if a.pw:
    s.sendall(f"PASS {a.pw}\n".encode())
for c in a.cmds:
    s.sendall((c + "\n").encode())
buf = b""
end = time.time() + a.wait
while time.time() < end:
    try:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    except socket.timeout:
        pass
s.close()
text = buf.decode("utf-8", "replace")
for line in text.splitlines():
    if a.grep is None or a.grep in line:
        print(line)
