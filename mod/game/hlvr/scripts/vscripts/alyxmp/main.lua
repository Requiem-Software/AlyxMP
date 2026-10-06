-- Alyx MP: the in-game half of the multiplayer mod.
--
-- Loaded on every map by cfg/skill_manifest.cfg ("script_reload_code alyxmp/main") and re-run by the
-- launcher when it attaches. The launcher reads our "[AMP]..." print() lines over VConsole and talks
-- back through the amp_* console commands registered below.
--
-- Remote players are drawn as Alyx bone-merged onto an invisible animated "rig": our own model
-- (models/alyxmp/avatar.vmdl), built with the Workshop Tools from Half-Life: Alyx's own animations - the
-- female citizen's idle and walk, the metrocop's run and crouch walk, and with a gun out the combine
-- soldier's whole set - and driven by its animation graph (see the remote players section). Weapons are
-- the same models NoVR shows in first person, in her right hand the way Alyx holds them in VR.
-- HL:Alyx doesn't render point_worldtext: name tags use the debug overlay, and the chat feed,
-- loading-zone banner and interact hint use game_text (the game's own HUD message font).

AMP = AMP or {}
local A = AMP
A.VERSION = "0.6.0"
A.PROTO = 3

local MODEL_ALYX = "models/characters/alyx/alyx.vmdl"
local RIG_MODEL = "models/alyxmp/avatar.vmdl"

-- weapon codes on the wire: 0 none, 1 pistol, 2 shotgun, 3 smg. These are NoVR's own first-person models
-- (spawned as prop_dynamic_override: as plain props the game removes them), parented to the rig's gun_R
-- attachment, which puts the grip in her hand exactly where their built-in VR hand holds it.
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
local AIM_HOLD = 1.2        -- keep the gun raised this long after a shot
local ARM_TIME = 0.35       -- taking a gun out / putting it away (the gun shows from halfway)
local RELOAD_TIME = 2.4
-- The ground velocity (forward, left; units/s) of each gait's clips, going round from forward. The graph
-- (tools/avatar/avatar_graph.py) blends each gait's directions at these speeds; playback is then scaled to
-- the real speed.
local WALK_CLIPS = { { 48.1, 0 }, { 50, -50 }, { 0, -53 }, { -38.7, -38.7 }, { -65.6, 0 }, { -38.7, 38.7 }, { 0, 53 }, { 50, 50 } }
-- (the forward run is listed at 175 rather than its real 220, so a 140 u/s sprint plays it at 0.8: quicker steps)
local RUN_CLIPS = { { 175, 0 }, { 151.5, -151.5 }, { 0, -153.1 }, { -108.2, -108.3 }, { -173.5, 0 }, { -108.2, 108.2 },
    { 0, 153.1 }, { 151.5, 151.5 } }
local ARMED_CLIPS = { { 166.4, 0 }, { 104.2, -104.2 }, { 0, -154 }, { -89.4, -89.4 }, { -117.5, 0 }, { -87.8, 87.8 },
    { 0, 135.4 }, { 84.1, 84.1 } }
local CROUCH_CLIPS = { { 92.6, 0 }, { 83.5, -59.4 }, { -0.4, -71.8 }, { -58.7, -46 }, { -74.7, 0 }, { -39.8, 51.4 },
    { 0.9, 87 }, { 57.5, 51.6 } }
local RUN_FROM, WALK_FROM = 120, 110   -- sprinting (NoVR: 140 u/s, walking 92) - with some hysteresis
local ZONE_PAD = 12         -- leeway around changelevel trigger volumes
local ZONE_SHOW = 90         -- a zone's outline and label fade in from about 2 m away...
local ZONE_FULL = 30         -- ...and are fully there this close
local MASK_PLAYERSOLID = 33636363
local ATTACH_FOLLOW = PATTACH_POINT_FOLLOW or 5

local IS_VR = not GlobalSys:CommandLineCheck("-novr")
local PROP_NAME = "amp_pp"  -- every prop the mod spawns; saves restore them, so they get cleaned up on load
local HUD_NAME = "amp_hud"
local TARGET_NAME = "amp_target"  -- + "_<player id>": the invisible npc_bullseye each avatar carries, so enemies go after it
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
    pp.weaponCode, pp.placed, pp.phase, pp.gp, pp.heldCode = nil, nil, nil, nil, nil
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
    screenText(x + px(110), y, "Y  CHAT      ESC  SETTINGS      /HELP", px(15), false, DIM, 150, dur)
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

-- The rig is a generic_actor (an NPC without AI, which Valve made for custom characters): props run
-- their animation graphs on the client only, where Lua can't set the graph's parameters.
local function buildPuppet(pp, pos)
    pp.rig = SpawnEntityFromTableSynchronous("generic_actor", {
        targetname = PROP_NAME, model = RIG_MODEL, origin = vecStr(pos), DisableCollisions = "1",
    })
    pp.rig:SetRenderAlpha(0)
    pp.alyx = spawnProp(MODEL_ALYX, pos, nil)
    pp.alyx:FollowEntity(pp.rig, true)
    pp.gp, pp.heldCode, pp.armed, pp.aim, pp.crouchW, pp.reloadW, pp.gait, pp.dir = {}, 0, 0, 0, 0, 0, 0, { 1, 0 }
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

-- a graph parameter, sent only when it changed
local function setParam(pp, name, v)
    local last = pp.gp[name]
    if last and math.abs(last - v) < 0.005 then return end
    pp.gp[name] = v
    pp.rig:SetGraphParameterFloat(name, v)
end

local function trigger(pp, name)
    pp.rig:SetGraphParameterBool(name, true)
end

local function approach(v, target, step)
    if v < target then return math.min(v + step, target) end
    return math.max(v - step, target)
end

local function spawnWeapon(pp, code)
    local e = SpawnEntityFromTableSynchronous("prop_dynamic_override", {
        targetname = PROP_NAME, model = WEAPONS[code].model, origin = vecStr(pp.rig:GetOrigin()), solid = 0,
    })
    if e then
        e:SetParent(pp.rig, "gun_R")
        e:SetLocalOrigin(Vector(0, 0, 0))
        e:SetLocalAngles(0, 0, 0)
    end
    return e
end

-- A gun out: the graph goes over to the combine soldier's animations (both hands on the gun); the gun
-- shows from halfway, once her hands are on it. Switching guns swaps the model in her hands.
local function updateWeapon(pp, now, dt, want, reloading)
    if not WEAPONS[want] then want = 0 end
    if want ~= 0 then pp.heldCode = want end
    pp.armed = approach(pp.armed, want ~= 0 and 1 or 0, dt / ARM_TIME)
    setParam(pp, "p_armed", pp.armed)
    local show = pp.armed >= 0.5 and pp.heldCode ~= 0
    local ent = pp.weaponEnt
    if ent and (not IsValidEntity(ent) or not show or pp.weaponCode ~= pp.heldCode) then
        killEnt(ent)
        pp.weaponEnt = nil
    end
    if show and not pp.weaponEnt then
        pp.weaponEnt, pp.weaponCode = spawnWeapon(pp, pp.heldCode), pp.heldCode
    end
    if pp.armed == 0 then pp.heldCode = 0 end
    -- raised for a while after each shot, otherwise held low
    local aimed = show and now - pp.lastShot < AIM_HOLD
    pp.aim = approach(pp.aim, aimed and 1 or 0, dt / (aimed and 0.15 or 0.4))
    setParam(pp, "p_aim", pp.aim)
    -- reloading: the soldier's reload on her upper body
    if reloading and not pp.reloading and show then
        trigger(pp, "p_reload")
        pp.reloadAt = now
    end
    pp.reloading = reloading
    local r = now - (pp.reloadAt or -100)
    local on = show and r < RELOAD_TIME
    pp.reloadW = approach(pp.reloadW, on and 1 or 0, dt / (on and 0.15 or 0.3))
    setParam(pp, "p_reload_w", pp.reloadW)
end

-- Re-setting a bone-merge parent's transform every tick, even to the same values, stops the game
-- from drawing the merged Alyx model, so only touch it when it really moved. SetAbsOrigin, not
-- SetOrigin: SetOrigin counts as a teleport, which throws away the rig's animation smoothing, so while
-- it moved every tick its animation only showed the server's 10 Hz steps.
local function placeRig(pp, pos, yaw)
    local last = pp.placed
    if last and (last.pos - pos):Length() < 0.05 and math.abs(angleDiff(last.yaw, yaw)) < 0.05 then return end
    pp.rig:SetAbsOrigin(pos)
    pp.rig:SetAngles(0, yaw, 0)
    pp.placed = { pos = pos, yaw = yaw }
end

-- Where the direction (dx, dy) meets the outline through a gait's clip velocities: the graph plays that
-- point at the clips' own speed, which is its length.
local function onOutline(clips, dx, dy)
    local n = #clips
    for i = 1, n do
        local a, b = clips[i], clips[i % n + 1]
        local ex, ey = b[1] - a[1], b[2] - a[2]
        local den = ex * dy - ey * dx
        if math.abs(den) > 1e-6 then
            local t = -(a[1] * dy - a[2] * dx) / den
            if t >= -1e-4 and t <= 1 + 1e-4 then
                local x, y = a[1] + ex * t, a[2] + ey * t
                local s = x * dx + y * dy
                if s > 0 then return x, y, s end
            end
        end
    end
    return clips[1][1], clips[1][2], clips[1][1]
end

local function setGait(pp, clips, px, py, prate, dx, dy, speed)
    local x, y, s = onOutline(clips, dx, dy)
    setParam(pp, px, x)
    setParam(pp, py, y)
    setParam(pp, prate, math.min(speed / s, 3))
end

-- Movement: every gait plays in the direction she moves (relative to where she faces), as fast as she moves.
local function updateMovement(pp, dt, yaw, crouched)
    local y = math.rad(yaw)
    local cy, sy = math.cos(y), math.sin(y)
    local fwd = pp.vel.x * cy + pp.vel.y * sy
    local left = pp.vel.y * cy - pp.vel.x * sy
    local speed = math.sqrt(fwd * fwd + left * left)
    -- the direction is kept while stopping, so the legs don't turn on the spot as she slows down
    if speed > 8 then pp.dir = { fwd / speed, left / speed } end
    local dx, dy = pp.dir[1], pp.dir[2]
    setGait(pp, WALK_CLIPS, "p_wx", "p_wy", "p_wrate", dx, dy, speed)
    setGait(pp, RUN_CLIPS, "p_rx", "p_ry", "p_rrate", dx, dy, speed)
    setGait(pp, ARMED_CLIPS, "p_ax", "p_ay", "p_arate", dx, dy, speed)
    setGait(pp, CROUCH_CLIPS, "p_cx", "p_cy", "p_crate", dx, dy, speed)
    local sprinting = speed > (pp.gait > 0.5 and WALK_FROM or RUN_FROM)
    pp.gait = approach(pp.gait, sprinting and 1 or 0, dt / 0.25)
    setParam(pp, "p_gait", pp.gait)
    local moving = math.min(speed / 40, 1)
    setParam(pp, "p_move", moving)
    setParam(pp, "p_cmove", moving)
    pp.crouchW = approach(pp.crouchW, crouched and 1 or 0, dt / 0.25)
    setParam(pp, "p_crouch", pp.crouchW)
end

local function fireEffects(pp, code)
    local w = WEAPONS[code]
    if not w or not puppetValid(pp) then return end
    local ent = pp.weaponEnt
    if not ent or not IsValidEntity(ent) then
        StartSoundEvent(w.snd, pp.rig)
        return
    end
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
-- Players never collide with each other. The bullseye's "not solid" flag doesn't keep it out of
-- player-sized traces, though, and NoVR's unstuck check would take a player standing against the avatar
-- for stuck and teleport them away (often through a wall). So while we're close to the avatar, its target
-- floats well above our heads; enemies near both of us go for us anyway.
local TARGET_CLEAR = 64     -- closer than this (sideways) and the target gets out of the way...
local TARGET_BACK = 88      -- ...and it comes back down once we're this far again
local TARGET_LIFT = 150     -- above the avatar's feet: over any standing (or jumping) player's head

local function updateTarget(pp, pos, eyeh, p)
    if p then
        local d = p:GetOrigin() - pos
        local side = math.sqrt(d.x * d.x + d.y * d.y)
        pp.targetLifted = math.abs(d.z) < 120 and side < (pp.targetLifted and TARGET_BACK or TARGET_CLEAR)
    end
    local at = pos + Vector(0, 0, pp.targetLifted and TARGET_LIFT or math.max(eyeh, 30) * 0.7)
    if not (pp.target and IsValidEntity(pp.target)) then
        -- it has to be damageable, or no enemy counts it as one (so it gets a lot of health instead)
        pp.target = SpawnEntityFromTableSynchronous("npc_bullseye", {
            targetname = TARGET_NAME .. "_" .. pp.id, origin = vecStr(at), health = 999999, minangle = "360",
            spawnflags = 65536,
        })
        -- the host learns who each enemy is after from what it hits (world.lua)
        if pp.target then pp.target:RedirectOutput("OnDamaged", "AMP_AvatarHit", pp.target) end
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

    placeRig(pp, pos, yaw)
    updateMovement(pp, dt, yaw, bit(flags, 2))
    updateWeapon(pp, now, dt, weapon or 0, bit(flags, 16))
    updateFlashlight(pp, pos, yaw, pitch, eyeh, bit(flags, 8))
    updateTarget(pp, pos, eyeh, Entities:GetLocalPlayer())
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
    A.hudFullMag = false
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

local function hookNoVRFire(now, p)
    if IS_VR or not Viewmodels_UpgradeModel or now < (A.nextFireHook or 0) or (A.menu and A.menu.open) then return end
    A.nextFireHook = now + 3
    SendToConsole("alias +customattack \"" .. NOVR_FIRE_ALIAS .. ";amp_trigger\"")
    -- the right mouse button also turns what you're carrying (see below); NoVR rebinds its keys on every
    -- level load and binds them to "load autosave" when you die, so leave it alone while dead
    if p:GetHealth() > 0 then
        SendToConsole("bind " .. (rawget(_G, "SECONDARY_ATTACK") or "MOUSE2") .. " +amp_turn")
    end
end

---------------------------------------------------------------------------------------------------
-- turning what you carry (NoVR), like in Garry's Mod: hold the right mouse button and move the mouse.
-- The game's carry can't turn things, and it lines them up straight with your view whenever it picks
-- them up, so once you turn something we carry it ourselves: it's pushed (with physics, so it still
-- bumps into things) to the same spot in front of you, at the angle you gave it, until you press E.
-- While the button is down mouse look is slowed to a thousandth: its tiny movements turn the object,
-- and the camera is put back each time it drifts a hundredth of a degree, so it stays put.

