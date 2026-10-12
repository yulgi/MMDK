-- Read-only trace: Reset Scripts, then manually change P2 once. Do not start a batch.
-- No game methods are invoked and no arguments, return values or game fields are changed.
local prefix = 'MMDK FlowProbe: '
local count, initialized = 0, false
local function emit(s)
    if count >= 1500 then return end
    count = count + 1
    log.info(prefix .. s)
end
local function inspect_fields(obj, label)
    if not obj then emit(label .. '=nil'); return end
    local td = obj:get_type_definition()
    emit(label .. ' TYPE ' .. td:get_full_name())
    local n = 0
    while td and td:get_full_name() ~= 'System.Object' do
        for _, f in ipairs(td:get_fields()) do
            if not f:is_static() then
                n = n + 1
                if n > 60 then return end
                local ok, value = pcall(f.get_data, f, obj)
                emit(label .. '.' .. f:get_name() .. ' [' .. f:get_type():get_full_name() .. ']=' .. (ok and tostring(value) or '?'))
            end
        end
        td = td:get_parent_type()
    end
end
local function snapshot(label)
    local m = sdk.get_managed_singleton('app.training.TrainingManager')
    if not m then return end
    local data = m:get_field('_tData')
    local selection = data and data:get_field('SelectMenu')
    local players = selection and selection:get_field('PlayerDatas')
    local p2 = players and players[1]
    local live = '?'
    pcall(function() live = sdk.find_type_definition('gBattle'):get_field('Player'):get_data().mPlayerType[1].mValue end)
    emit(label .. ' state=' .. tostring(m:get_field('_MenuState')) .. '/' .. tostring(m:get_field('_ActiveMenuType'))
        .. ' selected=' .. tostring(p2 and p2:get_field('FighterID')) .. ' live=' .. tostring(live))
end
local targets = {
    ['app.training.TrainingManager'] = {OpenMenu=true,RequestCloseMenu=true,CloseMenu=true,SetMenuData=true,ChangeState=true,RequestTrainingFlow=true,SetFighter=true},
    ['app.training.UITrainingMenu'] = {OnDecideStart=true,MainMenuCancel=true,StopMenu=true,EndMenu=true},
    ['app.training.TrainingMenuFunc'] = {OptionSelectFunction=true},
}
local function install()
    for name, wanted in pairs(targets) do
        local td = sdk.find_type_definition(name)
        if td then
            for _, method in ipairs(td:get_methods()) do
                local method_name = method:get_name()
                local types, names = method:get_param_types(), method:get_param_names()
                local parts = {}
                for i, ty in ipairs(types) do parts[i] = ty:get_full_name() .. ' ' .. tostring(names[i]) end
                local label = name .. '.' .. method_name .. '(' .. table.concat(parts, ', ') .. ')'
                emit('METHOD ' .. label)
                if wanted[method_name] then
                    local ok, err = pcall(sdk.hook, method, function(args)
                        local trace_ok, trace_err = pcall(function()
                            snapshot('ENTER ' .. label)
                            for i, ty in ipairs(types) do
                                local raw = args[i + 2]
                                local type_name = ty:get_full_name()
                                if type_name == 'System.Boolean' then
                                    emit('ARG ' .. tostring(names[i]) .. '=' .. tostring(sdk.to_int64(raw) % 256 ~= 0))
                                elseif type_name == 'System.Int32' or type_name == 'System.UInt32' or type_name:find('TrainingManager%.') then
                                    emit('ARG ' .. tostring(names[i]) .. '=' .. tostring(sdk.to_int64(raw) % 4294967296))
                                elseif not ty:is_value_type() then
                                    inspect_fields(sdk.to_managed_object(raw), 'ARG ' .. tostring(names[i]))
                                else
                                    emit('ARG ' .. tostring(names[i]) .. ' raw=' .. tostring(raw))
                                end
                            end
                        end)
                        if not trace_ok then emit('TRACE ERROR ' .. tostring(trace_err)) end
                    end, function(retval)
                        local ok_post, err_post = pcall(snapshot, 'EXIT ' .. label)
                        if not ok_post then emit('TRACE ERROR ' .. tostring(err_post)) end
                        return retval
                    end)
                    emit(ok and ('HOOKED ' .. label) or ('HOOK ERROR ' .. tostring(err)))
                end
            end
        else emit('MISSING TYPE ' .. name) end
    end
    emit('READY; manually select P2 once; do not start batch')
end
re.on_application_entry('UpdateBehavior', function()
    if initialized then return end
    local m = sdk.get_managed_singleton('app.training.TrainingManager')
    if not m then return end
    initialized = true
    local ok, err = pcall(function()
        snapshot('INITIAL')
        install()
    end)
    if not ok then emit('INIT ERROR ' .. tostring(err)) end
end)
