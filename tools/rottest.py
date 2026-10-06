"""Dev: test turning a carried object with the right mouse button (NoVR). Pick something up first.
usage: python tools/rottest.py <entindex> [yaw_px] [pitch_px]"""
import sys
import time
from amptest import Game
from keys import find_game, focus, press

idx = int(sys.argv[1])
yaw_px = int(sys.argv[2]) if len(sys.argv) > 2 else 600
pitch_px = int(sys.argv[3]) if len(sys.argv) > 3 else 0
SAMPLE = '''
local c=AMP.carry; local p=Entities:GetLocalPlayer(); local e=EntIndexToHScript(%d)
local v=p:EyeAngles()
local f,u=e:GetForwardVector(),e:GetUpVector()
-- the object's axes relative to the way you face
local cy,sy=math.cos(math.rad(v.y)),math.sin(math.rad(v.y))
local function ps(a) return string.format("(%%.2f %%.2f %%.2f)", a.x*cy+a.y*sy, -a.x*sy+a.y*cy, a.z) end
local d=e:GetCenter()-p:EyePosition()
print("R", c and (c.turning and "turning" or "carry") or "-", e:Attribute_GetIntValue("picked_up",-1), "F", ps(f), "U", ps(u),
  "V", string.format("%%.3f %%.3f", v.x, v.y), "D", ps(d))
''' % idx

g = Game()


def st(tag):
    out = g.lua(SAMPLE, 0.35)
    print(tag.ljust(9), *[l for l in out if l.startswith("R") or "rror" in l])


def move(dx, dy):
    n = max(1, max(abs(dx), abs(dy)) // 30)
    for _ in range(n):
        press("MOVE:%d:%d" % (dx // n, dy // n))
        time.sleep(0.025)
    time.sleep(0.3)


st("before")
focus(find_game())
press("M2DOWN")
time.sleep(0.3)
st("down")
move(yaw_px, pitch_px)
st("turned")
g.shot("rot_during", scale=0.5)
press("M2UP")
time.sleep(0.6)
st("released")
move(300, 0)
st("looked")
g.shot("rot_after", scale=0.5)
g.cmd("bind E")
print([l for l in g.collect(0.4) if '"E"' in l])
