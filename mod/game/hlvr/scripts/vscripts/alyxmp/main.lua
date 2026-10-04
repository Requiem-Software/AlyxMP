-- Alyx MP: the in-game half of the multiplayer mod.
--
-- Loaded on every map by cfg/skill_manifest.cfg ("script_reload_code alyxmp/main") and re-run by the
-- launcher when it attaches. The launcher reads our "[AMP]..." print() lines over VConsole and talks
-- back through the amp_* console commands registered below.
--
-- Remote players are drawn as Alyx bone-merged onto an invisible animated "rig" model. HL:Alyx's
-- Alyx model has no locomotion, but every human model shares her skeleton, so:
--   stand  - citizen_female_01: idle, 8-way walk/run
--   crouch - worker_m_helmet:   crouched idle
--   armed  - combine_grunt:     rifle idle, 8-way sprint with weapon, crouched aim
-- Weapons are the player's own weapon models bone-merged onto the rig's weapon_hand_R bone.
-- HL:Alyx doesn't render point_worldtext: name tags use the debug overlay, and the chat feed,
-- loading-zone banner and interact hint use game_text (the game's own HUD message font).

AMP = AMP or {}
local A = AMP
A.VERSION = "0.4.0"
A.PROTO = 3

local MODEL_ALYX = "models/characters/alyx/alyx.vmdl"
-- Every pose comes from the Combine soldier's animation set on one invisible rig that Alyx is
-- bone-merged onto. Staying on one rig means each change of animation is the engine's own blend.
local RIG_MODEL = "models/characters/combine_grunt/combine_grunt.vmdl"
local SEQ_IDLE = "idle_rifle_lowered"
local SEQ_IDLE_AIM = "combatidle"                 -- for a while after shooting
local SEQ_CROUCH = "crouch_idle_rifle_all"
local SEQ_RUN = "sprint_alt_"                     -- + direction, the soldiers' 8-way run
local SEQ_START = "stand_to_run_down_axis_"       -- + direction: setting off
local SEQ_STOP = "run_to_stand_down_axis_"        -- + direction: coming to a stop
local SEQ_STOP_S = "run_to_stand_down_west_axis_s" -- (there's no plain _s one)
local START_TIME = 0.35     -- how long the setting-off / stopping steps play before the run / idle
local STOP_TIME = 0.45
local DIRS = { "n", "nw", "w", "sw", "s", "se", "e", "ne" }

-- weapon codes on the wire: 0 none, 1 pistol, 2 shotgun, 3 smg
local WEAPONS = {
    [1] = { model = "models/weapons/vr_alyxgun/vr_alyxgun.vmdl", fx = "particles/weapon_fx/muzzleflash_pistol.vpcf", snd = "AlyxPistol.Fire" },
    [2] = { model = "models/weapons/vr_shotgun/vr_flip_shotgun_body.vmdl", fx = "particles/weapon_fx/muzzleflash_heavy_shotgun.vpcf", snd = "CombineShotgun.Fire" },
    [3] = { model = "models/weapons/vr_ipistol/vr_ipistol.vmdl", fx = "particles/weapon_fx/muzzleflash_player_rapidfire.vpcf", snd = "CombineSMG.Fire" },
}

local INTERP_MIN = 0.1      -- remote players are rendered this far behind their newest snapshot,
local INTERP_MAX = 0.35     -- more when their packets arrive unevenly
local EXTRAP = 0.25         -- how long we keep moving a player whose packets are late
local SMOOTH_POS = 0.045    -- time constants of the final position/yaw smoothing (s)
local SMOOTH_YAW = 0.06
local TELEPORT_DIST = 260   -- bigger jumps than this between snapshots aren't interpolated
local SEND_INTERVAL = 0.05  -- 20 Hz state updates
local HEARTBEAT = 0.5       -- resend state at least this often while standing still
local WALK_SPEED = 12       -- below this a player is idle (units/s)
local RUN_SPEED = 135       -- above this the run cycle is used
local AIM_HOLD = 1.2        -- keep the aiming pose this long after a shot
-- natural speeds of the locomotion clips, so playback can follow the real movement speed
local CLIP_SPEED = { sprint_alt_ = 250 }
local ZONE_PAD = 12         -- leeway around changelevel trigger volumes
local ZONE_DRAW_DIST = 900
local MASK_PLAYERSOLID = 33636363
local ATTACH_FOLLOW = PATTACH_POINT_FOLLOW or 5

local IS_VR = not GlobalSys:CommandLineCheck("-novr")
local SCREEN_W = GlobalSys:CommandLineInt("-w", 1280)
local PROP_NAME = "amp_pp"  -- every prop the mod spawns; saves restore them, so they get cleaned up on load
local HUD_NAME = "amp_hud"
local USE_RANGE = 75        -- NoVR's E reaches about this far (it caps player_use_radius at 60)
local PULL_RANGE = 650      -- gravity-glove pulls

---------------------------------------------------------------------------------------------------
-- helpers

local atan2 = math.atan2 or math.atan

local function fmt(n) return string.format("%.1f", n) end

function A.Emit(...)
    local parts = { ... }
    for i = 1, #parts do parts[i] = tostring(parts[i]) end
    print("[AMP]" .. table.concat(parts, " "))
end

local function displayName(s) return (string.gsub(s or "?", "_", " ")) end

local function angleDiff(a, b)
    local d = (a - b) % 360
    if d > 180 then d = d - 360 end
    return d
end

local function lerpAngle(a, b, f) return a + angleDiff(b, a) * f end

local function bit(flags, n) return math.floor(flags / n) % 2 == 1 end

local function killEnt(e) if e and IsValidEntity(e) then e:Kill() end end

local function vecStr(v) return fmt(v.x) .. " " .. fmt(v.y) .. " " .. fmt(v.z) end

local function localFeetAndView(p)
    local feet = p:GetOrigin()
    if IS_VR then
        local hmd = p:GetHMDAvatar()
        if hmd then
            local h = hmd:GetOrigin()
            local ang = hmd:GetAngles()
            return Vector(h.x, h.y, feet.z), ang.y, ang.x, h.z - feet.z
        end
    end
    local eye = p:EyePosition()
    local ang = p:EyeAngles()
    return feet, ang.y, ang.x, eye.z - feet.z
end

---------------------------------------------------------------------------------------------------
-- (re)initialisation: this file runs again on every map load and every launcher attach

local function destroyPuppetEnts(pp)
    killEnt(pp.weaponEnt)
    killEnt(pp.alyx)
    killEnt(pp.alyxB)
    if type(pp.rig) == "table" then killEnt(pp.rig) end
    if pp.rigs then for _, r in pairs(pp.rigs) do killEnt(r) end end  -- from older versions of this file
    pp.weaponEnt, pp.alyx, pp.alyxB, pp.rigs, pp.rig, pp.seq = nil, nil, nil, nil, nil, nil
    pp.weaponCode, pp.placed, pp.phase = nil, nil, nil
end

if A.puppets then
    for _, pp in pairs(A.puppets) do destroyPuppetEnts(pp) end
end
for _, id in ipairs(A.listeners or {}) do StopListeningToGameEvent(id) end

A.puppets = {}
A.listeners = {}
A.cfg = A.cfg or {}
A.zones = {}
A.zoneArmed = {}
A.zoneStatus = nil
A.myZone = nil
A.feed = {}
A.feedDirty = true
A.hint = nil
A.nextHint = 0
A.nextHintRefresh = 0
A.suppressKill = {}
A.ready = false
A.transitioning = false
A.levelChangeStarted = false
A.handlers = {}
A.lastSend = -100
A.lastSent = nil
A.lastShotEmit = -100
A.vrWeapon = A.vrWeapon or 0
A.vm = nil
A.vmSeq, A.vmCycle = nil, nil
A.nextVmScan = 0
A.nextZoneCheck = 0
A.nextZoneScan = 0
A.nextGate = 0
A.nextHud = 0
A.map = GetMapName()

local function mpActive() return A.cfg.mp == "1" end
A.isVR = IS_VR

DoIncludeScript("alyxmp/world.lua", nil)

---------------------------------------------------------------------------------------------------
-- HUD

local FEED_LINES = 6
local FEED_TIME = 12

-- the launcher tells us the game window's size (amp_cfg sw / sh); the overlay works in pixels
local function screenSize()
    return tonumber(A.cfg.sw or "") or 1920, tonumber(A.cfg.sh or "") or 1080
end

-- font sizes are given for 1080p and scale with the window height
local function px(n)
    local _, h = screenSize()
    return math.floor(n * h / 1080 + 0.5)
end

local function screenText(x, y, text, size, bold, r, g, b, dur)
    DebugScreenTextPretty(math.floor(x), math.floor(y), 0, text, r, g, b, 255, dur, "", size, bold)
end

local function centerText(y, text, size, bold, r, g, b, dur)
    local w = screenSize()
    screenText(w / 2 - #text * size * (bold and 0.29 or 0.26), y, text, size, bold, r, g, b, dur)
end

--- A line in the chat feed on the left of the screen.
function A.Feed(text)
    table.insert(A.feed, { text = text, t = Time() })
    while #A.feed > FEED_LINES do table.remove(A.feed, 1) end
end

function A.Note(text) A.Feed("* " .. text) end

local function drawFeed(now, dur)
    local keep = {}
    for _, f in ipairs(A.feed) do if now - f.t < FEED_TIME then table.insert(keep, f) end end
    A.feed = keep
    local w, h = screenSize()
    local size = px(21)
    for i, f in ipairs(keep) do
        screenText(w * 0.02, h * 0.5 + (i - 1) * size * 1.3, f.text, size, false, 255, 226, 160, dur)
    end
end

local function drawHud(now, p)
    local dur = 0.3
    if mpActive() then
        local count = 1
        for _ in pairs(A.puppets) do count = count + 1 end
        local size = px(19)
        local x, y = px(24), px(56)
        screenText(x, y, "ALYX MP  -  " .. count .. (count == 1 and " player" or " players") .. "    Y: chat   /help for commands", size, true, 255, 170, 40, dur)
        for _, pp in pairs(A.puppets) do
            y = y + size * 1.3
            local txt = "  " .. displayName(pp.name)
            if pp.map and pp.map ~= A.map then
                txt = txt .. "  (" .. pp.map .. ")"
            elseif pp.renderPos and p then
                txt = txt .. string.format("  %dm", math.floor((pp.renderPos - p:GetOrigin()):Length() / 39.37 + 0.5))
            end
            screenText(x, y, txt, size, false, 230, 230, 230, dur)
        end
    end
    drawFeed(now, dur)

    if A.myZone and mpActive() then
        local st = A.zoneStatus
        local title, sub
        if A.transitioning then
            title, sub = "LOADING ZONE", "Everyone is here - loading..."
        elseif st and st.id == A.myZone then
            title = string.format("LOADING ZONE  %d/%d players ready", st.ready, st.total)
            if st.waiting ~= "" then sub = "Waiting for: " .. displayName(st.waiting) end
        else
            title, sub = "LOADING ZONE", "Waiting for the other players"
        end
        local _, h = screenSize()
        centerText(h * 0.16, title, px(28), true, 120, 255, 140, dur)
        if sub then centerText(h * 0.16 + px(28) * 1.35, sub, px(21), false, 200, 255, 210, dur) end
    end
end

---------------------------------------------------------------------------------------------------
-- crosshair hint: what NoVR's E key would do with the thing you're looking at

local USE_CLASSES = {
    func_button = true, func_physical_button = true, func_rot_button = true, prop_animinteractable = true,
    prop_door_rotating = true, prop_door_rotating_physics = true, prop_hlvr_crafting_station_console = true,
    item_health_station_charger = true, item_combine_tank_locker = true, info_hlvr_holo_hacking_plug = true,
    hlvr_piano = true, prop_reviver_heart = true,
}
local PICKUP_CLASSES = { prop_physics = true, prop_physics_override = true, prop_physics_multiplayer = true, prop_physics_interactive = true }
local USE_WORDS = { "button", "switch", "lever", "door", "crank", "wheel", "drawer", "lid", "hatch", "handle", "plug", "socket", "ladder", "console", "panel", "valve", "lock", "window" }

local function eyeForward(ang)
    local p, y = math.rad(ang.x), math.rad(ang.y)
    return Vector(math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), -math.sin(p))
end

local function massOf(e)
    local ok, mass = pcall(function() return e:GetMass() end)
    return ok and mass or 0
end

local function aimTrace(p, eye, dir, size)
    local tr = { startpos = eye, endpos = eye + dir * PULL_RANGE, ignore = p, mask = 33636363 }
    if size then
        tr.min = Vector(-size, -size, -size)
        tr.max = Vector(size, size, size)
        TraceHull(tr)
    else
        TraceLine(tr)
    end
    local e = tr.enthit
    if not tr.hit or not e or not IsValidEntity(e) then return nil end
    local class = e:GetClassname()
    if class == "worldent" or class == "player" then return nil end
    return e, class, tr.pos
end

local function interactLabel(p)
    if p:GetHealth() <= 0 then return nil end
    local eye = p:EyePosition()
    local dir = eyeForward(p:EyeAngles())
    -- small things (ammo clips, resin) are easy to miss with a ray, so also try a thin box
    local e, class, hitPos = aimTrace(p, eye, dir, 4)
    if not e then e, class, hitPos = aimTrace(p, eye, dir, nil) end
    if not e then return nil end
    local name = string.lower(e:GetName() or "")
    if name == PROP_NAME then return nil end
    local dist = (hitPos - eye):Length()
    local item = class:sub(1, 5) == "item_"
    local physics = PICKUP_CLASSES[class]
    if dist <= USE_RANGE then
        if item then return "[E]  PICK UP" end
        if physics then return massOf(e) <= 35 and "[E]  PICK UP" or nil end
        if USE_CLASSES[class] or class:find("door", 1, true) then return "[E]  USE" end
        if class == "prop_dynamic" then
            for _, w in ipairs(USE_WORDS) do if name:find(w, 1, true) then return "[E]  USE" end end
        end
        return nil
    end
    -- further away the gravity gloves can pull light things
    if (item or physics) and p:Attribute_GetIntValue("gravity_gloves", 0) == 1 and massOf(e) <= 15 then
        return "[E]  PULL"
    end
    return nil
end

local function updateHint(now, p)
    if IS_VR or now < A.nextHint then return end
    A.nextHint = now + 0.1
    A.hint = interactLabel(p)
    if A.hint then
        local _, h = screenSize()
        centerText(h * 0.5 + px(30), A.hint, px(22), true, 255, 170, 40, 0.12)
    end
end

---------------------------------------------------------------------------------------------------
-- remote players

local function spawnProp(model, pos, seq)
    return SpawnEntityFromTableSynchronous("prop_dynamic", {
        targetname = PROP_NAME,
        model = model,
        origin = vecStr(pos),
        DefaultAnim = seq,
        solid = 0,
    })
end

local function buildPuppet(pp, pos)
    pp.rig = spawnProp(RIG_MODEL, pos, SEQ_IDLE)
    pp.rig:SetRenderAlpha(0)
    pp.alyx = spawnProp(MODEL_ALYX, pos, nil)
    pp.alyx:FollowEntity(pp.rig, true)
    pp.seq = nil
    pp.phase = nil
    pp.weaponCode = nil
end

local function puppetValid(pp)
    return type(pp.rig) == "table" and IsValidEntity(pp.rig) and pp.alyx ~= nil and IsValidEntity(pp.alyx)
end

local function getPuppet(id)
    local pp = A.puppets[id]
    if not pp then
        pp = { id = id, name = "Player" .. id, snaps = {}, vel = Vector(0, 0, 0), speed = 0, weapon = 0, lastShot = -100 }
        A.puppets[id] = pp
    end
    return pp
end

local function removePuppet(id)
    local pp = A.puppets[id]
    if not pp then return end
    destroyPuppetEnts(pp)
    A.puppets[id] = nil
end

local function hidePuppet(pp)
    destroyPuppetEnts(pp)
    pp.snaps = {}
    pp.off = nil
    pp.renderPos, pp.renderYaw = nil, nil
end

local function ensureWeapon(pp, code)
    if pp.weaponCode == code and (code == 0 or (pp.weaponEnt and IsValidEntity(pp.weaponEnt))) then return end
    killEnt(pp.weaponEnt)
    pp.weaponEnt = nil
    pp.weaponCode = code
    local w = WEAPONS[code]
    if not w or not puppetValid(pp) then return end
    pp.weaponEnt = spawnProp(w.model, pp.rig:GetOrigin(), nil)
    pp.weaponEnt:FollowEntity(pp.rig, true)
end

-- Re-setting a bone-merge parent's transform every tick, even to the same values, stops the game
-- from drawing the merged Alyx model, so only touch it when it really moved.
local function placeRig(pp, pos, yaw)
    local last = pp.placed
    if last and (last.pos - pos):Length() < 0.05 and math.abs(angleDiff(last.yaw, yaw)) < 0.05 then return end
    pp.rig:SetOrigin(pos)
    pp.rig:SetAngles(0, yaw, 0)
    pp.placed = { pos = pos, yaw = yaw }
end

local function moveDir(pp, relDir)
    -- 8-way direction with hysteresis so diagonal movement doesn't flicker between cycles
    local idx = math.floor(((relDir + 22.5) % 360) / 45) + 1
    if pp.dirIdx then
        local center = (pp.dirIdx - 1) * 45
        if math.abs(angleDiff(relDir, center)) < 32 then idx = pp.dirIdx end
    end
    pp.dirIdx = idx
    return DIRS[idx]
end

-- idle -> setting off -> running -> stopping -> idle, the way the soldiers move
local function chooseSeq(pp, now, crouched, aiming, relDir)
    if crouched then
        pp.phase = "crouch"
        return SEQ_CROUCH
    end
    if pp.speed >= WALK_SPEED then
        local dir = moveDir(pp, relDir)
        if pp.phase ~= "start" and pp.phase ~= "run" then
            pp.phase, pp.phaseAt = "start", now
        elseif pp.phase == "start" and now - pp.phaseAt >= START_TIME then
            pp.phase = "run"
        end
        pp.lastDir = dir
        return (pp.phase == "start" and SEQ_START or SEQ_RUN) .. dir
    end
    if pp.phase == "start" or pp.phase == "run" then pp.phase, pp.phaseAt = "stop", now end
    if pp.phase == "stop" and now - pp.phaseAt < STOP_TIME then
        local d = pp.lastDir or "n"
        return d == "s" and SEQ_STOP_S or SEQ_STOP .. d
    end
    pp.phase = "idle"
    return aiming and SEQ_IDLE_AIM or SEQ_IDLE
end

local function fireEffects(pp, code)
    local w = WEAPONS[code]
    if not w or not puppetValid(pp) then return end
    ensureWeapon(pp, code)
    local ent = pp.weaponEnt
    if not ent or not IsValidEntity(ent) then return end
    local fx = ParticleManager:CreateParticle(w.fx, PATTACH_POINT_FOLLOW, ent)
    ParticleManager:SetParticleControlEnt(fx, 0, ent, PATTACH_POINT_FOLLOW, "muzzle", Vector(0, 0, 0), true)
    ParticleManager:ReleaseParticleIndex(fx)
    StartSoundEvent(w.snd, ent)
end

-- Cubic Hermite between two snapshots using their velocities, so paths curve smoothly through
-- corners instead of zig-zagging between 20 Hz samples.
local function hermite(a, b, f)
    local dt = b.st - a.st
    local f2, f3 = f * f, f * f * f
    local h00 = 2 * f3 - 3 * f2 + 1
    local h10 = f3 - 2 * f2 + f
    local h01 = -2 * f3 + 3 * f2
    local h11 = f3 - f2
    return a.pos * h00 + a.vel * (h10 * dt) + b.pos * h01 + b.vel * (h11 * dt)
end

-- Where the remote player is on their own clock, a little in the past so there's always a snapshot
-- on either side; the delay grows when their packets arrive unevenly.
local function samplePuppet(pp, rt)
    local snaps = pp.snaps
    local n = #snaps
    if rt <= snaps[1].st then
        local s = snaps[1]
        return s.pos, s.yaw, s.eyeh, s.flags, s.weapon, false
    end
    if rt >= snaps[n].st then
        local s = snaps[n]
        local ex = math.min(rt - s.st, EXTRAP)
        return s.pos + s.vel * ex, s.yaw, s.eyeh, s.flags, s.weapon, false
    end
    for i = n - 1, 1, -1 do
        local a, b = snaps[i], snaps[i + 1]
        if a.st <= rt then
            local f = (rt - a.st) / math.max(b.st - a.st, 0.001)
            if b.teleport then
                return b.pos, b.yaw, b.eyeh, b.flags, b.weapon, true
            end
            return hermite(a, b, f), lerpAngle(a.yaw, b.yaw, f), a.eyeh + (b.eyeh - a.eyeh) * f, b.flags, b.weapon, false
        end
    end
    local s = snaps[n]
    return s.pos, s.yaw, s.eyeh, s.flags, s.weapon, false
end

local function setPlayback(pp, rig, seq)
    local rate = 1
    for prefix, clip in pairs(CLIP_SPEED) do
        if seq:sub(1, #prefix) == prefix then
            rate = math.max(0.55, math.min(1.6, pp.speed / clip))
            break
        end
    end
    if pp.rate and math.abs(rate - pp.rate) < 0.07 and pp.rateSeq == seq then return end
    pp.rate, pp.rateSeq = rate, seq
    DoEntFireByInstanceHandle(rig, "SetPlaybackRate", string.format("%.2f", rate), 0, nil, nil)
end

local function updatePuppet(pp, now, dt)
    local snaps = pp.snaps
    if #snaps == 0 or not pp.off then return end
    if pp.map and pp.map ~= A.map then
        if pp.alyx then hidePuppet(pp) end
        return
    end

    local rt = now - pp.off - (pp.interp or INTERP_MIN)
    local pos, yaw, eyeh, flags, weapon, jumped = samplePuppet(pp, rt)
    while #snaps > 3 and snaps[2].st < rt - 0.5 do table.remove(snaps, 1) end

    if bit(flags, 4) then  -- dead: they're about to reload, don't leave a statue behind
        if pp.alyx then hidePuppet(pp) end
        return
    end

    if not puppetValid(pp) then
        if not A.ready or not A.core then return end
        destroyPuppetEnts(pp)
        buildPuppet(pp, pos)
        pp.renderPos, pp.renderYaw = nil, nil
    end

    -- last smoothing pass over the interpolated path: removes the small steps left by late packets
    if not pp.renderPos or jumped or (pos - pp.renderPos):Length() > TELEPORT_DIST then
        pp.renderPos, pp.renderYaw = pos, yaw
        pp.vel = Vector(0, 0, 0)
    else
        local kp = 1 - math.exp(-dt / SMOOTH_POS)
        local ky = 1 - math.exp(-dt / SMOOTH_YAW)
        local prev = pp.renderPos
        pp.renderPos = prev + (pos - prev) * kp
        pp.renderYaw = pp.renderYaw + angleDiff(yaw, pp.renderYaw) * ky
        if dt > 0 then
            local v = (pp.renderPos - prev) * (1 / dt)
            v.z = 0
            pp.vel = pp.vel + (v - pp.vel) * math.min(dt * 8, 1)
        end
    end
    pos, yaw = pp.renderPos, pp.renderYaw
    pp.speed = pp.vel:Length()

    ensureWeapon(pp, weapon or 0)
    local aiming = (now - pp.lastShot) < AIM_HOLD
    local moveYaw = math.deg(atan2(pp.vel.y, pp.vel.x))
    local seq = chooseSeq(pp, now, bit(flags, 2), aiming, angleDiff(moveYaw, yaw))
    placeRig(pp, pos, yaw)
    if seq ~= pp.seq then
        pp.rig:ResetSequence(seq)
        pp.seq = seq
        pp.rate = nil
    end
    setPlayback(pp, pp.rig, seq)

    local label = displayName(pp.name)
    local p = Entities:GetLocalPlayer()
    if p then
        local dist = (pos - p:GetOrigin()):Length() / 39.37
        if dist > 15 then label = string.format("%s  [%dm]", label, math.floor(dist + 0.5)) end
    end
    DebugDrawText(pos + Vector(0, 0, math.max(eyeh, 30) + 14), label, false, 0)
end

local function addSnapshot(id, map, st, pos, yaw, pitch, eyeh, flags, weapon)
    local pp = getPuppet(id)
    local now = Time()
    if map ~= pp.map then
        pp.map = map
        pp.snaps = {}
        pp.off = nil
    end
    local snaps = pp.snaps
    local last = snaps[#snaps]
    -- the sender's clock restarts on map load; also drop anything out of order
    if last and (st < last.st - 1) then
        snaps = {}
        pp.snaps = snaps
        pp.off = nil
        last = nil
    end
    if last and st <= last.st then return end

    -- clock offset: snap down to the fastest delivery seen, drift up slowly when the route gets slower
    local off = now - st
    if not pp.off or math.abs(off - pp.off) > 1.0 then
        pp.off = off
        pp.jitter = 0.01
    elseif off < pp.off then
        pp.off = off
    else
        pp.off = pp.off + (off - pp.off) * 0.02
    end
    -- jitter = how much later than the fastest packet things typically arrive
    pp.jitter = (pp.jitter or 0.01) * 0.95 + math.max(0, off - pp.off) * 0.05
    pp.interp = math.max(INTERP_MIN, math.min(INTERP_MAX, 0.06 + pp.jitter * 3))

    local s = { st = st, pos = pos, yaw = yaw, pitch = pitch, eyeh = eyeh, flags = flags, weapon = weapon, vel = Vector(0, 0, 0) }
    if last then
        local dts = math.max(st - last.st, 0.001)
        if (pos - last.pos):Length() > TELEPORT_DIST then
            s.teleport = true
        else
            s.vel = (pos - last.pos) * (1 / dts)
            -- central difference for the previous sample now that both neighbours are known
            local before = snaps[#snaps - 1]
            if before and not last.teleport then
                last.vel = (pos - before.pos) * (1 / math.max(st - before.st, 0.001))
            end
        end
    end
    pp.weapon = weapon
    table.insert(snaps, s)
    if #snaps > 40 then table.remove(snaps, 1) end
end

---------------------------------------------------------------------------------------------------
-- loading zones (trigger_changelevel)

local function zoneId(center)
    local function r(v) return math.floor(v / 8 + 0.5) * 8 end
    return string.format("%d_%d_%d", r(center.x), r(center.y), r(center.z))
end

local function scanZones()
    local zones = {}
    for _, t in ipairs(Entities:FindAllByClassname("trigger_changelevel")) do
        local o = t:GetOrigin()
        local mins, maxs = o + t:GetBoundingMins(), o + t:GetBoundingMaxs()
        local c = t:GetCenter()
        table.insert(zones, { ent = t, id = zoneId(c), mins = mins, maxs = maxs, center = c })
    end
    A.zones = zones
end

local function drawBoxOutline(mn, mx, r, g, b, dur)
    local c = {
        Vector(mn.x, mn.y, mn.z), Vector(mx.x, mn.y, mn.z), Vector(mx.x, mx.y, mn.z), Vector(mn.x, mx.y, mn.z),
        Vector(mn.x, mn.y, mx.z), Vector(mx.x, mn.y, mx.z), Vector(mx.x, mx.y, mx.z), Vector(mn.x, mx.y, mx.z),
    }
    local edges = { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 }, { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }
    for _, e in ipairs(edges) do DebugDrawLine(c[e[1]], c[e[2]], r, g, b, false, dur) end
end

local function insideZone(z, pt)
    return pt.x >= z.mins.x - ZONE_PAD and pt.x <= z.maxs.x + ZONE_PAD
        and pt.y >= z.mins.y - ZONE_PAD and pt.y <= z.maxs.y + ZONE_PAD
        and pt.z >= z.mins.z - ZONE_PAD - 40 and pt.z <= z.maxs.z + ZONE_PAD
end

local function findZone(id)
    for _, z in ipairs(A.zones) do if z.id == id then return z end end
    -- ids are rounded positions; tolerate small differences between clients
    local px, py, pz = string.match(id, "(-?%d+)_(-?%d+)_(-?%d+)")
    if not px then return nil end
    local want = Vector(tonumber(px), tonumber(py), tonumber(pz))
    local best, bestD = nil, 64
    for _, z in ipairs(A.zones) do
        local d = (z.center - want):Length()
        if d < bestD then best, bestD = z, d end
    end
    return best
end

local function updateZones(now, p)
    if now >= A.nextZoneScan then
        scanZones()
        A.nextZoneScan = now + 3
    end
    if #A.zones == 0 then
        if A.myZone then A.myZone = nil A.Emit("z", "-") end
        return
    end

    -- while a session is running, walking into a changelevel trigger must not load the next map
    -- on its own: everyone has to be inside first (the host then sends amp_go)
    if mpActive() and not A.transitioning and now >= A.nextGate then
        for _, z in ipairs(A.zones) do
            if IsValidEntity(z.ent) then DoEntFireByInstanceHandle(z.ent, "Disable", "", 0, nil, nil) end
        end
        A.nextGate = now + 1
    end

    if now < A.nextZoneCheck then return end
    A.nextZoneCheck = now + 0.1

    -- after a level change you arrive standing in the trigger that leads back; like the game itself,
    -- a zone only counts once you've walked out of it at least once
    local feet = p:GetOrigin()
    local mine = nil
    for _, z in ipairs(A.zones) do
        if insideZone(z, feet) then
            if A.zoneArmed[z.id] and not mine then mine = z.id end
        else
            A.zoneArmed[z.id] = true
        end
    end
    if mine ~= A.myZone then
        A.myZone = mine
        A.Emit("z", mine or "-")
    end

    if not mpActive() then return end
    for _, z in ipairs(A.zones) do
        if A.zoneArmed[z.id] and (z.center - feet):Length() < ZONE_DRAW_DIST then
            local inside = z.id == A.myZone
            local r, g, b = 255, 170, 0
            if inside then r, g, b = 60, 255, 110 end
            drawBoxOutline(z.mins, z.maxs, r, g, b, 0.15)
            local st = A.zoneStatus
            local label = "LOADING ZONE"
            if st and st.id == z.id then label = string.format("LOADING ZONE  %d/%d", st.ready, st.total) end
            DebugDrawText(z.center + Vector(0, 0, 24), label, false, 0.12)
        end
    end
end

local function goZone(id)
    local z = findZone(id) or (A.myZone and findZone(A.myZone))
    if not z or not IsValidEntity(z.ent) then
        A.Emit("err", "zone_not_found", id)
        return
    end
    A.transitioning = true
    A.Emit("going", z.id)
    -- the transition places you in the next map relative to its landmark using the activator, so the
    -- player has to be passed along (with no activator the level change silently stalls)
    local player = Entities:GetLocalPlayer()
    DoEntFireByInstanceHandle(z.ent, "Enable", "", 0, player, player)
    DoEntFireByInstanceHandle(z.ent, "ChangeLevel", "", 0.05, player, player)
    -- if nothing happened (input ignored), fall back to gating after a few seconds
    if A.core then A.core:SetThink(function()
        if A.levelChangeStarted then return nil end
        A.transitioning = false
        A.Emit("err", "changelevel_timeout", z.id)
        return nil
    end, "amp_go_timeout", 10) end
end

---------------------------------------------------------------------------------------------------
-- local player: weapon + shots

local function weaponFromName(s)
    s = string.lower(s or "")
    if s:find("shotgun") then return 2 end
    if s:find("rapidfire") or s:find("smg") then return 3 end
    if s:find("energygun") or s:find("pistol") or s:find("alyxgun") then return 1 end
    return 0
end

local function findViewModel(now)
    if now >= A.nextVmScan or (A.vm and not IsValidEntity(A.vm)) then
        A.vm = Entities:FindByClassname(nil, "viewmodel")
        A.nextVmScan = now + 1
    end
    return A.vm
end

local function currentWeapon(now)
    if IS_VR then return A.vrWeapon end
    -- NoVR shows Half-Life 2 style viewmodels (v_pistol, v_shotgun, v_smg1...)
    if Convars:GetInt("r_drawviewmodel") == 0 then return 0 end
    local vm = findViewModel(now)
    if not vm then return 0 end
    return weaponFromName(vm:GetModelName())
end

local function localShot()
    local now = Time()
    if now - A.lastShotEmit < 0.04 then return end
    A.lastShotEmit = now
    if not mpActive() then return end
    local w = currentWeapon(now)
    if w == 0 then w = A.vrWeapon end
    if w == 0 then w = 1 end
    A.Emit("f", w)
    -- where the bullet went, so the others can draw the tracer and the impact
    local p = Entities:GetLocalPlayer()
    if p and A.World and not IS_VR then
        local eye = p:EyePosition()
        local dir = eyeForward(p:EyeAngles())
        local tr = { startpos = eye, endpos = eye + dir * 4000, ignore = p, mask = MASK_PLAYERSOLID }
        TraceLine(tr)
        A.World.LocalShot(w, tr.hit and tr.pos or tr.endpos, tr.hit, tr.normal or (dir * -1))
    end
end

-- NoVR's Half-Life 2 style guns fire natively without any game event, so chain a command onto the
-- console alias its fire button runs. NoVR resets the alias on every level load; keep re-applying it.
local NOVR_FIRE_ALIAS = "+iv_attack;usemultitool"

local function hookNoVRFire(now)
    if IS_VR or not Viewmodels_UpgradeModel or now < (A.nextFireHook or 0) then return end
    A.nextFireHook = now + 3
    SendToConsole("alias +customattack \"" .. NOVR_FIRE_ALIAS .. ";amp_trigger\"")
end

local function watchViewModelShots(now)
    if IS_VR then return end
    local vm = findViewModel(now)
    if not vm then return end
    local seq = vm:GetSequence() or ""
    local cyc = vm:GetCycle() or 0
    local firing = seq:find("fire") or seq:find("shoot") or seq:find("attack")
    if firing and (seq ~= A.vmSeq or cyc + 0.05 < (A.vmCycle or 0)) then localShot() end
    A.vmSeq, A.vmCycle = seq, cyc
end

---------------------------------------------------------------------------------------------------
-- local player state -> launcher

local function sendLocalState(now, p)
    if now - A.lastSend < SEND_INTERVAL then return end
    local feet, yaw, pitch, eyeh = localFeetAndView(p)
    local flags = 0
    if IS_VR then flags = flags + 1 end
    if eyeh < (IS_VR and 42 or 48) then flags = flags + 2 end
    if p:GetHealth() <= 0 then flags = flags + 4 end
    local weapon = currentWeapon(now)

    local last = A.lastSent
    local changed = not last
        or (feet - last.pos):Length() > 0.5
        or math.abs(angleDiff(yaw, last.yaw)) > 1
        or math.abs(eyeh - last.eyeh) > 2
        or flags ~= last.flags
        or weapon ~= last.weapon
    if not changed and now - A.lastSend < HEARTBEAT then return end

    A.lastSend = now
    A.lastSent = { pos = feet, yaw = yaw, eyeh = eyeh, flags = flags, weapon = weapon }
    A.Emit("s", A.map, string.format("%.3f", now), fmt(feet.x), fmt(feet.y), fmt(feet.z),
        fmt(yaw), fmt(pitch), fmt(eyeh), flags, weapon)
end

---------------------------------------------------------------------------------------------------
-- teleport next to a teammate (after joining / respawning from their save)

function A.TeleportNear(x, y, z, yaw)
    local p = Entities:GetLocalPlayer()
    if not p then return end
    local target = Vector(x, y, z)
    local offsets = {
        Vector(56, 0, 0), Vector(-56, 0, 0), Vector(0, 56, 0), Vector(0, -56, 0),
        Vector(40, 40, 0), Vector(-40, 40, 0), Vector(40, -40, 0), Vector(-40, -40, 0),
        Vector(96, 0, 0), Vector(-96, 0, 0), Vector(0, 96, 0), Vector(0, -96, 0),
    }
    local dest = nil
    for _, off in ipairs(offsets) do
        local pos = target + off
        local tr = {
            startpos = pos + Vector(0, 0, 18), endpos = pos + Vector(0, 0, 18.5),
            min = Vector(-16, -16, 0), max = Vector(16, 16, 54), ignore = p, mask = MASK_PLAYERSOLID,
        }
        TraceHull(tr)
        local clear = { startpos = target + Vector(0, 0, 36), endpos = pos + Vector(0, 0, 36), ignore = p, mask = MASK_PLAYERSOLID }
        TraceLine(clear)
        if not tr.hit and not tr.startsolid and not clear.hit then
            local down = { startpos = pos + Vector(0, 0, 18), endpos = pos + Vector(0, 0, -64), ignore = p, mask = MASK_PLAYERSOLID }
            TraceLine(down)
            if down.hit then
                dest = down.pos
                break
            end
        end
    end
    dest = dest or target
    local delta = dest - p:GetOrigin()
    local anchor = p:GetHMDAnchor()
    if anchor and IS_VR then anchor:SetOrigin(anchor:GetOrigin() + delta) end
    p:SetOrigin(dest)
    if yaw and not IS_VR then p:SetAngles(0, yaw, 0) end
    A.Emit("tp", fmt(dest.x), fmt(dest.y), fmt(dest.z))
end

---------------------------------------------------------------------------------------------------
-- console commands from the launcher

local function reg(name, fn)
    A.handlers[name] = fn
    pcall(function()
        Convars:RegisterCommand(name, function(_, ...)
            local h = A.handlers[name]
            if not h then return end
            local ok, err = pcall(h, ...)
            if not ok then A.Emit("err", name, tostring(err)) end
        end, "Alyx MP (internal)", 0)
    end)
end

reg("amp_cfg", function(key, value)
    A.cfg[key] = value
    if key == "mp" and value ~= "1" then
        for id in pairs(A.puppets) do removePuppet(id) end
        A.zoneStatus = nil
    end
end)

reg("amp_p", function(id, name)
    getPuppet(tonumber(id)).name = name or ("Player" .. id)
end)

reg("amp_rm", function(id)
    removePuppet(tonumber(id))
end)

reg("amp_clear", function()
    for id in pairs(A.puppets) do removePuppet(id) end
end)

reg("amp_s", function(id, map, st, x, y, z, yaw, pitch, eyeh, flags, weapon)
    addSnapshot(tonumber(id), map, tonumber(st), Vector(tonumber(x), tonumber(y), tonumber(z)),
        tonumber(yaw), tonumber(pitch), tonumber(eyeh), tonumber(flags), tonumber(weapon) or 0)
end)

reg("amp_f", function(id, weapon)
    local pp = A.puppets[tonumber(id)]
    if not pp then return end
    pp.lastShot = Time()
    fireEffects(pp, tonumber(weapon) or pp.weapon or 1)
end)

reg("amp_trigger", function()
    local now = Time()
    local w = currentWeapon(now)
    if w == 0 then return end
    localShot()
    if w == 3 and A.core then  -- the SMG keeps firing while held; show a short burst
        A.core:SetThink(function() A.lastShotEmit = -100 localShot() return nil end, "amp_burst1", 0.1)
        A.core:SetThink(function() A.lastShotEmit = -100 localShot() return nil end, "amp_burst2", 0.2)
    end
end)

reg("amp_w", function(...)
    if not A.World then return end
    local args = { ... }
    local i = 1
    while i <= #args do
        if args[i] == "~" then
            local from, kind = tonumber(args[i + 1]), args[i + 2]
            local rest = {}
            local j = i + 3
            while j <= #args and args[j] ~= "~" do
                table.insert(rest, args[j])
                j = j + 1
            end
            if from and kind then
                local ok, err = pcall(A.World.Receive, from, kind, rest)
                if not ok then A.Emit("err", "world", tostring(err)) end
            end
            i = j
        else
            i = i + 1
        end
    end
end)

reg("amp_zs", function(id, ready, total, waiting)
    if id == "-" then A.zoneStatus = nil return end
    A.zoneStatus = { id = id, ready = tonumber(ready) or 0, total = tonumber(total) or 0, waiting = waiting or "" }
end)

reg("amp_go", function(id) goZone(id) end)

reg("amp_k", function(idx, class, x, y, z)
    idx = tonumber(idx)
    local e = EntIndexToHScript(idx)
    if not e or not IsValidEntity(e) or e:GetClassname() ~= class then return end
    if e:GetHealth() <= 0 then return end
    if (e:GetOrigin() - Vector(tonumber(x), tonumber(y), tonumber(z))):Length() > 600 then return end
    A.suppressKill[idx] = true
    DoEntFireByInstanceHandle(e, "SetHealth", "0", 0, nil, nil)
    if A.core then A.core:SetThink(function()
        if IsValidEntity(e) and e:GetHealth() > 0 then e:Kill() end
        return nil
    end, "amp_kill_" .. idx, 1.0) end
end)

reg("amp_msg", function(secs, ...)
    A.Note(displayName(table.concat({ ... }, " ")))
end)

reg("amp_chat", function(name, ...)
    A.Feed(displayName(name) .. ": " .. table.concat({ ... }, " "))
end)

-- after a level change the launcher pauses whoever finished loading first until everyone is in; the
-- notice is drawn before the pause and stays up while the game is frozen
reg("amp_hold", function(on, ...)
    A.hold = on == "1"
    if A.hold then
        local _, h = screenSize()
        centerText(h * 0.42, "WAITING FOR EVERYONE TO FINISH LOADING", px(26), true, 255, 170, 40, 0.6)
        local who = table.concat({ ... }, " ")
        if who ~= "" then centerText(h * 0.42 + px(36), displayName(who), px(20), false, 230, 230, 230, 0.6) end
    end
end)

reg("amp_near", function(x, y, z, yaw)
    A.TeleportNear(tonumber(x), tonumber(y), tonumber(z), tonumber(yaw))
end)

reg("amp_hello", function()
    A.Emit("hello", A.PROTO, A.VERSION, A.map, IS_VR and 1 or 0, A.ready and 1 or 0)
end)

---------------------------------------------------------------------------------------------------
-- game events

local function listen(event, fn)
    table.insert(A.listeners, ListenToGameEvent(event, fn, nil))
end

listen("entity_killed", function(info)
    local idx = info.entindex_killed
    if A.suppressKill[idx] then
        A.suppressKill[idx] = nil
        return
    end
    if not mpActive() then return end
    if A.World then A.World.OnKilled(idx) end
end)

listen("player_hurt", function(info)
    if info.health and info.health <= 0 then A.Emit("died") end
end)

listen("change_level_activated", function()
    A.transitioning = true
    A.levelChangeStarted = true
    A.Emit("chl")
end)

listen("weapon_switch", function(info)
    A.vrWeapon = weaponFromName(info.item)
end)

listen("player_shoot_weapon", function() localShot() end)
listen("break_prop", function(info) if A.World and info.entindex then A.World.OnBreak(info.entindex) end end)
listen("break_breakable", function(info) if A.World and info.entindex then A.World.OnBreak(info.entindex) end end)
listen("physgun_pickup", function(info) if A.World and info.entindex and mpActive() then A.World.OnPickup(info.entindex) end end)
listen("player_shoot", function() localShot() end)

---------------------------------------------------------------------------------------------------
-- main loop

local lastTick = Time()
local function tick()
    local now = Time()
    local dt = now - lastTick
    lastTick = now
    local p = Entities:GetLocalPlayer()
    if p then
        hookNoVRFire(now)
        watchViewModelShots(now)
        updateHint(now, p)
        if A.World then
            -- a world-sync error must never stop the avatars, HUD and zones from updating
            local ok, err = pcall(A.World.Tick, now, p)
            if not ok and now >= (A.nextWorldErr or 0) then
                A.nextWorldErr = now + 5
                A.Emit("err", "world", tostring(err))
            end
        end
        sendLocalState(now, p)
        updateZones(now, p)
    end
    for _, pp in pairs(A.puppets) do updatePuppet(pp, now, dt) end
    if now >= A.nextHud then
        drawHud(now, p)
        A.nextHud = now + 0.25
    end
    return 0
end

-- an error in a think function stops it for good; keep the mod running and report the error instead
local function safeTick()
    local ok, r = pcall(tick)
    if ok then return r end
    local now = Time()
    if now >= (A.nextTickErr or 0) then
        A.nextTickErr = now + 5
        A.Emit("err", "tick", tostring(r))
    end
    return 0
end

-- Spawning entities while the map is still loading crashes the game (an asynchronous spawn gets queued
-- against the loading spawn group, which is gone by the time it runs), so everything that creates
-- entities waits until the map is live.
local function startNow()
    -- puppets that were in a save are just frozen props now; right after a restore their handles can't
    -- be called into yet, so remove them through the input queue
    for _, name in ipairs({ PROP_NAME, HUD_NAME }) do
        for _, e in ipairs(Entities:FindAllByName(name)) do
            DoEntFireByInstanceHandle(e, "Kill", "", 0, nil, nil)
        end
    end
    local core = Entities:FindByName(nil, "alyxmp_core")
    if not core then core = SpawnEntityFromTableSynchronous("info_target", { targetname = "alyxmp_core" }) end
    A.core = core
    lastTick = Time()
    core:SetThink(safeTick, "amp_tick", 0)
    if A.World then A.World.Start() end
    SpawnEntityFromTableAsynchronous("logic_script", { targetname = "alyxmp_precache", vscripts = "alyxmp/precache.lua" }, function()
        A.ready = true
        A.Emit("ready", A.map)
    end, nil)
end

local function start()
    if A.started then return end
    local ok, err = pcall(startNow)
    if ok then
        A.started = true
    else
        A.Emit("err", "start", tostring(err))
    end
end

A.Emit("hello", A.PROTO, A.VERSION, A.map, IS_VR and 1 or 0, 0, _VERSION)

A.started = false
if A.map == "startup" then
    -- main menu: nothing to draw, just let the launcher know the mod is here
    A.Emit("ready", A.map)
else
    local function startSoon(delay)
        local p = Entities:GetLocalPlayer()
        if p then p:SetThink(function() start() return nil end, "amp_start", delay) end
    end
    -- new map or loaded save: the player entity we see now may be replaced while the save restores,
    -- so the dependable signal is player_activate (NoVR initialises the same way)
    listen("player_activate", function() startSoon(0.1) end)
    -- reloaded by the launcher mid-game: no player_activate will come
    startSoon(0.5)
end
