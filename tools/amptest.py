"""Dev: helpers for in-game tests over VConsole (one PC, NoVR).

    from amptest import Game
    g = Game()                      # connects to 127.0.0.1:29000
    g.cmd("amp_cfg mp 1")           # console commands
    lines = g.collect(2.0)          # console lines printed in the next 2 s
    g.lua("print(Entities:GetLocalPlayer():GetOrigin())")   # run Lua in the game (prints come back)
    g.shot("name")                  # PNG of the game window into the scratchpad
"""
import os
import re
import socket
import struct
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from grab import find_window, grab  # noqa: E402

VERSION = 0x00D30000
OUT = os.environ.get("AMP_SHOTS", tempfile.gettempdir())
GAME = os.environ.get("HLA_DIR", r"D:\SteamLibrary\steamapps\common\Half-Life Alyx")
PROBE = os.path.join(GAME, "game", "hlvr", "scripts", "vscripts", "alyxmp", "probe_tmp.lua")


def _cmnd(text):
    p = text.encode() + b"\0"
    return b"CMND" + struct.pack(">IHH", VERSION, 12 + len(p), 0) + p


class Game:
    def __init__(self, port=29000):
        self.s = socket.create_connection(("127.0.0.1", port))
        self.s.settimeout(0.02)
        self.buf = b""
        self.lines = []
        self.collect(0.8)   # drop the buffered backlog
        self.lines.clear()

    def cmd(self, *cmds):
        for c in cmds:
            self.s.sendall(_cmnd(c))

    def pump(self):
        try:
            while True:
                c = self.s.recv(1 << 20)
                if not c:
                    break
                self.buf += c
        except (socket.timeout, BlockingIOError):
            pass
        while len(self.buf) >= 12:
            typ, ver, ln, h = struct.unpack(">4sIHH", self.buf[:12])
            if len(self.buf) < ln:
                break
            body, self.buf = self.buf[12:ln], self.buf[ln:]
            if typ == b"PRNT":
                msg = body[28:].split(b"\0", 1)[0].decode("utf-8", "replace")
                self.lines.extend(l for l in msg.splitlines() if "texturebase.cpp" not in l)

    def collect(self, secs):
        end = time.time() + secs
        start = len(self.lines)
        while time.time() < end:
            self.pump()
            time.sleep(0.02)
        return self.lines[start:]

    def wait_for(self, pattern, secs=10):
        rx = re.compile(pattern)
        end = time.time() + secs
        seen = len(self.lines)
        while time.time() < end:
            self.pump()
            for l in self.lines[seen:]:
                if rx.search(l):
                    return l
            seen = len(self.lines)
            time.sleep(0.02)
        return None

    def lua(self, code, secs=1.0):
        """Run Lua in the server VM; returns the lines it printed."""
        with open(PROBE, "w", encoding="utf-8") as f:
            f.write(code)
        self.lines.clear()
        self.cmd("script_reload_code alyxmp/probe_tmp")
        return self.collect(secs)

    def shot(self, name, crop=None, scale=None):
        im = grab(find_window())
        if crop:
            im = im.crop(crop)
        if scale:
            im = im.resize((int(im.size[0] * scale), int(im.size[1] * scale)))
        path = os.path.join(OUT, name + ".png")
        im.save(path)
        return path

    def amp(self, pattern=r"^\[AMP\]"):
        return [l for l in self.lines if re.search(pattern, l)]
