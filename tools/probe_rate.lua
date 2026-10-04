local p = Entities:GetLocalPlayer()
local fwd = p:GetForwardVector() fwd.z = 0 fwd = fwd:Normalized()
local right = Vector(fwd.y, -fwd.x, 0)
for _, n in ipairs({ "amp_rate" }) do local e = Entities:FindByName(nil, n) while e do local nx = Entities:FindByName(e, n) e:Kill() e = nx end end
local rigs = {}
SpawnEntityFromTableAsynchronous("logic_script", { targetname = "amp_rate", vscripts = "alyxmp/precache.lua" }, function()
    for i, rate in ipairs({ 1.0, 2.0, 0.4 }) do
        local pos = p:GetOrigin() + fwd * 130 + right * ((i - 2) * 45)
        local r = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_rate", model = "models/characters/citizens/citizen_female_01.vmdl",
            origin = pos.x .. " " .. pos.y .. " " .. pos.z, angles = "0 " .. (p:EyeAngles().y + 90) .. " 0", DefaultAnim = "walk_n", solid = 0 })
        DoEntFireByInstanceHandle(r, "SetPlaybackRate", tostring(rate), 0, nil, nil)
        rigs[i] = r
    end
    local t0 = Time()
    p:SetThink(function()
        local out = {}
        for i, r in ipairs(rigs) do table.insert(out, string.format("%.2f", r:GetCycle())) end
        print(string.format("[AMP-RATE] t=%.2f cycles %s", Time() - t0, table.concat(out, " ")))
        if Time() - t0 > 1.2 then return nil end
        return 0.4
    end, "amp_rate_watch", 0.2)
end, nil)
