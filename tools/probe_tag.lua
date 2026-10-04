local p = Entities:GetLocalPlayer()
local e = Entities:FindByName(nil, "amp_tagtest") while e do local n = Entities:FindByName(e, "amp_tagtest") e:Kill() e = n end
local fwd = p:GetForwardVector() fwd.z = 0 fwd = fwd:Normalized()
local eye = p:EyePosition()
local ey = p:EyeAngles().y
local pos = eye + fwd * 300
local t = SpawnEntityFromTableSynchronous("point_worldtext", {
    targetname = "amp_tagtest", message = "BIGTEXT", font_size = 200, world_units_per_pixel = 0.5,
    font_name = "Arial", color = "255 0 255 255", justify_horizontal = 1, justify_vertical = 1, reorient_mode = 1,
    fullbright = 1, enabled = 1, origin = pos.x .. " " .. pos.y .. " " .. pos.z, angles = "0 " .. (ey + 180) .. " 0",
})
print("[AMP-TAG] worldtext " .. tostring(t) .. " class=" .. t:GetClassname())
local ok, err = pcall(DebugDrawText, eye + fwd * 80, "DEBUG_DRAW_TEXT", false, 30)
print("[AMP-TAG] DebugDrawText " .. tostring(ok) .. " " .. tostring(err))
local ok2, err2 = pcall(DebugDrawScreenTextLine, 600, 300, 0, "SCREEN_TEXT_LINE", 255, 255, 255, 255, 30)
print("[AMP-TAG] DebugDrawScreenTextLine " .. tostring(ok2) .. " " .. tostring(err2))