local TURN_SENS_DIV = 1000      -- mouse look slowed down this much while turning...
local TURN_GAIN = 1.0           -- ...and an object degree per degree the view would have turned
local TURN_RECENTER = 0.01      -- the camera is put back once it drifted this far (degrees)
local TURN_TAG = 0.01           -- roll that marks each putting back (see updateTurning)
local CARRY_TAU = 0.05          -- seconds to close the gap to where it should be
local CARRY_MAX_SPEED = 1500
local CARRY_LOSE = 60           -- this far off (stuck behind something) for CARRY_LOSE_TIME: let go
local CARRY_LOSE_TIME = 0.5
local CARRY_CLASSES = { prop_physics = true, prop_physics_override = true, prop_physics_multiplayer = true,
    prop_physics_interactive = true }

local function axes(a)          -- forward, right, up of an angle (Source's conventions)
    local sp, cp = math.sin(math.rad(a.x)), math.cos(math.rad(a.x))
    local sy, cy = math.sin(math.rad(a.y)), math.cos(math.rad(a.y))
    local sr, cr = math.sin(math.rad(a.z)), math.cos(math.rad(a.z))
    return Vector(cp * cy, cp * sy, -sp),
        Vector(-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp),
        Vector(cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp)
end

local function anglesOf(f, u)
    local pitch = math.deg(math.asin(math.max(-1, math.min(1, -f.z))))
    local yaw = math.deg(atan2(f.y, f.x))
    local sp, cp = math.sin(math.rad(pitch)), math.cos(math.rad(pitch))
    local sy, cy = math.sin(math.rad(yaw)), math.cos(math.rad(yaw))
    local roll = math.deg(atan2(u:Dot(Vector(sy, -cy, 0)), u:Dot(Vector(sp * cy, sp * sy, cp))))
    return pitch, yaw, roll
end

local function rotate(v, k, deg)    -- v turned around the unit axis k (Rodrigues)
    local t = math.rad(deg)
    local c, s = math.cos(t), math.sin(t)
    return v * c + k:Cross(v) * s + k * (k:Dot(v) * (1 - c))
end

local function toBasis(v, f, r, u) return Vector(v:Dot(f), v:Dot(r), v:Dot(u)) end
local function fromBasis(v, f, r, u) return f * v.x + r * v.y + u * v.z end
local function interactKey() return rawget(_G, "INTERACT") or "E" end

-- what the game itself carries for you
local function gameCarried(p)
    for _, e in ipairs(Entities:FindAllInSphere(p:GetOrigin(), 200)) do
        if e:Attribute_GetIntValue("picked_up", 0) == 1 and CARRY_CLASSES[e:GetClassname()] then return e end
    end
    return nil
end

local function stopTurning()
    local c = A.carry
    if not c or not c.turning then return end
    c.turning = false
    SendToConsole("mouse_pitchyaw_sensitivity " .. c.sens)
    SendToConsole(string.format("setang_exact %.6f %.6f 0", c.view.x, c.view.y))
end

local function dropCarry(alive)
    local c = A.carry
    if not c then return end
    stopTurning()
    A.carry = nil
    -- (NoVR rebinds every key itself when you die)
    if alive then SendToConsole("bind " .. interactKey() .. " +useextra") end
    if IsValidEntity(c.ent) then c.ent:Attribute_SetIntValue("picked_up", 0) end
    -- the gun comes back, as when the game drops something
    local hh = Convars:GetInt("hidehud")
    if hh ~= 96 and hh ~= 1 and hh ~= 67 then SendToConsole("r_drawviewmodel 1") end
end

local function takeCarry(p, e)
    local eye, view = p:EyePosition(), p:EyeAngles()
    local vf, vr, vu = axes(view)
    local yf, yr, yu = axes(QAngle(0, view.y, 0))
    local of, _, ou = axes(e:GetAngles())
    A.carry = {
        ent = e,
        -- where it is in front of you, and its angle relative to the way you face (it turns with you,
        -- but not when you look up or down, like with the game's carry)
        off = toBasis(e:GetCenter() - eye, vf, vr, vu),
        f = toBasis(of, yf, yr, yu), u = toBasis(ou, yf, yr, yu),
    }
    DoEntFireByInstanceHandle(p, "ForceDropPhysObjects", "", 0, nil, nil)
    -- E lets go of it (the game's E would grab it again, straightened)
    SendToConsole("bind " .. interactKey() .. " amp_carry_drop")
end

local function startTurning(p)
    local c = A.carry
    if c.turning then return end
    -- (Convars can't read this one; NoVR keeps the value it sets in MOUSE_SENSITIVITY)
    local sens = Convars:GetFloat("mouse_pitchyaw_sensitivity") or rawget(_G, "MOUSE_SENSITIVITY") or 50
    local view = p:EyeAngles()
    c.turning, c.sens, c.view, c.last, c.tag, c.pending = true, sens, QAngle(view.x, view.y, 0), view, view.z, nil
    SendToConsole("mouse_pitchyaw_sensitivity " .. sens / TURN_SENS_DIV)
end

-- How far the mouse turned the camera since last tick, in degrees (yaw, pitch); the camera is put back
-- meanwhile. Putting it back (setang_exact) lands a tick or two later, so each one also sets a different
-- hint of roll, too little to see: the mouse never rolls the camera, so seeing that roll tells it has
-- landed, and from then on the camera moved from where it was put back to.
local function updateTurning(c, view, now)
    local from = c.last
    if c.pending and math.abs(angleDiff(view.z, c.pending)) < TURN_TAG / 4 then
        from = c.view
        c.tag, c.pending = c.pending, nil
    end
    c.last = view
    local dyaw, dpitch = angleDiff(view.y, from.y), view.x - from.x
    if math.max(math.abs(angleDiff(view.y, c.view.y)), math.abs(view.x - c.view.x)) > TURN_RECENTER
        and (not c.pending or now - c.pendingAt > 0.5) then
        if not c.pending then c.pending = math.abs(angleDiff(c.tag, TURN_TAG)) < TURN_TAG / 4 and 2 * TURN_TAG or TURN_TAG end
        c.pendingAt = now
        SendToConsole(string.format("setang_exact %.6f %.6f %.4f", c.view.x, c.view.y, c.pending))
    end
    return dyaw, dpitch
end

local function updateCarry(p, now)
    local c = A.carry
    if not c then return end
    local e = c.ent
    if not IsValidEntity(e) or p:GetHealth() <= 0 then
        dropCarry(p:GetHealth() > 0)
        return
    end
    local view = p:EyeAngles()
    local yf, yr, yu = axes(QAngle(0, view.y, 0))
    if c.turning then
        local dyaw, dpitch = updateTurning(c, view, now)
        dyaw, dpitch = dyaw * TURN_SENS_DIV * TURN_GAIN, dpitch * TURN_SENS_DIV * TURN_GAIN
        if dyaw ~= 0 or dpitch ~= 0 then
            -- left/right turns it around your view's up axis, up/down tips it toward or away from you
            local _, right, up = axes(c.view)
            local f, u = fromBasis(c.f, yf, yr, yu), fromBasis(c.u, yf, yr, yu)
            f, u = rotate(f, up, dyaw), rotate(u, up, dyaw)
            f, u = rotate(f, right, -dpitch), rotate(u, right, -dpitch)
            c.f, c.u = toBasis(f, yf, yr, yu), toBasis(u, yf, yr, yu)
        end
    end
    local vf, vr, vu = axes(view)
    local center = e:GetCenter()
    local gap = p:EyePosition() + fromBasis(c.off, vf, vr, vu) - center
    if gap:Length() > CARRY_LOSE then
        c.lostAt = c.lostAt or now
        if now - c.lostAt > CARRY_LOSE_TIME then
            dropCarry(true)
            return
        end
    else
        c.lostAt = nil
    end
    -- its angle is set outright (around its middle); where it is, it's pushed to
    local pitch, yaw, roll = anglesOf(fromBasis(c.f, yf, yr, yu), fromBasis(c.u, yf, yr, yu))
    e:SetAngles(pitch, yaw, roll)
    local shift = e:GetCenter() - center
    if shift:Length() > 0.01 then e:SetAbsOrigin(e:GetOrigin() - shift) end
    SetPhysAngularVelocity(e, Vector(0, 0, 0))
    local v = gap * (1 / CARRY_TAU)
    local speed = v:Length()
    if speed > CARRY_MAX_SPEED then v = v * (CARRY_MAX_SPEED / speed) end
    v = v + p:GetVelocity() + Vector(0, 0, (Convars:GetFloat("sv_gravity") or 500) * FrameTime())
    e:ApplyAbsVelocityImpulse(v - GetPhysVelocity(e))
    -- NoVR still counts it as carried (no aiming down sights meanwhile), and the hands stay empty
    if e:Attribute_GetIntValue("picked_up", 0) ~= 1 then e:Attribute_SetIntValue("picked_up", 1) end
    if Convars:GetInt("r_drawviewmodel") ~= 0 then SendToConsole("r_drawviewmodel 0") end
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
    -- a finished reload: the magazine is full (the HUD's glow goes by this, see updateGlowHud)
    if (A.vmSeq or ""):find("reload") and not seq:find("reload") then A.hudFullMag = true end
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
    if not IS_VR and (A.vmSeq or ""):find("reload") then flags = flags + 16 end
    local weapon = currentWeapon(now)

    local last = A.lastSent
    local changed = not last
        or (feet - last.pos):Length() > 0.5
        or math.abs(angleDiff(yaw, last.yaw)) > 1
        or math.abs(eyeh - last.eyeh) > 2
        or math.abs(pitch - last.pitch) > 2
        or flags ~= last.flags
        or weapon ~= last.weapon
    if not changed and now - A.lastSend < HEARTBEAT then return end

    A.lastSend = now
    A.lastSent = { pos = feet, yaw = yaw, pitch = pitch, eyeh = eyeh, flags = flags, weapon = weapon }
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

-- the right mouse button (NoVR, see hookNoVRFire): turns what you carry (unless that's switched off in
-- the settings menu); otherwise it does what it always did (aim down sights...)
reg("+amp_turn", function()
    if A.menu and A.menu.open then return end      -- (the menu is mouse-only; right-click does nothing there)
    local p = Entities:GetLocalPlayer()
    if not IS_VR and p and p:GetHealth() > 0 and shown("turn") then
        if not A.carry then
            local e = gameCarried(p)
            if e then takeCarry(p, e) end
        end
        if A.carry then
            startTurning(p)
            return
        end
    end
    A.m2Passed = true
    SendToConsole("+customattack2")
end)
reg("-amp_turn", function()
    if A.m2Passed then
        A.m2Passed = nil
        SendToConsole("-customattack2")
    end
    stopTurning()
end)
reg("amp_carry_drop", function()
    local p = Entities:GetLocalPlayer()
    dropCarry(p ~= nil and p:GetHealth() > 0)
end)

-- the launcher is about to load a save or a level
reg("amp_unload", function()
    local p = Entities:GetLocalPlayer()
    dropCarry(p ~= nil and p:GetHealth() > 0)
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
-- Glow HUD (NoVR). The game draws the numbers, the dots and the icons itself. What it
-- can't draw (the glow and the dim placeholder zeros) are labels that wait off the
-- screen until an event in the HUD's hudanimations.txt moves them in:
--   AmpHealth1 / 2 / 3   the health has that many digits (this also right-aligns it), AmpHealthOff
--   AmpAmmoOn1 / 2       a gun is out, its magazine count has that many digits, AmpAmmoOff
-- We run the ones that fit what the game is showing, and again every two seconds because a new
-- level or a reloaded HUD starts with everything hidden. Without that HUD the events don't exist
-- and nothing happens.

local function updateGlowHud(now, p)
    if IS_VR then return end
    local health, ammo = "Off", "Off"
    local hp = p:GetHealth()
    local hide = Convars:GetInt("hidehud") or 0
    local gun = currentWeapon(now)
    if gun ~= A.hudGun then A.hudGun, A.hudFullMag = gun, false end
    -- hidehud 4: everything, 8: health and ammo, 32: "needs the suit" (NoVR's menu and cutscenes)
    if hp > 0 and not (bit(hide, 4) or bit(hide, 8) or bit(hide, 32)) and Convars:GetInt("r_drawvgui") ~= 0 then
        health = hp >= 100 and "3" or hp >= 10 and "2" or "1"
        -- the ammo count shows for the guns; hidehud 1 hides it along with the weapon selection
        if gun ~= 0 and not bit(hide, 1) then
            -- Lua can't read the count, so go by the magazines: the SMG's 30 rounds are mostly two
            -- digits, the shotgun's 6 always one, the pistol's 10 only from a reload to the next shot
            ammo = (gun == 3 or (gun == 1 and A.hudFullMag)) and "On2" or "On1"
        end
    end
    local state = health .. ammo
    if state == A.glowHud and now < (A.nextGlowHud or 0) then return end
    A.glowHud = state
    A.nextGlowHud = now + 2
    SendToConsole("testhudanim AmpHealth" .. health)
    SendToConsole("testhudanim AmpAmmo" .. ammo)
end

---------------------------------------------------------------------------------------------------
-- The settings menu (NoVR): ESC over the game. The game keeps ESC to itself (binds never see it), so
-- the launcher passes it on as amp_menu. The menu is drawn by the glow HUD - its AmpMenu* labels, moved
-- and faded by its events (tools/menu_hud/make_menu.py writes both, and the layout numbers below come
-- from there). It's used with the mouse alone: the mouse moves a cursor (mouse look is slowed a thousand
-- times and the view put back, as when turning what you carry), pointing at a row lights up its name, a
-- click switches it; ESC closes it. While it's open the launcher keeps the keyboard from the game, and the
-- fire button clicks in the menu instead. Switches apply at once and go to the launcher, which keeps them
-- and sends them back (amp_cfg) every time.
-- Never let go of the game's trigger (-iv_attack) when it isn't held: that leaves it stuck down, and the
-- gun fires by itself until the next real click (NoVR's multitool code steers round the same thing).

local MENU = { "autoreload", "tags", "dot", "turn", "list", "feed", "zones" }   -- its rows, top down
local MENU_L, MENU_R, MENU_ROW0, MENU_ROW_H = -166, 166, 136, 29    -- HUD units (640x480, x from the centre)
local MENU_TOP, MENU_BOTTOM = 84, 348                                -- the menu's area (leaving it unlights the row)
local CURSOR_SPEED = 15         -- cursor pixels per thousandth of a degree the view would have turned...
local CURSOR_SENS = 50          -- ...at this mouse sensitivity (so it moves alike for everyone)
local CURSOR_PITCH = 0.65       -- the view turns about half as fast again up/down; even it out
local CURSOR_DOT = "k"          -- the cursor in AlyxMPMenuFx
-- NoVR's fire button (novr.lua sets it on every level load, hookNoVRFire adds to it); the menu borrows it
-- while it's open
local NOVR_ALIASES = { { "+customattack", NOVR_FIRE_ALIAS .. ";amp_trigger" }, { "-customattack", "-iv_attack" } }
local MENU_ALIASES = { { "+customattack", "amp_menu_click" }, { "-customattack", "amp_menu_unclick" } }

local function hudAnim(name) SendToConsole("testhudanim " .. name) end

local function setAliases(list)
    for _, a in ipairs(list) do SendToConsole("alias " .. a[1] .. " \"" .. a[2] .. "\"") end
end

-- the game's own menu sounds (Half-Life: Alyx's main menu uses them), right at the player's ears
local function menuSound(name)
    local p = Entities:GetLocalPlayer()
    if p then StartSoundEventFromPosition(name, p:EyePosition()) end
end

local function menuOn(i) return A.cfg[MENU[i]] ~= "0" end

-- HUD units -> screen pixels (the HUD scales with the window's height, x measured from the centre)
local function hudScale()
    local w, h = screenSize()
    return h / 480, w / 2
end

-- the row under screen point (x, y), or nil
local function rowAt(x, y)
    local s, cx = hudScale()
    local u, v = (x - cx) / s, y / s
    if u < MENU_L or u > MENU_R then return nil end
    local i = math.floor((v - MENU_ROW0) / MENU_ROW_H) + 1
    if i >= 1 and i <= #MENU then return i end
    return nil
end

local function insideMenu(x, y)
    local s, cx = hudScale()
    local u, v = (x - cx) / s, y / s
    return u >= MENU_L - 20 and u <= MENU_R + 20 and v >= MENU_TOP and v <= MENU_BOTTOM
end

local function menuHover(i, sound)
    local m = A.menu
    if i == m.hover then return end
    m.hover = i
    hudAnim(i and ("AmpMenuHover" .. i) or "AmpMenuHoverNone")
    if i and sound then menuSound("PanoUI.Rollover") end
end

function A.MenuOpen()
    local m = A.menu
    local p = Entities:GetLocalPlayer()
    if IS_VR or m.open or not p or p:GetHealth() <= 0 then return end
    if A.carry then dropCarry(true) end     -- (E switches things in the menu)
    m.open, m.hover, m.pressed = true, nil, false
    setAliases(MENU_ALIASES)
    -- the mouse drives the cursor; the view stays where it is
    local sens = Convars:GetFloat("mouse_pitchyaw_sensitivity") or rawget(_G, "MOUSE_SENSITIVITY") or 50
    local view = p:EyeAngles()
    m.cap = { sens = sens, view = QAngle(view.x, view.y, 0), last = view, tag = view.z }
    SendToConsole("mouse_pitchyaw_sensitivity " .. sens / TURN_SENS_DIV)
    local w, h = screenSize()
    m.cx, m.cy = w / 2, h / 2
    -- the game's reticle (the brackets round the middle of the screen) would sit in the menu
    m.reticle = Convars:GetInt("hud_draw_fixed_reticle")
    if m.reticle and m.reticle ~= 0 then SendToConsole("hud_draw_fixed_reticle 0") end
    hudAnim("AmpMenuOpen")
    m.showAt = Time() + 0.1     -- the switches come in as the rows do
    menuSound("PanoUI.Appear")
    A.Emit("menu", 1)           -- (the launcher keeps the keyboard from the game meanwhile)
end

function A.MenuClose(quiet)
    local m = A.menu
    if not m.open then return end
    m.open, m.showAt, m.hover = false, nil, nil
    hudAnim("AmpMenuClose")
    setAliases(NOVR_ALIASES)
    -- the mouse button is still down from a click in the menu: its release mustn't let go of the trigger
    if m.pressed then SendToConsole("alias -customattack \"alias -customattack -iv_attack\"") end
    m.pressed = false
    local c = m.cap
    m.cap = nil
    if c then
        SendToConsole("mouse_pitchyaw_sensitivity " .. c.sens)
        SendToConsole(string.format("setang_exact %.6f %.6f 0", c.view.x, c.view.y))
    end
    if m.reticle and m.reticle ~= 0 then SendToConsole("hud_draw_fixed_reticle " .. m.reticle) end
    if not quiet then menuSound("PanoUI.Disappear") end
    A.Emit("menu", 0)
end

local function menuSwitch(i)
    local m = A.menu
    if not m.open or m.showAt or not i then return end
    local key = MENU[i]
    local on = not menuOn(i)
    A.cfg[key] = on and "1" or "0"
    hudAnim((on and "AmpMenuOn" or "AmpMenuOff") .. i)
    menuSound("PanoUI.ToggleOption")
    A.Emit("cfg", key, A.cfg[key])
end

local function menuClick()
    local m = A.menu
    if not m.open then return end
    local i = rowAt(m.cx, m.cy)
    if i then
        menuHover(i, false)
        menuSwitch(i)
    end
end

local function updateMenu(now, p)
    local m = A.menu
    if not m.open then return end
    if p:GetHealth() <= 0 then
        A.MenuClose(true)
        return
    end
    if m.showAt and now >= m.showAt then
        m.showAt = nil
        for i = 1, #MENU do hudAnim((menuOn(i) and "AmpMenuShowOn" or "AmpMenuShowOff") .. i) end
        menuHover(rowAt(m.cx, m.cy), false)     -- the row under the cursor from the start
    end
    -- the cursor
    local c = m.cap
    if c then
        local dyaw, dpitch = updateTurning(c, p:EyeAngles(), now)
        local k = TURN_SENS_DIV * CURSOR_SPEED * CURSOR_SENS / math.max(c.sens, 1)
        local w, h = screenSize()
        local x = math.max(0, math.min(w - 1, m.cx - dyaw * k))
        local y = math.max(0, math.min(h - 1, m.cy + dpitch * k * CURSOR_PITCH))
        if x ~= m.cx or y ~= m.cy then
            m.cx, m.cy = x, y
            local i = rowAt(x, y)
            if i then menuHover(i, true) elseif m.hover and not insideMenu(x, y) then menuHover(nil) end
        end
        local size = px(34)
        local tx, ty = math.floor(m.cx - size / 2 + 0.5), math.floor(m.cy - size / 2 + 0.5)
        DebugScreenTextPretty(tx, ty, 0, CURSOR_DOT, 255, 236, 170, 255, 0, "AlyxMPMenuFx", size, false)
    end
end

reg("amp_menu", function() if A.menu.open then A.MenuClose() else A.MenuOpen() end end)
reg("amp_menu_click", function()
    A.menu.pressed = true
    menuClick()
end)
-- the fire button let go while the menu is open: after a click in the menu, nothing; otherwise it was
-- already down (firing) when the menu opened, and the trigger is let go of here (unless NoVR's multitool
-- already did)
reg("amp_menu_unclick", function()
    local m = A.menu
    if m.pressed then
        m.pressed = false
        return
    end
    local vm = Entities:FindByClassname(nil, "viewmodel")
    if vm and (vm:GetModelName() or ""):find("v_multitool") then return end
    SendToConsole("-iv_attack")
end)

-- this file is run again on every level (and when the launcher attaches): a menu that was open is gone
-- with the old level, and the mouse is given back
A.menu = A.menu or {}
if A.menu.open then A.MenuClose(true) end

---------------------------------------------------------------------------------------------------
-- main loop

local lastTick = Time()
local function tick()
    local now = Time()
    local dt = now - lastTick
    lastTick = now
    local p = Entities:GetLocalPlayer()
    if p then
        updateGlowHud(now, p)
        updateMenu(now, p)
        hookNoVRFire(now, p)
        updateCarry(p, now)
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
    for _, name in ipairs({ PROP_NAME, HUD_NAME }) do
        for _, e in ipairs(Entities:FindAllByName(name)) do
            DoEntFireByInstanceHandle(e, "Kill", "", 0, nil, nil)
        end
    end
    for _, e in ipairs(Entities:FindAllByClassname("npc_bullseye")) do
        if (e:GetName() or ""):sub(1, #TARGET_NAME) == TARGET_NAME then DoEntFireByInstanceHandle(e, "Kill", "", 0, nil, nil) end
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
