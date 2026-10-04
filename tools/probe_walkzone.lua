-- dev: put the player on the floor just outside, then inside a changelevel trigger (alternates each run)
local t = Entities:FindByName(nil, AMP_WALK_TARGET or "to_tunnels")
local p = Entities:GetLocalPlayer()
local o = t:GetOrigin()
local mins, maxs = o + t:GetBoundingMins(), o + t:GetBoundingMaxs()
local c = (mins + maxs) * 0.5
AMP_WALK_STEP = (AMP_WALK_STEP or 0) + 1
local xy
if AMP_WALK_STEP % 2 == 1 then
    xy = Vector(c.x + (maxs.x - mins.x) * 0.5 + 100, c.y, c.z)
else
    xy = Vector(c.x, c.y, c.z)
end
local tr = { startpos = xy, endpos = xy - Vector(0, 0, 400), ignore = p, mask = 33636363 }
TraceLine(tr)
local dest = tr.hit and (tr.pos + Vector(0, 0, 2)) or xy
p:SetOrigin(dest)
print("[AMP-W] " .. (AMP_WALK_STEP % 2 == 1 and "outside " or "inside ") .. tostring(dest) .. " floor=" .. tostring(tr.hit))
