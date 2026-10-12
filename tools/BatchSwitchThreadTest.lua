-- Temporary one-shot game-thread test of a training-menu P2 switch.
local key = "mmdk_batch_switch_thread_test"
local phase, frames, target = "idle", 0, 1
local function emit(s) log.info("[BatchSwitchThreadTest] " .. s) end
local function manager() return sdk.get_managed_singleton("app.training.TrainingManager") end
local function player(m)
    return m:get_field("_tData"):get_field("SelectMenu"):get_field("PlayerDatas")[1]
end
local function live()
    local ok, id = pcall(function()
        return sdk.find_type_definition("gBattle"):get_field("Player"):get_data().mPlayerType[1].mValue
    end)
    return ok and id or "?"
end
local function status(m)
    return "state=" .. tostring(m:get_field("_MenuState")) .. " type=" .. tostring(m:get_field("_ActiveMenuType")) .. " selected=" .. tostring(player(m):get_field("FighterID")) .. " live=" .. tostring(live())
end
local function fail(reason)
    phase = "failed"
    emit("FAILED " .. tostring(reason))
end
re.on_draw_ui(function()
    if not imgui.tree_node("MMDK Game Thread Switch Test") then return end
    imgui.text("Phase: " .. phase)
    if phase == "idle" and imgui.button("Switch Luke to Ryu once") then
        phase, frames = "opening", 0
        if not tmp_fns then return fail("MMDK unavailable") end
        tmp_fns[key] = function()
            tmp_fns[key] = nil
            local m = manager()
            if not m then return fail("no training manager") end
            emit("BEFORE OPEN " .. status(m))
            local ok, err = pcall(function() m:call("OpenMenu", 0, nil) end)
            if not ok then return fail("open: " .. tostring(err)) end
            emit("AFTER OPEN " .. status(m))
            phase, frames = "open", 0
        end
    end
    imgui.tree_pop()
end)
re.on_frame(function()
    if phase ~= "open" and phase ~= "waiting" then return end
    frames = frames + 1
    if phase == "open" then
        if frames < 60 then return end
        local m = manager()
        if not m or m:get_field("_ActiveMenuType") ~= 0 or m:get_field("_MenuState") ~= 4 then
            return fail("menu not ready: " .. (m and status(m) or "nil"))
        end
        phase = "committing"
        tmp_fns[key] = function()
            tmp_fns[key] = nil
            local current = manager()
            if not current then return fail("manager disappeared") end
            emit("BEFORE CLOSE " .. status(current))
            player(current):set_field("FighterID", target)
            emit("SET TARGET " .. status(current))
            local ok, err = pcall(function() current:call("CloseMenu(app.training.TrainingManager.MenuType)", 0) end)
            if not ok then return fail("close: " .. tostring(err)) end
            emit("AFTER CLOSE " .. status(current))
            player(current):set_field("FighterID", target)
            emit("AFTER PATCH " .. status(current))
            phase, frames = "waiting", 0
        end
    elseif phase == "waiting" then
        if live() == target then
            phase = "done"
            emit("SUCCESS P2=" .. tostring(live()))
        elseif frames > 600 then
            local m = manager()
            fail("timeout " .. (m and status(m) or "no manager"))
        end
    end
end)
