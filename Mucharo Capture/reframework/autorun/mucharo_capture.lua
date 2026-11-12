-- ============================================================
--  Mucharo Analyzer Capture v3.8.3
--  for REFramework / Street Fighter 6
--
--  Character-info patch:
--   - Read pl_type first (same field as PsychoDrive), with legacy fallbacks.
--   - Save per-frame character ID/name/source and summarize recorded identities.
--   - Display character read failures instead of silently caching a missing ID.
--  Replay-metadata patch:
--   - Keep the installed game version separate from ReplayInfo.Version.
--   - Snapshot loaded replay metadata and link observations to buffer-local contexts.
--   - Report unavailable hooks/fields and never use Label as an automatic replay ID.
--
--  v3.5.1 changes:
--   - Round is the game round (1-based); retain raw RoundNo as round_index.
--   - Segmentation and inferred segment winners are disabled pending design.
--  v3.5.2: save capture files under reframework/data/replay/.
--  v3.6.1: optional Stage0 companion status; no unverified gameplay labels.
--  v3.7.0: passive runtime facts (game notices/frame meter) in normal Save;
--  v3.7.1: contact processing windows via MCA/runtime (guard/parry/tech/context).
--          local MMDK properties are resolved offline, not embedded every frame.
--  v3.8.0: lossless compact Save via MCA/storage; native minified fallback.
--  v3.8.1: save the healing target for gray-health analysis; recognize Arjun.
--  v3.8.2: save a snapshot across frames and clear the buffer when recording starts.
--  v3.8.3: full-speed and background saves; save unsaved captures on replay changes.
--  v3.5 changes:
--   - Capture both players' logical input and transitions at simulation frame end.
--   - Preserve raw input/command state and invalidate edges across discontinuities.
--   - Physical device keys and command consumption are not inferred from actions.
--  v3.4 changes:
--   - Read scalar sfix action frames with ToFloat(), matching MMDK.
--     ToString() is not a reliable numeric conversion for these value types.
--   - Export action_read_ok and show action frame values for runtime verification.
--  v3.3 changes:
--   - Fixed the window close button by passing window_open to begin_window
--     and storing its return value. Closing sets window_open=false and stops drawing.
--   - Closing also disables Auto-Record, treating it as turning the tool off.
--     Minimize the window to hide the UI while continuing to record.
--     Use REFramework's "Reset scripts" or restart SF6 to reopen the window.
--  v3.2 changes:
--   - Changed the capture gate from both HP values > 0 to both cap values > 0.
--     This allows zero-HP samples to be recorded while both cap values remain positive.
--   - Historical inferred segment winners were removed in v3.5.1.
--  v3.1 changes:
--   - Replaced the side-selection combo box with explicit buttons to avoid reversed sides.
--   - Standardized the UI and messages in English to avoid garbled text.
--  v2-v3 features:
--   - Automatic combat recording / My Side / editable save labels
--
--  Usage:
--   1) Place this script in <SF6>/reframework/autorun/, replacing the previous copy.
--   2) Play a replay in SF6.
--   3) Select 1P or 2P under "My Side" and verify the displayed player HP.
--   4) Enable "Auto-Record" to record whenever the capture gate is active.
--   5) Enter a Label if desired, then press "Save".
--
--  Output: <SF6>/reframework/data/replay/mca_<label>.json
--
--  If an SF6 update breaks capture, check these game-dependent reads first:
--   (1) Fields in read_player()/read_character(): vital_new, focus_new, pl_type,
--       pos, speed, alpha, etc.
--   (2) The Rollback...ActEngines[0]._Parent._Engine chain used by read_action().
--   Saving and UI logic do not directly read these internal game fields.
--   Protected reads return nil on failure; displayed missing values appear as FAIL.
-- ============================================================

local runtime_facts
do
    local ok,value=pcall(require,'MCA/runtime')
    if ok and type(value)=='table' then runtime_facts=value end
end
local capture_storage
do
    local ok,value=pcall(require,'MCA/storage')
    if ok and type(value)=='table' and type(value.pack)=='function' then capture_storage=value end
end
local FIX = 6553600.0   -- Convert fixed-point position/motion values to capture units.
local SAVE_DIRECTORY = "replay/" -- Relative to REFramework's data directory.
local SAVE_SLICE_SECONDS = 0.004

-- ---- Internal state ----
local auto_record   = false      -- Master recording switch.
local window_open   = true       -- Window visibility, including the close button state.
local in_combat     = false      -- Whether the capture gate is active (both cap values > 0).
local frames        = {}
local frame_count   = 0
local replay_label  = ""
local cur_round     = nil
local cur_round_index = nil
local round_read_ok = false
local cur_timer     = nil
local last_p1       = {}
local last_p2       = {}
local last_status   = "Initializing..."
local my_side       = "p1"       -- Selected player side, stored explicitly as "p1" or "p2".
local game_version  = nil        -- Game version; automatic detection is attempted.
local game_version_source = "unavailable"
local version_checked_at = 0
local manual_game_version = ""
local manual_replay_id = ""
local replay_hook_status = {installed = false, error = "not attempted"}
local active_replay = nil
local replay_contexts = {}
local replay_context_index = nil
local capture_started_epoch = nil
local capture_ended_epoch = nil
local input_hook_status = {installed=false, error="not attempted", calls=0}
local simulation_seq = 0
local input_previous = {}
local previous_sample_time = nil
local capture_timer_epoch = 0
local capture_error = nil
local save_job = nil
local save_status = nil
local pending_saves = {}
local save_coverage = nil
local capture_replay_id = nil
local left_replay_flow = false
local rotate_recording

