local n = #Entities:FindAllByName("amp_pp")
local old = 0
for _, e in ipairs(Entities:FindAllByClassname("prop_dynamic")) do
    local m = e:GetModelName()
    if m:find("alyx/alyx") or m:find("citizen_female_01") or m:find("combine_grunt") then old = old + 1 end
end
print("[AMP-LEFT] amp_pp=" .. n .. " avatar-like props=" .. old .. " core=" .. tostring(Entities:FindByName(nil, "alyxmp_core") ~= nil) .. " ready=" .. tostring(AMP.ready))
