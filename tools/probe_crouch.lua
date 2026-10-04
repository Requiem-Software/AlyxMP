local function log(...) local t = {} for i, v in ipairs({...}) do t[i] = tostring(v) end print("[AMP-CR] " .. table.concat(t, " ")) end
local p = Entities:GetLocalPlayer()
for _, n in ipairs({ "amp_api_b", "amp_api_a", "amp_api_w" }) do local e = Entities:FindByName(nil, n) while e do local nx = Entities:FindByName(e, n) e:Kill() e = nx end end
local fwd = p:GetForwardVector() fwd.z = 0 fwd = fwd:Normalized()
local pos = p:GetOrigin() + fwd * 70
SpawnEntityFromTableAsynchronous("logic_script", { targetname = "amp_precache3", vscripts = "alyxmp/precache_cr.lua" }, function()
    local w = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_api_w", model = "models/characters/workers/worker_m_helmet.vmdl",
        origin = pos.x .. " " .. pos.y .. " " .. pos.z, angles = "0 " .. (p:EyeAngles().y + 150) .. " 0", solid = 0 })
    w:ResetSequence("walk_n")
    log("after reset", w:GetSequence())
    local a = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_api_a", model = "models/characters/alyx/alyx.vmdl", origin = pos.x .. " " .. pos.y .. " " .. pos.z, solid = 0 })
    a:FollowEntity(w, true)
    w:SetRenderAlpha(0)
end, nil)
