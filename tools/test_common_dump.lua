-- Run from MMDK with LuaJIT. Test the actual common exporter in isolation.
local file = assert(io.open('MMDK/reframework/autorun/MMDK.lua', 'r'))
local source = file:read('*a'); file:close()
local body = assert(source:match('dump_common_json = function%(self%)(.-)\n\tend,'))
local export = assert(loadstring('return function(self)' .. body .. '\nend'))()
local writes = {}
json = {dump_file=function(path, value) writes[path] = value; return true end}
lua_get_dict = function(value) return value end
act_id_enum = {enum={COMMON_ZERO=0, COMMON_GUARD=145, COMMON_DAMAGE=280, COMMON_OTHER=281}}
local fab = {StyleDict={
    [0]={ActionList={[0]={ActionID=0}, [1]={ActionID=145}, [2]={ActionID=280}}},
    [1]={ActionList={[0]={ActionID=281}}},
}, GetStyleNum=function() return 2 end}
gResource = {Data={[6]={FAB=fab, Rect={RectList={[8]={[1]={SizeX=10}}}}, Atemi={[0]={value=1}}}}}
PlayerData = {}; PlayerData.__index=PlayerData
function PlayerData:collect_fab_action(action)
    local move = {id=action.ActionID,name='COMMON_'..action.ActionID}
    self.moves_dict.By_Name[move.name]=move;self.moves_dict.By_ID[move.id]=move
    return move
end
function PlayerData:dump_moves_dict_json(path) json.dump_file(path,self.moves_dict.By_Name) end
function PlayerData:dump_rects_json(path) json.dump_file(path,self.rects) end
function PlayerData:dump_atemi_json(path,value) json.dump_file(path,value) end
local character = {moves_dict={By_ID={[280]={name='CHARACTER_OVERRIDE'}}}}
local result = export(character)
local prefix = 'MMDK\\PlayerData\\'
assert(result.action_entries==4 and result.style_count==2)
assert(writes[prefix..'common_moves.json'].COMMON_0,'Zero-indexed common action was skipped')
assert(writes[prefix..'common_moves.json'].COMMON_280,'Character override removed common action')
assert(writes[prefix..'common_moves.json'].COMMON_281._PL_StyleID==1,'Common style was skipped')
assert(writes[prefix..'common_names.json']['0280']=='COMMON_280')
assert(writes[prefix..'common_rects.json'][8][1].SizeX==10)
assert(writes[prefix..'common_act_id.json'].COMMON_DAMAGE==280)
assert(character.moves_dict.By_ID[280].name=='CHARACTER_OVERRIDE','Selected fighter dictionary was changed')
local count=0;for _ in pairs(writes) do count=count+1 end;assert(count==6)
fab.StyleDict={[0]={ActionList={}},[1]={ActionList={}}}
local ok,err=pcall(export,character)
assert(not ok and err:find('Common actions are empty'))
print('PASS common exporter: zero index, all styles, character override, six files, empty-resource error')
local tables=dofile('MMDK/reframework/autorun/MMDK/tables.lua')
assert(tables.characters[23]==nil and tables.characters[24]==nil)
assert(tables.characters[25]=='Sagat' and tables.characters[26]=='M Bison')
assert(tables.characters[27]=='Terry' and tables.characters[29]=='Elena' and tables.characters[34]=='Arjun')
print('PASS nonconsecutive fighter resource IDs')
