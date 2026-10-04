-- Dev probe: verifies the avatar rig (animated citizen base + bone-merged Alyx + name tag).
local function log(...) print("[AMP-PROBE] " .. table.concat({...}, " ")) end

for _, n in ipairs({ "amp_probe_base", "amp_probe_alyx", "amp_probe_tag" }) do
    local e = Entities:FindByName(nil, n)
    while e do
        local nxt = Entities:FindByName(e, n)
        e:Kill()
        e = nxt
    end
end

local p = Entities:GetLocalPlayer()
local fwd = p:GetForwardVector()
fwd.z = 0
fwd = fwd:Normalized()
local pos = p:GetOrigin() + fwd * 60 + Vector(0, 0, 0)
local yaw = p:EyeAngles().y + 90
local base = SpawnEntityFromTableSynchronous("prop_dynamic", {
    targetname = "amp_probe_base",
    model = "models/characters/citizens/citizen_female_01.vmdl",
    origin = pos.x .. " " .. pos.y .. " " .. pos.z,
    angles = "0 " .. yaw .. " 0",
    DefaultAnim = "run_n",
    solid = 0,
})
local alyx = SpawnEntityFromTableSynchronous("prop_dynamic", {
    targetname = "amp_probe_alyx",
    model = "models/characters/alyx/alyx.vmdl",
    origin = pos.x .. " " .. pos.y .. " " .. pos.z,
    solid = 0,
})
alyx:FollowEntity(base, true)
base:SetRenderAlpha(0)
local tag = SpawnEntityFromTableSynchronous("point_worldtext", {
    targetname = "amp_probe_tag",
    message = "Player2",
    font_size = 100,
    world_units_per_pixel = 0.08,
    color = "255 255 255 255",
    justify_horizontal = 1,
    justify_vertical = 1,
    reorient_mode = 1,
    fullbright = 1,
    origin = pos.x .. " " .. pos.y .. " " .. (pos.z + 80),
})
tag:SetParent(base, "")
log("spawned at", tostring(pos), "seq", tostring(base:GetSequence()), "cycle", tostring(base:GetCycle()))
local ok, err = pcall(function() base:SetPlaybackRate(1.0) end)
log("SetPlaybackRate", tostring(ok), tostring(err))
base:SetThink(function()
    log("cycle", string.format("%.3f", base:GetCycle()))
    return nil
end, "amp_probe_cycle", 0.5)
