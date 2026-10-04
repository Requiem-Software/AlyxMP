local A = AMP
local n = 0
for id, pp in pairs(A.puppets) do
    n = n + 1
    local function d(e) if not e then return "nil" end if not IsValidEntity(e) then return "INVALID" end return e:GetModelName() .. "@" .. tostring(e:GetOrigin()) .. " parent=" .. tostring(e:GetMoveParent() and e:GetMoveParent():GetModelName()) end
    print("[AMP-PP] id=" .. id .. " name=" .. tostring(pp.name) .. " map=" .. tostring(pp.map) .. " rig=" .. tostring(pp.rig) .. " seq=" .. tostring(pp.seq) .. " snaps=" .. #pp.snaps .. " weapon=" .. tostring(pp.weaponCode))
    print("[AMP-PP]   alyx " .. d(pp.alyx))
    if pp.rigs then for k, r in pairs(pp.rigs) do print("[AMP-PP]   rig " .. k .. " " .. d(r)) end end
    print("[AMP-PP]   weapon " .. d(pp.weaponEnt))
end
print("[AMP-PP] puppets=" .. n .. " ready=" .. tostring(A.ready) .. " map=" .. tostring(A.map))
