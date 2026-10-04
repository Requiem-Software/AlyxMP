local p = Entities:GetLocalPlayer()
print("[AMP-Z] player at " .. tostring(p:GetOrigin()))
for _, t in ipairs(Entities:FindAllByClassname("trigger_changelevel")) do
    local o = t:GetOrigin()
    print("[AMP-Z] trigger name=" .. t:GetName() .. " center=" .. tostring(t:GetCenter()) .. " mins=" .. tostring(o + t:GetBoundingMins()) .. " maxs=" .. tostring(o + t:GetBoundingMaxs()) .. " dist=" .. math.floor((t:GetCenter() - p:GetOrigin()):Length()))
end
