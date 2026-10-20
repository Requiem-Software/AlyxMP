-- Alyx MP world sync: physics objects, pickups, breakables, story triggers, interactions and enemies.
--
-- Every player runs their own copy of the level; this keeps the copies in step. Messages are printed
-- as "[AMP]w <type> ..." lines, the launcher relays them to the other players, and they arrive here
-- through the amp_w command (see main.lua).
--
-- Entities are named by a "ref": a hash of class|model plus the spot where the entity was first seen,
-- e.g. "3fa2c1@-256,1984,150". That first sighting is stamped onto the entity as attributes, which are
-- saved with the game, so a player who loads the host's save carries the host's stamps. Entity
-- indices can't be used for this: they differ between games and change on every load. An enemy a
-- spawner made is "3fa2c1#4@..." instead: the spawner's 4th, stamped where the spawner is.
--
--   p   ref x y z pitch yaw roll   a physics object the sender is moving (they simulate it, we follow)
--   pr  ref x y z pitch yaw roll   it came to rest there; hand it back to local physics
--   pg  ref                        an item disappeared (picked up / stored) - remove ours
--   bk  ref                        something broke - break ours
--   kd  ref x y z                  an enemy died (there) - kill ours
--   tg  ref                        a story trigger fired for the sender - fire ours
--   io  ref output                 an interaction (button, lever, hack, door...) fired - replay it
--   us  ref                        the sender used something (NoVR's E / pickup script) - use ours
--   ai  ref value pos              the sender is working a wheel / lever / sliding door: how far along
--                                  it is, and the Position output that goes with it (or "-")
--   nh  ref hp                     host: an enemy's health
--   np  ref x y z yaw              host: an enemy's position
--   ne  ref id                     host: which player an enemy is after (-1: nobody)
--   nd  ref damage x y z           a player hurt an enemy in their world - the host applies it
--   sh  weapon x y z hit nx ny nz  the sender's shot landed there - draw a tracer and impact
--   na  seq part parts ref|x,y,z ...  host: the enemies alive in its world, every few seconds (in parts);
--                                  the others remove what the host no longer has and pair up the rest
--   pa  ref x y z pitch yaw roll   host: where a moved object rests in its world (a few every few seconds);
--                                  the others put theirs there if it drifted
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
-- enemies that go after the other players' avatars too (each avatar carries an invisible target)
local HOSTILE_NPCS = { "npc_combine_s", "npc_zombie", "npc_antlion", "npc_headcrab", "npc_headcrab_black",
    "npc_headcrab_runner", "npc_headcrab_armored", "npc_headcrab_fast", "npc_manhack", "npc_turret_floor" }
local TARGET_PREFIX = "amp_target"   -- + "_<player id>", the avatars' bullseyes (main.lua)
local HOSTILE_SET = {}
for _, c in ipairs(HOSTILE_NPCS) do HOSTILE_SET[c] = true end
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
local CLAIM_RANGE = 200       -- a guest only takes over objects that start moving this close to them; anything
                              -- further off was moved by an enemy or an explosion, and the host streams that
local NPC_POS_STEP = 24       -- host sends an enemy's position when it moved this far...
local NPC_YAW_STEP = 25       -- ...or turned this much
local NPC_TELEPORT = 240      -- clients snap enemies that are further off than this
local NPC_STEER = 56          -- and walk them to the host's spot when they're further off than this
local NPC_STEER_EVERY = 0.6   -- (re-issued at most this often, or when the spot moved on)
local NPC_HIT_MEMORY = 2.5    -- an enemy that just hit an avatar is after that player
local NPC_TARGET_RESEND = 3
local NPC_MATCH = 400         -- an enemy we can't find by its ref: the nearest one of its kind this close
local REF_TOLERANCE = 64      -- how far apart two games' first sightings of the same entity may be
local NPC_TOLERANCE = 200     -- enemies are often first seen a moment after they spawn and start moving
local STAMP_SCAN = 1.0        -- look for new entities to stamp this often
local WALK_PER_TICK = 20      -- the background pass over every entity: this many per frame (stamps them,
                              -- and keeps the lists of physics objects and enemies the checks go through)
local NEAR_RADIUS = 450       -- physics objects this close to us are checked for movement every PROP_CHECK...
local FAR_CHECKS = 32         -- ...and this many of the level's others, round robin
local PROP_CHECK = 0.05
local HOOK_ROUND = 5          -- output hooks: every class once this often, one class at a time
local NPC_REBIND = 280        -- a matched enemy this far from where the host's copy is, while another of its kind
local NPC_REBIND_NEAR = 120   -- is this close to that spot: the two were swapped - swap them back
local AUDIT_EVERY = 4         -- host: list the living enemies (and some resting objects) this often
local AUDIT_PROPS = 8         -- resting objects per audit
local GHOST_AUDITS = 2        -- an enemy of ours left over in this many audits in a row (and around for a while)
local GHOST_AGE = 10          -- is a ghost: the host doesn't have it (or one of its kind to pair it with)
local GHOSTS_PER_AUDIT = 4    -- (removed at most this many at a time)
local BEHIND_ENEMIES = 3      -- the host has this many enemies we can't find or pair, the same ones audit
local BEHIND_AUDITS = 3       -- after audit: our world fell behind; reload the host's
local RESYNC_GAP = 30         -- (asking the launcher at most this often; it decides - at most every few minutes, never right after a load)
local JOURNAL_WAIT = 15       -- catch-up entries whose entity isn't there yet (spawned a moment after the level
                              -- starts) wait this long for it, in order
local SPAWN_TOLERANCE = 4     -- a spawned enemy's stamp is its spawner's spot: exactly the same everywhere
local NPC_STAMP_SCAN = 0.2    -- new enemies get stamped quickly, before they've walked far from their spawn
local AI_RATE = 1 / 15        -- wheels / levers / sliding doors being worked
local AI_INTERP = 0.12
local AI_IDLE = 0.35          -- unchanged this long: send the final value
local AI_DRIVE = 20           -- after we use one, its movement is ours to stream for this long
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
W.infoIdx = {}
W.byHash = {}
W.refCache = {}
W.props = {}
W.seen = setmetatable({}, { __mode = "k" })
W.items = {}
W.npcs = setmetatable({}, { __mode = "k" })
W.npcList = {}
W.npcClaim = setmetatable({}, { __mode = "k" })   -- enemy -> the ref it was matched to
W.hostPos = {}                                    -- ref -> where the host last said its enemy was
W.anims = setmetatable({}, { __mode = "k" })
W.replays = {}                                    -- uses we're replaying right now (their scripts chain on)
W.nextNpcStamp = 0
W.nextAnims = 0
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
W.walk = { props = {}, npcs = {} }
W.propList = {}
W.nearProps = {}
W.propCursor = 0
W.nextNear = 0
W.hookCursor = 0
W.audit = { parts = {}, misses = {}, behind = 0 }
W.nextAudit = 0
W.auditSeq = 0
W.auditPropCursor = 0
W.moved = {}                  -- host: refs of objects that were moved and came to rest (for the audit)
W.passes = 0                  -- background passes over every entity done since the level loaded
W.fresh = setmetatable({}, { __mode = "k" })   -- enemies seen once, stamped the next time (see stampNewNpcs)
W.lastResync = -1000
W.journalWait = {}            -- catch-up entries waiting for their entity (see JOURNAL_WAIT)

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
    local n = e:Attribute_GetIntValue("amp_n", 0)        -- a spawner's n-th (see stampSpawned)
    local idx = e:GetEntityIndex()
    local h = e:Attribute_GetIntValue("amp_h", 0)
    -- an entity that's on its way out (a constraint that just broke, an enemy that just died) has lost
    -- its name by the time our output hooks run; it keeps its stamp, so find what we called it by that
    local known = W.infoIdx[idx]
    if known and h ~= 0 and known.h == h and known.pos.x == e:Attribute_GetFloatValue("amp_x", 0)
        and known.pos.y == e:Attribute_GetFloatValue("amp_y", 0) and known.pos.z == e:Attribute_GetFloatValue("amp_z", 0) then
        W.info[e] = known
        return known
    end
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
    local at = string.format("@%d,%d,%d", math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5))
    -- story things mostly have names of their own, which every game agrees on even when the first
    -- sighting doesn't (the shotgun is stamped mid-air while its zombie is still being hoisted). NoVR
    -- names unnamed things after their index when they're used; those numbers don't count.
    local name = e:GetName() or ""
    local ref
    if n > 0 then
        -- (an enemy from a spawner goes by which spawn it was: they often all share one name)
        ref = string.format("%x#%d", h, n) .. at
    elseif #name <= 64 and name:match("^[%w_%-%.]+$") and name:match("%a") and name:sub(1, 4) ~= "amp_" then
        ref = "=" .. name .. at
    else
        ref = string.format("%x", h) .. at
    end
    i = { h = h, n = n, pos = pos, ref = ref }
    W.info[e] = i
    W.infoIdx[idx] = i
    local list = W.byHash[h]
    if not list then
        list = {}
        W.byHash[h] = list
    end
    table.insert(list, e)
    return i
