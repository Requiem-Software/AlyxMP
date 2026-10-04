local p = Entities:GetLocalPlayer()
local fwd = p:GetForwardVector() fwd.z = 0 fwd = fwd:Normalized()
local pos = p:GetOrigin() + fwd * 120
SpawnEntityFromTableAsynchronous("logic_script", { targetname = "amp_t_pre", vscripts = "alyxmp/precache.lua" }, function()
    local rig = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_t_rig", model = "models/characters/citizens/citizen_female_01.vmdl",
        origin = pos.x .. " " .. pos.y .. " " .. pos.z, DefaultAnim = "walk_n", solid = 0 })
    local a = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_t_alyx", model = "models/characters/alyx/alyx.vmdl", origin = pos.x .. " " .. pos.y .. " " .. pos.z, solid = 0 })
    a:FollowEntity(rig, true)
    rig:SetRenderAlpha(0)
    print("[AMP-T] bonemerge pair spawned")
end, nil)
