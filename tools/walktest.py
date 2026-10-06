"""Dev: walk the NoVR player through a fake avatar (holding W) and report how far they got."""
import sys, time, subprocess
from amptest import Game
g = Game()
AV = (700, 1290, -208)
t0 = time.time()
def feed():
    g.cmd(f"amp_s 2 a2_headcrabs_tunnel {time.time()-t0+5000:.3f} {AV[0]} {AV[1]} {AV[2]} 180 0 64 0 1")
for _ in range(10): feed(); time.sleep(0.05)
# start 110 units in front of the avatar, facing it
g.cmd(f"setpos_exact {AV[0]-110} {AV[1]} -200", "setang 0 0 0")
time.sleep(1.0)
for _ in range(5): feed(); time.sleep(0.05)
before = [l for l in g.lua('print("P", Entities:GetLocalPlayer():GetOrigin().x)', 0.4) if l.startswith("P\t")]
proc = subprocess.Popen([sys.executable, "keys.py", "--hold", "2.0", "W"])
end = time.time() + 3.6
while time.time() < end:
    feed(); time.sleep(0.05)
proc.wait()
after = [l for l in g.lua('print("P", Entities:GetLocalPlayer():GetOrigin().x, Entities:GetLocalPlayer():GetOrigin().y)', 0.4) if l.startswith("P\t")]
print("start x", before, "end", after, "(avatar at x=%d; passing through means end x > %d)" % (AV[0], AV[0] + 20))