end

local function refOf(e) return infoOf(e).ref end

-- An enemy a spawner (npc_maker, npc_template_maker) just made is named after which of the spawner's
-- it is: every game runs the same spawners in the same order, so the n-th of its kind from one spawner is
-- the same enemy everywhere, however close together they appear or wherever they wander. Its stamp is
-- the spawner's spot (they never move) and its kind as usual (class|model, so a stray one can still be
-- paired with one of its kind).
local function stampSpawned(maker, e)
    if not IsValidEntity(maker) or not IsValidEntity(e) or e:Attribute_GetIntValue("amp_n", 0) > 0 then return end
    local n = maker:Attribute_GetIntValue("amp_sn", 0) + 1
    maker:Attribute_SetIntValue("amp_sn", n)
    local at = infoOf(maker).pos
    local old = W.info[e]
    if old then
        -- (stamped as it appeared, before the spawner said whose it was)
        local list = W.byHash[old.h]
        if list then for i = #list, 1, -1 do if list[i] == e then table.remove(list, i) end end end
        if W.refCache[old.ref] == e then W.refCache[old.ref] = nil end
        W.info[e] = nil
        W.infoIdx[e:GetEntityIndex()] = nil
    end
    e:Attribute_SetIntValue("amp_h", hash(e:GetClassname() .. "|" .. (e:GetModelName() or "")))
    e:Attribute_SetIntValue("amp_n", n)
    e:Attribute_SetFloatValue("amp_x", at.x)
    e:Attribute_SetFloatValue("amp_y", at.y)
    e:Attribute_SetFloatValue("amp_z", at.z)
    infoOf(e)
end

function AMP_NpcSpawned(self, args)
    if AMP and AMP.World and AMP.World.OnSpawned and self then AMP.World.OnSpawned(self, args and args.activator) end
end

function W.OnSpawned(maker, e)
    if e and IsValidEntity(e) and e.IsNPC and e:IsNPC() then stampSpawned(maker, e) end
end

