-- Passive game facts used by the normal recorder. OFF until recording starts.
-- No active command/collision/capability checks, no changed game fields/returns.
local M={version='runtime-0.8.1',enabled=false,events={},errors={},hooks={},stats={},limit=60000,
 enum={},meter_enum={},generation=0,seq=0,epoch=0,tick_seq=0}
local function safe(fn) local ok,v=pcall(fn);if ok then return v end end
local function scalar(v) if type(v)=='number' or type(v)=='boolean' or type(v)=='string' then return v end end
local function field(o,k) return o and safe(function() return o[k] end) end
local function battle(n)
 return safe(function() return sdk.find_type_definition('gBattle'):get_field(n):get_data(nil) end)
end
local function actor(p)
 if not p then return {available=false} end
 local a={available=true}
 for _,n in ipairs({'pl_no','pl_work_no','pl_type','mStyleNo','mActionId','act_st','pose_st','hit_stop',
  'vital_new','focus_new','combo_cnt','combo_dm_cnt','counter_dm_flag','counter_fw_flag','rl_dir',
  'check_status','hit_st','damage_back','damage_back_old','mActUniqueId','act_st_old',
  'damage_st','guard_st','throw_tech_no','combo_hold_flag','combo_reset_flag','gard_combo_cnt','parry_combo_cnt'}) do a[n]=scalar(field(p,n)) end
 a.object_type=safe(function() return p:get_type_definition():get_full_name() end)
 if a.object_type=='nBattle.cPlayer' then
  a.heal_new=scalar(field(p,'heal_new'))
  a.is_air=scalar(safe(function() return p:call('get_IsAir()') end))
  a.is_down=scalar(safe(function() return p:call('get_IsDown()') end))
 end
 local owner=field(p,'owner_add')
 if owner then a.owner={pl_no=scalar(field(owner,'pl_no')),pl_work_no=scalar(field(owner,'pl_work_no')),
  pl_type=scalar(field(owner,'pl_type'))} end
 a.pos_x=safe(function() return p.pos.x.v/6553600.0 end)
 a.pos_y=safe(function() return p.pos.y.v/6553600.0 end)
 a.super=scalar(field(field(p,'mpTeam'),'mSuperGauge'))
 local engine=safe(function() return p.mpActParam.ActionPart._Engine end)
 if engine then a.action_id=safe(function() return engine:get_ActionID() end)
  a.action_frame=safe(function() return engine:get_ActionFrame():ToFloat() end) end
 return a
end
local function context()
 local g,r=battle('Game'),battle('Round')
 return {timer=scalar(field(g,'stage_timer')),round_index=scalar(field(r,'RoundNo')),
  fight_st=scalar(field(g,'fight_st')),tick_seq=M.tick_seq,epoch=M.epoch}
end
local function players()
 local ps=field(battle('Player'),'mcPlayer')
 return {actor(ps and safe(function() return ps[0] end)),actor(ps and safe(function() return ps[1] end))}
