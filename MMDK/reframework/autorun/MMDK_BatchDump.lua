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
local cooldown_frames = 0
local starting_p2_id = nil
local last_switch_details = "No switch requested yet."
local last_switch_returns = ""
local common_exported = false
local common_summary = nil

local READY_FRAMES = 20
local TIMEOUT_FRAMES = 3600
local NEXT_FIGHTER_DELAY_FRAMES = 120
local JOB_KEY = "mmdk_batch_dump_current_character"
local SCRIPT_VERSION = "2026-10-14.2"

local function message(value)
    last_message = value
    log.info("MMDK Batch Dump: " .. value)
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
    if previous_data and data == previous_data.instance
        and data.chara_id == previous_data.chara_id
        and data.person == previous_data.person
        and data.engine == previous_data.engine then
        return nil, "waiting for MMDK to rebuild P2 data"
    end
    if data.chara_id ~= id or data.name ~= characters[id] then return nil, "P2 data belongs to a different fighter" end
    if not data.person or not data.hit_datas then return nil, "fighter resources are not ready" end
    if not data.triggers_by_act_id or not data.rects or not data.commands or not data.tgroups then return nil, "move resources are not ready" end
    if not data.atemi or not data.charge or not data.char_info or not data.assist_combo then return nil, "supplemental resources are not ready" end
    if not data.moves_dict or not data.moves_dict.By_Name or not next(data.moves_dict.By_Name) then return nil, "moves dictionary is empty" end
    if not data.common_moves_collected then return nil, "waiting for common actions to be collected" end
    return data
end

local function dump_character(data)
    -- MMDK's dump methods do not check json.dump_file's boolean result.
    local original_dump_file = json.dump_file
    json.dump_file = function(path, value, ...)
        if not original_dump_file(path, value, ...) then
            error("Could not write reframework/data/" .. path)
        end
        return true
    end
    local step = ""
    local ok, err = pcall(function()
        if not common_exported then
            step = "common resources"
            log.info("MMDK Batch Dump: Exporting common actions, rects, atemi and ACT_ID")
            common_summary = data:dump_common_json()
            common_exported = true
        end
        local methods = {
            {"HIT_DT", "dump_hit_dt_json"},
            {"triggers", "dump_trigger_json"},
            {"atemi", "dump_atemi_json"},
            {"tgroups", "dump_tgroups_json"},
            {"rects", "dump_rects_json"},
            {"commands", "dump_commands_json"},
            {"charge", "dump_charge_json"},
            {"char_info", "dump_char_info_json"},
            {"assist_combo", "dump_assist_combo_json"},
            {"moves_dict", "dump_moves_dict_json"},
        }
        for _, method in ipairs(methods) do
            step = method[1]
            log.info("MMDK Batch Dump: Exporting " .. data.name .. " " .. step)
            data[method[2]](data)
        end
    end)
    json.dump_file = original_dump_file
    if not ok then error(step .. ": " .. tostring(err)) end
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

-- The training controller owns both the fighter selection and the resource
-- reload flags. Editing FighterDesc or SelectMenu.FighterID alone bypasses it.
local function switch_p2(id)
    local manager = training_objects()
    if not manager then error("Training Mode is no longer available") end
    if manager:get_field("_ActiveMenuType") ~= -1 then
        error("Close the game training menu before switching fighters")
    end
    local funcs = manager:get_field("_tfFuncs")
    if not funcs then error("Training function controllers are unavailable") end
    local selector = require("MMDK\\functions").lua_get_dict(funcs)[1]
    if not selector or selector:get_type_definition():get_full_name() ~= "app.training.tf_SelectMenu" then
        error("Training character-selection controller is unavailable")
    end
    local selection = manager:get_field("_tData"):get_field("SelectMenu"):get_field("PlayerDatas")[1]
    local controller = selector:get_field("FuncList")
    if not controller or not selection then error("Training P2 selection is unavailable") end
    local live_before = current_p2_id()
    -- Zero-based player 1 is P2. Preserve controls, reset costume/color to the
    -- target's default, and let ChangeFighter mark IsCharaChange/IsChanged.
    controller:call("ChangeFighter", 1, id, 0, 0,
        selection:get_field("InputType"), selection:get_field("KeyConfigPreset"),
        selection:get_field("NegativeEdge"), selection:get_field("LowStickSensitivity"))
    local game_data = selector:get_field("_GameData")
    local marked = game_data and game_data:get_field("IsCharaChange")
    if not marked then error("ChangeFighter did not request a character reload") end
    -- Apply only selection; other controllers still reference the old fighter
    -- until the new battle loads (global Apply can index incompatible gauges).
    selector:call("Apply")
    last_switch_details = "target=" .. id .. ", live=" .. tostring(live_before) .. "; waiting for fighter resources"
    last_switch_returns = "ChangeFighter(P2) marked reload=" .. tostring(marked) .. "; tf_SelectMenu.Apply() completed"
    log.info("MMDK Batch Dump: " .. last_switch_details .. "; " .. last_switch_returns)
