local function log(...) local t = {} for i, v in ipairs({...}) do t[i] = tostring(v) end print("[AMP-GUN] " .. table.concat(t, " ")) end
local p = Entities:GetLocalPlayer()
local e = Entities:FindByName(nil, "amp_gun") while e do local n = Entities:FindByName(e, "amp_gun") e:Kill() e = n end
local fwd = p:GetForwardVector() fwd.z = 0 fwd = fwd:Normalized()
local right = Vector(fwd.y, -fwd.x, 0)
local setups = {
    { "combatidle", "models/weapons/vr_alyxgun/vr_alyxgun.vmdl", "particles/weapon_fx/muzzleflash_pistol.vpcf", "AlyxPistol.Fire" },
    { "idle_rifle_up", "models/weapons/vr_ipistol/vr_ipistol.vmdl", "particles/weapon_fx/muzzleflash_player_rapidfire.vpcf", "CombineSMG.Fire" },
    { "shoot_01", "models/weapons/w_ipistol/ipistol_wm.vmdl", "particles/weapon_fx/muzzleflash_smg_heavy.vpcf", "CombineSMG.Fire" },
    { "sprint_alt_n", "models/weapons/vr_shotgun/vr_flip_shotgun_body.vmdl", "particles/weapon_fx/muzzleflash_heavy_shotgun.vpcf", "CombineShotgun.Fire" },
}
log("PATTACH_POINT_FOLLOW", PATTACH_POINT_FOLLOW, "PATTACH_POINT", PATTACH_POINT)
SpawnEntityFromTableAsynchronous("logic_script", { targetname = "amp_gun", vscripts = "alyxmp/precache_gun.lua" }, function()
    local guns = {}
    for i, s in ipairs(setups) do
        local pos = p:GetOrigin() + fwd * 130 + right * ((i - 2.5) * 50)
        local rig = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_gun", model = "models/characters/combine_grunt/combine_grunt.vmdl",
            origin = pos.x .. " " .. pos.y .. " " .. pos.z, angles = "0 " .. (p:EyeAngles().y + 200) .. " 0", solid = 0 })
        rig:ResetSequence(s[1])
        local a = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_gun", model = "models/characters/alyx/alyx.vmdl", origin = pos.x .. " " .. pos.y .. " " .. pos.z, solid = 0 })
        a:FollowEntity(rig, true)
        rig:SetRenderAlpha(0)
        local w = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_gun", model = s[2], origin = pos.x .. " " .. pos.y .. " " .. pos.z, solid = 0 })
        w:FollowEntity(rig, true)
        log(s[1], s[2], "muzzle att", w:ScriptLookupAttachment("muzzle"))
        guns[i] = { w = w, fx = s[3], snd = s[4] }
    end
    p:SetThink(function()
        for _, g in ipairs(guns) do
            local idx = ParticleManager:CreateParticle(g.fx, PATTACH_POINT_FOLLOW, g.w)
            ParticleManager:SetParticleControlEnt(idx, 0, g.w, PATTACH_POINT_FOLLOW, "muzzle", Vector(0, 0, 0), true)
            ParticleManager:ReleaseParticleIndex(idx)
            StartSoundEvent(g.snd, g.w)
        end
        SendToConsole("png_screenshot amp_gun_fire")
        log("fired")
        return nil
    end, "amp_gun_fire", 1.5)
end, nil)
