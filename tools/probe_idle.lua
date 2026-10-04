local p = Entities:GetLocalPlayer()
local e = Entities:FindByName(nil, "amp_idle") while e do local n = Entities:FindByName(e, "amp_idle") e:Kill() e = n end
local fwd = p:GetForwardVector() fwd.z = 0 fwd = fwd:Normalized()
local right = Vector(fwd.y, -fwd.x, 0)
local cases = {
    { "A reset", "idle_subtle", true, false },
    { "B move", "idle_subtle", false, true },
    { "C neutral reset+move", "idle_neutral_01", true, true },
    { "D subtle reset+move", "idle_subtle", true, true },
}
for i, c in ipairs(cases) do
    local pos = p:GetOrigin() + fwd * 140 + right * ((i - 2.5) * 44)
    local rig = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_idle", model = "models/characters/citizens/citizen_female_01.vmdl",
        origin = pos.x .. " " .. pos.y .. " " .. pos.z, angles = "0 " .. (p:EyeAngles().y + 180) .. " 0", DefaultAnim = c[2], solid = 0 })
    local a = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_idle", model = "models/characters/alyx/alyx.vmdl", origin = pos.x .. " " .. pos.y .. " " .. pos.z, solid = 0 })
    a:FollowEntity(rig, true)
    rig:SetRenderAlpha(0)
    if c[3] then rig:ResetSequence(c[2]) end
    if c[4] then
        local yaw = p:EyeAngles().y + 180
        rig:SetThink(function() rig:SetOrigin(pos) rig:SetAngles(0, yaw, 0) return 0 end, "mv", 0)
    end
    DebugDrawText(pos + Vector(0, 0, 80), c[1], false, 10)
end
print("[AMP-IDLE] ok")
