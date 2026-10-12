-- Temporary read-only trace of the game's own training menu opening.
local t = sdk.find_type_definition("app.training.TrainingManager")
local m = t and t:get_method("OpenMenu")
local function emit(s) log.info("[BatchOpenMenu] " .. s) end
if not m then
    emit("OpenMenu method unavailable")
else
    sdk.hook(m, function(args)
        local ok, err = pcall(function()
            local param = sdk.to_managed_object(args[4])
            emit("type=" .. tostring(sdk.to_int64(args[3])) .. " param=" .. tostring(param))
            if param then
                local ty = param:get_type_definition()
                emit("param type=" .. tostring(ty:get_full_name()))
                for _, f in ipairs(ty:get_fields() or {}) do
                    local name = f:get_name()
                    local field_ok, value = pcall(function() return param:get_field(name) end)
                    emit("param." .. name .. "=" .. (field_ok and tostring(value) or ("ERROR " .. tostring(value))))
                end
            end
        end)
        if not ok then emit("trace error " .. tostring(err)) end
    end, function(retval) return retval end)
    emit("ready")
end
