"""Dev: as a client, tell our copy of an enemy which player the host's copy is after and check it follows."""
import time
from amptest import Game
g = Game()
g.cmd("amp_cfg mp 1", "amp_cfg role client", "amp_cfg id 2", "amp_p 1 Host", "setpos_exact 600 1330 -200", "setang 0 40 0")
AV = (560, 1420, -208)
t0 = time.time()
def feed():
    g.cmd(f"amp_s 1 a2_headcrabs_tunnel {time.time()-t0+1000:.3f} {AV[0]} {AV[1]} {AV[2]} 0 0 64 0 1")
for _ in range(10): feed(); time.sleep(0.05)
out = g.lua(r'''
for _, e in ipairs(Entities:FindAllByName("amp_c1")) do e:Kill() end
local s = SpawnEntityFromTableSynchronous("npc_combine_s", { targetname = "amp_c1", origin = "720 1460 -200", angles = "0 200 0" })
print("REF", AMP.World.RefOf(s))
''', 0.4)
REF = [l.split("\t")[1] for l in out if l.startswith("REF")][0]
probe = r'''
local p = Entities:GetLocalPlayer(); local t = Entities:FindByName(nil, "amp_target_1")
print("ST", p:GetHealth(), t and t:GetHealth() or -1)
if p:GetHealth() < 70 then DoEntFireByInstanceHandle(p, "SetHealth", "100", 0, nil, nil) end
'''
open(r"D:\SteamLibrary\steamapps\common\Half-Life Alyx\game\hlvr\scripts\vscripts\alyxmp\probe_d.lua", "w").write(probe)
def phase(target, secs):
    g.lines.clear()
    end = time.time() + secs; k = 0
    while time.time() < end:
        feed(); k += 1
        if k % 3 == 0:
            g.cmd(f"amp_w ~ 1 ne {REF} {target}")
            g.cmd("script_reload_code alyxmp/probe_d")
        time.sleep(0.1); g.pump()
    st = [l.split("\t") for l in g.lines if l.startswith("ST\t")]
    hp = [int(s[1]) for s in st]; th = [int(s[2]) for s in st]
    player_hits = sum(1 for a, b in zip(hp, hp[1:]) if b < a)
    avatar_dmg = (th[0] - th[-1]) if th and th[0] > 0 else None
    return player_hits, avatar_dmg, hp[-3:], th[-1:] if th else None
print("ref", REF)
print("after host (1): player hits, avatar damage:", phase(1, 10))
print("after me (2):   player hits, avatar damage:", phase(2, 10))
print("errors:", [l for l in g.lines if "[AMP]err" in l or "Script Runtime" in l][:4])
g.lua('for _, e in ipairs(Entities:FindAllByName("amp_c1")) do e:Kill() end', 0.3)