end

local function start(resume)
    if not PlayerData or not player_data or not mmsettings or not tmp_fns then
        stop_with_error("MMDK.lua is not loaded.")
        return
    end
    if not PlayerData.dump_common_json then
        stop_with_error("Update MMDK.lua together with MMDK_BatchDump.lua, then Reset scripts.")
        return
    end
    local ok, manager, descs = pcall(training_objects)
    if not ok or not manager or not descs then
        stop_with_error("Enter Training Mode before starting.")
        return
    end
    if manager:get_field("_ActiveMenuType") ~= -1 then
        stop_with_error("Close the game training menu before starting or resuming.")
        return
    end
    if not resume then
        local selected, err = parse_ids(ids_text)
        if not selected then stop_with_error(err); return end
        queue, index, completed = selected, 1, {}
        common_exported, common_summary = false, nil
        last_switch_details = "No switch requested yet."
        last_switch_returns = ""
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
    -- Common moves are intentionally enabled after the batch as well.
    -- A previously built dictionary without common data is rebuilt by ready_data.
    mmsettings.do_common_dict = true
    phase = "request"
    message("Starting at " .. index .. "/" .. #queue .. ".")
end

local function request_character(id)
    local manager = training_objects()
    if not manager then error("Training Mode is no longer available") end
    frames_waited = 0
    stable_frames = 0
    wait_reason = ""
    rebuild_requested = false
    starting_p2_id = current_p2_id()
    if starting_p2_id == id then
        -- TrainingManager may not rebuild the battle when P2 already has this ID.
        previous_data = nil
        if ready_data(id) then
            phase = "waiting"
            message("Using loaded " .. characters[id] .. " data (" .. index .. "/" .. #queue .. ").")
            return
        end
        local data = player_data and player_data[2]
        previous_data = data and {instance = data, chara_id = data.chara_id, person = data.person, engine = data.engine}
        phase = "waiting"
        rebuild_p2_data(id)
        return
    end
    -- Wait for MMDK to create new player data after switching fighters.
    local data = player_data and player_data[2]
    previous_data = data and {instance = data, chara_id = data.chara_id, person = data.person, engine = data.engine}
    switch_p2(id)
    phase = "waiting"
    message("Loading " .. characters[id] .. " (" .. index .. "/" .. #queue .. ").")
end

-- Menu operations must run on the game update thread, never on the render callback.
re.on_application_entry("UpdateBehavior", function()
    if phase == "cooldown" then
        cooldown_frames = cooldown_frames - 1
        if cooldown_frames <= 0 then phase = "request" end
        return
    end
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
        local observed_id = current_p2_id()
        if not rebuild_requested and frames_waited >= 120 and observed_id == id then
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
        if queue[index] then
            cooldown_frames = NEXT_FIGHTER_DELAY_FRAMES
            phase = "cooldown"
        else
            phase = "request"
        end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("MMDK Batch Dump") then return end
    imgui.text("Script version: " .. SCRIPT_VERSION)
    imgui.text("Training Mode: cycles P2 through the selected character IDs.")
    local changed, value = imgui.input_text("Character IDs", ids_text)
    if changed and (phase == "idle" or phase == "done" or phase == "error" or phase == "stopped") then ids_text = value end
    imgui.text("Example: 1-22,25-34. IDs are game resource IDs, not roster positions.")
    imgui.text("Common moves are collected and shared resources are exported automatically.")
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
    imgui.text("Phase: " .. phase)
    imgui.text("Switch: " .. last_switch_details)
    if last_switch_returns ~= "" then imgui.text("Calls: " .. last_switch_returns) end
    if phase == "waiting" then
        imgui.text("Waiting: " .. frames_waited .. "/" .. TIMEOUT_FRAMES .. " frames; " .. (wait_reason ~= "" and wait_reason or "checking stability"))
    elseif phase == "cooldown" then
        imgui.text("Waiting before next fighter: " .. cooldown_frames .. " frames")
    end
    imgui.text("Output: reframework/data/MMDK/PlayerData/<character>/")
    if common_summary then imgui.text("Common actions exported: " .. common_summary.action_entries) end
    imgui.text("Shared output: reframework/data/MMDK/PlayerData/common_*.json")
    imgui.tree_pop()
end)
