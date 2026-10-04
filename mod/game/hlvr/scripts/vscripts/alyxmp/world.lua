-- Alyx MP world sync: physics objects, pickups, breakables, story triggers, interactions and enemies.
--
-- Every player runs their own copy of the level; this keeps the copies in step. Messages are printed
-- as "[AMP]w <type> ..." lines, the launcher relays them to the other players, and they arrive here
-- through the amp_w command (see main.lua).
--
-- Entities are named by a "ref": a hash of class|model plus the spot where the entity was first seen,
-- e.g. "3fa2c1@-256,1984,150". That first sighting is stamped onto the entity as attributes, which are
-- saved with the game, so a player who loads the host's save carries the host's stamps. Entity
-- indices can't be used for this: they differ between games and change on every load.
--
--   p   ref x y z pitch yaw roll   a physics object the sender is moving (they simulate it, we follow)
--   pr  ref x y z pitch yaw roll   it came to rest there; hand it back to local physics
--   pg  ref                        an item disappeared (picked up / stored) - remove ours
--   bk  ref                        something broke - break ours
--   kd  ref                        an enemy died - kill ours
--   tg  ref                        a story trigger fired for the sender - fire ours
--   io  ref output                 an interaction (button, lever, hack, door...) fired - replay it
--   us  ref                        the sender used something (NoVR's E / pickup script) - use ours
--   nh  ref hp                     host: an enemy's health
--   np  ref x y z                  host: an enemy's position
--   nd  ref damage                 a player hurt an enemy in their world - the host applies it
--   sh  weapon x y z hit nx ny nz  the sender's shot landed there - draw a tracer and impact
--   J   <any of the above>         catch-up replay after loading the level fresh (VR joining a NoVR
--                                  host): applied in order, without the duplicate checks

local A = AMP
local W = {}
A.World = W

local PROP_CLASSES = {
    prop_physics = true, prop_physics_override = true, prop_physics_multiplayer = true,
    prop_physics_interactive = true, prop_door_rotating_physics = true, prop_dry_erase_marker = true,
    prop_russell_headset = true,
}
local SKIP_NPCS = { npc_bullseye = true, npc_enemyfinder = true, npc_furniture = true, npc_maker = true, npc_template_maker = true }
local STATIC_NPCS = { npc_barnacle = true, npc_turret_floor = true }
-- picked up by one player, gone for everyone; but using one never gives it to the others
local CONSUMABLE_PREFIXES = { "item_hlvr_clip", "item_hlvr_crafting_currency", "item_healthvial", "item_hlvr_grenade",
    "item_item_crate", "item_hlvr_prop_ammobag" }
-- quest items (what NoVR keeps in the wrist pockets as valuables): when one player takes one, everybody
-- gets their own copy, so nobody is left without the battery / keycard / vial the story needs
local QUEST_CLASSES = { item_hlvr_prop_battery = true, item_hlvr_health_station_vial = true, prop_reviver_heart = true }
local QUEST_MODELS = { ["models/props/misc/keycard_001.vmdl"] = true, ["models/props/distillery/bottle_vodka.vmdl"] = true }

local SCAN_RADIUS = 1400
local SEND_RATE = 1 / 15      -- moving objects
local MARKER_RATE = 1 / 30    -- markers, so strokes come out the same on the other side
local REST_TIME = 0.6         -- this long without moving = at rest
local START_DIST = 6          -- an object has to leave its resting spot by this many units...
local START_TURN = 0.35       -- ...or turn this far (axis chord, ~20 degrees) to count as moved; things that
                              -- only jiggle in place (nails in boards, clips in holders) never do
local DOOR_TURN = 0.05        -- doors don't jiggle; a slowly swinging door would take seconds to reach 20
local STILL_DIST = 1.5        -- while moving, it's at rest once it stays this close to one spot...
local STILL_TURN = 0.1        -- ...and one orientation (~6 degrees) for REST_TIME
local HELD_RESEND = 0.5       -- something we hold still is re-sent this often so the others keep it in our hands
local PROP_INTERP = 0.12      -- remote objects are shown this far behind their newest update
local PROP_TIMEOUT = 2.5      -- give an object back to physics if its mover goes quiet
local SETTLE_TIME = 1.5       -- after an object comes to rest here, ignore its settling wobble
local ITEM_RADIUS = 220
local NPC_POS_STEP = 40       -- host sends an enemy's position when it moved this far
local NPC_TELEPORT = 420      -- clients snap enemies that are further off than this
local NPC_STEER = 180         -- and walk them back when they're further off than this
local REF_TOLERANCE = 64      -- how far apart two games' first sightings of the same entity may be
local NPC_TOLERANCE = 200     -- enemies are often first seen a moment after they spawn and start moving
local STAMP_SCAN = 1.0        -- look for new entities to stamp this often
local USE_DELAY = 0.25        -- replayed uses wait this long, so uses they trigger themselves come first
local USE_SEEN = 1.5          -- a use that happened here this recently isn't replayed

local function f1(n) return string.format("%.1f", n) end
local function myId() return tonumber(A.cfg.id or "0") or 0 end
local function isHost() return A.cfg.role == "host" end
local function active() return A.cfg.mp == "1" end
local function send(...) A.Emit("w", ...) end

local function angDiff(a, b)
    local d = (a - b) % 360
    if d > 180 then d = d - 360 end
    return d
end

local function consumable(class)
    for _, prefix in ipairs(CONSUMABLE_PREFIXES) do
        if class:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- everyone gets their own weapons and tools: picking these up never removes anyone else's
local function personalItem(class)
    return class:sub(1, 16) == "item_hlvr_weapon" or class == "item_hlvr_multitool" or class == "item_hlvr_prop_flashlight"
end

local function questItem(e)
    return QUEST_CLASSES[e:GetClassname()] or QUEST_MODELS[e:GetModelName() or ""] or false
end

-- NoVR flags whatever the player is carrying
local function held(e)
    return e:Attribute_GetIntValue("picked_up", 0) == 1
end

-- reset on every load: handles from the previous level are dead
W.info = setmetatable({}, { __mode = "k" })
W.byHash = {}
W.refCache = {}
W.props = {}
W.seen = setmetatable({}, { __mode = "k" })
W.items = {}
W.npcs = setmetatable({}, { __mode = "k" })
W.npcList = {}
W.suppressBreak = setmetatable({}, { __mode = "k" })
W.suppressItem = {}
W.suppressKill = setmetatable({}, { __mode = "k" })
W.ioQuiet = {}
W.ioSeen = {}
W.useQuiet = {}
W.useSeen = {}
W.useQueue = {}
W.journal = false
W.lastJournalUse = 0
W.hooked = setmetatable({}, { __mode = "k" })
W.nextScan = 0
W.nextItems = 0
W.nextNpcScan = 0
W.nextNpcSend = 0
W.nextNpcCheck = 0
W.nextStamp = 0
W.nextHook = 0

---------------------------------------------------------------------------------------------------
-- identity

local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 16777213 end
    return h + 1
end

local function infoOf(e)
    local i = W.info[e]
    if i then return i end
    local h = e:Attribute_GetIntValue("amp_h", 0)
    if h == 0 then
        -- first sighting in this game (and not inherited from the host's save): stamp it
        h = hash(e:GetClassname() .. "|" .. (e:GetModelName() or ""))
        local o = e:GetOrigin()
        e:Attribute_SetIntValue("amp_h", h)
        e:Attribute_SetFloatValue("amp_x", o.x)
        e:Attribute_SetFloatValue("amp_y", o.y)
        e:Attribute_SetFloatValue("amp_z", o.z)
    end
    local pos = Vector(e:Attribute_GetFloatValue("amp_x", 0), e:Attribute_GetFloatValue("amp_y", 0), e:Attribute_GetFloatValue("amp_z", 0))
    i = { h = h, pos = pos,
          ref = string.format("%x@%d,%d,%d", h, math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5)) }
    W.info[e] = i
    local list = W.byHash[h]
    if not list then
        list = {}
        W.byHash[h] = list
    end
    table.insert(list, e)
    return i
end

local function refOf(e) return infoOf(e).ref end

local function resolve(ref, tolerance)
    local e = W.refCache[ref]
    if e and IsValidEntity(e) then return e end
    local hs, x, y, z = ref:match("^(%x+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not hs then return nil end
    local list = W.byHash[tonumber(hs, 16)]
    if not list then return nil end
    local target = Vector(tonumber(x), tonumber(y), tonumber(z))
    local best, bestD = nil, tolerance or REF_TOLERANCE
    for i = #list, 1, -1 do
        local c = list[i]
        if not IsValidEntity(c) then
            table.remove(list, i)
        else
            local d = (infoOf(c).pos - target):Length()
            if d < bestD then best, bestD = c, d end
        end
    end
    if best then W.refCache[ref] = best end
    return best
end

local function ours(e)
    local name = e:GetName()
    return name == "amp_pp" or name == "amp_hud" or name == "alyxmp_core" or name == "alyxmp_precache"
end

-- stamp everything that exists, so later sightings (and refs from the others) can find it
local function stampAll()
    local p = Entities:GetLocalPlayer()
    local e = Entities:First()
    while e do
        if not W.info[e] and e ~= p and e:GetClassname() ~= "worldent" and not ours(e) then infoOf(e) end
        e = Entities:Next(e)
    end
end

---------------------------------------------------------------------------------------------------
-- physics objects: whoever's game moves an object simulates it and streams it; everyone else freezes
-- their copy and follows. When two players move the same object the lower player id wins.

local function propState(e)
    local st = W.props[e]
    if not st then
        st = { e = e, snaps = {}, still = 0, rate = e:GetClassname() == "prop_dry_erase_marker" and MARKER_RATE or SEND_RATE }
        W.props[e] = st
    end
    return st
end

local function releaseRemote(st)
    if st.frozen and IsValidEntity(st.e) then st.e:EnableMotion() end
    st.frozen = false
    st.remote = nil
    st.owner = nil
    st.snaps = {}
end

local function pose(e)
    return { o = e:GetOrigin(), f = e:GetForwardVector(), u = e:GetUpVector() }
end

-- distance between two poses, and rotation as the larger chord between their axes (Euler angles flip
-- around near +-90 pitch, axes don't)
local function poseDiff(a, b)
    return (a.o - b.o):Length(), math.max((a.f - b.f):Length(), (a.u - b.u):Length())
end

local function propClass(e)
    local class = e:GetClassname()
    return (PROP_CLASSES[class] or class:sub(1, 5) == "item_") and not e:GetMoveParent() and not questItem(e)
end

-- motion is judged against where the object last settled, not frame to frame: constrained things
-- (nailed boards, locked gates) report velocity and wobble a few degrees while staying put.
-- Parented things (items a zombie carries, a clip in a gun) just follow their parent.
local function scanProps(now, p)
    for _, e in ipairs(Entities:FindAllInSphere(p:GetOrigin(), SCAN_RADIUS)) do
        if propClass(e) then
            local st = W.props[e]
            local cur = pose(e)
            local anchor = W.seen[e]
            if not anchor or (st and (st.remote or now < (st.quietUntil or 0))) then
                -- first sight, or another player drives it / it's settling after their move
                W.seen[e] = cur
            else
                local d, r = poseDiff(cur, anchor)
                if st and st.owner == myId() then
                    if d > STILL_DIST or r > STILL_TURN then
                        W.seen[e] = cur
                        st.lastMove = now
                    end
                elseif d > START_DIST or r > (e:GetClassname() == "prop_door_rotating_physics" and DOOR_TURN or START_TURN) then
                    -- it left its resting spot in our world: we simulate it, the others follow
                    st = st or propState(e)
                    st.owner = myId()
                    st.lastSend = -100
                    st.lastMove = now
                    W.seen[e] = cur
                end
            end
        end
    end
end

local function sendPose(kind, e)
    local o, a = e:GetOrigin(), e:GetAngles()
    send(kind, refOf(e), f1(o.x), f1(o.y), f1(o.z), f1(a.x), f1(a.y), f1(a.z))
end

local function sendOwned(now)
    for e, st in pairs(W.props) do
        if not IsValidEntity(e) then
            W.props[e] = nil
        elseif st.owner == myId() and not st.remote and now - (st.lastSend or -100) >= st.rate then
            local still = now - (st.lastMove or 0) > REST_TIME
            if still and held(e) then
                if now - st.lastSend >= HELD_RESEND then
                    sendPose("p", e)
                    st.lastSend = now
                end
            elseif still then
                sendPose("pr", e)
                st.owner = nil
            else
                sendPose("p", e)
                st.lastSend = now
            end
        end
    end
end

local function renderRemote(now)
    for e, st in pairs(W.props) do
        if st.remote then
            if not IsValidEntity(e) then
                W.props[e] = nil
            elseif now - (st.lastRecv or now) > PROP_TIMEOUT then
                releaseRemote(st)
            else
                local snaps = st.snaps
                local n = #snaps
                if n > 0 then
                    local rt = now - PROP_INTERP
                    local pos, ang
                    if rt <= snaps[1].t or n == 1 then
                        pos, ang = snaps[1].pos, snaps[1].ang
                    elseif rt >= snaps[n].t then
                        pos, ang = snaps[n].pos, snaps[n].ang
                    else
                        for i = n - 1, 1, -1 do
                            local a, b = snaps[i], snaps[i + 1]
                            if a.t <= rt then
                                local f = (rt - a.t) / math.max(b.t - a.t, 0.001)
                                pos = a.pos + (b.pos - a.pos) * f
                                ang = { a.ang[1] + angDiff(b.ang[1], a.ang[1]) * f,
                                        a.ang[2] + angDiff(b.ang[2], a.ang[2]) * f,
                                        a.ang[3] + angDiff(b.ang[3], a.ang[3]) * f }
                                break
                            end
                        end
                    end
                    while #snaps > 2 and snaps[2].t < rt do table.remove(snaps, 1) end
                    if pos then
                        e:SetAbsOrigin(pos)
                        e:SetAngles(ang[1], ang[2], ang[3])
                    end
                end
            end
        end
    end
end

local function onPropMsg(from, ref, rest, x, y, z, ax, ay, az)
    local e = resolve(ref)
    if not e or not propClass(e) or held(e) then return end  -- never take something out of our hands
    local st = propState(e)
    if st.owner == myId() and from > myId() then return end  -- we simulate it and win ties
    st.owner = from
    local pos = Vector(x, y, z)
    if rest then
        releaseRemote(st)
        e:SetAbsOrigin(pos)
        e:SetAngles(ax, ay, az)
        st.owner = nil
        st.quietUntil = Time() + SETTLE_TIME
        return
    end
    if not st.frozen then
        e:DisableMotion()
        st.frozen = true
    end
    st.remote = from
    st.lastRecv = Time()
    table.insert(st.snaps, { t = Time(), pos = pos, ang = { ax, ay, az } })
    if #st.snaps > 20 then table.remove(st.snaps, 1) end
end

---------------------------------------------------------------------------------------------------
-- pickups: an item near us that vanished was taken by us (inventory, backpack); tell the others

local function scanItems(now, p)
    local here = p:GetOrigin()
    for e, it in pairs(W.items) do
        if not IsValidEntity(e) then
            if not W.suppressItem[it.ref] and (it.pos - here):Length() < 160 then send("pg", it.ref) end
            W.items[e] = nil
            W.suppressItem[it.ref] = nil
        else
            it.pos = e:GetOrigin()
        end
    end
    for _, e in ipairs(Entities:FindAllInSphere(here, ITEM_RADIUS)) do
        local class = e:GetClassname()
        if class:sub(1, 5) == "item_" and not personalItem(class) and not questItem(e) and not W.items[e] then
            W.items[e] = { ref = refOf(e), pos = e:GetOrigin() }
        end
    end
end

---------------------------------------------------------------------------------------------------
-- story triggers and interactions: when one fires for the local player, the others replay it so
-- their copy of the level progresses too (doors open, scenes start, puzzles count as solved)

local function withCompletions(list)
    for _, l in ipairs({ "A", "B", "C", "D", "E", "F" }) do
        for _, suffix in ipairs({ "", "_Forward", "_Backward" }) do table.insert(list, "OnCompletion" .. l .. suffix) end
        table.insert(list, "OnCompletionExit" .. l)
    end
    return list
end

-- class -> outputs worth replaying (generated from the game's FGD: outputs a player sets off)
local IO_HOOKS = {
    env_headcrabcanister = { "OnOpened" },
    func_button = { "OnPressed" },
    func_door = { "OnOpen", "OnClose" },
    func_door_rotating = { "OnOpen", "OnClose" },
    func_physical_button = { "OnPressed" },
    func_rot_button = { "OnPressed" },
    hlvr_vault_tractor_beam_console = { "OnConsoleStarted", "OnFirstLeverActivated", "OnSecondLeverActivated", "OnThirdLeverActivated", "OnFourthLeverActivated" },
    hlvr_weapon_crowbar = { "OnPlayerPickup", "OnGlovePulled", "OnCrowbarAcquired" },
    hlvr_weapon_energygun = { "OnPlayerPickup", "OnGlovePulled" },
    info_hlvr_holo_hacking_plug = { "OnHackSuccess", "OnPuzzleSuccess", "OnPuzzleCompleted", "OnHackSuccessAnimationComplete" },
    info_hlvr_toner_path = { "OnPowerOn", "OnPowerOff" },
    item_combine_console = { "OnOpened", "OnTankAdded", "OnBatteryPlaced", "OnPuzzleSolved", "OnCompleted", "OnRackMissingTankOpen" },
    item_combine_tank_locker = withCompletions({}),
    item_hlvr_combine_console_tank = { "OnPlayerPickup", "OnPlayerUse" },
    item_hlvr_multitool = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_prop_battery = { "OnPlayerPickup", "OnPlayerUse" },
    item_hlvr_prop_discovery = { "OnPlayerPickup", "OnPlayerUse" },
    item_hlvr_weapon_energygun = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weapon_generic_pistol = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weapon_grabbity_glove = { "OnPlayerPickup", "OnGlovePulled", "OnGrabbityGloveEquipped" },
    item_hlvr_weapon_grabbity_slingshot = { "OnPlayerPickup", "OnGlovePulled", "OnGrabbitySlingshotEquipped" },
    item_hlvr_weapon_radio = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weapon_rapidfire = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weapon_shotgun = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weapon_tripmine = { "OnPlayerPickup", "OnGlovePulled", "OnHackSuccess", "OnPuzzleSuccess", "OnPuzzleCompleted", "OnHackSuccessAnimationComplete" },
    item_hlvr_weaponmodule_guidedmissle = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weaponmodule_guidedmissle_cluster = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weaponmodule_physcannon = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weaponmodule_rapidfire = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weaponmodule_ricochet = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weaponmodule_snark = { "OnPlayerPickup", "OnGlovePulled" },
    item_hlvr_weaponmodule_zapper = { "OnPlayerPickup", "OnGlovePulled" },
    item_suitcharger = { "OnPlayerUse" },
    npc_alyx = { "OnPlayerUse" },
    npc_barney = { "OnPlayerUse" },
    npc_citizen = { "OnPlayerUse" },
    npc_vortigaunt = { "OnPlayerUse" },
    point_training_gravity_gloves = { "OnComplete" },
    point_vort_energy = { "OnEnergyPulled" },
    prop_animinteractable = withCompletions({}),
    prop_combine_ball = { "OnPlayerPickup", "OnPlayerUse" },
    prop_door_rotating = { "OnOpen", "OnClose" },
    prop_handpose = { "OnPlayerPickup", "OnPlayerUse", "OnHandPosed" },
    prop_russell_headset = { "OnPlayerPickup", "OnPlayerUse" },
    prop_welded_physics = { "OnPlayerPickup", "OnPlayerUse" },
    prop_welded_physics_to_target = { "OnPlayerPickup", "OnPlayerUse" },
    trigger_look = { "OnTrigger" },
    trigger_multiple = { "OnStartTouch", "OnEndTouch", "OnTrigger" },
}
local IO_SET = {}
for class, outs in pairs(IO_HOOKS) do
    IO_SET[class] = {}
    for _, o in ipairs(outs) do IO_SET[class][o] = true end
end
-- replayed as the input that does the same thing, so the button/door actually moves on the other side
local BUTTON_INPUTS = { OnPressed = "Press" }
local DOOR_INPUTS = { OnOpen = "Open", OnClose = "Close" }
local IO_INPUTS = {
    func_button = BUTTON_INPUTS, func_physical_button = BUTTON_INPUTS, func_rot_button = BUTTON_INPUTS,
    prop_door_rotating = DOOR_INPUTS, func_door = DOOR_INPUTS, func_door_rotating = DOOR_INPUTS,
}
local TRIGGERS = { trigger_once = true, trigger_multiple = true, trigger_look = true }
-- how close the local player must be for an interaction to count as theirs
local IO_RANGE = { info_hlvr_toner_path = 900 }
local IO_RANGE_DEFAULT = 220
local IO_ECHO = 1.5           -- our hooks fire (asynchronously) after a replay; ignore them this long
local IO_DUPLICATE = 3        -- an output that fired here this recently isn't replayed again
local TRIGGER_REPEAT = 2      -- trigger_multiple keeps firing while you stand in it; send at most this often

-- something the local player is carrying, or threw a moment ago (a headset put on, a battery slotted in)
local function ourObject(e)
    if not e or not IsValidEntity(e) then return false end
    if held(e) then return true end
    local st = W.props[e]
    return st ~= nil and st.owner == myId()
end

-- in VR the hands (or the headset avatar) are often the activator rather than the player
local function isPlayer(act, p)
    if act == p then return true end
    if not act or not IsValidEntity(act) then return false end
    local hmd = p.GetHMDAvatar and p:GetHMDAvatar()
    if not hmd then return false end
    if act == hmd or act:GetOwner() == hmd or act:GetOwner() == p or act:GetMoveParent() == hmd then return true end
    for i = 0, 1 do
        local ok, hand = pcall(function() return hmd:GetVRHand(i) end)
        if ok and hand == act then return true end
    end
    return false
end

-- did the local player set this off?
local function localCause(self, args, p)
    local act = args and args.activator
    if isPlayer(act, p) then act = p end
    local class = self:GetClassname()
    if TRIGGERS[class] then
        return act == p or ourObject(act)
    end
    local range = IO_RANGE[class] or IO_RANGE_DEFAULT
    local dist = (self:GetCenter() - p:EyePosition()):Length()
    if act == p then return dist <= range + 100 end
    if act == nil or act == self then return dist <= range end   -- NoVR fires these itself, no activator
    return ourObject(act) and dist <= range + 200
end

function AMP_WorldTriggerFired(self, args)
    if A.World ~= W or not active() or not self or not IsValidEntity(self) then return end
    local p = Entities:GetLocalPlayer()
    if not p or not localCause(self, args, p) then return end
    local ref = refOf(self)
    local id = "tg " .. ref
    local now = Time()
    if now < (W.ioQuiet[id] or 0) then return end
    W.ioQuiet[id] = now + 0.25
    send("tg", ref)
end

local function onLocalOutput(output, self, args)
    if not active() or not self or not IsValidEntity(self) then return end
    local p = Entities:GetLocalPlayer()
    if not p then return end
    local ref = refOf(self)
    local id = ref .. " " .. output
    local now = Time()
    W.ioSeen[id] = now
    if now < (W.ioQuiet[id] or 0) then return end   -- a replay echoing, a duplicate hook, or a repeat
    if not localCause(self, args, p) then return end
    W.ioQuiet[id] = now + (self:GetClassname() == "trigger_multiple" and TRIGGER_REPEAT or 0.25)
    send("io", ref, output)
end

-- the hooks are global functions (RedirectOutput takes a name); they look up the current module, so
-- connections made before a reload keep working
local function ioCallback(output)
    local fname = "AMP_IO_" .. output
    if not _G[fname] then
        _G[fname] = function(self, args)
            if AMP and AMP.World and AMP.World.OnLocalOutput then AMP.World.OnLocalOutput(output, self, args) end
        end
    end
    return fname
end
W.OnLocalOutput = onLocalOutput
-- define them all up front: a save made by another player already carries connections to them
for _, outs in pairs(IO_HOOKS) do
    for _, o in ipairs(outs) do ioCallback(o) end
end

-- hook everything once per load, then pick up entities spawned later
local function hookAll()
    for _, t in ipairs(Entities:FindAllByClassname("trigger_once")) do
        if not W.hooked[t] and t:Attribute_GetIntValue("amp_io", 0) == 0 then
            W.hooked[t] = true
            t:Attribute_SetIntValue("amp_io", 1)
            t:RedirectOutput("OnTrigger", "AMP_WorldTriggerFired", t)
        end
    end
    for class, outputs in pairs(IO_HOOKS) do
        for _, e in ipairs(Entities:FindAllByClassname(class)) do
            -- the flag is saved with the game along with the connections, so loads don't stack hooks
            if not W.hooked[e] and e:Attribute_GetIntValue("amp_io", 0) == 0 then
                W.hooked[e] = true
                e:Attribute_SetIntValue("amp_io", 1)
                for _, o in ipairs(outputs) do e:RedirectOutput(o, ioCallback(o), e) end
            end
        end
    end
end

local function onTrigger(ref)
    local t = resolve(ref)
    if not t or not TRIGGERS[t:GetClassname()] then return end
    local p = Entities:GetLocalPlayer()
    W.ioQuiet["tg " .. ref] = Time() + IO_ECHO
    t:FireOutput("OnStartTouch", p, t, nil, 0)
    t:FireOutput("OnTrigger", p, t, nil, 0)
    -- a trigger_once that fired remotely mustn't fire again when we walk through it
    if t:GetClassname() == "trigger_once" then DoEntFireByInstanceHandle(t, "Kill", "", 0.1, nil, nil) end
end

local function onOutput(ref, output)
    local e = resolve(ref)
    if not e then return end
    local class = e:GetClassname()
    local allowed = IO_SET[class]
    if not allowed or not allowed[output] then return end
    local id = ref .. " " .. output
    local now = Time()
    if not W.journal and now - (W.ioSeen[id] or -100) < IO_DUPLICATE then return end  -- already happened here
    W.ioSeen[id] = now
    W.ioQuiet[id] = now + IO_ECHO
    local p = Entities:GetLocalPlayer()
    local input = IO_INPUTS[class] and IO_INPUTS[class][output]
    if input then
        DoEntFireByInstanceHandle(e, input, "", 0, p, p)
    else
        e:FireOutput(output, p, e, nil, 0)
    end
end

-- NoVR runs scripts/vscripts/useextra.lua on whatever the player presses E on or picks up; that's
-- where its story handling lives (put on the headset, take the gloves, pull levers...). The launcher
-- adds a line at its top that calls this, and the others run the same script on their copy.
function AMP_OnUseExtra(e)
    if not AMP or AMP.World ~= W or not active() or not e or not IsValidEntity(e) or ours(e) then return end
    local ref = refOf(e)
    local now = Time()
    W.useSeen[ref] = now
    if now < (W.useQuiet[ref] or 0) then return end   -- it's our replay running
    if consumable(e:GetClassname()) then return end
    send("us", ref)
end

local function runUses(now)
    local i = 1
    while i <= #W.useQueue do
        local u = W.useQueue[i]
        if now >= u.due then
            table.remove(W.useQueue, i)
            if u.journal or now - (W.useSeen[u.ref] or -100) >= USE_SEEN then
                local e = resolve(u.ref)
                if e and not consumable(e:GetClassname()) then
                    W.useSeen[u.ref] = now
                    W.useQuiet[u.ref] = now + USE_SEEN
                    local p = Entities:GetLocalPlayer()
                    if A.isVR and questItem(e) then
                        -- no wrist pockets in VR: put our copy right in front of us to grab
                        local hmd = p:GetHMDAvatar()
                        local eye = hmd and hmd:GetCenter() or p:EyePosition()
                        local dir = (hmd or p):GetForwardVector()
                        dir = Vector(dir.x, dir.y, 0):Normalized()
                        e:SetAbsOrigin(eye + dir * 16 - Vector(0, 0, 16))
                    else
                        DoEntFireByInstanceHandle(e, "RunScriptFile", "useextra", 0, p, p)
                    end
                end
            end
        else
            i = i + 1
        end
    end
end

---------------------------------------------------------------------------------------------------
-- shots: the shooter sends where their bullet landed; we draw a tracer from their gun to there

local TRACERS = { [1] = "particles/tracer_fx/pistol_tracer.vpcf", [2] = "particles/tracer_fx/pistol_tracer.vpcf", [3] = "particles/tracer_fx/smg_tracer.vpcf" }
local IMPACT = "particles/impact_fx/impact_concrete.vpcf"

local function muzzleOf(from)
    local pp = A.puppets and A.puppets[from]
    if not pp then return nil end
    local gun = pp.weaponEnt
    if gun and IsValidEntity(gun) then
        local att = gun:ScriptLookupAttachment("muzzle")
        if att and att > 0 then return gun:GetAttachmentOrigin(att) end
        return gun:GetCenter()
    end
    if pp.alyx and IsValidEntity(pp.alyx) then return pp.alyx:GetCenter() + Vector(0, 0, 20) end
    return nil
end

local function shotFx(start, stop, hit, normal, weapon)
    local fx = ParticleManager:CreateParticle(TRACERS[weapon] or TRACERS[1], PATTACH_CUSTOMORIGIN, nil)
    ParticleManager:SetParticleControl(fx, 0, start)
    ParticleManager:SetParticleControl(fx, 1, stop)
    ParticleManager:ReleaseParticleIndex(fx)
    if hit then
        local imp = ParticleManager:CreateParticle(IMPACT, PATTACH_CUSTOMORIGIN, nil)
        ParticleManager:SetParticleControl(imp, 0, stop)
        ParticleManager:SetParticleControlForward(imp, 0, normal)
        ParticleManager:ReleaseParticleIndex(imp)
    end
end

local function onShot(from, weapon, pos, hit, normal)
    local start = muzzleOf(from)
    if not start then return end
    shotFx(start, pos, hit, normal, weapon)
    if weapon == 2 then
        -- shotgun: a few more pellets spread across the surface around the aim point
        local up = math.abs(normal.z) > 0.9 and Vector(1, 0, 0) or Vector(0, 0, 1)
        local t1 = normal:Cross(up):Normalized()
        local t2 = normal:Cross(t1):Normalized()
        local spread = math.min((pos - start):Length() * 0.05, 60)
        for _ = 1, 4 do
            shotFx(start, pos + t1 * RandomFloat(-spread, spread) + t2 * RandomFloat(-spread, spread), hit, normal, weapon)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- enemies: everyone keeps their own (native AI and animation); the host's copy is the reference for
-- health and position, and damage anyone deals is applied on the host

local function isNpc(e)
    return e.IsNPC and e:IsNPC() and not SKIP_NPCS[e:GetClassname()]
end

local function refreshNpcList()
    local list = {}
    local e = Entities:First()
    while e do
        if isNpc(e) then table.insert(list, e) end
        e = Entities:Next(e)
    end
    W.npcList = list
end

local function hostSendNpcs(now)
    for _, e in ipairs(W.npcList) do
        if IsValidEntity(e) and e:IsAlive() then
            local rec = W.npcs[e]
            if not rec then
                rec = {}
                W.npcs[e] = rec
            end
            local hp = e:GetHealth()
            if hp ~= rec.hp then
                send("nh", refOf(e), hp)
                rec.hp = hp
            end
            if not STATIC_NPCS[e:GetClassname()] then
                local o = e:GetOrigin()
                if not rec.pos or (o - rec.pos):Length() > NPC_POS_STEP or (now - (rec.posAt or 0) > 2 and (o - rec.pos):Length() > 4) then
                    send("np", refOf(e), f1(o.x), f1(o.y), f1(o.z))
                    rec.pos, rec.posAt = o, now
                end
            end
        end
    end
end

-- clients: notice health lost in our world and report it so the host's enemy takes it too
local function clientCheckDamage(p)
    for _, e in ipairs(Entities:FindAllInSphere(p:GetOrigin(), 2500)) do
        if isNpc(e) then
            local rec = W.npcs[e]
            if not rec then
                rec = {}
                W.npcs[e] = rec
            end
            local hp = e:GetHealth()
            if rec.lastHp and hp < rec.lastHp and hp ~= rec.expectHp then
                send("nd", refOf(e), rec.lastHp - hp)
            end
            rec.lastHp = hp
        end
    end
end

local function npcByRef(ref)
    local e = resolve(ref, NPC_TOLERANCE)
    if e and isNpc(e) then return e end
    return nil
end

local function onNpcHealth(ref, hp)
    local e = npcByRef(ref)
    if not e then return end
    local rec = W.npcs[e] or {}
    W.npcs[e] = rec
    if hp < e:GetHealth() then
        rec.expectHp = hp
        rec.lastHp = hp
        DoEntFireByInstanceHandle(e, "SetHealth", tostring(hp), 0, nil, nil)
    end
end

local function onNpcPos(ref, pos)
    local e = npcByRef(ref)
    if not e or STATIC_NPCS[e:GetClassname()] then return end
    local d = (e:GetOrigin() - pos):Length()
    if d > NPC_TELEPORT then
        e:SetAbsOrigin(pos)
    elseif d > NPC_STEER then
        pcall(function() e:NpcForceGoPosition(pos, true, 32) end)
    end
end

local function onNpcDamage(ref, dmg)
    if not isHost() then return end
    local e = npcByRef(ref)
    if not e or not e:IsAlive() then return end
    local p = Entities:GetLocalPlayer()
    local info = CreateDamageInfo(p, p, Vector(0, 0, 0), e:GetCenter(), dmg, 2)
    e:TakeDamage(info)
    DestroyDamageInfo(info)
end

local function onKilled(ref)
    local e = npcByRef(ref)
    if not e or e:GetHealth() <= 0 then return end
    W.suppressKill[e] = true
    DoEntFireByInstanceHandle(e, "SetHealth", "0", 0, nil, nil)
    -- some enemies ignore SetHealth 0 (scripted states); remove those
    if A.core then A.core:SetThink(function()
        if IsValidEntity(e) and e:GetHealth() > 0 then e:Kill() end
        return nil
    end, "amp_kill_" .. ref, 1.0) end
end

---------------------------------------------------------------------------------------------------
-- entry points used by main.lua

function W.Start()
    stampAll()
    hookAll()
    refreshNpcList()
    W.nextStamp = Time() + STAMP_SCAN
    W.nextHook = Time() + 5
end

function W.Tick(now, p)
    if not active() or not p then return end
    if now >= W.nextStamp then
        W.nextStamp = now + STAMP_SCAN
        stampAll()
    end
    if now >= W.nextScan then
        W.nextScan = now + 0.1
        scanProps(now, p)
    end
    sendOwned(now)
    renderRemote(now)
    runUses(now)
    if now >= W.nextItems then
        W.nextItems = now + 0.25
        scanItems(now, p)
    end
    if now >= W.nextNpcScan then
        W.nextNpcScan = now + 2
        refreshNpcList()
    end
    if now >= W.nextHook then
        W.nextHook = now + 5
        hookAll()
    end
    if isHost() then
        if now >= W.nextNpcSend then
            W.nextNpcSend = now + 0.25
            hostSendNpcs(now)
        end
    elseif now >= W.nextNpcCheck then
        W.nextNpcCheck = now + 0.1
        clientCheckDamage(p)
    end
end

function W.Receive(from, kind, a)
    if kind == "J" then
        local rest = {}
        for i = 2, #a do rest[i - 1] = a[i] end
        W.journal = true
        local ok, err = pcall(W.Receive, from, a[1], rest)
        W.journal = false
        if not ok then error(err) end
        return
    end
    local n = function(i) return tonumber(a[i]) end
    if kind == "sh" then
        local weapon, x, y, z, hit, nx, ny, nz = n(1), n(2), n(3), n(4), n(5), n(6), n(7), n(8)
        if nz then onShot(from, weapon, Vector(x, y, z), hit == 1, Vector(nx, ny, nz)) end
        return
    end
    local ref = a[1]
    if not ref then return end
    if kind == "p" or kind == "pr" then
        local x, y, z, ax, ay, az = n(2), n(3), n(4), n(5), n(6), n(7)
        if az then onPropMsg(from, ref, kind == "pr", x, y, z, ax, ay, az) end
    elseif kind == "pg" then
        local e = resolve(ref)
        if e and e:GetClassname():sub(1, 5) == "item_" and not personalItem(e:GetClassname()) and not questItem(e) and not held(e) then
            W.suppressItem[ref] = true
            W.props[e] = nil
            e:Kill()
        end
    elseif kind == "bk" then
        local e = resolve(ref)
        if e then
            W.suppressBreak[e] = true
            DoEntFireByInstanceHandle(e, "Break", "", 0, nil, nil)
        end
    elseif kind == "kd" then
        onKilled(ref)
    elseif kind == "tg" then
        onTrigger(ref)
    elseif kind == "io" then
        if a[2] then onOutput(ref, a[2]) end
    elseif kind == "us" then
        if W.journal then
            -- one after another, the way they happened
            W.lastJournalUse = math.max(Time() + USE_DELAY, W.lastJournalUse + 0.35)
            table.insert(W.useQueue, { ref = ref, due = W.lastJournalUse, journal = true })
        else
            table.insert(W.useQueue, { ref = ref, due = Time() + USE_DELAY })
        end
    elseif kind == "nh" then
        if n(2) and not isHost() then onNpcHealth(ref, n(2)) end
    elseif kind == "np" then
        if n(4) and not isHost() then onNpcPos(ref, Vector(n(2), n(3), n(4))) end
    elseif kind == "nd" then
        if n(2) then onNpcDamage(ref, n(2)) end
    end
end

function W.OnBreak(idx)
    if not active() then return end
    local e = EntIndexToHScript(idx)
    if not e or not IsValidEntity(e) then return end
    if W.suppressBreak[e] then
        W.suppressBreak[e] = nil
        return
    end
    send("bk", refOf(e))
end

--- an enemy died in our game
function W.OnKilled(idx)
    if not active() then return end
    local e = EntIndexToHScript(idx)
    if not e or not IsValidEntity(e) or not isNpc(e) then return end
    if W.suppressKill[e] then
        W.suppressKill[e] = nil
        return
    end
    send("kd", refOf(e))
end

--- the local player fired: tell the others where the bullet went
function W.LocalShot(weapon, pos, hit, normal)
    if not active() then return end
    send("sh", weapon, f1(pos.x), f1(pos.y), f1(pos.z), hit and 1 or 0,
        string.format("%.2f", normal.x), string.format("%.2f", normal.y), string.format("%.2f", normal.z))
end

-- for tools and debugging
W.RefOf, W.Resolve = refOf, resolve

--- a NoVR physics pickup: we're holding this object now, so we drive it
function W.OnPickup(idx)
    local e = EntIndexToHScript(idx)
    if not e or not IsValidEntity(e) or not propClass(e) then return end
    local st = propState(e)
    if st.remote then releaseRemote(st) end
    st.owner = myId()
    st.lastMove = Time()
    st.lastSend = -100
end
