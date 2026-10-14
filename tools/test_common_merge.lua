-- Ensure common action objects/names are not borrowed from a previous fighter.
local file=assert(io.open('MMDK/reframework/autorun/MMDK.lua','r'))
local source=file:read('*a');file:close()
local body=assert(source:match('collect_fab_action = function%(self, fab_action, is_common%)(.-)\n\tend,'))
local collect=assert(loadstring('return function(self,fab_action,is_common)'..body..'\nend'))()
act_id_enum={reverse_enum={[282]='DMG_V_SPIN_AIR'}}
common_move_dict={[282]={id=282,name='Ryu_cached_animation',box={}}}
lua_get_array=function(value) return value end
get_unique_name=function(name,dict) return dict[name] and name..'(1)' or name end
characters={}
local function fighter()
    return {player_index=2,motion={},person={},triggers_by_act_id={},
        moves_dict={By_Name={},By_ID={},By_Index={}}}
end
local action={ActionID=282,Keys={}}
local a,b=fighter(),fighter()
local first,second=collect(a,action,true),collect(b,action,true)
assert(first~=second and first~=common_move_dict[282],'Shared mutable move reused across fighters')
assert(first.name=='DMG_V_SPIN_AIR' and second.name==first.name)
assert(a.moves_dict.By_Name[first.name]==first and b.moves_dict.By_Name[second.name]==second)
assert(common_move_dict[282].name=='Ryu_cached_animation','Previous fighter cache was changed')
local collision=fighter();collision.moves_dict.By_Name.DMG_V_SPIN_AIR={id=999}
local unique=collect(collision,action,true)
assert(unique.name=='DMG_V_SPIN_AIR(1)' and collision.moves_dict.By_Name[unique.name]==unique)
local override=fighter();override.moves_dict.By_ID[282]={name='CHARACTER_OVERRIDE'}
assert(collect(override,action,true)==nil and override.moves_dict.By_ID[282].name=='CHARACTER_OVERRIDE')
print('PASS common merge: fresh objects, canonical names/keys, unique-name collision, character ID override')
