-- Reproduce a primitive getter being accepted as an address by the SDK predicate.
local file=assert(io.open('MMDK/reframework/autorun/MMDK/functions.lua','r'))
local source=file:read('*a');file:close()
local body=assert(source:match('(local function convert_to_json_tbl.-)\n%-%-Create a resource'))
local convert=assert(loadstring(body..'\nreturn convert_to_json_tbl'))()
json={dump_string=function(value) return value==nil and 'null' or 'value' end}
get_fmt_string=function() return '%01d' end
local sdk_checks=0
sdk={is_managed_object=function(value) sdk_checks=sdk_checks+1;return true end}
local return_type={is_a=function() return false end}
local function getter(name,value)
    return {get_name=function() return name end,is_static=function() return false end,
        get_num_params=function() return 0 end,get_return_type=function() return return_type end,
        call=function() return value end}
end
local td={get_full_name=function() return 'Test.GetterObject' end,is_value_type=function() return false end,
    is_a=function() return false end,get_field=function() return nil end,
    get_fields=function() return {} end,get_parent_type=function() return nil end,
    get_methods=function() return {getter('GetNumber',19729),getter('GetZero',0),getter('GetFalse',false)} end}
local obj=newproxy(true)
getmetatable(obj).__index={get_type_definition=function() return td end,
    setNumber=function() end,setZero=function() end,setFalse=function() end}
local result=convert(obj)
assert(result.Number==19729 and result.Zero==0 and result.False==false)
assert(sdk_checks==0,'Primitive values were passed to the managed-address predicate')
print('PASS JSON conversion: numeric getter, zero and false remain primitives; no add_ref/address check')
