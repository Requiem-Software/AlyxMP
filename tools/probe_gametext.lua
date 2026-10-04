local function show(name, x, y, channel, msg, r, g, b, hold)
    local e = Entities:FindByName(nil, name)
    if not e then
        e = SpawnEntityFromTableSynchronous("game_text", { targetname = name, effect = 0, spawnflags = 1, color = r .. " " .. g .. " " .. b,
            color2 = "0 0 0", fadein = 0, fadeout = 0.5, fxtime = 0, holdtime = hold or 6, x = x, y = y, channel = channel })
    end
    DoEntFireByInstanceHandle(e, "SetText", msg, 0, nil, nil)
    DoEntFireByInstanceHandle(e, "Display", "", 0.01, nil, nil)
end
show("amp_t_chat", 0.02, 0.5, 3, "Bob: hey where are you\nAlice: by the train cars\n* Carl joined the game\nBob: ok coming", 255, 220, 140, 8)
show("amp_t_ind", -1, 0.535, 5, "[E] PICK UP", 255, 157, 0, 6)
show("amp_t_zone", -1, 0.2, 2, "LOADING ZONE  1/2 players ready\nWaiting for: Bob", 120, 255, 140, 6)
print("[AMP-GT] shown")
