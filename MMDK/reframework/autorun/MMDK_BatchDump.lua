-- Batch-export current-game MMDK data by cycling P2 in Training Mode.
-- Install beside MMDK.lua in reframework/autorun. Start it from Script Generated UI.

local characters = require("MMDK\\tables").characters
local ids = {}
for id in pairs(characters) do ids[#ids + 1] = id end
table.sort(ids)

local default_ids = {}
for _, id in ipairs(ids) do default_ids[#default_ids + 1] = tostring(id) end
local ids_text = table.concat(default_ids, ",")

local queue = {}
local index = 1
local phase = "idle"
local frames_waited = 0
local stable_frames = 0
local last_message = "Enter Training Mode, then press Start."
local completed = {}
local saved_settings = nil
local previous_data = nil
local wait_reason = ""
local rebuild_requested = false

local READY_FRAMES = 20
local TIMEOUT_FRAMES = 3600
local JOB_KEY = "mmdk_batch_dump_current_character"

local function message(value)
    last_message = value
    print("MMDK Batch Dump: " .. value)
end

local function restore_settings()
    if not saved_settings or not mmsettings then return end
    mmsettings.enabled = saved_settings.enabled
    for name, settings in pairs(saved_settings.fighters) do
        local option = mmsettings.fighter_options[name]
        option.enabled = settings.enabled
        for filename, enabled in pairs(settings.mods) do
            option[filename].enabled = enabled
        end
    end
    saved_settings = nil
end

local function stop_with_error(value)
    phase = "error"
    if tmp_fns then tmp_fns[JOB_KEY] = nil end
    restore_settings()
    message(value)
end

local function parse_ids(value)
    local selected, seen = {}, {}
    for token in value:gmatch("[^,%s]+") do
        local first, last = token:match("^(%d+)%-(%d+)$")
        first, last = tonumber(first), tonumber(last)
        if not first then first = tonumber(token); last = first end
        if not first or first > last then return nil, "Invalid ID or range: " .. token end
        for id = first, last do
            if not characters[id] then return nil, "ID " .. id .. " is missing from MMDK/tables.lua" end
            if not seen[id] then
                selected[#selected + 1] = id
                seen[id] = true
            end
        end
    end
    if #selected == 0 then return nil, "Enter at least one character ID." end
    return selected
end

local function training_objects()
    local manager = sdk.get_managed_singleton("app.training.TrainingManager")
    if not manager then return nil, nil end
    local core = manager:call("get_BattleCore()")
    if not core then return nil, nil end
    local descs = core:get_field("_FighterDescs")
    if not descs or not descs[0] or not descs[1] then return nil, nil end
    return manager, descs
end

local function current_p2_id()
    local ok, id = pcall(function()
        local player = sdk.find_type_definition("gBattle"):get_field("Player"):get_data()
        return player.mPlayerType[1].mValue
    end)
    return ok and id or nil
end

local function ready_data(id)
    local data = player_data and player_data[2]
    local observed_id = current_p2_id()
    if observed_id ~= id then return nil, "P2 ID is " .. tostring(observed_id) .. ", expected " .. id end
    if not data then return nil, "MMDK has not built P2 data" end
    if data == previous_data then return nil, "waiting for a new P2 data object" end
    if data.chara_id ~= id or data.name ~= characters[id] then return nil, "P2 data belongs to a different fighter" end
    if not data.person or not data.hit_datas then return nil, "fighter resources are not ready" end
    if not data.triggers_by_act_id or not data.rects or not data.commands or not data.tgroups then return nil, "move resources are not ready" end
    if not data.atemi or not data.charge or not data.char_info or not data.assist_combo then return nil, "supplemental resources are not ready" end
    if not data.moves_dict or not data.moves_dict.By_Name or not next(data.moves_dict.By_Name) then return nil, "moves dictionary is empty" end
    return data
end

local function dump_character(data)
    -- Match the per-character files written by MMDK's Dump All button.
    data:dump_hit_dt_json()
    data:dump_trigger_json()
    data:dump_atemi_json()
    data:dump_tgroups_json()
    data:dump_rects_json()
    data:dump_commands_json()
    data:dump_charge_json()
    data:dump_char_info_json()
    data:dump_assist_combo_json()
    data:dump_moves_dict_json()
end

local function rebuild_p2_data(id)
    rebuild_requested = true
    tmp_fns[JOB_KEY] = function()
        tmp_fns[JOB_KEY] = nil
        local ok, err = pcall(function() PlayerData:new(2, true) end)
        if not ok then stop_with_error("Cannot collect " .. characters[id] .. ": " .. tostring(err)) end
    end
    message("Rebuilding " .. characters[id] .. " data (" .. index .. "/" .. #queue .. ").")
end

local function start(resume)
    if not PlayerData or not player_data or not mmsettings or not tmp_fns then
        stop_with_error("MMDK.lua is not loaded.")
        return
    end
    local ok, manager, descs = pcall(training_objects)
    if not ok or not manager or not descs then
        stop_with_error("Enter Training Mode before starting.")
        return
    end
    if not resume then
        local selected, err = parse_ids(ids_text)
        if not selected then stop_with_error(err); return end
        queue, index, completed = selected, 1, {}
    end
    local names = {["All Characters"] = true}
    for _, id in ipairs(queue) do names[characters[id]] = true end
    for name in pairs(names) do
        if not mmsettings.fighter_options[name] then
            stop_with_error("No MMDK fighter option for " .. name .. ". Reload MMDK after updating tables.lua.")
            return
        end
    end

    saved_settings = {enabled = mmsettings.enabled, fighters = {}}
    for name in pairs(names) do
        local option = mmsettings.fighter_options[name]
        local settings = {enabled = option.enabled, mods = {}}
        for _, filename in ipairs(option.ordered or {}) do
            if option[filename] then
                settings.mods[filename] = option[filename].enabled
                option[filename].enabled = false
            end
        end
        saved_settings.fighters[name] = settings
        option.enabled = name ~= "All Characters"
    end
    mmsettings.enabled = true
    phase = "request"
    message("Starting at " .. index .. "/" .. #queue .. ".")
end

local function request_character(id)
    local manager, descs = training_objects()
    if not manager then error("Training Mode is no longer available") end
    frames_waited = 0
    stable_frames = 0
    wait_reason = ""
    rebuild_requested = false
    if current_p2_id() == id then
        -- TrainingManager may not rebuild the battle when P2 already has this ID.
        previous_data = nil
        if ready_data(id) then
            phase = "waiting"
            message("Using loaded " .. characters[id] .. " data (" .. index .. "/" .. #queue .. ").")
            return
        end
        previous_data = player_data and player_data[2]
        phase = "waiting"
        rebuild_p2_data(id)
        return
    end
    -- Wait for MMDK to create new player data after switching fighters.
    previous_data = player_data and player_data[2]
    descs[1].FighterId = id
    manager:SetFighter(descs[0], descs[1])
    manager:RequestTrainingFlow(false)
    phase = "waiting"
    message("Loading " .. characters[id] .. " (" .. index .. "/" .. #queue .. ").")
end

re.on_frame(function()
    if phase ~= "request" and phase ~= "waiting" then return end
    local id = queue[index]
    if not id then
        phase = "done"
        restore_settings()
        message("Finished " .. #completed .. " characters.")
        return
    end

    if phase == "request" then
        local ok, err = pcall(request_character, id)
        if not ok then stop_with_error("Cannot load " .. characters[id] .. ": " .. tostring(err)) end
        return
    end

    frames_waited = frames_waited + 1
    if frames_waited > TIMEOUT_FRAMES then
        stop_with_error("Timed out waiting for " .. characters[id] .. ": " .. (wait_reason ~= "" and wait_reason or "data did not stay stable") .. ". Check the REFramework log.")
        return
    end
    local data, reason = ready_data(id)
    if not data then
        wait_reason = reason
        stable_frames = 0
        if not rebuild_requested and frames_waited >= 120 and current_p2_id() == id then
            if engines and engines[2] then
                rebuild_p2_data(id)
            else
                wait_reason = reason .. "; MMDK P2 engine is unavailable"
            end
        end
        return
    end
    wait_reason = ""
    stable_frames = stable_frames + 1
    if stable_frames < READY_FRAMES then return end

    phase = "dumping"
    tmp_fns[JOB_KEY] = function()
        tmp_fns[JOB_KEY] = nil
        local current = ready_data(id)
        if current ~= data then
            stop_with_error(characters[id] .. " changed before export; press Resume to retry.")
            return
        end
        local ok, err = pcall(dump_character, current)
        if not ok then
            stop_with_error("Export failed for " .. characters[id] .. ": " .. tostring(err))
            return
        end
        completed[#completed + 1] = characters[id]
        message("Exported " .. characters[id] .. " (" .. index .. "/" .. #queue .. ").")
        index = index + 1
        phase = "request"
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("MMDK Batch Dump") then return end
    imgui.text("Training Mode: cycles P2 through the selected character IDs.")
    local changed, value = imgui.input_text("Character IDs", ids_text)
    if changed and (phase == "idle" or phase == "done" or phase == "error" or phase == "stopped") then ids_text = value end
    imgui.text("Example: 1-22,25-33. IDs must exist in MMDK/tables.lua.")
    imgui.text("Moveset mods are disabled during the batch and restored afterward.")
    if phase == "idle" or phase == "done" or phase == "error" or phase == "stopped" then
        if imgui.button("Start new batch") then start(false) end
        if (phase == "error" or phase == "stopped") and #queue > 0 and imgui.button("Resume") then start(true) end
    else
        if imgui.button("Stop") then
            phase = "stopped"
            if tmp_fns then tmp_fns[JOB_KEY] = nil end
            restore_settings()
            message("Stopped after " .. #completed .. " characters.")
        end
    end
    imgui.text("Status: " .. last_message)
    if phase == "waiting" then
        imgui.text("Waiting: " .. frames_waited .. "/" .. TIMEOUT_FRAMES .. " frames; " .. (wait_reason ~= "" and wait_reason or "checking stability"))
    end
    imgui.text("Output: reframework/data/MMDK/PlayerData/<character>/")
    imgui.tree_pop()
end)
