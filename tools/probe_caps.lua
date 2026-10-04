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
local p = Entities:GetLocalPlayer()
local prop = Entities:FindByClassname(nil, "prop_physics")
print("[AMP-C] prop_physics " .. tostring(prop and prop:GetModelName()))
if prop then print("[AMP-C] prop methods: " .. table.concat(methods(prop), " ")) end
local npc = Entities:FindByClassname(nil, "npc_headcrab") or Entities:FindByClassname(nil, "npc_zombie") or Entities:FindByClassname(nil, "npc_combine_s")
print("[AMP-C] npc " .. tostring(npc and npc:GetClassname()))
local g = {}
for k, v in pairs(_G) do if type(k) == "string" and (k:find("Damage") or k:find("Glow") or k:find("Npc") or k:find("NPC") or k:find("AI") or k:find("Hud") or k:find("HUD") or k:find("Text")) then table.insert(g, k) end end
table.sort(g) print("[AMP-C] globals: " .. table.concat(g, " "))
print("[AMP-C] glow-ish on prop: " .. table.concat(methods(prop or p, "low"), " ") .. " | render: " .. table.concat(methods(prop or p, "Render"), " "))
