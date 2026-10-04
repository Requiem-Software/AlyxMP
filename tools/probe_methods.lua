local e = Entities:FindByName(nil, "amp_gun")
local seen, out = {}, {}
local mt = getmetatable(e)
local depth = 0
while mt and depth < 10 do
    local idx = mt.__index
    if type(idx) == "table" then
        for k, v in pairs(idx) do
            if type(k) == "string" and not seen[k] and (k:find("Bone") or k:find("Attach") or k:find("Parent") or k:find("Sequence") or k:find("Graph") or k:find("Pose") or k:find("Anim") or k:find("Sound") or k:find("Particle") or k:find("Cycle") or k:find("Body")) then
                seen[k] = true table.insert(out, k)
            end
        end
        mt = getmetatable(idx)
    else
        break
    end
    depth = depth + 1
end
table.sort(out)
print("[AMP-M] " .. #out .. " " .. table.concat(out, " "))
local g = {}
for k, v in pairs(_G) do if type(k) == "string" and (k:find("Sound") or k:find("Particle") or k:find("Emit")) then table.insert(g, k) end end
table.sort(g)
print("[AMP-M] globals: " .. table.concat(g, " "))
if ParticleManager then local pm = {} for k in pairs(getmetatable(ParticleManager).__index or {}) do table.insert(pm, k) end table.sort(pm) print("[AMP-M] PM: " .. table.concat(pm, " ")) end