local function resolve(ref, tolerance)
    local e = W.refCache[ref]
    if e and IsValidEntity(e) then return e end
    local name, nx, ny, nz = ref:match("^=([^@]+)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if name then
        -- by name; several share it: the one first seen nearest the sender's sighting
        local list = Entities:FindAllByName(name)
        local best = list[1]
        if #list > 1 then
            local target = Vector(tonumber(nx), tonumber(ny), tonumber(nz))
            local bestD = (tolerance or REF_TOLERANCE) * 2
            best = nil
            for _, c in ipairs(list) do
                local d = (infoOf(c).pos - target):Length()
                if d < bestD then best, bestD = c, d end
            end
        end
        if best then W.refCache[ref] = best end
        return best
    end
    local hs, sn, x, y, z = ref:match("^(%x+)#?(%d*)@(%-?%d+),(%-?%d+),(%-?%d+)$")
    if not hs then return nil end
    local list = W.byHash[tonumber(hs, 16)]
    if not list then return nil end
    -- a spawner's n-th is exactly that one; anything else is never one of a spawner's
    local n = tonumber(sn) or 0
    local target = Vector(tonumber(x), tonumber(y), tonumber(z))
    local best, bestD = nil, n > 0 and SPAWN_TOLERANCE or tolerance or REF_TOLERANCE
    for i = #list, 1, -1 do
        local c = list[i]
        if not IsValidEntity(c) then
            table.remove(list, i)
        else
            local ci = infoOf(c)
            if ci.n == n then
                local d = (ci.pos - target):Length()
                if d < bestD then best, bestD = c, d end
            end
        end
    end
    if best then W.refCache[ref] = best end
    return best
end

local function ours(e)
    local name = e:GetName()
    return name == "amp_pp" or name == "amp_hud" or name == "alyxmp_core" or name == "alyxmp_precache"
        or name:sub(1, #TARGET_PREFIX) == TARGET_PREFIX or name == "amp_rel" or name == "amp_rel2"
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

-- stop an object's own motion so it holds the pose we give it
local function still(e)
    if e.SetVelocity then e:SetVelocity(Vector(0, 0, 0)) end
    if SetPhysAngularVelocity then pcall(SetPhysAngularVelocity, e, Vector(0, 0, 0)) end
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
local function checkProp(e, now, p)
    if not IsValidEntity(e) or not propClass(e) then return end
    local st = W.props[e]
    local anchor = W.seen[e]
    if anchor and not st then
        -- asleep: physics reports it perfectly still, nothing to look at
        local ok, v = pcall(GetPhysVelocity, e)
        if ok and v and v.x == 0 and v.y == 0 and v.z == 0 then return end
    end
    local cur = pose(e)
    if not anchor or (st and (st.remote or now < (st.quietUntil or 0))) then
        -- first sight, or another player drives it / it's settling after their move
        W.seen[e] = cur
        return
    end
    local d, r = poseDiff(cur, anchor)
    if st and st.owner == myId() then
        if d > STILL_DIST or r > STILL_TURN then
            W.seen[e] = cur
            st.lastMove = now
        end
    elseif (d > START_DIST or r > (e:GetClassname() == "prop_door_rotating_physics" and DOOR_TURN or START_TURN))
        and (isHost() or held(e) or (cur.o - p:GetOrigin()):Length() < CLAIM_RANGE) then
        -- it left its resting spot in our world: we simulate it, the others follow
        st = st or propState(e)
        st.owner = myId()
        st.lastSend = -100
        st.lastMove = now
        W.seen[e] = cur
    end
end

-- The objects near us every check; the rest of the level's a few at a time (the host streams whatever
-- moves anywhere, so it goes round them all). Objects we or others are moving are checked each time.
local function scanProps(now, p)
    if now >= W.nextNear then
        W.nextNear = now + 0.5
        -- around us, and (the host streams what enemies and explosions move) around everyone else
        local spots = { p:GetOrigin() }
        if isHost() then
            for _, pp in pairs(A.puppets or {}) do
                if type(pp.rig) == "table" and IsValidEntity(pp.rig) then table.insert(spots, pp.rig:GetOrigin()) end
            end
        end
        local r2 = NEAR_RADIUS * NEAR_RADIUS
        local near = {}
        for _, e in ipairs(W.propList) do
            if IsValidEntity(e) then
                local o = e:GetOrigin()
                for _, at in ipairs(spots) do
                    local dx, dy, dz = o.x - at.x, o.y - at.y, o.z - at.z
                    if dx * dx + dy * dy + dz * dz < r2 then
                        table.insert(near, e)
                        break
                    end
                end
            end
        end
        W.nearProps = near
    end
    for _, e in ipairs(W.nearProps) do checkProp(e, now, p) end
    for e, st in pairs(W.props) do
        if st.owner == myId() and not st.remote then checkProp(e, now, p) end
    end
    local list = W.propList
    local n = #list
    if n == 0 then return end
    local i = W.propCursor
    for _ = 1, math.min(FAR_CHECKS, n) do
        i = i % n + 1
        checkProp(list[i], now, p)
    end
    W.propCursor = i
end

-- One pass over every entity, a few per frame: new ones get stamped (so the others' refs find them)
-- and the lists the frequent checks walk are rebuilt, instead of asking the engine for everything
-- around us several times a second.
local function walk(p)
    local w = W.walk
    if w.cur and not IsValidEntity(w.cur) then
        -- (the entity we stopped at is gone: start this pass again)
        w.cur, w.props, w.npcs = nil, {}, {}
    end
    for _ = 1, WALK_PER_TICK do
        -- (not "w.cur and Next(w.cur) or First()": at the end of the list Next is nil and that would start over)
        local e
        if w.cur then e = Entities:Next(w.cur) else e = Entities:First() end
        if not e then
            W.propList, W.npcList = w.props, w.npcs
            w.cur, w.props, w.npcs = nil, {}, {}
            W.passes = W.passes + 1
            return
        end
        w.cur = e
        if e ~= p and not ours(e) then
            local class = e:GetClassname()
            if class ~= "worldent" then
                local npc = e.IsNPC and e:IsNPC()
                -- (a new enemy waits for stampNewNpcs: a spawner may still say whose it is)
                if not W.info[e] and not (npc and HOSTILE_SET[class]) then infoOf(e) end
                if PROP_CLASSES[class] or class:sub(1, 5) == "item_" then
                    table.insert(w.props, e)
                elseif npc and not SKIP_NPCS[class] then
                    table.insert(w.npcs, e)
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
        elseif not st.owner and not st.remote and now > (st.quietUntil or 0) + 5 then
            W.props[e] = nil      -- nobody's moving it any more
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
                st.quietUntil = now
                if isHost() then W.moved[refOf(e)] = e end
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
                        if not st.frozen then still(e) end
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
        still(e)
        st.owner = nil
        st.quietUntil = Time() + SETTLE_TIME
        if isHost() then W.moved[ref] = e end
        return
    end
    if not st.frozen and e.DisableMotion then
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
    prop_door_rotating_physics = { "OnOpen", "OnClose", "OnFullyOpen", "OnFullyClosed" },
    prop_handpose = { "OnPlayerPickup", "OnPlayerUse", "OnHandPosed" },
    prop_russell_headset = { "OnPlayerPickup", "OnPlayerUse" },
    prop_welded_physics = { "OnPlayerPickup", "OnPlayerUse" },
    prop_welded_physics_to_target = { "OnPlayerPickup", "OnPlayerUse" },
    trigger_look = { "OnTrigger" },
    trigger_multiple = { "OnStartTouch", "OnEndTouch", "OnTrigger" },
}
-- physics constraints: a bar pulled out of a door's handles, a gun taken out of a dead hand...
local CONSTRAINTS = { "phys_constraint", "phys_ballsocket", "phys_hinge", "phys_hinge_local", "phys_slideconstraint",
    "phys_lengthconstraint", "phys_pulleyconstraint", "phys_ragdollconstraint", "phys_genericconstraint" }
for _, c in ipairs(CONSTRAINTS) do IO_HOOKS[c] = { "OnBreak" } end
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
for _, c in ipairs(CONSTRAINTS) do IO_INPUTS[c] = { OnBreak = "Break" } end
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

-- the classes hooked for spawned enemies (see stampSpawned)
local SPAWNERS = { "npc_maker", "npc_template_maker" }

local function hookSpawners()
    for _, class in ipairs(SPAWNERS) do
        for _, e in ipairs(Entities:FindAllByClassname(class)) do
            if e:Attribute_GetIntValue("amp_spw", 0) == 0 then
                e:Attribute_SetIntValue("amp_spw", 1)
                e:RedirectOutput("OnSpawnNPC", "AMP_NpcSpawned", e)
            end
        end
    end
end

-- hook one class at a time, round after round, instead of all of them at once every few seconds
local function hookSome()
    if not W.hookClasses then
        W.hookClasses = {}
        for class in pairs(IO_HOOKS) do table.insert(W.hookClasses, class) end
        table.sort(W.hookClasses)
    end
    local list = W.hookClasses
    local now = Time()
    if now < (W.nextHookClass or 0) then return end
    W.nextHookClass = now + HOOK_ROUND / #list
    W.hookCursor = W.hookCursor % #list + 1
    local class = list[W.hookCursor]
    for _, e in ipairs(Entities:FindAllByClassname(class)) do
        if not W.hooked[e] and e:Attribute_GetIntValue("amp_io", 0) == 0 then
            W.hooked[e] = true
            e:Attribute_SetIntValue("amp_io", 1)
            for _, o in ipairs(IO_HOOKS[class]) do e:RedirectOutput(o, ioCallback(o), e) end
        end
    end
end

-- hook everything once per load, then pick up entities spawned later
local function hookAll()
    hookSpawners()
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
    -- a VR hand grabbing / letting go of a wheel or lever (games saved by 0.4 lack these, hence the own flag)
    for _, e in ipairs(Entities:FindAllByClassname("prop_animinteractable")) do
        if e:Attribute_GetIntValue("amp_ai", 0) == 0 then
            e:Attribute_SetIntValue("amp_ai", 1)
            e:RedirectOutput("OnInteractStart", "AMP_AnimGrab", e)
            e:RedirectOutput("OnInteractStop", "AMP_AnimRelease", e)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- wheels, levers, cranks, sliding doors (prop_animinteractable): whoever works one streams how far
-- along it is and the others' copies follow; finishing it fires its outputs everywhere (io)

local CRANK_MODEL = "models/interaction/anim_interact/hand_crank_wheel/hand_crank_wheel.vmdl"
-- the Position output NoVR fires while the player works these (useextra.lua), from the completion
local NOVR_POSITION = { ["12712_shotgun_wheel"] = function(v) return v / 2 end }

-- what NoVR's script does when the player finishes these (useextra.lua); when another player
-- finished it, it has to happen here too
local NOVR_DONE = {
    ["12712_shotgun_wheel"] = function()
        -- the winch locks with the bar back in and the shotgun on the lowered zombie can be taken
        local bar = Entities:FindByName(nil, "12712_shotgun_bar_for_wheel")
        if bar then bar:Kill() end
        SpawnEntityFromTableSynchronous("prop_dynamic_override", { targetname = "12712_shotgun_bar_for_wheel",
            model = "models/props/misc_debris/vort_winch_pipe.vmdl", origin = "711.395874 1319.248047 -168.302490",
            angles = "0.087952 120.220528 90.588112" })
        SendToConsole("ent_remove shotgun_pickup_blocker")
    end,
    barricade_door = function() SendToConsole("ent_fire barricade_lock_relay Trigger") end,
    verticaldoor_wheel = function()
        Entities:GetLocalPlayer():Attribute_SetIntValue("locked_jeff_in_freezer", 1)
        SendToConsole("ent_fire relay_verticaldoor_opened Trigger")
    end,
}
-- NoVR lets these be worked again after letting go; everything else is done once it's done
local NOVR_REUSABLE = { "elev_anim_door", "tractor_beam_console_lever", "console_selector_interact", "12712_shotgun_wheel" }

local function animState(e)
    local st = W.anims[e]
    if not st then
        st = { snaps = {} }
        W.anims[e] = st
    end
    return st
end

local function animTouched(e, holding)
    local st = animState(e)
    if st.remote then return end   -- someone else is working it
    st.driveUntil = Time() + (holding and 3600 or AI_DRIVE)
end

function AMP_AnimGrab(self)
    if AMP and AMP.World == W and active() and self and IsValidEntity(self) then animTouched(self, true) end
end

function AMP_AnimRelease(self)
    if AMP and AMP.World == W and active() and self and IsValidEntity(self) then animTouched(self, false) end
end

-- the Position output the others should fire along with the completion value, or nil
local function animPosition(e, v)
    if A.isVR then return v end   -- the game itself fires it as the hand moves
    local f = NOVR_POSITION[e:GetName()]
    if f then return f(v) end
    if e:GetModelName() == CRANK_MODEL then return v end
    return nil
end

local function sendAnims(now)
    for e, st in pairs(W.anims) do
        if not IsValidEntity(e) then
            W.anims[e] = nil
        elseif not st.remote and now < (st.driveUntil or 0) then
            local v = e:GetCycle()
            if not st.lastV or math.abs(v - st.lastV) > 0.0005 then st.lastV, st.lastChange = v, now end
            local moving = now - (st.lastChange or -100) < AI_IDLE
            if (not st.sent or math.abs(v - st.sent) > 0.0005) and (not moving or now - (st.sentAt or -100) >= AI_RATE) then
                st.sent, st.sentAt = v, now
                local pos = animPosition(e, v)
                send("ai", refOf(e), string.format("%.4f", v), pos and string.format("%.4f", pos) or "-")
            end
        end
    end
end

local function applyAnim(e, st, v, pos)
    if st.applied and math.abs(v - st.applied) < 0.0002 then return end
    st.applied = v
    DoEntFireByInstanceHandle(e, "SetCompletionValue", string.format("%.4f", v), 0, nil, nil)
    -- SetCompletionValue fires nothing; whatever follows the wheel (a winch, a gate) listens to Position
    if pos then
        if e:GetName() == "" then e:SetEntityName("amp_ai_" .. e:GetEntityIndex()) end
        SendToConsole("ent_fire_output " .. e:GetName() .. " Position " .. string.format("%.4f", pos))
    end
end

local function renderAnims(now)
    for e, st in pairs(W.anims) do
        if st.remote then
            local snaps = st.snaps
            local n = #snaps
            if not IsValidEntity(e) then
                W.anims[e] = nil
            elseif n > 0 then
                local rt = now - AI_INTERP
                local v, pos
                if rt <= snaps[1].t or n == 1 then
                    v, pos = snaps[1].v, snaps[1].pos
                elseif rt >= snaps[n].t then
                    v, pos = snaps[n].v, snaps[n].pos
                else
                    for i = n - 1, 1, -1 do
                        local a, b = snaps[i], snaps[i + 1]
                        if a.t <= rt then
                            local f = (rt - a.t) / math.max(b.t - a.t, 0.001)
                            v = a.v + (b.v - a.v) * f
                            if a.pos and b.pos then pos = a.pos + (b.pos - a.pos) * f else pos = b.pos end
                            break
                        end
                    end
                end
                while #snaps > 2 and snaps[2].t < rt do table.remove(snaps, 1) end
                if v then applyAnim(e, st, v, pos) end
                -- the stream ended and we've played it out: it's anyone's again
                if now - st.lastRecv > 1.0 and rt >= snaps[#snaps].t then
                    st.remote, st.snaps, st.applied, st.lastV, st.sent = nil, {}, nil, nil, nil
                end
            end
        end
    end
end

local function onAnimMsg(from, ref, v, pos)
    local e = resolve(ref)
    if not e or e:GetClassname() ~= "prop_animinteractable" then return end
    local st = animState(e)
    local now = Time()
    if now < (st.driveUntil or 0) and from > myId() then return end   -- we're working it too and win ties
    st.driveUntil = nil
    st.remote = from
    st.lastRecv = now
    table.insert(st.snaps, { t = now, v = v, pos = pos })
    if #st.snaps > 20 then table.remove(st.snaps, 1) end
end

-- another player finished working one (its completion output came in)
local function animCompleted(e)
    if A.isVR or e:Attribute_GetIntValue("amp_done", 0) == 1 then return end
    e:Attribute_SetIntValue("amp_done", 1)
    local name = e:GetName()
    local reusable = false
    for _, s in ipairs(NOVR_REUSABLE) do if name:find(s, 1, true) then reusable = true end end
    if not reusable then e:Attribute_SetIntValue("used", 1) end
    local f = NOVR_DONE[name]
    if f then f() end
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
    if class == "prop_animinteractable" and output:sub(1, 13) == "OnCompletionA" then animCompleted(e) end
end

-- a use we're replaying runs NoVR's script, which often goes on to use other things nearby (a lock
-- opens its door); those are part of the replay, not something the local player did
local function partOfReplay(e, now)
    local c = e:GetCenter()
    for i = #W.replays, 1, -1 do
        local r = W.replays[i]
        if now > r.untilT then
            table.remove(W.replays, i)
        elseif (r.pos - c):Length() < 400 then
            return true
        end
    end
    return false
end

-- NoVR runs scripts/vscripts/useextra.lua on whatever the player presses E on or picks up; that's
-- where its story handling lives (put on the headset, take the gloves, pull levers...). The launcher
-- adds a line at its top that calls this, and the others run the same script on their copy.
function AMP_OnUseExtra(e)
    if not AMP or AMP.World ~= W or not active() or not e or not IsValidEntity(e) or ours(e) then return end
    local ref = refOf(e)
    local now = Time()
    W.useSeen[ref] = now
    if now < (W.useQuiet[ref] or 0) or partOfReplay(e, now) then return end   -- it's our replay running
    local class = e:GetClassname()
    if consumable(class) then return end
    if class == "prop_door_rotating_physics" or (e:GetModelName() or ""):find("doorhandle", 1, true) then return end
    if class == "prop_animinteractable" then
        -- NoVR animates it for as long as E is held; the others follow how far it gets (ai), and
        -- running NoVR's script on their copy would animate it a second time (or freeze them in place)
        animTouched(e, false)
        return
    end
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
                if e and not consumable(e:GetClassname()) and e:GetClassname() ~= "prop_animinteractable" then
                    W.useSeen[u.ref] = now
                    W.useQuiet[u.ref] = now + USE_SEEN
                    table.insert(W.replays, { pos = e:GetCenter(), untilT = now + 0.6 })
                    local p = Entities:GetLocalPlayer()
                    if A.isVR and (questItem(e) or e:GetClassname():sub(1, 16) == "item_hlvr_weapon") then
                        -- no wrist pockets (or NoVR's instant weapon pickup) in VR: put our copy right
                        -- in front of us to grab
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
-- enemies: the host's game decides. Every game keeps its own copy of each enemy (so it moves, shoots,
-- talks and dies with the game's own animation and sound), but the copies follow the host's: where it
-- is, who it's after, how much health it has and when it dies.
--   host:    nh (health), np (position), ne (which player it's after: an id, or -1 for nobody)
--   clients: their copy is steered to the host's spot and set on the same player; damage they deal
--            goes to the host (nd) and counts as coming from their avatar

local function isNpc(e)
    return e.IsNPC and e:IsNPC() and not SKIP_NPCS[e:GetClassname()] and not ours(e)
end

local function npcRec(e)
    local rec = W.npcs[e]
    if not rec then
        rec = {}
        W.npcs[e] = rec
    end
    return rec
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

-- enemies spawned mid-game are stamped (named) where they appear, before they walk off: every game
-- then names them alike (a spawner's are named after the spawner, see stampSpawned). They also report when they find or lose an enemy (the host uses that).
local function stampNewNpcs()
    for _, class in ipairs(HOSTILE_NPCS) do
        for _, e in ipairs(Entities:FindAllByClassname(class)) do
            -- the check after it appears: a spawner's OnSpawnNPC (stampSpawned) arrives a frame after the
            -- enemy, and names it after the spawner
            if not W.info[e] and not ours(e) then
                if W.fresh[e] then infoOf(e) else W.fresh[e] = true end
            end
            if e:Attribute_GetIntValue("amp_ne", 0) == 0 then
                e:Attribute_SetIntValue("amp_ne", 1)
                e:RedirectOutput("OnFoundEnemy", "AMP_NpcFoundEnemy", e)
                e:RedirectOutput("OnLostEnemy", "AMP_NpcLostEnemy", e)
            end
        end
    end
end

-- every game's enemies also go after the other players' avatars: each avatar carries an invisible
-- npc_bullseye named amp_target_<id> (main.lua) and these always-on relationships cover enemies and
-- avatars that appear later too. (0.5.0/0.5.1 saves carry amp_rel ones aimed at the old single name.)
local function ensureRelationships()
    if Entities:FindByName(nil, "amp_rel2") then return end
    for _, old in ipairs(Entities:FindAllByName("amp_rel")) do old:Kill() end
    for _, class in ipairs(HOSTILE_NPCS) do
        local rel = SpawnEntityFromTableSynchronous("ai_relationship", {
            targetname = "amp_rel2", subject = class, target = TARGET_PREFIX .. "*", disposition = 1, rank = 0,
            StartActive = 1, Reciprocal = 0,
        })
        if rel then DoEntFireByInstanceHandle(rel, "ApplyRelationship", "", 0.1, nil, nil) end
    end
end

function AMP_NpcFoundEnemy(self)
    if AMP and AMP.World and AMP.World.NpcCombat and self and IsValidEntity(self) then AMP.World.NpcCombat(self, true) end
end

function AMP_NpcLostEnemy(self)
    if AMP and AMP.World and AMP.World.NpcCombat and self and IsValidEntity(self) then AMP.World.NpcCombat(self, false) end
end

-- an avatar's bullseye was hit: whatever hit it is after that player
function AMP_AvatarHit(self, args)
    if AMP and AMP.World and AMP.World.AvatarHit and self and IsValidEntity(self) then
        AMP.World.AvatarHit(self, args and args.activator)
    end
end

function W.IsHostile(e) return HOSTILE_SET[e:GetClassname()] == true end

function W.NpcCombat(e, on)
    npcRec(e).combat = on
end

function W.AvatarHit(bullseye, attacker)
    if not attacker or not IsValidEntity(attacker) or not isNpc(attacker) then return end
    local id = tonumber((bullseye:GetName() or ""):match("_(%d+)$") or "")
    if not id then return end
    local rec = npcRec(attacker)
    rec.hitBy, rec.hitAt = id, Time()
end

-- Which player the host's enemy is after. What it last hit tells for sure; otherwise, once it's in a
-- fight, it's the player it faces (soldiers aim at their enemy, zombies and headcrabs face where they go).
local function npcTarget(e, rec, now)
    if rec.hitBy and now - (rec.hitAt or -100) < NPC_HIT_MEMORY then return rec.hitBy end
    if not rec.combat then return -1 end
    local fwd = e:GetForwardVector()
    local fl = math.max(math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y), 0.001)
    local eye = e:EyePosition()
    local best, bestScore = nil, nil
    local function consider(id, pos)
        local d = pos - eye
        local flat = math.sqrt(d.x * d.x + d.y * d.y)
        if flat < 1 or flat > 3000 then return end
        local facing = (fwd.x * d.x + fwd.y * d.y) / (flat * fl)
        if facing < 0.7 then return end   -- more than ~45 degrees off
        local score = (1 - facing) * 4 + flat / 1500
        if not bestScore or score < bestScore then best, bestScore = id, score end
    end
    local p = Entities:GetLocalPlayer()
    if p and p:GetHealth() > 0 then consider(myId(), p:EyePosition()) end
    for id, pp in pairs(A.puppets or {}) do
        if pp.target and IsValidEntity(pp.target) then consider(id, pp.target:GetOrigin()) end
    end
    if best then return best end
    return rec.target or -1   -- turning between targets: keep the last one
end

local function hostSendNpcs(now)
    for _, e in ipairs(W.npcList) do
        if IsValidEntity(e) and e:IsAlive() then
            local rec = npcRec(e)
            local ref = refOf(e)
            local hp = e:GetHealth()
            if hp ~= rec.hp then
                send("nh", ref, hp)
                rec.hp = hp
            end
            if not STATIC_NPCS[e:GetClassname()] then
                local o = e:GetOrigin()
                local yaw = e:GetAngles().y
                if not rec.pos or (o - rec.pos):Length() > NPC_POS_STEP or math.abs(angDiff(yaw, rec.yaw or yaw)) > NPC_YAW_STEP
                    or (now - (rec.posAt or 0) > 2 and (o - rec.pos):Length() > 4) then
                    send("np", ref, f1(o.x), f1(o.y), f1(o.z), f1(yaw))
                    rec.pos, rec.yaw, rec.posAt = o, yaw, now
                end
            end
            if HOSTILE_SET[e:GetClassname()] then
                local t = npcTarget(e, rec, now)
                -- repeated now and then while it's after someone (a client may have just met it)
                if t ~= rec.target or (t ~= -1 and now - (rec.targetAt or -100) > NPC_TARGET_RESEND) then
                    send("ne", ref, t)
                    rec.target, rec.targetAt = t, now
                end
            end
        end
    end
end

-- clients: notice health lost in our world and report it so the host's enemy takes it too
local function clientCheckDamage(p)
    local here = p:GetOrigin()
    for _, e in ipairs(W.npcList) do
        if IsValidEntity(e) and isNpc(e) and (e:GetOrigin() - here):Length() < 2500 then
            local rec = npcRec(e)
            local hp = e:GetHealth()
            if rec.lastHp and hp < rec.lastHp and hp ~= rec.expectHp then
                local o = e:GetOrigin()
                send("nd", W.npcClaim[e] or refOf(e), rec.lastHp - hp, f1(o.x), f1(o.y), f1(o.z))
            end
            rec.lastHp = hp
        end
    end
end

-- The enemy another game means. Normally its ref finds it; enemies that spawned while moving can be
-- stamped a little apart in each game, so failing that take the nearest one of the same kind (hash)
-- around where the sender says it is that isn't already matched to something else.
local function npcByRef(ref, near)
    local e = resolve(ref, NPC_TOLERANCE)
    if e and isNpc(e) then
        local claim = W.npcClaim[e]
        if claim and claim ~= ref and refOf(e) == ref then
            -- it was paired with another of the host's enemies as a guess, but it's this one exactly
            if W.refCache[claim] == e then W.refCache[claim] = nil end
            claim = nil
        end
        if claim == nil or claim == ref then
            W.npcClaim[e] = ref
            return e
        end
    end
    if not near then return nil end
    local hs = ref:match("^(%x+)[#@]")
    local h = hs and tonumber(hs, 16)
    if not h then return nil end
    local best, bestD = nil, NPC_MATCH
    for _, c in ipairs(W.byHash[h] or {}) do
        if IsValidEntity(c) and isNpc(c) and c:IsAlive() and (W.npcClaim[c] == nil or W.npcClaim[c] == ref) then
            local d = (c:GetOrigin() - near):Length()
            if d < bestD then best, bestD = c, d end
        end
    end
    if best then
        W.npcClaim[best] = ref
        W.refCache[ref] = best
    end
    return best
end

local function onNpcHealth(ref, hp)
    local e = npcByRef(ref)
    if not e then return end
    local rec = npcRec(e)
    if hp < e:GetHealth() then
        rec.expectHp = hp
        rec.lastHp = hp
        DoEntFireByInstanceHandle(e, "SetHealth", tostring(hp), 0, nil, nil)
    end
end

-- The host's enemy `ref` is at `pos`, but the one we matched to it is far from there while another of
-- its kind is right there: two that spawned together got swapped. Swap them back.
local function rebind(ref, e, pos)
    if (e:GetOrigin() - pos):Length() < NPC_REBIND then return e end
    local h = infoOf(e).h
    local best, bestD = nil, NPC_REBIND_NEAR
    for _, c in ipairs(W.byHash[h] or {}) do
        if c ~= e and IsValidEntity(c) and isNpc(c) and c:IsAlive() then
            local d = (c:GetOrigin() - pos):Length()
            -- (one that's matched to another enemy only if that one is far from it too)
            local theirs = W.npcClaim[c]
            local free = not theirs or (W.hostPos[theirs] and (c:GetOrigin() - W.hostPos[theirs]):Length() > NPC_REBIND)
            if d < bestD and free then best, bestD = c, d end
        end
    end
    if not best then return e end
    local other = W.npcClaim[best]
    W.npcClaim[e] = other
    if other then W.refCache[other] = e end
    W.npcClaim[best] = ref
    W.refCache[ref] = best
    return best
end

local function onNpcPos(ref, pos, yaw)
    local e = npcByRef(ref, pos)
    if not e or STATIC_NPCS[e:GetClassname()] then return end
    W.hostPos[ref] = pos
    e = rebind(ref, e, pos)
    local rec = npcRec(e)
    -- only while the host's copy is in a fight: before that both copies run the same scripts (a zombie
    -- breaking through a wall, a scripted walk), and being moved would break them out of it
    if not rec.target or rec.target == -1 then return end
    local d = (e:GetOrigin() - pos):Length()
    if d > NPC_TELEPORT then
        e:SetAbsOrigin(pos)
        if yaw then e:SetAngles(0, yaw, 0) end
        rec.steerTo = nil
    elseif d > NPC_STEER then
        -- walk it there (it keeps fighting on the way); don't nag it with the same goal every update
        local now = Time()
        if not rec.steerTo or (rec.steerTo - pos):Length() > 40 or now - (rec.steerAt or -100) > NPC_STEER_EVERY then
            rec.steerTo, rec.steerAt = pos, now
            pcall(function() e:NpcForceGoPosition(pos, true, 24) end)
        end
    end
end

local function relate(e, who, how)
    DoEntFireByInstanceHandle(e, "SetRelationship", who .. " " .. how, 0, nil, nil)
end

-- the host's copy is after player `target` (-1: nobody): set ours on the same one
local function onNpcEnemy(ref, target)
    local e = npcByRef(ref)
    if not e or not e:IsAlive() or not HOSTILE_SET[e:GetClassname()] then return end
    local rec = npcRec(e)
    local me = myId()
    local pp = target ~= me and A.puppets and A.puppets[target]
    local avatar = pp and pp.target and IsValidEntity(pp.target) and pp.target or nil
    -- relationships hold the entities they were given, so set them again when that avatar was respawned
    if rec.target == target and rec.targetEnt == avatar then return end
    -- drop the one it was after, or it keeps shooting at it for a few seconds before switching
    if rec.target and rec.target ~= target then
        local old = rec.target == me and "!player" or (rec.targetEnt and IsValidEntity(rec.targetEnt) and rec.targetEnt:GetName())
        if old then DoEntFireByInstanceHandle(e, "ForgetEntity", old, 0, nil, nil) end
    end
    rec.target, rec.targetEnt = target, avatar
    -- every avatar by its own name: the SetRelationship input takes no wildcards
    for id, other in pairs(A.puppets or {}) do
        if other.target and IsValidEntity(other.target) then
            local how = (target == -1 and "D_HT 0") or (id == target and "D_HT 99") or "D_NU 99"
            relate(e, other.target:GetName(), how)
        end
    end
    if target == -1 then
        relate(e, "player", "D_HT 0")
    elseif target == me then
        relate(e, "player", "D_HT 99")
        DoEntFireByInstanceHandle(e, "UpdateEnemyMemory", "!player", 0, nil, nil)
    elseif avatar then
        relate(e, "player", "D_NU 99")
        DoEntFireByInstanceHandle(e, "UpdateEnemyMemory", avatar:GetName(), 0, nil, nil)
    end
end

-- a client hurt this enemy in their game: the host's copy takes it, from that player's avatar
local function onNpcDamage(from, ref, dmg, near)
    if not isHost() or not dmg or dmg <= 0 then return end
    dmg = math.min(dmg, 400)    -- (what one shot can do; the launcher drops anything bigger)
    local e = npcByRef(ref, near)
    if not e or not e:IsAlive() then return end
    local pp = A.puppets and A.puppets[from]
    local attacker = pp and pp.target and IsValidEntity(pp.target) and pp.target or Entities:GetLocalPlayer()
    local info = CreateDamageInfo(attacker, attacker, Vector(0, 0, 0), e:GetCenter(), dmg, 2)
    e:TakeDamage(info)
    DestroyDamageInfo(info)
end

-- ---------------------------------------------------------------- audits and automatic resync
-- Every few seconds the host lists the enemies alive in its world, and where. Each client pairs them with
-- its own: by name first, then the nearest of the kind around the host's spot, then (for ones that stay
-- unpaired) any of the kind, brought to the host's spot. What's left over of ours is a ghost - the host
-- killed it, or never had it - and goes. When the host keeps listing enemies we have nothing for, our
-- world fell behind the host's: we ask for it again (the launcher loads it).

local function needResync(why)
    local now = Time()
    if isHost() or now - W.lastResync < RESYNC_GAP then return end
    W.lastResync = now
    A.Emit("resync", why)
end

local function kindOf(ref)
    local hs = ref:match("^(%x+)[#@]")
    if hs then return tonumber(hs, 16) end
    local e = resolve(ref)
    return e and infoOf(e).h
end

-- host: the enemies alive in its world, in parts that fit a message
local function hostSendAudit()
    if W.passes < 1 then return end      -- (the list of them isn't complete yet)
    W.auditSeq = W.auditSeq % 999 + 1
    local entries = {}
    for _, e in ipairs(W.npcList) do
        if IsValidEntity(e) and e:IsAlive() and HOSTILE_SET[e:GetClassname()] then
            local o = e:GetOrigin()
            -- ("|", not ":" - the console splits arguments at colons)
            table.insert(entries, string.format("%s|%d,%d,%d", refOf(e), math.floor(o.x + 0.5), math.floor(o.y + 0.5), math.floor(o.z + 0.5)))
        end
    end
    local parts, part = {}, {}
    local len = 0
    for _, en in ipairs(entries) do
        if len + #en + 1 > 440 then
            table.insert(parts, part)
            part, len = {}, 0
        end
        table.insert(part, en)
        len = len + #en + 1
    end
    table.insert(parts, part)
    if #parts > 20 then return end
    for i, pt in ipairs(parts) do
        send("na", W.auditSeq, i, #parts, #pt > 0 and table.concat(pt, " ") or "-")
    end
    -- and where a few of the objects that were moved rest, round robin
    local refs = {}
    for ref, e in pairs(W.moved) do
        if IsValidEntity(e) then table.insert(refs, ref) else W.moved[ref] = nil end
    end
    table.sort(refs)
    for _ = 1, math.min(AUDIT_PROPS, #refs) do
        W.auditPropCursor = W.auditPropCursor % #refs + 1
        local ref = refs[W.auditPropCursor]
        local e = W.moved[ref]
        local st = W.props[e]
        -- (not ones that fell out of the level: nothing to put right there)
        if not (st and (st.owner or st.remote)) and not held(e) and e:GetOrigin().z > -15000 then
            local o, a = e:GetOrigin(), e:GetAngles()
            send("pa", ref, f1(o.x), f1(o.y), f1(o.z), f1(a.x), f1(a.y), f1(a.z))
        end
    end
end

local function killGhost(e)
    W.suppressKill[e] = true
    npcRec(e).expectHp = 0      -- (not damage we dealt: nothing to tell the host)
    DoEntFireByInstanceHandle(e, "SetHealth", "0", 0, nil, nil)
    if A.core then A.core:SetThink(function()
        if IsValidEntity(e) and e:GetHealth() > 0 then e:Kill() end
        return nil
    end, "amp_ghost_" .. e:GetEntityIndex(), 1.0) end
end

-- client: a whole audit arrived
local function onAudit(entries)
    if W.passes < 1 then return end
    local now = Time()
    local mine = {}                        -- our living enemies, by kind
    for _, e in ipairs(W.npcList) do
        if IsValidEntity(e) and e:IsAlive() and HOSTILE_SET[e:GetClassname()] then
            local h = infoOf(e).h
            mine[h] = mine[h] or {}
            table.insert(mine[h], e)
        end
    end
    local taken = {}                       -- ours -> the host's entry it's paired with now
    local function take(en, e)
        taken[e] = en
        en.e = e
    end
    -- 1. by name (or the pairing we already had)
    for _, en in ipairs(entries) do
        en.h = kindOf(en.ref)
        W.hostPos[en.ref] = en.pos
        local e = resolve(en.ref, NPC_TOLERANCE)
        if e and IsValidEntity(e) and e:IsAlive() and isNpc(e) and not taken[e] then take(en, e) end
    end
    -- 2. the nearest unpaired one of its kind around the host's spot; a pair far apart while one of the
    --    kind is right at the host's spot: swapped, so take that one instead
    for _, en in ipairs(entries) do
        if en.h then
            local far = en.e and (en.e:GetOrigin() - en.pos):Length() > NPC_REBIND
            if not en.e or far then
                local best, bestD = nil, en.e and NPC_REBIND_NEAR or NPC_MATCH
                for _, c in ipairs(mine[en.h] or {}) do
                    local d = (c:GetOrigin() - en.pos):Length()
                    local other = taken[c]
                    local free = not other or (other ~= en and (c:GetOrigin() - other.pos):Length() > NPC_REBIND)
                    if d < bestD and free then best, bestD = c, d end
                end
                if best then
                    local other = taken[best]
                    if en.e then
                        -- swap: ours that was paired with this entry goes to the one `best` was paired with
                        taken[en.e] = other
                        if other then other.e = en.e end
                    elseif other then
                        other.e = nil
                    end
                    take(en, best)
                end
            end
        end
    end
    -- 3. still unpaired, two audits running: any left over of the kind, wherever it is, brought over
    local au = W.audit
    au.unpaired = au.unpaired or {}
    local unpaired = {}
    for _, en in ipairs(entries) do
        if not en.e and en.h then
            unpaired[en.ref] = (au.unpaired[en.ref] or 0) + 1
            if unpaired[en.ref] >= 2 then
                local best, bestD = nil, math.huge
                for _, c in ipairs(mine[en.h] or {}) do
                    if not taken[c] and (au.misses[c] or 0) >= 1 then
                        local d = (c:GetOrigin() - en.pos):Length()
                        if d < bestD then best, bestD = c, d end
                    end
                end
                if best then
                    take(en, best)
                    unpaired[en.ref] = nil
                    if bestD > NPC_TELEPORT then best:SetAbsOrigin(en.pos) end
                end
            end
        end
    end
    au.unpaired = unpaired
    -- the pairs stand until the next audit
    for _, list in pairs(mine) do
        for _, e in ipairs(list) do
            local en = taken[e]
            W.npcClaim[e] = en and en.ref or nil
            if en then W.refCache[en.ref] = e end
        end
    end
    -- 4. ours that are left over: ghosts. (Not when none of the host's enemies are ours at all: that's
    --    another world, not a few ghosts - the resync below handles that.)
    local paired = false
    for _ in pairs(taken) do paired = true break end
    local trusted = paired or #entries == 0
    local misses = au.misses
    local removed = 0
    for _, list in pairs(mine) do
        for _, e in ipairs(list) do
            if taken[e] then
                misses[e] = nil
                npcRec(e).leftSince = nil
            elseif trusted then
                local rec = npcRec(e)
                rec.leftSince = rec.leftSince or now
                misses[e] = (misses[e] or 0) + 1
                if misses[e] >= GHOST_AUDITS and now - rec.leftSince > GHOST_AGE and removed < GHOSTS_PER_AUDIT then
                    misses[e] = nil
                    removed = removed + 1
                    killGhost(e)
                end
            end
        end
    end
    -- 5. the host's that we keep having nothing for (the same ones, audit after audit): we're behind
    local behind = 0
    for _, count in pairs(unpaired) do
        if count >= BEHIND_AUDITS then behind = behind + 1 end
    end
    if behind >= BEHIND_ENEMIES then
        au.unpaired = {}
        needResync("enemies")
    end
end

local function onAuditPart(seq, part, parts, a)
    local au = W.audit
    if au.seq ~= seq then
        au.seq = seq
        au.parts = {}
    end
    local entries = {}
    for i = 4, #a do
        local ref, x, y, z = a[i]:match("^(.+)|(%-?%d+),(%-?%d+),(%-?%d+)$")
        if ref then
            table.insert(entries, { ref = ref, pos = Vector(tonumber(x), tonumber(y), tonumber(z)) })
        elseif a[i] ~= "-" then
            -- something we can't read: this audit can't be trusted (it would make everything look like a ghost)
            au.seq = nil
            au.parts = {}
            return
        end
    end
    au.parts[part] = entries
    for i = 1, parts do if not au.parts[i] then return end end
    local all = {}
    for i = 1, parts do for _, en in ipairs(au.parts[i]) do table.insert(all, en) end end
    au.parts = {}
    onAudit(all)
end

-- client: where the host's copy of a moved object rests; ours goes there if it drifted (unless we moved
-- it a moment ago: the host may not have heard yet)
local function onPropAudit(ref, pos, ax, ay, az)
    local e = resolve(ref)
    if not e or not propClass(e) or held(e) then return end
    local st = W.props[e]
    if st and (st.owner or st.remote or Time() < (st.quietUntil or 0) + 3) then return end
    local a = e:GetAngles()
    if (e:GetOrigin() - pos):Length() < 12 and math.abs(angDiff(a.x, ax)) < 15 and math.abs(angDiff(a.y, ay)) < 15
        and math.abs(angDiff(a.z, az)) < 15 then return end
    e:SetAbsOrigin(pos)
    e:SetAngles(ax, ay, az)
    still(e)
    W.seen[e] = pose(e)
end

local function onKilled(ref, near)
    local e = npcByRef(ref, near)
    if not e then return end
    W.suppressKill[e] = true
    npcRec(e).expectHp = 0      -- (not damage we dealt: nothing to tell the host)
    if W.journal then
        -- catch-up after loading the level: it died long ago over there. Right after a load an enemy can still
        -- be setting itself up (no health yet, so SetHealth 0 does nothing): remove it outright
        e:Kill()
        return
    end
    if e:GetHealth() <= 0 then return end
    DoEntFireByInstanceHandle(e, "SetHealth", "0", 0, nil, nil)
    -- some enemies ignore SetHealth 0 (scripted states); remove those
    if A.core then A.core:SetThink(function()
        if IsValidEntity(e) and (e:GetHealth() > 0 or e:IsAlive()) then e:Kill() end
        return nil
    end, "amp_kill_" .. ref, 1.0) end
end

---------------------------------------------------------------------------------------------------
-- entry points used by main.lua

function W.Start()
    stampAll()
    hookAll()
    refreshNpcList()
    local props = {}
    for class in pairs(PROP_CLASSES) do
        for _, e in ipairs(Entities:FindAllByClassname(class)) do table.insert(props, e) end
    end
    W.propList = props
    W.passes = 0
    W.nextStamp = Time() + STAMP_SCAN
    W.nextHook = Time() + 5
end

-- the waiting catch-up entries, in order: each once its entity is there (or it waited long enough - then it
-- goes ahead anyway, and the usual fallbacks get their chance)
local function replayWaiting(now)
    while #W.journalWait > 0 do
        local j = W.journalWait[1]
        if j.args[1] and not resolve(j.args[1], NPC_TOLERANCE) and now < j.giveUp then return end
        table.remove(W.journalWait, 1)
        W.journal = true
        local ok, err = pcall(W.Receive, j.from, j.kind, j.args)
        W.journal = false
        if not ok then A.Emit("err", "journal", tostring(err)) end
    end
end

function W.Tick(now, p)
    if not active() or not p then return end
    walk(p)
    if #W.journalWait > 0 and now >= (W.nextJournalTry or 0) then
        W.nextJournalTry = now + 0.5
        replayWaiting(now)
    end
    if now >= W.nextStamp then
        W.nextStamp = now + STAMP_SCAN
        ensureRelationships()
    end
    if now >= W.nextNpcStamp then
        W.nextNpcStamp = now + NPC_STAMP_SCAN
        stampNewNpcs()
    end
    if now >= W.nextScan then
        W.nextScan = now + PROP_CHECK
        scanProps(now, p)
    end
    sendOwned(now)
    renderRemote(now)
    sendAnims(now)
    renderAnims(now)
    runUses(now)
    if now >= W.nextItems then
        W.nextItems = now + 0.25
        scanItems(now, p)
    end
    hookSome()
    if now >= W.nextHook then
        W.nextHook = now + 5
        hookSpawners()
    end
    if isHost() then
        if now >= W.nextNpcSend then
            W.nextNpcSend = now + 0.25
            hostSendNpcs(now)
        end
        if now >= W.nextAudit then
            W.nextAudit = now + AUDIT_EVERY
            hostSendAudit()
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
        -- what the others did before we loaded. Its entity may not exist yet (some are spawned a moment
        -- after the level starts): then it waits, and so does everything after it, to keep the order
        if #W.journalWait > 0 or (rest[1] and not resolve(rest[1], NPC_TOLERANCE)) then
            table.insert(W.journalWait, { from = from, kind = a[1], args = rest, giveUp = Time() + JOURNAL_WAIT })
            return
        end
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
    -- enemy health / position / target are the host's to say (the host is player 1; the launcher checks
    -- this too)
    if (kind == "nh" or kind == "np" or kind == "ne" or kind == "na" or kind == "pa") and (isHost() or from ~= 1) then return end
    if kind == "na" then
        local seq, part, parts = n(1), n(2), n(3)
        if seq and part and parts and part >= 1 and part <= parts and parts <= 20 then onAuditPart(seq, part, parts, a) end
        return
    end
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
        onKilled(ref, n(4) and Vector(n(2), n(3), n(4)) or nil)
    elseif kind == "tg" then
        onTrigger(ref)
    elseif kind == "io" then
        if a[2] then onOutput(ref, a[2]) end
    elseif kind == "ai" then
        if n(2) then onAnimMsg(from, ref, n(2), n(3)) end
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
        if n(4) and not isHost() then onNpcPos(ref, Vector(n(2), n(3), n(4)), n(5)) end
    elseif kind == "nd" then
        if n(2) then onNpcDamage(from, ref, n(2), n(5) and Vector(n(3), n(4), n(5)) or nil) end
    elseif kind == "ne" then
        if n(2) and not isHost() then onNpcEnemy(ref, n(2)) end
    elseif kind == "pa" then
        if n(7) then onPropAudit(ref, Vector(n(2), n(3), n(4)), n(5), n(6), n(7)) end
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
    local o = e:GetOrigin()
    send("kd", W.npcClaim[e] or refOf(e), f1(o.x), f1(o.y), f1(o.z))
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
