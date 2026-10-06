"""Dev: look at and click the launcher's / setup's windows.

  python tools/ui.py shot "Alyx Multiplayer" name        PNG of a window (exact title) into %TEMP%
  python tools/ui.py click "Alyx Multiplayer" 452 40     click at client coordinates (as in the screenshot)
  python tools/ui.py close "Alyx Multiplayer"            ask the window to close
  python tools/ui.py list                                visible window titles
"""
import ctypes
import os
import sys
import tempfile
import time
from ctypes import wintypes

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from grab import grab  # noqa: E402

user32 = ctypes.windll.user32


def windows():
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _):
        n = user32.GetWindowTextLengthW(hwnd)
        if n and user32.IsWindowVisible(hwnd):
            buf = ctypes.create_unicode_buffer(n + 1)
            user32.GetWindowTextW(hwnd, buf, n + 1)
            found.append((hwnd, buf.value))
        return True

    user32.EnumWindows(cb, 0)
    return found


def find(title):
    for hwnd, t in windows():
        if t == title:
            return hwnd
    return None


def front(hwnd):
    user32.keybd_event(0x12, 0, 0, 0)
    user32.keybd_event(0x12, 0, 2, 0)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.25)


def click(hwnd, x, y):
    front(hwnd)
    pt = wintypes.POINT(x, y)
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    user32.SetCursorPos(pt.x, pt.y)
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.05)
    user32.mouse_event(0x0004, 0, 0, 0, 0)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "list":
        for _, t in windows():
            print(t)
        sys.exit(0)
    h = find(sys.argv[2])
    if not h:
        print("no window", sys.argv[2])
        sys.exit(1)
    if cmd == "shot":
        path = os.path.join(tempfile.gettempdir(), sys.argv[3] + ".png")
        grab(h).save(path)
        print(path)
    elif cmd == "click":
        click(h, int(sys.argv[3]), int(sys.argv[4]))
    elif cmd == "close":
        user32.PostMessageW(h, 0x0010, 0, 0)
