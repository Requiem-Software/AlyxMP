local p = Entities:GetLocalPlayer()
local ang = p:EyeAngles()
local pr, yr = math.rad(ang.x), math.rad(ang.y)
local fwd = Vector(math.cos(pr) * math.cos(yr), math.cos(pr) * math.sin(yr), -math.sin(pr))
local eye = p:EyePosition()
for _, mask in ipairs({ 33636363, -1 }) do
    local tr = { startpos = eye, endpos = eye + fwd * 650, ignore = p, mask = mask }
    TraceLine(tr)
    print(string.format("[AMP-TR] mask %d hit=%s ent=%s dist=%.0f", mask, tostring(tr.hit), tr.enthit and tr.enthit:GetClassname() or "-", tr.hit and (tr.pos - eye):Length() or -1))
end
local it = Entities:FindByName(nil, "amp_test_item")
print("[AMP-TR] eye " .. tostring(eye) .. " ang " .. tostring(ang) .. " item " .. tostring(it and it:GetOrigin()))