end
local function emit(kind,source,data)
 if not M.enabled then return end
 if #M.events>=M.limit then M.stats.dropped=(M.stats.dropped or 0)+1;return end
 M.seq=M.seq+1
 M.events[#M.events+1]={seq=M.seq,kind=kind,source=source,time=context(),data=data}
end
local function fail(where,err)
 if #M.errors<32 then M.errors[#M.errors+1]={where=where,error=tostring(err)} end
end
local function enum(name)
 local td=sdk.find_type_definition(name);local values={}
 for _,f in ipairs(td and safe(function() return td:get_fields() end) or {}) do
  if f:is_static() then local v=scalar(safe(function() return f:get_data(nil) end))
   if type(v)=='number' then values[tostring(v)]=f:get_name() end end
 end
 return values
end
M.enum=enum('app.ENoticeSelf');M.meter_enum=enum('app.training.UIWidget_TMFrameMeter.FrameType')
M.actor_enum=enum('nBattle.ACT_ST.ID')
M.check_enum=enum('nBattle.nHit.CHECK_ST')
local function integer(v,bits,signed)
 local n=safe(function() return sdk.to_int64(v) end);if type(n)~='number' then return end
 n=n%(2^bits);if signed and n>=2^(bits-1) then n=n-2^bits end
 return math.tointeger and math.tointeger(n) or n
end
local function params(method,args)
 local types=method:get_param_types();local names=method:get_param_names();local out={}
 local static=safe(function() return method:is_static() end)==true
 for i,t in ipairs(types) do
  local name=names[i] or ('arg'..i);if name=='' then name='arg'..i end
  local tn=t:get_full_name();local v=args[i+(static and 1 or 2)]
  if tn=='System.Boolean' then local n=integer(v,8,false);if n==0 or n==1 then out[name]=n==1 end
  elseif tn=='System.Int32' then out[name]=integer(v,32,true)
  elseif tn=='System.UInt32' then out[name]=integer(v,32,false)
  elseif tn=='app.ENoticeSelf' then out[name]=integer(v,8,false)
  elseif tn=='app.training.UIWidget_TMFrameMeter.FrameType' or tn=='app.training.UIWidget_TMFrameMeter.EMeterPos' then out[name]=integer(v,32,true) end
 end
 return out
end
local function hook_type(type_name,select,callback)
 local td=sdk.find_type_definition(type_name)
 for _,m in ipairs(td and td:get_methods() or {}) do
  if select(m) then
   local label=type_name..'.'..m:get_name();local row={source=label,installed=false};M.hooks[#M.hooks+1]=row
   local ok,err=pcall(sdk.hook,m,function(args)
    if not M.enabled then return end
    M.stats[label]=(M.stats[label] or 0)+1
    local good,why=pcall(callback,m,args,label);if not good then fail(label,why) end
   end,function(ret) return ret end)
   row.installed=ok;row.error=not ok and tostring(err) or nil
  end
 end
end
-- Paired, detached contact observations. A callback entry is a processing phase,
-- not necessarily the collision's earliest pre-state. Frame context is separate.
local function hook_window(name,kind,expected)
 local label='nBattle.cPlayer.'..name
 local row={source=label,installed=false,kind=kind};M.hooks[#M.hooks+1]=row
 local td=sdk.find_type_definition('nBattle.cPlayer');local candidates={}
 for _,m in ipairs(td and td:get_methods() or {}) do
  if m:get_name()==name then
   local ts=m:get_param_types();local matches=#ts==#expected
   for i,t in ipairs(ts) do if t:get_full_name()~=expected[i] then matches=false end end
   if matches and safe(function() return m:is_static() end)==false then candidates[#candidates+1]=m end
  end
 end
 if #candidates~=1 or not (thread and thread.get_hook_storage) then
  row.error='missing_or_ambiguous_signature_or_hook_storage';return
 end
 local m=candidates[1];local key='mca_runtime_window_'..name
 local ok,err=pcall(sdk.hook,m,function(args)
  local st=thread.get_hook_storage();st[key]=st[key] or {}
  local item={enabled=M.enabled,generation=M.generation};table.insert(st[key],item)
  if not M.enabled then return end
  M.stats[label]=(M.stats[label] or 0)+1
  local good,why=pcall(function()
   M.window_seq=M.window_seq+1;item.window_id=M.window_seq;item.entry_time=context()
   item.self=sdk.to_managed_object(args[2]);item.other=#expected>0 and expected[1]=='nBattle.cWork'
    and safe(function() return sdk.to_managed_object(args[3]) end) or nil
   item.before=actor(item.self);item.attacker_before=actor(item.other)
   item.players_before=players();item.arguments=params(m,args)
  end)
  item.read_ok=good;if not good then fail(label,why) end
 end,function(ret)
  local st=thread.get_hook_storage();local item=table.remove(st[key] or {})
  if item and item.enabled and item.read_ok and M.enabled and item.generation==M.generation then
   local good,why=pcall(function()
    local after=actor(item.self)
    if kind=='combo_reset' and not (type(item.before.combo_dm_cnt)=='number' and
     type(after.combo_dm_cnt)=='number' and item.before.combo_dm_cnt>0 and after.combo_dm_cnt==0) then
     M.stats.combo_reset_without_positive_zero_transition=(M.stats.combo_reset_without_positive_zero_transition or 0)+1
     return
    end
    emit(kind,label,{window_id=item.window_id,entry_time=item.entry_time,
     before=item.before,after=after,attacker_before=item.attacker_before,
     attacker_after=actor(item.other),players_before=item.players_before,players_after=players(),
     arguments=item.arguments,sampling_phase='function_entry_and_exit_not_collision_boundary'})
   end)
   if not good then fail(label,why) end
  end
  return ret
 end)
 row.installed=ok;row.error=not ok and tostring(err) or nil
end
hook_window('pl_guard_set','guard_contact',{'nBattle.cWork'})
hook_window('pl_parry_dmg','parry_contact',{'nBattle.cWork','System.Boolean'})
hook_window('throw_tech_ok','throw_tech',{})
hook_window('pl_damage_set','damage_context',{'nBattle.cWork'})
hook_window('combo_reset','combo_reset',{})
hook_window('combo_nage','throw_capture',{'nBattle.HIT_DT'})
hook_type('app.FBattleMediator',function(m) return m:get_name()=='SetHitMessage' end,function(m,args,label)
 local data=params(m,args);data.notice_name=M.enum[tostring(data.msgType)]
 data.players=players();emit('hud_notice',label,data)
end)
-- Observe the game's own cross-up predicate when it is called. Never invoke it
-- ourselves or turn a missing HUD notice into a negative gameplay result.
do
 local td=sdk.find_type_definition('app.FBattleMediator')
 for _,m in ipairs(td and td:get_methods() or {}) do
  if m:get_name()=='GetCrossUp' and thread and thread.get_hook_storage then
   local label='app.FBattleMediator.GetCrossUp';local row={source=label,installed=false};M.hooks[#M.hooks+1]=row
   local ok,err=pcall(sdk.hook,m,function(args)
    local st=thread.get_hook_storage();st.mca_cross_stack=st.mca_cross_stack or {}
    local item={enabled=M.enabled,generation=M.generation};table.insert(st.mca_cross_stack,item)
    if M.enabled then
     M.stats[label]=(M.stats[label] or 0)+1
     local good,why=pcall(function()
      item.entry_time=context();item.attacker=actor(sdk.to_managed_object(args[3]))
      item.defender=actor(sdk.to_managed_object(args[4]))
     end)
     if not good then fail(label,why) end
    end
   end,function(ret)
    local st=thread.get_hook_storage();local item=table.remove(st.mca_cross_stack or {})
    if item and item.enabled and M.enabled and item.generation==M.generation then
     local good,why=pcall(function()
      local value=integer(ret,8,false);local readable=value==0 or value==1;local result
      if readable then result=value==1 end
      emit('cross_up_check',label,{entry_time=item.entry_time,attacker=item.attacker,defender=item.defender,
       result_read_ok=readable,result=result})
     end)
     if not good then fail(label,why) end
    end
    return ret
   end)
   row.installed=ok;row.error=not ok and tostring(err) or nil
  end
 end
end
hook_type('app.training.tf_DisplaySetting',function(m) return m:get_name():find('g__SetFrameCover',1,true)~=nil end,function(m,args,label)
 local data=params(m,args);data.frame_type_name=M.meter_enum[tostring(data.type)]
 data.players=players()
 -- Closure contains the game's computed end-of-action state; read only.
 local ts=m:get_param_types();local offset=safe(function() return m:is_static() end)==true and 1 or 2
 local value_type=safe(function() return ts[#ts]:is_value_type() end)
 local reference=value_type==false
 local closure=reference and safe(function() return sdk.to_managed_object(args[#ts+offset]) end) or nil
 data.closure_reference_read=reference
 local function closure_field(name)
  if reference then return field(closure,name) end
  if value_type==true and sdk.get_native_field then
   return safe(function() return sdk.get_native_field(args[#ts+offset],ts[#ts],name) end)
  end
 end
 data.is_end_frame=scalar(closure_field('isEndFrame'))
 data.closure_value_read=value_type==true
 local pd=closure_field('plData');local ef=field(pd,'endFrameData')
 data.end_frame_data={IsEndFrame=scalar(field(ef,'IsEndFrame')),LastFrame=scalar(field(ef,'LastFrame'))}
 data.current_frame=scalar(field(pd,'currentFrame'))
 local key=tostring(data.plID)
 local signature=table.concat({tostring(context().timer),tostring(data.frame),tostring(data.type),tostring(data.isEnd),tostring(data.isNotWhole),
   tostring(data.isEmpty),tostring(data.isNotAdd),tostring(data.is_end_frame)},':')
 if M.last_meter[key]~=signature then M.last_meter[key]=signature;emit('frame_meter',label,data) end
end)
local function widget_display(widget,label)
 if not widget then return end
 for i=0,1 do
  local md=safe(function() return widget:GetMeterData(i) end)
  if md then
   local d={position_raw=i,players=players()};local signature={}
   for _,k in ipairs({'ApperFrame','MeatyFrame','StunFrame','WholeFrame','HighAndLowType','MainGauge','EndGauge'}) do
    d[k]=scalar(field(md,k));signature[#signature+1]=tostring(d[k])
   end
   local sig=table.concat(signature,':')
   if M.last_display[i]~=sig then M.last_display[i]=sig;emit('frame_meter_display',label,d) end
  end
 end
end
local function poll_widget()
 if not M.widget and M.tick_seq%60==1 then
  local manager=safe(function() return sdk.get_managed_singleton('app.training.TrainingManager') end)
  local entries=field(field(manager,'_ViewUIWigetDict'),'_entries')
  local visited=0
  if entries then
   for _,entry in pairs(entries) do
    local list=field(entry,'value');local items=field(list,'_items')
    if items then for _,w in pairs(items) do
     visited=visited+1;if visited>512 then break end
     local name=safe(function() return w:get_type_definition():get_full_name() end)
     if name=='app.training.UIWidget_TMFrameMeter' then M.widget=safe(function() return w:add_ref() end) or w;break end
    end end
    if M.widget or visited>512 then break end
   end
  end
  M.stats.widget_scan_objects=visited
 end
 if M.widget then widget_display(M.widget,'app.training.UIWidget_TMFrameMeter.GetMeterData.readonly_poll') end
end
hook_type('app.training.UIWidget_TMFrameMeter',function(m)
 return m:get_name()=='UpdateFrameText'
end,function(m,args,label) widget_display(safe(function() return sdk.to_managed_object(args[2]) end),label) end)
hook_type('app.training.UIWidget_TMFrameMeter',function(m)
 if m:get_name()~='SetStunFrame' then return false end
 local t=m:get_param_types();return #t==2 or #t==4
end,function(m,args,label) local data=params(m,args);data.players=players();emit('frame_advantage_display',label,data) end)
hook_type('app.training.tf_DisplaySetting',function(m)
 return m:get_name()=='OnStunUpFrameDisp' or m:get_name()=='OnStunDownFrameDisp'
end,function(m,args,label)
 local data=params(m,args);data.posType=m:get_name()=='OnStunUpFrameDisp' and 0 or 1
 data.players=players();emit('frame_advantage_display',label,data)
end)
-- Read the completed meter calculation directly as well as its individual cells.
-- This avoids depending on compiler-generated value-type closure layouts.
do
 local td=sdk.find_type_definition('app.training.tf_DisplaySetting')
 local method=td and safe(function() return td:get_method('UpdateFrameMeter') end)
 if method and thread and thread.get_hook_storage then
  local label='app.training.tf_DisplaySetting.UpdateFrameMeter.post'
  local row={source=label,installed=false};M.hooks[#M.hooks+1]=row
  local ok,err=pcall(sdk.hook,method,function(args)
   local st=thread.get_hook_storage();st.mca_meter_stack=st.mca_meter_stack or {}
   table.insert(st.mca_meter_stack,{enabled=M.enabled,self=M.enabled and sdk.to_managed_object(args[2]) or nil})
  end,function(ret)
   local st=thread.get_hook_storage();local stack=st.mca_meter_stack or {};local item=table.remove(stack)
   if item and item.enabled and M.enabled then
    local good,why=pcall(function()
     local gd=field(field(item.self,'FuncList'),'_gData');local ps=field(gd,'PlayerDatas')
     for i=0,1 do
      local pd=ps and safe(function() return ps[i] end);local ef=field(pd,'endFrameData')
      if pd then
       local d={plID=i,players=players(),end_frame_data={IsEndFrame=scalar(field(ef,'IsEndFrame')),LastFrame=scalar(field(ef,'LastFrame'))}}
       for _,k in ipairs({'currentFrame','prevActionFrame','atkFrameMarginFrame','isDown_FutureFrame','damageFrameIsAir','hitStopOwnFrame','isApper','isCatchApper'}) do d[k]=scalar(field(pd,k)) end
       for _,k in ipairs({'FMCurrentFrame','FMStartFrame','FMStopFrame','FMActive','StunFrame','StopAttackFrame'}) do d[k]=scalar(field(gd,k)) end
       local sig=table.concat({tostring(d.currentFrame),tostring(d.end_frame_data.IsEndFrame),tostring(d.end_frame_data.LastFrame),tostring(d.StunFrame),tostring(d.atkFrameMarginFrame),tostring(d.isDown_FutureFrame),tostring(d.damageFrameIsAir),tostring(d.FMActive)},':')
       if M.last_state[i]~=sig then M.last_state[i]=sig;emit('frame_meter_state',label,d) end
      end
     end
    end)
    if not good then fail(label,why) end
   end
   return ret
  end)
  row.installed=ok;row.error=not ok and tostring(err) or nil
 end
end
hook_type('nBattle.cPlayer',function(m) return m:get_name()=='set_counter_msg' end,function(m,args,label)
 local p=safe(function() return sdk.to_managed_object(args[2]) end)
 local attacker=safe(function() return sdk.to_managed_object(args[3]) end)
 emit('hit_property',label,{defender=actor(p),attacker=actor(attacker)})
end)
do
 local td=sdk.find_type_definition('nBattle.cPlayer')
 for _,m in ipairs(td and td:get_methods() or {}) do
  if m:get_name()=='combo_calc' and thread and thread.get_hook_storage then
   local label='nBattle.cPlayer.combo_calc';local row={source=label,installed=false};M.hooks[#M.hooks+1]=row
   local ok,err=pcall(sdk.hook,m,function(args)
    local st=thread.get_hook_storage();st.mca_combo_stack=st.mca_combo_stack or {}
    local item={enabled=M.enabled,time=context(),generation=M.generation}
    if M.enabled then
     item.self=sdk.to_managed_object(args[2]);item.before=actor(item.self)
     item.attacker=actor(safe(function() return sdk.to_managed_object(args[3]) end))
    end
    table.insert(st.mca_combo_stack,item)
   end,function(ret)
    local st=thread.get_hook_storage();local item=table.remove(st.mca_combo_stack or {})
    if item and item.enabled and M.enabled and item.generation==M.generation then
     local ok,why=pcall(function() emit('combo_increment',label,{before=item.before,after=actor(item.self),attacker=item.attacker,entry_time=item.time}) end)
     if not ok then fail(label,why) end
    end
    return ret
   end)
   row.installed=ok;row.error=not ok and tostring(err) or nil
  end
 end
end
hook_type('app.training.UIWidget_TMFrameMeter',function(m) return m:get_name()=='ResetFrame' end,function(m,args,label)
 M.epoch=M.epoch+1;M.last_meter={};M.last_state={};M.last_display={};emit('meter_reset',label,{})
end)
function M.clear()
 M.events={};M.errors={};M.stats={};M.seq=0;M.window_seq=0;M.tick_seq=0;M.epoch=0;M.last_meter={};M.last_state={};M.last_display={};M.previous=nil;M.widget=nil;M.generation=M.generation+1
end
function M.set_recording(value)
 local enabled=value==true
 if enabled~=M.enabled then M.generation=M.generation+1 end
 if enabled and not M.enabled then
  M.epoch=M.epoch+1;M.last_meter={};M.last_state={};M.last_display={};M.previous=nil;M.widget=nil
 end
 M.enabled=enabled
end
function M.on_tick()
 if not M.enabled then return end
 M.tick_seq=M.tick_seq+1;local t=context();local old=M.previous
 if old and (old.round_index~=t.round_index or type(t.timer)=='number' and type(old.timer)=='number' and t.timer<old.timer) then
  M.epoch=M.epoch+1;M.last_meter={};M.last_state={};M.last_display={};emit('time_boundary','app.BattleFlow.UpdateFrameEnd',{})
 end
 M.previous=t
 poll_widget()
end
function M.export() return {schema='sf6-runtime-facts-0.2',version=M.version,events=M.events,errors=M.errors,
 stats=M.stats,hooks=M.hooks,notice_enum=M.enum,meter_enum=M.meter_enum,actor_enum=M.actor_enum,
 check_enum=M.check_enum,limit=M.limit,
 dropped=M.stats.dropped or 0,semantics={frame_meter='game meter observations, not universal per-category actionability',
 notice='game SetHitMessage notifications; display notifications are not individual damage counts',
 contact='guard/parry/tech callbacks are distinct from hit flags, damage processing and throw capture; entry/exit snapshots are processing phases',
 cross_up_flag='raw check_status with live CHECK_ST enum at contact/notice callbacks; freshness and attacker/defender role require validation'}} end
M.clear()
local td=sdk.find_type_definition('app.BattleFlow');local frame_method=td and td:get_method('UpdateFrameEnd()')
if frame_method then
 local ok,err=pcall(sdk.hook,frame_method,function() end,function(ret)
  local good,why=pcall(M.on_tick);if not good then fail('tick',why) end;return ret
 end)
 M.hooks[#M.hooks+1]={source='app.BattleFlow.UpdateFrameEnd',installed=ok,error=not ok and tostring(err) or nil}
end
_G.MCA_RUNTIME_CAPTURE=M
return M
