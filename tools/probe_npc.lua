local function methods(e, filter)
    local seen, out = {}, {}
    local mt = getmetatable(e) local depth = 0
    while mt and depth < 14 do
        local idx = mt.__index
        if type(idx) ~= "table" then break end
        for k in pairs(idx) do if type(k) == "string" and not seen[k] and (not filter or k:find(filter)) then seen[k] = true table.insert(out, k) end end
        mt = getmetatable(idx) depth = depth + 1
    end
    table.sort(out) return out
end
local npc = Entities:FindByClassname(nil, "npc_zombie")
local prop = Entities:FindByClassname(nil, "prop_physics")
local npcOnly, propSet = {}, {}
for _, k in ipairs(methods(prop)) do propSet[k] = true end
for _, k in ipairs(methods(npc)) do if not propSet[k] then table.insert(npcOnly, k) end end
print("[AMP-N] npc-only methods: " .. table.concat(npcOnly, " "))
local g = {}
for _, k in ipairs({ "CreateDamageInfo", "DestroyDamageInfo", "ApplyDamage", "CalculateBulletDamageForce", "UTIL_Remove", "GetPhysVelocity", "GetPhysAngularVelocity", "EntIndexToHScript", "ScreenShake", "DispatchParticleEffect", "CreateTrigger", "DoEntFire", "EntFire" }) do
    table.insert(g, k .. "=" .. type(_G[k]))
end
print("[AMP-N] globals: " .. table.concat(g, " "))
print("[AMP-N] zombie seq=" .. tostring(npc:GetSequence()) .. " cycle=" .. string.format("%.2f", npc:GetCycle()) .. " health=" .. npc:GetHealth() .. " pos=" .. tostring(npc:GetOrigin()))
