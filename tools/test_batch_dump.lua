-- Run from MMDK with: luajit tools/test_batch_dump.lua
-- Exercise export ordering and safeguards with delayed native fighter loading.
local function scenario(mode)
    local callbacks,messages,writes={}, {}, {}
    local live,pending,ticks,button=1,nil,0,'Start new batch'
    local chars={[1]='Ryu',[2]='Luke',[3]='Kimberly'}
    package.loaded['MMDK\\tables']={characters=chars}
    local p2={InputType=0,KeyConfigPreset=1,NegativeEdge=false,LowStickSensitivity=false}
    function p2:get_field(k) return self[k] end
    local selection={get_field=function() return {[1]=p2} end}
    local tdata={get_field=function() return selection end}
    local gd={IsCharaChange=false,get_field=function(self,k) return self[k] end}
    local controller={}
    local target
    function controller:call(name,player,id,color,costume,input,preset,negative,low)
        assert(callbacks.in_update,'Switch called outside UpdateBehavior')
        assert(name=='ChangeFighter' and player==1,'Wrong native entry or changed P1')
        assert(color==0 and costume==0,'Non-default appearance')
        assert(input==0 and preset==1 and negative==false and low==false,'Control settings changed')
        target=id; gd.IsCharaChange=mode~='missing_reload'
    end
    local selector={get_type_definition=function() return {get_full_name=function() return 'app.training.tf_SelectMenu' end} end}
    function selector:get_field(k) return k=='FuncList' and controller or gd end
    package.loaded['MMDK\\functions']={lua_get_dict=function() return {[1]=selector} end}
    function selector:call(name)
        assert(callbacks.in_update,'Apply called outside UpdateBehavior')
        assert(name=='Apply','Wrong selector apply request')
        assert(gd.IsCharaChange,'Applied without reload request')
        if mode~='no_load' then pending=60 end
        gd.IsCharaChange=false
    end
    local manager={_ActiveMenuType=-1,_tData=tdata,_tfFuncs={}}
    function manager:get_field(k) return self[k] end
    function manager:call(name,reset)
        if name=='get_BattleCore()' then return {get_field=function() return {[0]={},[1]={}} end} end
        error('Global TrainingManager.Apply must not be used for character switching')
    end
    local function make_data(id)
        local d={chara_id=id,name=chars[id],person={},engine={},hit_datas={},triggers_by_act_id={},rects={},commands={},tgroups={},atemi={},charge={},char_info={},assist_combo={},moves_dict={By_Name={move={}}},common_moves_collected=mode~='needs_common' or mmsettings and mmsettings.do_common_dict==true}
        for _,name in ipairs({'hit_dt','trigger','atemi','tgroups','rects','commands','charge','char_info','assist_combo','moves_dict'}) do
            d['dump_'..name..'_json']=function(self)
                assert(live==self.chara_id,'Exported stale fighter data')
                json.dump_file(self.name..'/'..name,{})
            end
        end
        d.dump_common_json=function(self)
            for _,name in ipairs({'moves','rects','atemi','names','act_id','manifest'}) do
                json.dump_file('common_'..name..'.json',{})
            end
            return {action_entries=123}
        end
        return d
    end
    mmsettings=nil
    player_data={[2]=make_data(1)};tmp_fns={};engines={[2]={}}
    PlayerData={new=function(_,i) player_data[i]=make_data(live) end,dump_common_json=true}
    mmsettings={enabled=false,do_common_dict=false,fighter_options={}}
    for _,name in ipairs({'All Characters','Ryu','Luke','Kimberly'}) do mmsettings.fighter_options[name]={enabled=true,ordered={'test'},test={enabled=true}} end
    log={info=function(s) messages[#messages+1]=s end}
    json={dump_file=function(path) if mode=='write_failure' or mode=='common_write_failure' and path=='common_rects.json' then return false end;writes[path]=(writes[path] or 0)+1;return true end}
    sdk={get_managed_singleton=function() return manager end,find_type_definition=function() return {get_field=function() return {get_data=function() return {mPlayerType={[1]={mValue=live}}} end} end} end}
    re={on_application_entry=function(name,fn) assert(name=='UpdateBehavior');callbacks.update=fn end,on_draw_ui=function(fn) callbacks.ui=fn end}
    imgui={tree_node=function() return true end,tree_pop=function() end,text=function() end,input_text=function() return true,'1,2,3' end,button=function(label) if label==button then button=nil;return true end;return false end}
    dofile('MMDK/reframework/autorun/MMDK_BatchDump.lua');callbacks.ui()
    for n=1,5000 do
        ticks=n;callbacks.in_update=true
        if pending then pending=pending-1;if pending==0 then live=target;player_data[2]=make_data(live);pending=nil end end
        callbacks.update()
        local jobs={};for k,v in pairs(tmp_fns) do jobs[k]=v end;for _,fn in pairs(jobs) do fn() end
        callbacks.in_update=false
        if mode=='stop' and pending then button='Stop';callbacks.ui();break end
        local last=messages[#messages] or ''
        if last:find('Finished') or last:find('Timed out') or last:find('Cannot load') or last:find('Export failed') then break end
    end
    local last=messages[#messages] or ''
    if mode=='success' or mode=='needs_common' then
        assert(last:find('Finished 3 characters'),last)
        local count=0;for _ in pairs(writes) do count=count+1 end;assert(count==36,count)
        assert(writes['common_moves.json']==1,'Common export ran more than once')
        assert(mmsettings.do_common_dict==true,'Common collection was not enabled')
    elseif mode=='stop' then assert(last:find('Stopped'),last)
    elseif mode=='write_failure' then assert(last:find('Export failed for Ryu'),last)
    elseif mode=='common_write_failure' then assert(last:find('common resources'),last);assert(not writes['Ryu/hit_dt'])
    elseif mode=='missing_reload' then assert(last:find('did not request a character reload'),last)
    elseif mode=='no_load' then assert(last:find('Timed out waiting for Luke'),last);assert(not writes['Luke/hit_dt']) end
    assert(mmsettings.enabled==false,'Settings not restored')
    for _,o in pairs(mmsettings.fighter_options) do assert(o.enabled and o.test.enabled) end
    print('PASS '..mode..' ('..ticks..' frames)')
end
for _,mode in ipairs({'success','needs_common','no_load','missing_reload','stop','write_failure','common_write_failure'}) do scenario(mode) end
