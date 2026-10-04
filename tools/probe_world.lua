local p = Entities:GetLocalPlayer()
local ok, list = pcall(function() return Entities:FindAllInSphere(p:GetOrigin(), 600) end)
print("[AMP-W] FindAllInSphere ok=" .. tostring(ok) .. " n=" .. tostring(ok and #list))
-- trigger output hook
function AMP_TestTrig(a, b)
    local t = {}
    if type(a) == "table" then for k, v in pairs(a) do table.insert(t, tostring(k) .. "=" .. tostring(v)) end end
    print("[AMP-W] trigger fired a=" .. type(a) .. " {" .. table.concat(t, ",") .. "} b=" .. tostring(b))
end
local trig = Entities:FindByClassname(nil, "trigger_once")
local n = 0
for _, tr in ipairs(Entities:FindAllByClassname("trigger_once")) do n = n + 1 end
print("[AMP-W] trigger_once count=" .. n .. " first=" .. tostring(trig and trig:GetName()) .. " at " .. tostring(trig and trig:GetCenter()))
if trig then
    trig:RedirectOutput("OnTrigger", "AMP_TestTrig", trig)
    trig:FireOutput("OnTrigger", p, p, nil, 0)
end
-- physics prop drive test
local prop = Entities:FindByClassnameNearest("prop_physics", p:GetOrigin(), 800)
if prop then
    local start = prop:GetOrigin()
    prop:DisableMotion()
    local t0 = Time()
    prop:SetThink(function()
        local f = Time() - t0
        prop:SetAbsOrigin(start + Vector(0, 0, 20 + 20 * math.sin(f * 4)))
        prop:SetAngles(0, f * 90, 0)
        if f > 2 then
            prop:EnableMotion()
            print("[AMP-W] prop released at " .. tostring(prop:GetOrigin()))
            return nil
        end
        return 0
    end, "amp_drive", 0)
    print("[AMP-W] driving prop " .. prop:GetModelName() .. " idx " .. prop:GetEntityIndex())
end
