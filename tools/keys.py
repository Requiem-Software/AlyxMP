"""Dev: bring the game window to the front and press keys in it.

  python tools/keys.py ESCAPE            (names from VK below, or a single letter/digit)
  python tools/keys.py F10 --hold 0.1
"""
import ctypes
import sys
import time
from ctypes import wintypes

user32 = ctypes.windll.user32
VK = {"ESCAPE": 0x1B, "F10": 0x79, "RETURN": 0x0D, "SPACE": 0x20, "UP": 0x26, "DOWN": 0x28, "TAB": 0x09,
      "F5": 0x74, "F9": 0x78, "MENU": 0x12, "BACK": 0x08}


def find_game():
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _):
        n = user32.GetWindowTextLengthW(hwnd)
        if n and user32.IsWindowVisible(hwnd):
            buf = ctypes.create_unicode_buffer(n + 1)
            user32.GetWindowTextW(hwnd, buf, n + 1)
            if buf.value == "Half-Life: Alyx":
                found.append(hwnd)
        return True

    user32.EnumWindows(cb, 0)
    return found[0] if found else None


def focus(hwnd):
    # Windows only lets the foreground process hand focus over; a tap of ALT unlocks it
    user32.keybd_event(VK["MENU"], 0, 0, 0)
    user32.keybd_event(VK["MENU"], 0, 2, 0)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.3)
    return user32.GetForegroundWindow() == hwnd


def press(name, hold=0.08):
    if name.upper() == "MOUSE1":
        user32.mouse_event(0x0002, 0, 0, 0, 0)
        time.sleep(hold)
        user32.mouse_event(0x0004, 0, 0, 0, 0)
        return
    vk = VK.get(name.upper()) or ord(name.upper())
    scan = user32.MapVirtualKeyW(vk, 0)
    user32.keybd_event(vk, scan, 0, 0)
    time.sleep(hold)
    user32.keybd_event(vk, scan, 2, 0)


if __name__ == "__main__":
    hold = 0.08
    keys = []
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--hold":
            hold = float(args.pop(0))
        else:
            keys.append(a)
    h = find_game()
    print("focused" if h and focus(h) else "could not focus the game")
    for k in keys:
        press(k, hold)
        time.sleep(0.2)
