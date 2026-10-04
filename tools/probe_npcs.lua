local p = Entities:GetLocalPlayer()
local list = {}
local e = Entities:First()
while e do
    if e.IsNPC and e:IsNPC() then table.insert(list, e) end
    e = Entities:Next(e)
end
print("[AMP-NPC] count=" .. #list)
for _, n in ipairs(list) do
    local ok, fac = pcall(function() return n:GetFaction() end)
    print(string.format("[AMP-NPC] idx=%d %s model=%s faction=%s seq=%s hp=%d dist=%.0f name=%s", n:GetEntityIndex(), n:GetClassname(), n:GetModelName(), tostring(fac), tostring(n:GetSequence()), n:GetHealth(), (n:GetOrigin() - p:GetOrigin()):Length(), n:GetName()))
end
