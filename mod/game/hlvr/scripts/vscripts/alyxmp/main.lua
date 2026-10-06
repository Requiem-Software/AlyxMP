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
A.VERSION = "0.5.0"
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
-- ground speed of the run cycle at normal playback (measured from the planted foot: ~150 u/s);
-- playback follows the real speed so feet stay planted, from NoVR's 86 u/s walk up to sprinting
local CLIP_SPEED = { sprint_alt_ = 150 }
local RATE_MIN, RATE_MAX = 0.45, 1.8
local RATE_STEP = 0.1        -- only re-send the playback rate when it changed this much...
local RATE_HOLD = 0.4        -- ...or this long has passed, so jittery packets don't make it stutter
local ZONE_PAD = 12         -- leeway around changelevel trigger volumes
local ZONE_SHOW = 90         -- a zone's outline and label fade in from about 2 m away...
local ZONE_FULL = 30         -- ...and are fully there this close
local MASK_PLAYERSOLID = 33636363
local ATTACH_FOLLOW = PATTACH_POINT_FOLLOW or 5

local IS_VR = not GlobalSys:CommandLineCheck("-novr")
local PROP_NAME = "amp_pp"  -- every prop the mod spawns; saves restore them, so they get cleaned up on load
local HUD_NAME = "amp_hud"
local TARGET_NAME = "amp_target"  -- the invisible npc_bullseye each avatar carries, so enemies go after it
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

-- NoVR keeps its flashlight in the global flashlight_ent; in VR it's the flashlight item in the hand
local function localFlashlightOn()
    if not IS_VR then
        local e = rawget(_G, "flashlight_ent")
        return e ~= nil and IsValidEntity(e)
    end
    local f = Entities:FindByClassname(nil, "item_hlvr_prop_flashlight")
    return f ~= nil and f:GetMoveParent() ~= nil
end

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
    killEnt(pp.light)
    pp.light, pp.lightOn = nil, nil
    killEnt(pp.target)
    pp.target = nil
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
A.dimmed = nil
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
-- the launcher's settings menu switches these (amp_cfg <key> 0/1); all on unless switched off
local function shown(key) return A.cfg[key] ~= "0" end

