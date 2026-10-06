"""Dev: aim at an entity (by index) and press E to pick it up. usage: python tools/aimuse.py <entindex>"""
import math
import subprocess
import sys
import time
import os
from amptest import Game

idx = int(sys.argv[1])
g = Game()
out = g.lua('''
local p=Entities:GetLocalPlayer()
local e=EntIndexToHScript(%d)
local c=e:GetCenter(); local eye=p:EyePosition()
print("AIM", c.x, c.y, c.z, eye.x, eye.y, eye.z)
''' % idx, 1.0)
l = [x for x in out if x.startswith("AIM")][0].split()
cx, cy, cz, ex, ey, ez = map(float, l[1:])
dx, dy, dz = cx - ex, cy - ey, cz - ez
yaw = math.degrees(math.atan2(dy, dx))
pitch = -math.degrees(math.atan2(dz, math.hypot(dx, dy)))
g.cmd("setang_exact %.2f %.2f 0" % (pitch, yaw))
g.collect(0.4)
subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "keys.py"), "E"], capture_output=True)
time.sleep(0.8)
out = g.lua('''
local e=EntIndexToHScript(%d)
print("PU", e:Attribute_GetIntValue("picked_up",-1), e:GetAngles())
''' % idx, 1.0)
print("\n".join(l for l in out if l.startswith("PU")))
