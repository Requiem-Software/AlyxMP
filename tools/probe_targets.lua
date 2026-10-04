-- dev: report nearby test targets for tools/worldtest.py, and run small actions on demand
local p = Entities:GetLocalPlayer()
local here = p:GetOrigin()
local function near(class, radius)
    return Entities:FindByClassnameNearest(class, here, radius or 3000)
end
local action = AMP_TEST_ACTION or "list"
if action == "list" then
    local prop = near("prop_physics", 900)
    local zombie = near("npc_zombie", 6000)
    local trig = Entities:FindByClassname(nil, "trigger_once")
    local item = near("item_hlvr_clip_energygun", 900) or near("item_hlvr_crafting_currency_small", 2000)
    print(string.format("[AMP-T] prop %s %s", prop and prop:GetEntityIndex() or -1, prop and tostring(prop:GetOrigin()) or ""))
    print(string.format("[AMP-T] zombie %s %s", zombie and zombie:GetEntityIndex() or -1, zombie and zombie:GetHealth() or -1))
    print(string.format("[AMP-T] trigger %s", trig and ("#" .. trig:GetEntityIndex()) or "-"))
    print(string.format("[AMP-T] item %s %s", item and item:GetEntityIndex() or -1, item and item:GetClassname() or "-"))
elseif action == "query" then
    local e = EntIndexToHScript(AMP_TEST_IDX)
    if e and IsValidEntity(e) then
        print(string.format("[AMP-T] q %d valid pos %s hp %d vel %.1f", AMP_TEST_IDX, tostring(e:GetOrigin()), e:GetHealth(), GetPhysVelocity(e):Length()))
    else
        print(string.format("[AMP-T] q %d gone", AMP_TEST_IDX))
    end
elseif action == "hurt" then
    local e = EntIndexToHScript(AMP_TEST_IDX)
    local info = CreateDamageInfo(p, p, Vector(0, 0, 0), e:GetCenter(), 5, 2)
    e:TakeDamage(info)
    DestroyDamageInfo(info)
    print("[AMP-T] hurt done")
elseif action == "push" then
    local e = EntIndexToHScript(AMP_TEST_IDX)
    e:ApplyAbsVelocityImpulse(Vector(0, 0, 280))
    print("[AMP-T] pushed")
elseif action == "kill" then
    local e = EntIndexToHScript(AMP_TEST_IDX)
    e:Kill()
    print("[AMP-T] killed")
end
if action == "near" then
    -- list interesting things near the player: items, breakables (props with health), doors
    local here = p:GetOrigin()
    for _, e in ipairs(Entities:FindAllInSphere(here, 1500)) do
        local c = e:GetClassname()
        local hp = e:GetHealth()
        if (c:sub(1, 5) == "item_" and not e:GetMoveParent()) or c:find("door") or c == "func_breakable" or (c:sub(1, 12) == "prop_physics" and hp > 0) then
            print(string.format("[AMP-T] n %d %s hp %d d %.0f %s", e:GetEntityIndex(), c, hp, (e:GetOrigin() - here):Length(), e:GetModelName()))
        end
    end
elseif action == "bring" then
    local e = EntIndexToHScript(AMP_TEST_IDX)
    local fwd = p:GetForwardVector()
    e:SetAbsOrigin(p:GetOrigin() + Vector(fwd.x * 50, fwd.y * 50, 40))
    print("[AMP-T] brought")
elseif action == "smash" then
    local e = EntIndexToHScript(AMP_TEST_IDX)
    local info = CreateDamageInfo(p, p, Vector(0, 0, 0), e:GetCenter(), 500, 2)
    e:TakeDamage(info)
    DestroyDamageInfo(info)
    print("[AMP-T] smashed")
elseif action == "zpos" then
    local e = EntIndexToHScript(AMP_TEST_IDX)
    print(string.format("[AMP-T] z %d %s alive %s", AMP_TEST_IDX, tostring(e:GetOrigin()), tostring(e:IsAlive())))
end
