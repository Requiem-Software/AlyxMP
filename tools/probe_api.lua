local function log(...) local t = {} for i, v in ipairs({...}) do t[i] = tostring(v) end print("[AMP-API] " .. table.concat(t, " ")) end
local p = Entities:GetLocalPlayer()
log("IsValidEntity", type(IsValidEntity), "EntIndexToHScript", type(EntIndexToHScript), "TraceHull", type(TraceHull), "TraceLine", type(TraceLine))
log("DebugDrawBox", type(DebugDrawBox), "DebugDrawText", type(DebugDrawText), "GlobalSys", type(GlobalSys), "FrameTime", type(FrameTime))
log("player IsNPC", type(p.IsNPC), "GetHMDAnchor", type(p.GetHMDAnchor), "GetVelocity", type(p.GetVelocity), "GetHealth", p:GetHealth(), "EntIdx", p:GetEntityIndex())
log("w", GlobalSys:CommandLineInt("-w", -1), "h", GlobalSys:CommandLineInt("-h", -1), "novr", GlobalSys:CommandLineCheck("-novr"))
local anchor = p:GetHMDAnchor()
log("anchor", anchor and anchor:GetClassname(), anchor and anchor:GetOrigin())
log("player origin", p:GetOrigin(), "eye", p:EyePosition(), "vel", p:GetVelocity())
local tr = { startpos = p:GetOrigin() + Vector(0, 0, 40), endpos = p:GetOrigin() + Vector(0, 0, 41), min = Vector(-16, -16, 0), max = Vector(16, 16, 72), ignore = p, mask = 33636363 }
local ok, err = pcall(TraceHull, tr)
log("TraceHull", ok, err, tr.hit, tr.startsolid, tr.fraction)
-- worker crouch rig
local fwd = p:GetForwardVector() fwd.z = 0 fwd = fwd:Normalized()
local pos = p:GetOrigin() + fwd * 70
for _, n in ipairs({ "amp_api_b", "amp_api_a", "amp_api_w" }) do local e = Entities:FindByName(nil, n) while e do local nx = Entities:FindByName(e, n) e:Kill() e = nx end end
SpawnEntityFromTableAsynchronous("logic_script", { targetname = "amp_precache2", vscripts = "alyxmp/precache.lua" }, function()
    local w = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_api_w", model = "models/characters/workers/worker_m_helmet.vmdl",
        origin = pos.x .. " " .. pos.y .. " " .. pos.z, angles = "0 " .. (p:EyeAngles().y + 150) .. " 0", DefaultAnim = "workers_construction_flag_idling_crouched", solid = 0 })
    local a = SpawnEntityFromTableSynchronous("prop_dynamic", { targetname = "amp_api_a", model = "models/characters/alyx/alyx.vmdl", origin = pos.x .. " " .. pos.y .. " " .. pos.z, solid = 0 })
    a:FollowEntity(w, true)
    w:SetRenderAlpha(0)
    log("worker seq", w:GetSequence(), "SetCycle", type(w.SetCycle), "SetPoseParameter", type(w.SetPoseParameter), "IsNPC", type(w.IsNPC))
    -- think-rate measurement
    local n, t0 = 0, Time()
    w:SetThink(function()
        n = n + 1
        if Time() - t0 >= 1.0 then log("thinks/sec", n, "FrameTime", FrameTime()) return nil end
        return 0
    end, "amp_rate", 0)
end, nil)
local trig = Entities:FindAllByClassname("trigger_changelevel")
log("changelevel triggers", #trig)
for _, t in ipairs(trig) do log("  trig", t:GetName(), t:GetOrigin(), t:GetBoundingMins(), t:GetBoundingMaxs(), t:GetCenter(), t:GetAngles()) end
