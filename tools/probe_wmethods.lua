local w = Entities:FindByClassname(nil, "weapon_pistol")
local seen, out = {}, {}
local mt = getmetatable(w)
local depth = 0
while mt and depth < 12 do
    local idx = mt.__index
    if type(idx) ~= "table" then break end
    for k, v in pairs(idx) do
        if type(k) == "string" and not seen[k] then seen[k] = true table.insert(out, k) end
    end
    mt = getmetatable(idx)
    depth = depth + 1
end
table.sort(out)
local pick = {}
for _, k in ipairs(out) do if k:find("Clip") or k:find("Ammo") or k:find("Attack") or k:find("Weapon") or k:find("Fire") or k:find("Owner") or k:find("Active") then table.insert(pick, k) end end
print("[AMP-WM] " .. #out .. " methods; relevant: " .. table.concat(pick, " "))
local p = Entities:GetLocalPlayer()
local pm, pseen = {}, {}
mt = getmetatable(p) depth = 0
while mt and depth < 12 do
    local idx = mt.__index
    if type(idx) ~= "table" then break end
    for k in pairs(idx) do if type(k) == "string" and not pseen[k] and (k:find("Weapon") or k:find("Ammo") or k:find("Active") or k:find("Clip")) then pseen[k] = true table.insert(pm, k) end end
    mt = getmetatable(idx) depth = depth + 1
end
table.sort(pm)
print("[AMP-WM] player: " .. table.concat(pm, " "))