-- ---- Helpers ----
local function try(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function read_field(object, name)
    if object == nil then return nil end
    return try(function() return object:get_field(name) end)
end

-- Convert metadata to detached JSON-safe values. Never traverse InputData or
-- retain managed objects: hooks may release/reuse them before Save is pressed.
local function metadata_value(value, depth)
    depth = depth or 0
    if value == nil or depth > 6 then return nil end
    local kind = type(value)
    if kind == "boolean" or kind == "string" then return value end
    if kind == "number" then
        if value == value and math.abs(value) < math.huge then return value end
        return nil
    end
    local string_value = try(function()
        if value:get_type_definition():get_full_name() == "System.String" then
            return value:ToString()
        end
    end)
    if type(string_value) == "string" then return string_value end
    local elements = try(function() return value:get_elements() end)
    if elements ~= nil then
        local out = {}
        for _, item in ipairs(elements) do
            if #out >= 32 then break end
            local converted = metadata_value(item, depth + 1)
            if converted == nil then return nil end -- Do not shift array slots.
            out[#out + 1] = converted
        end
        return out
    end
    local fields = try(function() return value:get_type_definition():get_fields() end)
    if fields == nil then return nil end
    local out, count = {}, 0
    for _, field in ipairs(fields) do
        local name = try(function() return field:get_name() end)
        local is_static = try(function() return field:is_static() end)
        if name and is_static == false and name ~= "InputData" then
            count = count + 1
            if count > 64 then break end
            local converted = metadata_value(read_field(value, name), depth + 1)
            if converted ~= nil then out[name] = converted end
        end
    end
    return out
end

local function integer_value(value)
    if type(value)=="number" and value==math.floor(value) and math.abs(value)<math.huge then return value end
    local v=read_field(value,"mValue")
    if type(v)=="number" and v==math.floor(v) then return v end
end

-- CFN short_id is UInt32; platform IDs are supplied as strings. Keep IDs textual.
local function identifier(value)
    if type(value)=="string" and value~="" then return value end
    local n=integer_value(value)
    if n and n>0 then
        if math.type and math.type(n)=="integer" then return tostring(n) end
        if n<=9007199254740991 then return string.format("%.0f",n) end
    end
end

local function uint_list(value)
    if not value then return nil end
    return try(function()
        local count=value:call("get_Count()")
        if type(count)~="number" or count<0 or count>32 then return nil end
        local out={}
        for i=0,count-1 do
            local v=integer_value(value:call("get_Item(System.Int32)",i))
            if v==nil or v<0 then return nil end
            out[#out+1]=v
        end
        return out
    end)
end

local function replay_players(common)
    local out={}
    for i,side in ipairs({"p1","p2"}) do
        local info=read_field(common,"player"..i.."_info")
        local person=read_field(info,"player")
        local id=identifier(read_field(person,"short_id"))
        out[side]={side=side,cfn_account_id=id,account_id_read_ok=id~=nil,
            account_id_source="CommonReplayInfo.player"..i.."_info.player.short_id",
            display_name=metadata_value(read_field(person,"fighter_id")),
            platform_id=integer_value(read_field(person,"platform_id")),
            platform_online_id=identifier(read_field(person,"platform_online_id")),
            rebe_subject=identifier(read_field(person,"rebe_subject")),
            character_id=integer_value(read_field(info,"playing_character_id")),
            battle_input_type=integer_value(read_field(info,"battle_input_type")),
            raw_round_results=uint_list(read_field(info,"round_results"))}
    end
    return out
end

local function replay_results(info, players, network_id_ok, network_version)
    local rows=info and info.RoundInfo
    local a,b=players.p1.raw_round_results,players.p2.raw_round_results
    local out={source="ReplayInfo.RoundInfo cross-checked with CommonReplayInfo.player*_info.round_results",
        scope="entire_replay_metadata",verified=false,rounds={},wins={p1=0,p2=0},draws=0}
    if type(rows)~="table" or type(a)~="table" or type(b)~="table" then
        out.error="round_result_source_unavailable";return out
    end
    if not network_id_ok or not network_version or network_version~=info.Version then
        out.error="replay_id_or_version_disagreement";return out
    end
    local active=0
    for _,r in ipairs(rows) do if type(r.FinishType)=="number" and r.FinishType>0 then active=active+1 end end
    if active==0 or active~=#a or active~=#b then
        out.error="completed_round_count_disagreement";return out
    end
    local all_ok=true
    for index,r in ipairs(rows) do
        local finish=r.FinishType
        if type(finish)=="number" and finish>0 then
            local x={round=index,round_index=index-1,raw_win_player_type=r.WinPlayerType,
                raw_finish_type=finish,raw_network_result={p1=a[index],p2=b[index]},verified=false}
            -- Network per-round codes are FINISH codes for the winner and 0 for
            -- the loser, not the unrelated api.Enum.BattleResult Win/Lose enum.
            local winner
            if a[index]==finish and b[index]==0 and r.WinPlayerType==0 then winner="p1"
            elseif b[index]==finish and a[index]==0 and r.WinPlayerType==1 then winner="p2" end
            if winner then
                x.winner=winner;x.loser=winner=="p1" and "p2" or "p1"
                x.winner_cfn_account_id=players[winner].cfn_account_id
                x.loser_cfn_account_id=players[x.loser].cfn_account_id
                x.verified=true;out.wins[winner]=out.wins[winner]+1
            else
                x.error="winner_disagreement_or_unsupported_draw_encoding";all_ok=false
            end
            out.rounds[#out.rounds+1]=x
        end
    end
    out.verified=all_ok
    out.winner_mapping_verified=all_ok
    if not all_ok then out.error="one_or_more_rounds_unverified" end
    return out
end

local function make_replay_context(data, id, common, selected)
    local info = read_field(data, "ReplayInfo")
    local result = {
        source = selected and "app.BattleReplayDataManager.GetReplayData()" or "app.BattleReplayDataManager.AddReplayData",
        loaded_at_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        replay_id = id,
        replay_id_read_ok = id ~= nil,
        replay_info = metadata_value(info),
        replay_game_version = metadata_value(read_field(info, "Version")),
        round_count = metadata_value(read_field(info, "RoundNum")),
        -- Availability depends on which replay object this game version exposes.
        replay_result_info = metadata_value(read_field(data, "ReplayResultInfo")),
        association = selected and "current_selection_in_replay_flow" or "latest_loaded_replay_not_verified_playback",
        association_verified = selected==true,
        serialization_limits = {max_depth = 6, max_array_items = 32, max_fields = 64},
    }
    result.replay_info_read_ok = type(result.replay_info) == "table" and next(result.replay_info) ~= nil
    result.replay_game_version_read_ok = result.replay_game_version ~= nil
    result.players=replay_players(common)
    result.account_player_ids_available=result.players.p1.account_id_read_ok and result.players.p2.account_id_read_ok
    result.network_replay_id=metadata_value(read_field(common,"replay_id"))
    result.network_battle_version=integer_value(read_field(common,"battle_version"))
    result.network_uploaded_at=identifier(read_field(common,"uploaded_at"))
    result.network_replay_id_matches=id~=nil and id==result.network_replay_id
    result.official_results=replay_results(result.replay_info,result.players,result.network_replay_id_matches,result.network_battle_version)
    result.metadata_complete=result.account_player_ids_available and result.official_results.verified
    if result.network_replay_id and not result.network_replay_id_matches then result.association_verified=false end
    return result
end

local function remember_replay(data,id,common)
    active_replay=make_replay_context(data,id,common,false)
    replay_context_index = nil -- Existing observations keep their old context.
end

local selection_status={available=false}
local current_key=nil
local metadata_retry_epoch=0
local function refresh_current_replay()
    local ok,err=pcall(function()
        local m=sdk.get_managed_singleton("app.BattleReplayDataManager")
        if not m then selection_status.available=false;return end
        selection_status.available=true
        local in_replay_flow = m:call("get_IsReplayFlow()")
        if in_replay_flow~=true then
            if in_replay_flow==false and auto_record and capture_replay_id and not left_replay_flow then
                left_replay_flow=true
                if runtime_facts then runtime_facts.set_recording(false) end
            end
            if active_replay then active_replay=nil;replay_context_index=nil;current_key=nil end
            selection_status.in_replay_flow=false;return
        end
        selection_status.in_replay_flow=true
        local selected=m:call("GetReplayData()")
        if not selected then active_replay=nil;replay_context_index=nil;current_key=nil;return end
        local id=metadata_value(read_field(selected,"ReplayID"))
        local data=read_field(selected,"ReplayData")
        local common=read_field(selected,"ReplayInfo")
        local info=read_field(data,"ReplayInfo")
        local key=tostring(id)..":"..tostring(metadata_value(read_field(info,"RandomSeed")))
            ..":"..tostring(metadata_value(read_field(info,"Version")))
        if current_key==key and active_replay and active_replay.association_verified then
            if active_replay.metadata_complete or os.time()-metadata_retry_epoch<1 then return end
        end
        local ctx=make_replay_context(data,id,common,true)
        ctx.manager_selection_index=integer_value(m:call("get_CurrentReplayID()"))
        local signature=key..":"..tostring(ctx.network_replay_id)..":"..tostring(ctx.network_battle_version)
        for _,s in ipairs({"p1","p2"}) do
            local p=ctx.players[s]
            signature=signature..":"..tostring(p.cfn_account_id)..":"..tostring(p.platform_online_id)
                ..":"..tostring(p.character_id)..":"..table.concat(p.raw_round_results or {},"/")
        end
        for _,r in ipairs(ctx.replay_info and ctx.replay_info.RoundInfo or {}) do
            signature=signature..":"..tostring(r.WinPlayerType).."/"..tostring(r.FinishType)
        end
        metadata_retry_epoch=os.time()
        if auto_record and capture_replay_id and id and id~=""
            and (left_replay_flow or capture_replay_id~=id) then
            rotate_recording()
            if runtime_facts then runtime_facts.set_recording(true) end
        end
        if active_replay and active_replay.selection_signature==signature and active_replay.association_verified then return end
        ctx.selection_signature=signature
        active_replay=ctx;current_key=key;metadata_retry_epoch=os.time();replay_context_index=nil
    end)
    selection_status.last_read_ok=ok;selection_status.error=not ok and tostring(err) or nil
    if not ok then
        if current_key then active_replay=nil;replay_context_index=nil;current_key=nil end
    end
end

local function install_replay_hook()
    if replay_hook_status.installed then return end
    local ok, err = pcall(function()
        local definition = sdk.find_type_definition("app.BattleReplayDataManager")
        assert(definition, "BattleReplayDataManager unavailable")
        local method = definition:get_method("AddReplayData")
        assert(method, "AddReplayData unavailable")
        sdk.hook(method, function(args)
            local read_ok, read_error = pcall(function()
                -- This argument layout is also used by PsychoDrive's exporter.
                local data = sdk.to_managed_object(args[3])
                local id = try(function()
                    local object = sdk.to_managed_object(args[4])
                    if object then return object:ToString() end
                end)
                if type(id) ~= "string" or id == "" then id = nil end
                local common=try(function() return sdk.to_managed_object(args[5]) end)
                remember_replay(data, id, common)
            end)
            replay_hook_status.last_read_ok = read_ok
            replay_hook_status.last_read_error = nil
            if not read_ok then replay_hook_status.last_read_error = tostring(read_error) end
        end, function(retval) return retval end)
    end)
    replay_hook_status.installed = ok
    replay_hook_status.error = nil
    if not ok then replay_hook_status.error = tostring(err) end
end

local function recording_context()
    if replay_context_index == nil then
        replay_contexts[#replay_contexts + 1] = active_replay or {
            source = "unavailable",
            replay_id_read_ok = false,
            replay_info_read_ok = false,
            association = "no_replay_load_observed",
        }
        replay_context_index = #replay_contexts
    end
    return replay_context_index
end

install_replay_hook()

-- IDs and data-directory names from PsychoDrive/main.cpp: makeCharEntries().
-- Unknown IDs are kept as numbers; do not guess a character from action_id/HP.
local CHARACTER_NAMES = {
    [1] = "ryu", [2] = "luke", [3] = "kimberly", [4] = "chunli",
    [5] = "manon", [6] = "zangief", [7] = "jp", [8] = "dhalsim",
    [9] = "cammy", [10] = "ken", [11] = "deejay", [12] = "lily",
    [13] = "aki", [14] = "rashid", [15] = "blanka", [16] = "juri",
    [17] = "marisa", [18] = "guile", [19] = "ed", [20] = "honda",
    [21] = "jamie", [22] = "akuma", [25] = "sagat", [26] = "dictator",
    [27] = "terry", [28] = "mai", [29] = "elena", [30] = "viper",
    [31] = "alex", [32] = "ingrid", [33] = "yasmine", [34] = "arjun",
}

local function character_name(id)
    if id == nil then return "unknown" end
    return CHARACTER_NAMES[id] or ("unknown_" .. tostring(id))
end

local function read_character(player, d)
    for _, field in ipairs({"pl_type", "CharaID", "chara_id"}) do
        local id = try(function() return tonumber(player[field]) end)
        if id ~= nil and id > 0 and id < math.huge and id == math.floor(id) then
            d.char_id = id
            d.char_name = character_name(id)
            d.char_id_source = field
            d.char_read_ok = true
            return
        end
    end
    d.char_name = "unknown"
    d.char_id_source = "unavailable"
    d.char_read_ok = false
end

-- Describe the buffer, not the live players at Save time (which may be a new match).
local function recorded_character(side)
    local ids, seen, missing = {}, {}, 0
    for _, frame in ipairs(frames) do
        local id = frame[side].char_id
        if id == nil then
            missing = missing + 1
        elseif not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    local id = nil
    if #ids == 1 then id = ids[1] end
    return {
        char_id = id,
        char_name = (#ids > 1) and "mixed" or character_name(id),
        observed_ids = ids,
        mixed_characters = #ids > 1,
        missing_frames = missing,
        read_ok = #frames > 0 and missing == 0 and #ids == 1,
    }
end

local function bitand(a, b)
    local result, bitval = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then result = result + bitval end
        bitval = bitval * 2
        a = math.floor(a / 2)
        b = math.floor(b / 2)
    end
    return result
end

-- Live replay verification: player input and command direct-input low bits agree.
-- Left/right are stage directions; convert to owner space using the observed facing.
local INPUT_BITS = {UP=1, DOWN=2, LEFT=4, RIGHT=8,
    LP=16, MP=32, HP=64, LK=128, MK=256, HK=512}
local INPUT_ORDER = {"UP","DOWN","LEFT","RIGHT","LP","MP","HP","LK","MK","HK"}
local function input_names(mask)
    local names={}
    for _,n in ipairs(INPUT_ORDER) do
        if bitand(mask,INPUT_BITS[n])~=0 then names[#names+1]=n end
    end
    return names
end
local function read_mask(value)
    if type(value)=="number" and value==value and value>=0 and value<=4294967295
        and value==math.floor(value) then return value end
end
local function raw_player_input(player)
    local d={}
    for _,n in ipairs({"pl_input_new","pl_input_old","pl_input_old1","pl_input_now","input_mask_timer"}) do
        d[n]=try(function() return read_mask(player[n]) end)
    end
    return d
end
local function direction(mask, facing)
    local u,d,l,r=bitand(mask,1)~=0,bitand(mask,2)~=0,bitand(mask,4)~=0,bitand(mask,8)~=0
    if (u and d) or (l and r) then return nil,nil end
    local x=(r and 1 or 0)-(l and 1 or 0)
    local y=(u and 1 or 0)-(d and 1 or 0)
    local world=5+x+3*y
    if facing==0 then x=-x elseif facing~=1 then return world,nil end
    return world,5+x+3*y
end
local function read_command_input(engine)
    local out={source="Command.UserEngine",read_ok=false,consumption_verified=false}
    if not engine then return out end
    for key,method in pairs({direct="GetDirectInput()",press="GetPressInput()",release="GetReleaseInput()"}) do
        out[key]=try(function() return read_mask(engine:call(method)) end)
    end
    for _,key in ipairs({"m_key_inputs_wp","m_key_inputs_rp","m_saved_key_p","m_saved_key_r"}) do
        out[key]=try(function() return read_mask(engine[key]) end)
    end
    local wp=out.m_key_inputs_wp
    if wp and wp<64 then
        out.current_slot=try(function()
            local v=engine.m_key_inputs[wp]
            local slot={}
            for _,k in ipairs({"d","p","r","pp","rp","s"}) do slot[k]=read_mask(v[k]) end
            return slot
        end)
    end
    out.read_ok=out.direct~=nil and out.press~=nil and out.release~=nil
    return out
end
local function read_input(player, side, continuous, continuity_reason, pre, facing, command)
    local raw=raw_player_input(player)
    local mask=raw.pl_input_new
    local d={source="nBattle.cPlayer.pl_input_new", kind="game_logical_input",
        read_ok=mask~=nil, raw=raw, pre_frame_end_raw=pre,
        direction_space="stage_absolute", physical_device_input_available=false,
        command_consumption_verified=false, edge_valid=false}
    if mask==nil then
        d.edge_reason="input_unreadable"
        input_previous[side]=nil
        return d
    end
    d.held_mask=bitand(mask,1023)
    d.held=input_names(d.held_mask)
    d.direction_numpad_world,d.direction_numpad_relative=direction(d.held_mask,facing)
    d.buttons_held_mask=bitand(d.held_mask,1008)
    d.buttons_held=input_names(d.buttons_held_mask)
    d.command=read_command_input(command)
    d.unmapped_bits=mask-d.held_mask
    local previous=input_previous[side]
    if continuous and previous~=nil then
        d.edge_valid=true
        d.edge_reason="adjacent_simulation_timer"
        d.pressed_mask=d.held_mask-bitand(d.held_mask,previous)
        d.released_mask=previous-bitand(d.held_mask,previous)
        d.pressed=input_names(d.pressed_mask)
        d.released=input_names(d.released_mask)
    else
        d.edge_reason=continuous and "previous_input_unreadable" or continuity_reason
    end
    input_previous[side]=d.held_mask
    return d
end

local function input_stats()
    local out={}
    for _,s in ipairs({"p1","p2"}) do
        local d={samples=0,read_ok=0,edge_valid=0,nonzero_held=0,pressed_observations=0,released_observations=0}
        for _,f in ipairs(frames) do
            local v=f[s].input or {}
            d.samples=d.samples+1
            if v.read_ok then d.read_ok=d.read_ok+1 end
            if v.edge_valid then d.edge_valid=d.edge_valid+1 end
            if v.held_mask and v.held_mask~=0 then d.nonzero_held=d.nonzero_held+1 end
            if v.pressed_mask and v.pressed_mask~=0 then d.pressed_observations=d.pressed_observations+1 end
            if v.released_mask and v.released_mask~=0 then d.released_observations=d.released_observations+1 end
        end
        out[s]=d
    end
    return out
end

local function observed_rounds()
    local seen, out = {}, {}
    for _,f in ipairs(frames) do
        if f.round_read_ok then
            local key=tostring(f.replay_context)..":"..tostring(f.round_index)
            if not seen[key] then
                seen[key]={replay_context=f.replay_context,round=f.round,round_index=f.round_index,samples=0,
                    recording_association_verified=true}
                out[#out+1]=seen[key]
            end
            seen[key].samples=seen[key].samples+1
            if not f.replay_association_verified then seen[key].recording_association_verified=false end
        end
    end
    for _,r in ipairs(out) do
        local ctx=replay_contexts[r.replay_context]
        local results=ctx and ctx.official_results
        if results and results.verified and r.recording_association_verified then
            for _,x in ipairs(results.rounds) do
                if x.round_index==r.round_index then
                    r.official_result={verified=x.verified,winner=x.winner,loser=x.loser,
                        winner_cfn_account_id=x.winner_cfn_account_id,loser_cfn_account_id=x.loser_cfn_account_id}
                    break
                end
            end
        end
    end
    return out
end

local function read_sfix(o)
    local value = o:ToFloat()
    if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
        error("Invalid scalar sfix value")
    end
    return value
end

-- ---- Raw values for one player ----
local function read_player(cPlayer, cTeam, idx)
    local P = cPlayer[idx]
    local T = cTeam[idx]
    local d = {}
    read_character(P, d)
    d.style_id = try(function() return P.mStyleNo end)
    -- Health.
    d.hp        = try(function() return P.vital_new end)
    d.hp_cap    = try(function() return P.vital_old end)
    d.hp_cool   = try(function() return P.healing_wait end)
    d.heal_new  = try(function() return P.heal_new end)
    -- Drive Gauge.
    d.drive     = try(function() return P.focus_new end)
    d.drive_cool= try(function() return P.focus_wait end)
    -- Super Art Gauge (captured, but not used by the original resource-management theory).
    d.super     = try(function() return T.mSuperGauge end)
    -- Position and motion.
    d.pos_x     = try(function() return P.pos.x.v / FIX end)
    d.pos_y     = try(function() return P.pos.y.v / FIX end)
    d.vel_x     = try(function() return P.speed.x.v / FIX end)
    d.vel_y     = try(function() return P.speed.y.v / FIX end)
    d.acc_x     = try(function() return P.alpha.x.v / FIX end)
    d.acc_y     = try(function() return P.alpha.y.v / FIX end)
    d.pushback  = try(function() return P.vector_zuri.speed.v / FIX end)
    -- Facing direction.
    d.facing    = try(function() return (bitand(P.BitValue, 128) == 128) and 1 or 0 end)
    -- Contact and state values.
    d.hitstun   = try(function() return P.damage_time end)
    d.blockstun = try(function() return P.guard_time end)
    d.hitstop   = try(function() return P.hit_stop end)
    d.throw_inv = try(function() return P.catch_muteki end)
    d.full_inv  = try(function() return P.muteki_time end)
    d.juggle    = try(function() return P.combo_dm_air end)
    d.stance    = try(function() return P.pose_st end)
    d.act_st    = try(function() return P.act_st end)
    d.is_air    = try(function() return P:call('get_IsAir()') end)
    d.is_down   = try(function() return P:call('get_IsDown()') end)
    d.buff      = try(function() return P.style_timer end)
    return d
end

local function read_action(engine, d)
    d.action_id     = try(function() return engine:get_ActionID() end)
    d.action_frame  = try(function() return math.floor(read_sfix(engine:get_ActionFrame())) end)
    d.action_end    = try(function() return math.floor(read_sfix(engine:get_ActionFrameNum())) end)
    d.action_margin = try(function() return math.floor(read_sfix(engine:get_MarginFrame())) end)
    d.action_read_ok = d.action_id ~= nil and d.action_frame ~= nil
        and d.action_end ~= nil and d.action_margin ~= nil
end

-- ---- Save JSON ----
local function copy_fields(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

local function snapshot_runtime()
    if not runtime_facts then return {available=false,reason='MCA/runtime module unavailable'} end
    local snapshot = runtime_facts.export()
    -- Emitted rows are immutable. Only their lists and the counters keep changing.
    if snapshot.events then snapshot.events = table.move(snapshot.events, 1, #snapshot.events, 1, {}) end
    if snapshot.errors then snapshot.errors = table.move(snapshot.errors, 1, #snapshot.errors, 1, {}) end
    if snapshot.stats then snapshot.stats = copy_fields(snapshot.stats) end
    return snapshot
end

local function prepare_save()
    local save_started = os.clock()
    local stage0_status=try(function()
        local probe=rawget(_G,"MCA_STAGE0_PROBE")
        if type(probe)=="table" and type(probe.status)=="function" then return probe.status() end
    end)
    local character_p1 = recorded_character("p1")
    local character_p2 = recorded_character("p2")
    local my_character = (my_side == "p1") and character_p1 or character_p2
    local saved_epoch = os.time()
    local single_replay = (#replay_contexts == 1) and replay_contexts[1] or nil
    local replay_id = single_replay and single_replay.replay_id or nil
    local replay_id_source = replay_id and "latest_loaded_replay_unverified" or "unavailable"
    if manual_replay_id ~= "" then
        replay_id = manual_replay_id
        replay_id_source = "user_entered"
    end
    local installed_version = game_version
    local installed_version_source = game_version_source
    if manual_game_version ~= "" then
        installed_version = manual_game_version
        installed_version_source = "user_entered"
    end
    local recorded_rounds=observed_rounds()
    local all_assigned=#frames>0
    for _,f in ipairs(frames) do if not f.replay_association_verified then all_assigned=false;break end end
    local top_results=single_replay and single_replay.official_results
    local result_verified=all_assigned and top_results and top_results.verified or false
    if manual_replay_id~="" and single_replay and manual_replay_id~=single_replay.replay_id then result_verified=false end
    if single_replay and single_replay.association_verified and replay_id_source~="user_entered" then
        replay_id_source="current_replay_manager_selection"
    end

    -- If Label is empty, use the recorded/annotated replay ID and export time.
    local label = replay_label
    if label == nil or label == "" then
        label = (replay_id or "unknown") .. "_" .. os.date("%Y%m%d_%H%M%S", saved_epoch)
    end
    -- Replace characters that are not allowed by this filename convention.
    label = label:gsub("[^%w%-_]", "_")

    local out = {
        meta = {
            schema_version = "capture-0.6.0",
            capture_script_version = "3.8.3-compact-1",
            runtime_facts_available=runtime_facts~=nil,
            diagnostics = {stage0=stage0_status},
            captured_at    = os.date("%Y-%m-%d %H:%M:%S"),
            saved_at_utc   = os.date("!%Y-%m-%dT%H:%M:%SZ", saved_epoch),
            saved_at_epoch = saved_epoch,
            fps            = 60,
            fps_source     = "assumed_simulation_rate_not_measured_sampling_rate",
            replay_label   = label,
            game_version   = installed_version or "(unknown)", -- Legacy alias: installed game only.
            installed_game_version = {
                value = installed_version,
                source = installed_version_source,
                read_ok = game_version ~= nil,
                automatic_value = game_version,
                automatic_source = game_version_source,
                user_override = manual_game_version ~= "" and manual_game_version or nil,
            },
            replay_id = replay_id,
            replay_id_source = replay_id_source,
            replay_game_version = single_replay and single_replay.replay_game_version or nil,
            replay_metadata = {
                contexts = table.move(replay_contexts, 1, #replay_contexts, 1, {}),
                context_count = #replay_contexts,
                multiple_contexts = #replay_contexts > 1,
                hook_status = copy_fields(replay_hook_status),
                selection_status=copy_fields(selection_status),
                association_verified = all_assigned,
                note = "Current manager selection in replay flow is matched to live character slots; loaded-only metadata remains unverified. Results belong to each replay context.",
            },
            capture = {
                started_at_epoch = capture_started_epoch,
                ended_at_epoch = capture_ended_epoch,
                started_at_utc = capture_started_epoch and os.date("!%Y-%m-%dT%H:%M:%SZ", capture_started_epoch) or nil,
                ended_at_utc = capture_ended_epoch and os.date("!%Y-%m-%dT%H:%M:%SZ", capture_ended_epoch) or nil,
                wall_duration_seconds = capture_started_epoch and (capture_ended_epoch - capture_started_epoch) or nil,
                sampling_callback = input_hook_status.installed and "app.BattleFlow.UpdateFrameEnd.post" or "re.on_frame.fallback",
                sample_index_field = "f",
                simulation_timer_field = "timer",
                capture_gate = "both vital_old > 0 and vital_new readable",
                position_fixed_point_divisor = FIX,
                round_results_source = result_verified and "official_replay_and_network_metadata_crosscheck" or "unavailable_or_unverified",
                save_directory = "reframework/data/replay/",
            },
            input_capture = {
                schema="sf6-logical-input-0.1", source="nBattle.cPlayer.pl_input_new",
                hook_status=copy_fields(input_hook_status), statistics=input_stats(), bit_mapping=INPUT_BITS,
                direction_space="stage_absolute", physical_device_input_available=false,
                command_buffer_scope="current 64-slot ring entry and pointers/saved masks, not a complete history or verified consumed command",
                edge_policy="derive held changes only between recorded adjacent simulation ticks; otherwise omit edges",
                pre_post_scope="UpdateFrameEnd entry/exit, not before/after all command processing",
                command_consumption_verified=false,
            },
            my_side        = my_side,                                        -- Selected player side.
            my_char        = my_character.char_id,
            my_char_name   = my_character.char_name,
            char_p1        = character_p1.char_id,
            char_p2        = character_p2.char_id,
            char_p1_name   = character_p1.char_name,
            char_p2_name   = character_p2.char_name,
            characters     = {p1 = character_p1, p2 = character_p2},
            frame_count    = #frames,
            round_format = {source="gBattle.Round.RoundNo",round_index_base=0,round_base=1},
            observed_rounds = recorded_rounds,
            players = single_replay and single_replay.players or nil,
            official_results = top_results,
            my_wins = result_verified and top_results.wins[my_side] or nil,
            opp_wins = result_verified and top_results.wins[my_side=="p1" and "p2" or "p1"] or nil,
            result_scope = "entire_replay_metadata_not_remaining_hp",
            segmentation = {enabled=false,reason="deferred_pending_design"},
            identity_and_results = {
                account_player_ids_available=single_replay and single_replay.account_player_ids_available or false,
                account_player_ids_source="CommonReplayInfo.player*_info.player.short_id",
                fighter_id_meaning="character_resource_id_not_account_player_id",
                official_round_winner_verified=result_verified,
                winner_enum_mapping_verified=top_results and top_results.winner_mapping_verified or false,
                playback_association_verified=all_assigned,
                note="Round winners require replay/network result agreement. Unfinished slots and unsupported draw/conflict codes remain unknown; multiple contexts have no flat score.",
            },
        },
        frames = table.move(frames, 1, #frames, 1, {}),
        runtime_facts = snapshot_runtime(),
    }
    return {data=out, path=SAVE_DIRECTORY .. "mca_" .. label .. ".json", prepare=os.clock()-save_started}
end

local function choose_background_path(job, checkpoint)
    if job.background_path_chosen then return end
    local path, number = job.path, 1
    while true do
        local existing = io.open(path, "rb")
        if not existing then break end
        existing:close()
        number = number + 1
        path = job.path:sub(1, -6) .. "_" .. number .. ".json"
        checkpoint()
    end
    job.path = path
    job.background_path_chosen = true
end

local function start_save(job)
    job.phase = "Encoding"
    job.started = os.clock()
    job.times = {}
    job.worker = coroutine.create(function()
        local checkpoint, timings
        if job.background then
            assert(capture_storage and type(capture_storage.write_sliced)=='function'
                and io and type(io.open)=='function' and type(json.dump_string)=='function',
                "Background Save needs the current MCA/storage and REFramework file APIs.")
            local checks = 0
            checkpoint = function(next_phase, eager)
                if next_phase then coroutine.yield(next_phase); return end
                checks = checks + 1
                if (eager or checks % 32 == 0) and (checks >= 2048 or os.clock() >= job.deadline) then
                    checks = 0
                    coroutine.yield()
                end
            end
        else
            timings = {}
        end
        local payload = job.data
        job.storage_status = "Original schema (minified): compact module unavailable"
        local encode_started = os.clock()
        if capture_storage then
            local ok, value = pcall(capture_storage.pack, job.data, timings, checkpoint)
            if ok and type(value)=='table' and value.storage_format=='sf6-capture-compact-1' then
                payload = value
                job.storage_status = "Lossless compact JSON (verified)"
            else
                job.storage_status = "Original schema (minified): compact failed; " .. tostring(value)
            end
        end
        if job.background then
            coroutine.yield("Writing JSON")
            local function checkpoint_write() checkpoint(nil, true) end
            choose_background_path(job, checkpoint_write)
            return capture_storage.write_sliced(job.path, payload, checkpoint_write)
        end
        local write_started = os.clock()
        job.times.Verifying = timings.verify or 0
        job.times.Encoding = write_started - encode_started - job.times.Verifying
        local written = json.dump_file(job.path, payload, -1)
        job.times["Writing JSON"] = os.clock() - write_started
        return written
    end)
    save_job = job
    save_status = nil
end

local function advance_save()
    if not save_job and #pending_saves>0 then start_save(table.remove(pending_saves, 1)) end
    local job = save_job
    if not job or not job.worker then return end
    local phase = job.phase
    local started = os.clock()
    job.deadline = started + SAVE_SLICE_SECONDS
    local ok, result = coroutine.resume(job.worker)
    local finished = os.clock()
    if job.background then job.times[phase] = (job.times[phase] or 0) + finished - started end
    if ok and coroutine.status(job.worker) == "suspended" then
        job.phase = result or phase
        return
    end
    job.worker = nil
    if not ok or not result then
        save_status = "Save failed: " .. job.path .. "\n"
            .. (ok and "Check that replay/ is writable." or tostring(result))
            .. " The capture snapshot is available for retry."
        return
    end
    save_status = "Saved: reframework/data/" .. job.path .. "\n" .. job.storage_status .. "\n"
        .. string.format("%d observations / %d runtime events\n", #job.data.frames, #(job.data.runtime_facts.events or {}))
        .. string.format("Save work: prepare %.3fs / encode %.3fs / verify %.3fs / write %.3fs\nElapsed: %.1fs",
            job.prepare, job.times.Encoding or 0, job.times.Verifying or 0, job.times["Writing JSON"] or 0,
            job.prepare + finished - job.started)
    save_job = nil
end

local function runtime_event_count()
    return runtime_facts and runtime_facts.events and #runtime_facts.events or 0
end

local function submit_save(background)
    local job = prepare_save()
    job.background = background
    job.coverage = {frames=#job.data.frames, events=#(job.data.runtime_facts.events or {})}
    save_coverage = job.coverage
    pending_saves[#pending_saves+1] = job
    if not background then advance_save() end
end

local function clear_buffer()
    frames = {}
    frame_count = 0
    in_combat = false
    replay_contexts = {}
    replay_context_index = nil
    manual_replay_id = ""
    capture_started_epoch = nil
    capture_ended_epoch = nil
    previous_sample_time = nil
    input_previous = {}
    capture_timer_epoch = 0
    capture_error = nil
    save_coverage = nil
    capture_replay_id = nil
    left_replay_flow = false
    if runtime_facts then runtime_facts.clear() end
end

rotate_recording = function()
    if #frames>(save_coverage and save_coverage.frames or 0)
        or runtime_event_count()>(save_coverage and save_coverage.events or 0) then
        submit_save(true)
    end
    clear_buffer()
end

local function set_recording(value)
    local enabled = value == true
    if enabled == auto_record then return end
    if enabled then rotate_recording() end
    auto_record = enabled
    if runtime_facts then runtime_facts.set_recording(enabled) end
end

-- Local control for training validation; the recorder itself never initiates actions.
_G.MCA_CAPTURE_CONTROL = {set_recording=set_recording}

local function fv(v)
    if v == nil then return "FAIL" end
    if type(v) == "number" then return string.format("%.3f", v) end
    return tostring(v)
end

-- ---- Detect the installed game version; retry unavailable reads at most every 5s ----
local function detect_game_version()
    if game_version ~= nil then return end
    local now = os.time()
    if version_checked_at ~= 0 and now - version_checked_at < 5 then return end
    version_checked_at = now
    -- Capture continues with "(unknown)" if the version cannot be read.
    local value = try(function()
        local app = sdk.find_type_definition("app.ApplicationFunc")
        if app then
            local v = app:get_method("getVersionString")
            if v then
                local result = v:call(nil)
                if type(result) == "string" then return result end
                if result ~= nil then return result:ToString() end
            end
        end
        return nil
    end)
    if type(value) == "string" and value ~= "" and value ~= "nil" then
        game_version = value
        game_version_source = "app.ApplicationFunc.getVersionString"
    end
end

-- Simulation sampling is independent from drawing the UI.
local function capture_sample(phase, pre, monitor_only)
    local ok, err=pcall(function()
        local gB = sdk.find_type_definition("gBattle")
        if not gB then last_status = "gBattle type not found"; in_combat = false; return end

        local sRound  = gB:get_field("Round"):get_data(nil)
        local sGame   = gB:get_field("Game"):get_data(nil)
        local sPlayer = gB:get_field("Player"):get_data(nil)
        local sTeam   = gB:get_field("Team"):get_data(nil)
        if not (sRound and sGame and sPlayer and sTeam) then
            last_status = "Not in battle (menu/loading)"; in_combat = false; return
        end

        local cPlayer = sPlayer.mcPlayer
        local cTeam   = sTeam.mcTeam
        if not (cPlayer and cTeam) then last_status = "Player array empty"; in_combat = false; return end

        cur_round_index = try(function() return sRound.RoundNo end)
        round_read_ok=type(cur_round_index)=="number" and cur_round_index>=0
            and cur_round_index<math.huge and cur_round_index==math.floor(cur_round_index)
        cur_round=round_read_ok and (cur_round_index+1) or nil
        cur_timer = try(function() return sGame.stage_timer end)

        local p1=read_player(cPlayer,cTeam,0)
        local p2=read_player(cPlayer,cTeam,1)
        if not monitor_only then refresh_current_replay() end

        -- ---- Capture gate (not a round boundary or recording segment) ----
        -- Treat positive cap values for both players as the capture gate.
        -- HP=0 does not close the gate while cap remains positive.
        -- Frames with missing HP or nonpositive cap values are excluded.
        local hp1, hp2 = p1.hp, p2.hp
        local cap1, cap2 = p1.hp_cap, p2.hp_cap
        local combat_now =
            (cap1 ~= nil and cap1 > 0) and (cap2 ~= nil and cap2 > 0) and
            (hp1 ~= nil) and (hp2 ~= nil)

        if combat_now then
            if monitor_only then return end
            simulation_seq=simulation_seq+1
            -- Read the live players' action engines in the same phase as input.
            -- Do not invoke Rollback.GetLatestEngine from menus or mix snapshots.
            for i,d in ipairs({p1,p2}) do
                local engine=try(function() return cPlayer[i-1].mpActParam.ActionPart._Engine end)
                if engine then read_action(engine,d);d.action_source="nBattle.cPlayer.mpActParam.ActionPart._Engine" end
            end
            last_p1,last_p2=p1,p2
            in_combat = true
            last_status = "In combat (game round " .. tostring(cur_round or "unreadable") .. ")"

            if auto_record and not left_replay_flow then
                if active_replay and active_replay.source=="app.BattleReplayDataManager.GetReplayData()"
                    and active_replay.replay_id~="" and not capture_replay_id then
                    capture_replay_id = active_replay.replay_id
                end
                local sample_epoch = os.time()
                if capture_started_epoch == nil then capture_started_epoch = sample_epoch end
                capture_ended_epoch = sample_epoch
                local context_index = recording_context()
                local ctx=replay_contexts[context_index]
                local fighters=ctx.replay_info and ctx.replay_info.Fighters
                local assignment_ok=ctx.association_verified==true and type(fighters)=="table"
                    and fighters[1] and fighters[2] and fighters[1].FighterID==p1.char_id and fighters[2].FighterID==p2.char_id
                    and ctx.players and ctx.players.p1.character_id==p1.char_id and ctx.players.p2.character_id==p2.char_id
                    and ctx.network_replay_id_matches==true
                local reason="first_recorded_observation"
                local continuous=false
                local old=previous_sample_time
                if old then
                    if not round_read_ok or not old.round_read_ok then
                        reason="round_unreadable"
                    elseif old.round_index~=cur_round_index or old.context~=context_index then
                        reason="game_round_or_replay_boundary"
                        capture_timer_epoch=capture_timer_epoch+1
                    elseif type(cur_timer)~="number" or type(old.timer)~="number" then
                        reason="timer_unreadable"
                    elseif cur_timer==old.timer then
                        -- Paused/render duplicates must not generate another edge.
                        return
                    elseif cur_timer<old.timer then
                        reason="simulation_timer_rewind_or_reset"
                        capture_timer_epoch=capture_timer_epoch+1
                    elseif cur_timer~=old.timer+1 then
                        reason="simulation_timer_gap"
                    elseif simulation_seq~=old.simulation_seq+1 then
                        reason="recording_or_callback_gap"
                    elseif phase=="re.on_frame.fallback" then
                        reason="render_fallback_unverified_sampling"
                    else
                        continuous=true
                    end
                end
                local command=try(function() return gB:get_field("Command"):get_data(nil):get_mUserEngine() end)
                last_p1.input=read_input(cPlayer[0],"p1",continuous,reason,pre and pre.p1,last_p1.facing,command and command[0])
                last_p2.input=read_input(cPlayer[1],"p2",continuous,reason,pre and pre.p2,last_p2.facing,command and command[1])
                previous_sample_time={round_index=cur_round_index,round_read_ok=round_read_ok,context=context_index,
                    timer=cur_timer,simulation_seq=simulation_seq}
                frame_count = frame_count + 1
                frames[#frames + 1] = {
                    f = frame_count,
                    round = cur_round, round_index=round_read_ok and cur_round_index or nil,
                    round_read_ok=round_read_ok, timer = cur_timer,
                    play_timer = try(function() return sRound.play_timer end),
                    play_timer_subtick = try(function() return sRound.play_timer_ms end),
                    replay_context = context_index,
                    replay_association_verified=assignment_ok==true,
                    simulation_seq=simulation_seq,timer_epoch=capture_timer_epoch,sample_phase=phase,
                    p1 = last_p1, p2 = last_p2,
                }
            end
            if not auto_record then previous_sample_time=nil;input_previous={} end
        else
            in_combat = false
            previous_sample_time=nil
            input_previous={}
            last_p1,last_p2=p1,p2
            if hp1 ~= nil then
                last_status = "Not in combat (cutscene/KO/select)"
            else
                last_status = "HP unreadable"
            end
        end
    end)
    if not ok then
        capture_error=tostring(err)
        last_status="Capture error: "..capture_error
        previous_sample_time=nil
        input_previous={}
    end
end

local function install_input_hook()
    if input_hook_status.installed then return end
    local ok,err=pcall(function()
        assert(thread and thread.get_hook_storage,"Hook storage unavailable")
        local td=sdk.find_type_definition("app.BattleFlow")
        local method=td and td:get_method("UpdateFrameEnd()")
        assert(method,"BattleFlow.UpdateFrameEnd unavailable")
        sdk.hook(method,function()
            thread.get_hook_storage().mca_pre=try(function()
                local g=sdk.find_type_definition("gBattle")
                local p=g:get_field("Player"):get_data(nil).mcPlayer
                return {p1=raw_player_input(p[0]),p2=raw_player_input(p[1])}
            end)
        end,function(ret)
            input_hook_status.calls=input_hook_status.calls+1
            capture_sample("app.BattleFlow.UpdateFrameEnd.post",thread.get_hook_storage().mca_pre)
            return ret
        end)
    end)
    input_hook_status.installed=ok
    input_hook_status.error=not ok and tostring(err) or nil
end
install_input_hook()

-- Drawing/monitoring never adds samples when the simulation hook is available.
re.on_frame(function()
    advance_save()
    detect_game_version()
    if not auto_record or not in_combat then refresh_current_replay() end
    if input_hook_status.installed then capture_sample("re.on_frame.monitor",nil,true)
    else capture_sample("re.on_frame.fallback") end

    -- ---- UI ----
    -- Pass window_open to begin_window; the close button returns false.
    -- Once closed, skip drawing on subsequent callbacks.
    -- Use REFramework's "Reset scripts" or restart SF6 to reopen it.
    if not window_open then return end
    window_open = imgui.begin_window("Mucharo Capture v3.8.3", window_open, 0)
    if not window_open then
        -- Closing turns off recording. Minimize instead to keep recording with the UI hidden.
        -- The existing capture buffer is preserved.
        set_recording(false)
        imgui.end_window()
        return
    end

    imgui.text("Status: " .. last_status)
    imgui.text("Game round: " .. tostring(cur_round or "FAIL") .. "   Raw index: "
        .. tostring(round_read_ok and cur_round_index or "FAIL") .. "   Timer: " .. fv(cur_timer))
    imgui.text("Installed game version: " .. (game_version or "(unknown)"))
    imgui.text("Replay metadata hook: " .. (replay_hook_status.installed and "ready" or "unavailable"))
    imgui.text("Simulation input hook: "..(input_hook_status.installed and "ready" or "FALLBACK / edges unknown"))
    if input_hook_status.error then imgui.text("Input hook error: "..input_hook_status.error) end
    imgui.text("Loaded replay ID (candidate): " .. (active_replay and active_replay.replay_id or "unknown"))
    imgui.text("Replay version code: " .. tostring(active_replay and active_replay.replay_game_version or "unknown"))
    if active_replay and active_replay.players then
        imgui.text("CFN P1: "..tostring(active_replay.players.p1.cfn_account_id or "unavailable")
            .." / P2: "..tostring(active_replay.players.p2.cfn_account_id or "unavailable"))
        local results=active_replay.official_results
        imgui.text("Replay results: "..(results and results.verified and (results.wins.p1.." - "..results.wins.p2) or "unverified"))
    end
    if replay_hook_status.error then imgui.text("Metadata hook error: " .. replay_hook_status.error) end
    if replay_hook_status.last_read_error then imgui.text("Metadata read error: " .. replay_hook_status.last_read_error) end
    if not replay_hook_status.installed and imgui.button("Retry replay metadata hook") then
        install_replay_hook()
    end
    imgui.separator()

    imgui.text("--- P1 ---")
    imgui.text("Character: " .. (last_p1.char_name or "unknown")
        .. " / ID: " .. tostring(last_p1.char_id or "FAIL")
        .. " / Source: " .. (last_p1.char_id_source or "unavailable"))
    imgui.text("HP: " .. fv(last_p1.hp) .. " / cap " .. fv(last_p1.hp_cap))
    imgui.text("Drive: " .. fv(last_p1.drive) .. "   Super: " .. fv(last_p1.super))
    imgui.text("PosX: " .. fv(last_p1.pos_x) .. "   AccX: " .. fv(last_p1.acc_x))
    imgui.text("Hitstun: " .. fv(last_p1.hitstun) .. "   Blockstun: " .. fv(last_p1.blockstun))
    imgui.text("Action ID: " .. fv(last_p1.action_id) .. "   Frame: " .. fv(last_p1.action_frame)
        .. " / End: " .. fv(last_p1.action_end) .. " / Margin: " .. fv(last_p1.action_margin))
    imgui.text("Logical input: "..(last_p1.input and table.concat(last_p1.input.held or {},"+") or "not recorded"))
    imgui.text("--- P2 ---")
    imgui.text("Character: " .. (last_p2.char_name or "unknown")
        .. " / ID: " .. tostring(last_p2.char_id or "FAIL")
        .. " / Source: " .. (last_p2.char_id_source or "unavailable"))
    imgui.text("HP: " .. fv(last_p2.hp) .. "   PosX: " .. fv(last_p2.pos_x))
    imgui.text("Action ID: " .. fv(last_p2.action_id) .. "   Frame: " .. fv(last_p2.action_frame)
        .. " / End: " .. fv(last_p2.action_end) .. " / Margin: " .. fv(last_p2.action_margin))
    imgui.text("Logical input: "..(last_p2.input and table.concat(last_p2.input.held or {},"+") or "not recorded"))
    imgui.separator()

    -- My Side selection (explicit buttons to avoid index ambiguity)
    imgui.text("My Side (who are you?)")
    if imgui.button(((my_side == "p1") and "[*] " or "[ ] ") .. "1P (Left)") then
        my_side = "p1"
    end
    if imgui.button(((my_side == "p2") and "[*] " or "[ ] ") .. "2P (Right)") then
        my_side = "p2"
    end
    local my_char_now = (my_side == "p1") and last_p1 or last_p2
    imgui.text(">> Selected: " .. my_side .. "  (My HP: " .. fv(my_char_now.hp) .. ")")
    imgui.separator()

    local changed
    local recording
    changed, recording = imgui.checkbox("Auto-Record (combat only)", auto_record)
    if changed then set_recording(recording) end
    imgui.text("Recording: " .. (auto_record and (in_combat and "● ON / In combat" or "○ ON / Waiting") or "OFF"))
    imgui.text("Observations: " .. frame_count .. " (segmentation disabled)")
    imgui.text('Runtime facts: '..(runtime_facts and tostring(runtime_event_count()) or 'module unavailable'))
    imgui.text('Save: '..(capture_storage and 'lossless compact JSON' or 'original JSON (compact module unavailable)'))
    changed, replay_label = imgui.input_text("Label (filename / replay ID)", replay_label)
    changed, manual_replay_id = imgui.input_text("Replay ID (optional manual annotation)", manual_replay_id)
    changed, manual_game_version = imgui.input_text("Installed game version (optional manual override)", manual_game_version)

    if not save_job and #pending_saves==0 then
        local full_speed = imgui.button("Save (Full Speed)")
        imgui.same_line()
        local background = imgui.button("Save (Background)")
        if full_speed or background then submit_save(not full_speed) end
    end
    if save_job then
        if save_job.worker then
            imgui.text("Saving in background: " .. save_job.phase .. "...")
        else
            if imgui.button("Retry save") then
                start_save(save_job)
                if not save_job.background then advance_save() end
            elseif save_job.background and imgui.button("Retry (Full Speed)") then
                save_job.background = false
                start_save(save_job)
                advance_save()
            elseif imgui.button("Discard failed save") then
                if save_coverage==save_job.coverage then save_coverage=nil end
                save_job = nil
                save_status = nil
            end
        end
    end
    if #pending_saves>0 then imgui.text("Queued saves: " .. #pending_saves) end
    if save_status then imgui.text(save_status) end
    if imgui.button("Clear (reset buffer)") then
        clear_buffer()
        active_replay = nil
        if runtime_facts then runtime_facts.set_recording(auto_record) end
    end

    imgui.end_window()
end)
