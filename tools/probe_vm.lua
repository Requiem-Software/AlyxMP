local vms = Entities:FindAllByClassname("viewmodel")
print("[AMP-VM] viewmodels=" .. #vms)
for i, vm in ipairs(vms) do print("[AMP-VM]  " .. i .. " model=" .. tostring(vm:GetModelName()) .. " seq=" .. tostring(vm:GetSequence()) .. " owner=" .. tostring(vm:GetOwner())) end
local p = Entities:GetLocalPlayer()
for _, cls in ipairs({ "weapon_pistol", "hlvr_weapon_energygun", "weapon_shotgun", "weapon_smg1" }) do
    for _, w in ipairs(Entities:FindAllByClassname(cls)) do print("[AMP-VM]  weapon " .. cls .. " owner=" .. tostring(w:GetOwner()) .. " model=" .. w:GetModelName()) end
end
local n, lastSeq, lastCyc = 0, nil, nil
local vm = vms[1]
p:SetThink(function()
    n = n + 1
    for i, v in ipairs(vms) do
        local s, c = v:GetSequence(), v:GetCycle()
        if i == 1 and (s ~= lastSeq or (lastCyc and c < lastCyc - 0.05)) then
            print(string.format("[AMP-VM] t=%.2f vm%d seq=%s cyc=%.2f", Time(), i, tostring(s), c))
            lastSeq, lastCyc = s, c
        elseif i == 1 then lastCyc = c end
    end
    if n > 90 * 4 then return nil end
    return 0
end, "amp_vm_watch", 0)
