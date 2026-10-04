-- try release orders on three props; report where they end up
local p = Entities:GetLocalPlayer()
local props = {}
for _, e in ipairs(Entities:FindAllInSphere(p:GetOrigin(), 1200)) do
    if e:GetClassname() == "prop_physics" and #props < 3 then table.insert(props, e) end
end
local variants = { "disabled_then_enable", "enable_then_set", "enable_set_zero" }
for i, e in ipairs(props) do
    local start = e:GetOrigin()
    local v = variants[i]
    e:DisableMotion()
    local t0 = Time()
    e:SetThink(function()
        local f = Time() - t0
        if f < 1.0 then
            e:SetAbsOrigin(start + Vector(0, 0, 40 + 20 * math.sin(f * 6)))
            e:SetAngles(0, f * 60, 0)
            return 0
        end
        local final = start + Vector(10, 0, 3)
        if v == "disabled_then_enable" then
            e:SetAbsOrigin(final) e:SetAngles(0, 0, 0) e:EnableMotion()
        elseif v == "enable_then_set" then
            e:EnableMotion() e:SetAbsOrigin(final) e:SetAngles(0, 0, 0)
        else
            e:EnableMotion() e:SetAbsOrigin(final) e:SetAngles(0, 0, 0)
            e:ApplyAbsVelocityImpulse(GetPhysVelocity(e) * -1)
        end
        e:SetThink(function()
            print(string.format("[AMP-R] %s start z %.1f -> now z %.1f vel %.1f", v, start.z, e:GetOrigin().z, GetPhysVelocity(e):Length()))
            return nil
        end, "check", 1.5)
        return nil
    end, "drive", 0)
end
print("[AMP-R] testing " .. #props .. " props")