-- stop drawing (and clear what's on screen) before a save or level loads; r_showdebugoverlays is a
-- different thing (the render system's debug views) and stays off
function A.HideOverlays()
    A.unloading = true
    SendToConsole("ent_clear_debug_overlays")
    SendToConsole("cl_ent_clear_debug_overlays")
end
A.isVR = IS_VR

DoIncludeScript("alyxmp/world.lua", nil)

---------------------------------------------------------------------------------------------------
-- HUD: the engine's screen-text overlay, set in Half-Life: Alyx's own UI typeface (Raju, from its
-- Panorama fonts) and kept as quiet as the game's own menus: white type, small caps labels, no boxes

local FEED_LINES = 6
local FEED_TIME = 12
local FONT = "Raju"
local CHAR_W = 0.37           -- Raju's average advance, in font sizes (for centring); bold runs wider
local CHAR_W_BOLD = 0.39
local WHITE = { 255, 255, 255 }
local DIM = { 200, 204, 208 }
local ACCENT = { 255, 199, 92 }

-- the launcher tells us the game window's size (amp_cfg sw / sh); the overlay works in pixels
local function screenSize()
    return tonumber(A.cfg.sw or "") or 1920, tonumber(A.cfg.sh or "") or 1080
end

-- font sizes are given for 1080p and scale with the window height
local function px(n)
    local _, h = screenSize()
    return math.floor(n * h / 1080 + 0.5)
end

local function screenText(x, y, text, size, bold, c, alpha, dur)
    DebugScreenTextPretty(math.floor(x + 0.5), math.floor(y + 0.5), 0, text, c[1], c[2], c[3], alpha or 255, dur,
        A.cfg.font or FONT, size, bold)
end

local function textWidth(text, size, bold)
    return #text * size * (tonumber(A.cfg.charw or "") or (bold and CHAR_W_BOLD or CHAR_W))
end

local function centerText(y, text, size, bold, c, alpha, dur)
    local w = screenSize()
    screenText(w / 2 - textWidth(text, size, bold) / 2, y, text, size, bold, c, alpha, dur)
end

-- where a point in the world lands on the NoVR player's screen (nil when behind them)
local function viewBasis(ang)
    local pr, yr = math.rad(ang.x), math.rad(ang.y)
    local cp, sp, cy, sy = math.cos(pr), math.sin(pr), math.cos(yr), math.sin(yr)
    return Vector(cp * cy, cp * sy, -sp), Vector(sy, -cy, 0), Vector(sp * cy, sp * sy, cp)
end

local function toScreen(eye, fwd, right, up, world)
    local d = world - eye
    local z = d:Dot(fwd)
    if z < 4 then return nil end
    local w, h = screenSize()
    -- like Source's fov_desired: the horizontal field of view of a 4:3 picture, wider screens see more
    local tanV = math.tan(math.rad(Convars:GetFloat("fov_desired") or 90) / 2) * 0.75
    local tanH = tanV * w / h
    return w / 2 + d:Dot(right) / z / tanH * (w / 2), h / 2 - d:Dot(up) / z / tanV * (h / 2), z
end

--- A line in the chat feed on the left of the screen.
function A.Feed(text, note)
    table.insert(A.feed, { text = text, t = Time(), note = note })
    while #A.feed > FEED_LINES do table.remove(A.feed, 1) end
end

function A.Note(text) A.Feed(text, true) end

local function drawFeed(now, dur)
    local keep = {}
    for _, f in ipairs(A.feed) do if now - f.t < FEED_TIME then table.insert(keep, f) end end
    A.feed = keep
    if not shown("feed") then return end
    local _, h = screenSize()
    local size, step = px(22), px(28)
    local y = h * 0.74 - #keep * step
    for _, f in ipairs(keep) do
        -- fade out over the last two seconds
        local alpha = math.floor(255 * math.min(1, (FEED_TIME - (now - f.t)) / 2))
        screenText(px(32), y, f.text, size, false, f.note and ACCENT or WHITE, alpha, dur)
        y = y + step
    end
end

local function drawRoster(p, dur)
    local x, y = px(32), px(30)
    local count = 1
    for _ in pairs(A.puppets) do count = count + 1 end
    screenText(x, y, "PLAYERS  " .. count, px(15), true, DIM, 210, dur)
    screenText(x + px(110), y, "Y  CHAT      F10  SETTINGS      /HELP", px(15), false, DIM, 150, dur)
    y = y + px(26)
    for _, pp in pairs(A.puppets) do
        screenText(x, y, displayName(pp.name), px(21), false, WHITE, 235, dur)
        local info
        if pp.map and pp.map ~= A.map then
            info = pp.map
        elseif pp.renderPos and p then
            info = string.format("%d m", math.floor((pp.renderPos - p:GetOrigin()):Length() / 39.37 + 0.5))
        end
        if info then screenText(x + px(200), y + px(3), info, px(17), false, DIM, 190, dur) end
        y = y + px(27)
    end
end

local function drawHud(now, p)
    local dur = 0.3
    if mpActive() and shown("list") then drawRoster(p, dur) end
    drawFeed(now, dur)

    if A.myZone and mpActive() then
        local st = A.zoneStatus
        local title, sub = "LOADING ZONE", "Waiting for the other players"
        if A.transitioning then
            title, sub = "LOADING", "Everyone is here"
        elseif st and st.id == A.myZone then
            sub = string.format("%d of %d ready", st.ready, st.total)
            if st.waiting ~= "" then sub = sub .. "   \194\183   waiting for " .. displayName(st.waiting) end
        end
        local _, h = screenSize()
        centerText(h * 0.15, title, px(30), true, WHITE, 245, dur)
        centerText(h * 0.15 + px(40), sub, px(21), false, DIM, 220, dur)
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
    if IS_VR or now < A.nextHint or not shown("dot") then return end
    A.nextHint = now + 0.1
    A.hint = interactLabel(p)
    if A.hint then
        -- a dot in the middle of NoVR's crosshair, in the crosshair's colour; the glyph's centre sits
        -- about a quarter of its size right of where it's drawn
        local w, h = screenSize()
        local size = px(14)
        DebugScreenTextPretty(math.floor(w / 2 - size * 0.24 + 0.5), math.floor(h / 2 + 0.5), 0, "\226\151\143",
            254, 207, 64, 255, 0.12, "", size, false)
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

-- NoVR's own flashlight (flashlight.lua) is a light_spot; remote players get an identical one
local FLASHLIGHT_KV = {
    enabled = "0", color = "255 255 255 255", brightness = "1", range = "700", castshadows = "1",
    shadowtexturewidth = "1024", shadowtextureheight = "1024", style = "0", fademindist = "0", fademaxdist = "6000",
    bouncescale = "1.0", renderdiffuse = "1", renderspecular = "1", directlight = "2", indirectlight = "0",
    attenuation1 = "0.0", attenuation2 = "1.0", innerconeangle = "10", outerconeangle = "32", lightcookie = "flashlight",
}

-- an invisible target at the avatar's chest: enemies in this game go after the other players too
local function updateTarget(pp, pos, eyeh)
    local at = pos + Vector(0, 0, math.max(eyeh, 30) * 0.7)
    if not (pp.target and IsValidEntity(pp.target)) then
        -- not solid, so shots and bodies pass through; it has to be damageable though, or no enemy
        -- counts it as one (so it gets a lot of health instead)
        pp.target = SpawnEntityFromTableSynchronous("npc_bullseye", {
            targetname = TARGET_NAME, origin = vecStr(at), health = 999999, minangle = "360", spawnflags = 65536,
        })
        return
    end
    pp.target:SetAbsOrigin(at)
end

-- the player's name over their head: on the NoVR screen in the HUD's type, in VR in the world
local function drawTag(pp, pos, eyeh, p)
    if not shown("tags") then return end
    local label = displayName(pp.name)
    local head = pos + Vector(0, 0, math.max(eyeh, 30) + 14)
    local dist = p and (pos - p:GetOrigin()):Length() / 39.37 or 0
    if IS_VR or not p then
        if dist > 15 then label = string.format("%s  [%dm]", label, math.floor(dist + 0.5)) end
        DebugDrawText(head, label, false, 0)
        return
    end
    local eye = p:EyePosition()
    local fwd, right, up = viewBasis(p:EyeAngles())
    local x, y = toScreen(eye, fwd, right, up, head)
    if not x then return end
    local size = px(20)
    local alpha = dist > 25 and 170 or 235
    screenText(x - textWidth(label, size) / 2, y - size, label, size, false, WHITE, alpha, 0)
    if dist > 15 then
        local d = string.format("%d m", math.floor(dist + 0.5))
        screenText(x - textWidth(d, px(16)) / 2, y + px(4), d, px(16), false, DIM, alpha - 30, 0)
    end
end

local function updateFlashlight(pp, pos, yaw, pitch, eyeh, on)
    if on and not (pp.light and IsValidEntity(pp.light)) then
        local kv = {}
        for k, v in pairs(FLASHLIGHT_KV) do kv[k] = v end
        kv.targetname = PROP_NAME
        kv.origin = vecStr(pos + Vector(0, 0, eyeh))
        pp.light = SpawnEntityFromTableSynchronous("light_spot", kv)
        pp.lightOn = false
    end
    if not pp.light or not IsValidEntity(pp.light) then return end
    if on ~= pp.lightOn then
        pp.lightOn = on
        DoEntFireByInstanceHandle(pp.light, on and "TurnOn" or "TurnOff", "", 0, nil, nil)
        StartSoundEventFromPosition(on and "HL2Player.FlashLightOn" or "HL2Player.FlashLightOff", pos + Vector(0, 0, eyeh))
    end
    if on then
        -- where NoVR puts it: a little right of and below the eyes, along the view
        local y = math.rad(yaw)
        local fwd, right = Vector(math.cos(y), math.sin(y), 0), Vector(math.sin(y), -math.cos(y), 0)
        pp.light:SetAbsOrigin(pos + Vector(0, 0, eyeh - 1) + fwd * 1 + right * 3.5)
        pp.light:SetAngles(pitch or 0, yaw, 0)
    end
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
        return s.pos, s.yaw, s.eyeh, s.flags, s.weapon, false, s.pitch
    end
    if rt >= snaps[n].st then
        local s = snaps[n]
        local ex = math.min(rt - s.st, EXTRAP)
        return s.pos + s.vel * ex, s.yaw, s.eyeh, s.flags, s.weapon, false, s.pitch
    end
    for i = n - 1, 1, -1 do
        local a, b = snaps[i], snaps[i + 1]
        if a.st <= rt then
            local f = (rt - a.st) / math.max(b.st - a.st, 0.001)
            if b.teleport then
                return b.pos, b.yaw, b.eyeh, b.flags, b.weapon, true, b.pitch
            end
            return hermite(a, b, f), lerpAngle(a.yaw, b.yaw, f), a.eyeh + (b.eyeh - a.eyeh) * f, b.flags, b.weapon, false,
                (a.pitch or 0) + ((b.pitch or 0) - (a.pitch or 0)) * f
        end
    end
    local s = snaps[n]
    return s.pos, s.yaw, s.eyeh, s.flags, s.weapon, false, s.pitch
end

local function setPlayback(pp, rig, seq)
    local rate = 1
    for prefix, clip in pairs(CLIP_SPEED) do
        if seq:sub(1, #prefix) == prefix then
            rate = math.max(RATE_MIN, math.min(RATE_MAX, pp.gait / clip))
            break
        end
    end
    local now = Time()
    if pp.rate and pp.rateSeq == seq and (math.abs(rate - pp.rate) < RATE_STEP or now - (pp.rateAt or 0) < RATE_HOLD)
        and math.abs(rate - pp.rate) < 0.3 then
        return
    end
    pp.rate, pp.rateSeq, pp.rateAt = rate, seq, now
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
    local pos, yaw, eyeh, flags, weapon, jumped, pitch = samplePuppet(pp, rt)
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
    pp.gait = (pp.gait or pp.speed) + (pp.speed - (pp.gait or pp.speed)) * math.min(dt * 4, 1)

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
    updateFlashlight(pp, pos, yaw, pitch, eyeh, bit(flags, 8))
    updateTarget(pp, pos, eyeh)
    drawTag(pp, pos, eyeh, Entities:GetLocalPlayer())
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
        -- the floor under it (the volume often reaches below the ground)
        local down = { startpos = c, endpos = Vector(c.x, c.y, mins.z - 64), mask = MASK_PLAYERSOLID }
        TraceLine(down)
        local floor = down.hit and math.max(down.pos.z, mins.z) or mins.z
        table.insert(zones, { ent = t, id = zoneId(c), mins = mins, maxs = maxs, center = c, floor = floor })
    end
    A.zones = zones
end

local function drawFloorOutline(z, mn, mx, r, g, b, dur)
    z = z + 2
    local c = { Vector(mn.x, mn.y, z), Vector(mx.x, mn.y, z), Vector(mx.x, mx.y, z), Vector(mn.x, mx.y, z) }
    for i = 1, 4 do DebugDrawLine(c[i], c[i % 4 + 1], r, g, b, true, dur) end   -- hidden behind walls and floors
end

-- is the spot in plain view (not behind a wall or under the floor)?
local function canSee(p, eye, at)
    local tr = { startpos = eye, endpos = at, ignore = p, mask = MASK_PLAYERSOLID }
    TraceLine(tr)
    return not tr.hit or tr.fraction > 0.97
end

-- how far a point is from a zone's volume (0 inside it)
local function zoneDistance(z, pt)
    local c = Vector(math.max(z.mins.x, math.min(z.maxs.x, pt.x)), math.max(z.mins.y, math.min(z.maxs.y, pt.y)),
        math.max(z.mins.z, math.min(z.maxs.z, pt.z)))
    return (c - pt):Length()
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

    if not mpActive() or not shown("zones") then return end
    local eye, fwd, right, up
    if not IS_VR then
        eye = p:EyePosition()
        fwd, right, up = viewBasis(p:EyeAngles())
    end
    for _, z in ipairs(A.zones) do
        local inside = z.id == A.myZone
        -- only once you're close (or in it): nobody needs to see an exit from across the level
        local d = inside and 0 or zoneDistance(z, feet)
        if A.zoneArmed[z.id] and d < ZONE_SHOW then
            local f = math.max(0, math.min(1, (ZONE_SHOW - d) / (ZONE_SHOW - ZONE_FULL)))
            -- the zone's footprint on the floor, white; green once you're standing in it (lines have no
            -- alpha, so fading in means brightening)
            local r, g, b = 235, 235, 235
            if inside then r, g, b = 110, 235, 150 end
            drawFloorOutline(z.floor, z.mins, z.maxs, math.floor(r * f), math.floor(g * f), math.floor(b * f), 0.15)
            local st = A.zoneStatus
            local label = "LOADING ZONE"
            if st and st.id == z.id then label = string.format("LOADING ZONE   %d/%d", st.ready, st.total) end
            local at = Vector(z.center.x, z.center.y, z.floor + 64)
            if IS_VR then
                if f > 0.5 then DebugDrawText(at, label, true, 0.12) end
            elseif not inside and canSee(p, eye, at) then
                local x, y = toScreen(eye, fwd, right, up, at)
                if x then
                    screenText(x - textWidth(label, px(18), true) / 2, y, label, px(18), true, WHITE, math.floor(220 * f), 0.12)
                end
            end
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
    -- auto reload (settings menu): when the gun reloads by itself, come out of aim-down-sights the way
    -- NoVR's reload key does
    if A.cfg.autoreload == "1" and seq ~= A.vmSeq and seq:find("reload") then SendToConsole("novr_resetads") end
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
    if localFlashlightOn() then flags = flags + 8 end
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

-- dim the world the way the game does when it pauses (a screen fade that stays until faded back)
local function dimWorld(on)
    local p = Entities:GetLocalPlayer()
    if IS_VR or not p or on == A.dimmed then return end
    A.dimmed = on
    local f = SpawnEntityFromTableSynchronous("env_fade", {
        targetname = HUD_NAME, duration = on and "0" or "0.35", holdtime = "0",
        rendercolor = "0 0 0 150",            -- the fade's alpha goes in the colour
        spawnflags = on and "8" or "1",       -- stay faded out / fade back in from it
    })
    DoEntFireByInstanceHandle(f, "Fade", "", 0, p, p)
    DoEntFireByInstanceHandle(f, "Kill", "", 1, nil, nil)
end

-- after a level change the launcher freezes whoever finished loading first until everyone is in. The
-- card is drawn before the freeze and stays up while the game stands still (the launcher redraws it
-- every few seconds and when the list of who we're waiting for changes)
reg("amp_hold", function(on, ...)
    A.hold = on == "1"
    dimWorld(A.hold)
    if not A.hold then return end
    local _, h = screenSize()
    local y = h * 0.4
    centerText(y, "P A U S E D", px(42), true, WHITE, 250, 0.6)
    local who = table.concat({ ... }, " ")
    local sub = who ~= "" and ("Waiting for " .. displayName(who) .. " to finish loading") or "Waiting for everyone to finish loading"
    centerText(y + px(58), sub, px(22), false, DIM, 230, 0.6)
end)

-- the launcher is about to load a save or a level
reg("amp_unload", function()
    A.HideOverlays()
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
    if info.health and info.health <= 0 then
        A.HideOverlays()  -- a save gets loaded next
        A.Emit("died")
    end
end)

listen("change_level_activated", function()
    A.HideOverlays()
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
    if A.unloading then return 0 end
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
    for _, name in ipairs({ PROP_NAME, HUD_NAME, TARGET_NAME }) do
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
        A.unloading = false
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
