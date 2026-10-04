local p = Entities:GetLocalPlayer()
print("[AMP-POS] origin " .. tostring(p:GetOrigin()) .. " abs " .. tostring(p:GetAbsOrigin()) .. " eye " .. tostring(p:EyePosition()) .. " center " .. tostring(p:GetCenter()))
local o = p:GetOrigin() print(string.format("[AMP-POS] fmt %.1f %.1f %.1f  raw %s", o.x, o.y, o.z, tostring(o.x)))
