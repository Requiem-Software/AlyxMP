"""Dev: send console commands to the running game over VConsole and print matching output lines.
usage: python tools/vc.py [--wait SECONDS] [--grep REGEX] "cmd1" "cmd2" ...
"""
import re, socket, struct, sys, time
args = sys.argv[1:]
wait, pat = 1.0, r"\[AMP[^\]]*\][^\n\x00]*|[^\n\x00]*rror[^\n\x00]*"
while args and args[0].startswith("--"):
    if args[0] == "--wait": wait = float(args[1]); args = args[2:]
    elif args[0] == "--grep": pat = args[1]; args = args[2:]
def cmnd(t):
    p = t.encode() + b"\0"
    return b"CMND" + struct.pack(">IHH", 0x00D30000, 12 + len(p), 0) + p
s = socket.create_connection(("127.0.0.1", 29000)); s.settimeout(0.05)
buf = b""
def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        try:
            c = s.recv(1 << 20)
            if c: buf += c
        except socket.timeout: pass
pump(0.8); buf = b""
for c in args: s.sendall(cmnd(c))
pump(wait)
for l in re.findall(pat, buf.decode("utf-8", "replace")): print(l.strip())
