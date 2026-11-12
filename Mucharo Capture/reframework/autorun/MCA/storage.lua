-- Lossless JSON storage, shared with scripts/capture_storage.py.
-- Only used by Save. Recording buffers, hooks and game values are untouched.
local M={version='storage-1.0.5',format='sf6-capture-compact-1'}
local number_type=math.type
local pack_number=string.pack
local function primitive(v)
 local t=type(v);return t=='string' or t=='boolean' or t=='number'
end
local function check_finite(v)
 assert(v==v and v~=math.huge and v~=-math.huge,'non-finite number')
end
local function key(v)
 local t=type(v)
 if t=='string' then return 's'..#v..':'..v end
 if t=='boolean' then return v and 'b1' or 'b0' end
 if t=='number' then
  check_finite(v)
  if number_type and number_type(v)=='integer' then return 'i'..tostring(v) end
  return 'f'..(pack_number and pack_number('n',v) or string.format('%.17g',v))
 end
 error('not a scalar')
end
local function same(a,b)
 local t=type(a)
 if t~=type(b) or a~=b then return false end
 if t=='number' then
  -- Lua's == treats integer/float pairs and signed zeros as equal.
  return (not number_type or number_type(a)==number_type(b)) and (a~=0 or 1/a==1/b)
 end
 return t=='string' or t=='boolean'
end
local function copy(t,omit)
 local out={};for k,v in pairs(t) do if not (omit and omit[k]~=nil) then out[k]=v end end;return out
end
local function constants(rows,exclude,checkpoint)
 local out={};if #rows==0 then return out end
 for k,v in pairs(rows[1]) do
  if primitive(v) and not (exclude and exclude[k]) then
   local equal=true
   for i=2,#rows do
    if not same(v,rows[i][k]) then equal=false;break end
    if checkpoint and i%256==0 then checkpoint() end
   end
   if equal then
    if type(v)=='number' then check_finite(v) end
    out[k]=v
   end
  end
 end
 return out
end
local function sorted_fields(t)
 local fields={};for k in pairs(t) do fields[#fields+1]=k end;table.sort(fields);return fields
end
local function fields_key(fields)
 local parts={};for i,k in ipairs(fields) do parts[i]=#k..':'..k end;return table.concat(parts,'|')
end

function M.pack(data, timings, checkpoint)
 local encode_started=timings and os.clock()
 assert(type(json)=='table' and type(json.dump_string)=='function','JSON API unavailable')
 -- Empty Lua tables have no inherent array/object/null identity. Match the
 -- installed JSON writer instead of inventing an identity or deleting nulls.
 local empty_json=json.dump_string({},-1)
 assert(empty_json=='null' or empty_json=='[]' or empty_json=='{}','unknown empty table encoding')
 local numeric_keys={};local forced={}
 local function shape(t)
  if forced[t] then return forced[t] end
  local count,max=0,0
  for k in pairs(t) do
   if type(k)~='number' or k<1 or k%1~=0 then return 'object' end
   count=count+1
   if k>max then max=k end
   if checkpoint and count%256==0 then checkpoint() end
  end
  if count==0 then return empty_json=='null' and 'null' or empty_json=='[]' and 'array' or 'object' end
  return max==count and 'array' or 'object'
 end
 local function object(t)
  if getmetatable(t)==nil then
   local count=0
   for k in pairs(t) do
    if type(k)~='string' then count=nil;break end
    count=count+1
   end
   if count then return t,count end
  end
  local out,count={},0
  for k,v in pairs(t) do
   local name=k
   if type(k)=='number' then
    -- Use the native writer's own numeric-key spelling, not tostring guesses.
    local nk=key(k);name=numeric_keys[nk]
    if name==nil then
     assert(type(json.load_string)=='function','numeric object key needs JSON parser')
     local normalized=json.load_string(json.dump_string({[k]=true},-1))
     assert(type(normalized)=='table','numeric key normalization failed')
     name=next(normalized);assert(type(name)=='string','numeric key is not an object key');numeric_keys[nk]=name
    end
   end
   assert(type(name)=='string','unsupported object key')
   assert(out[name]==nil,'colliding JSON object keys');out[name]=v
   count=count+1
  end
  return out,count
 end
 local defaults={frame={},players={},inputs={}}
 local frames=data.frames or {}
 assert(type(frames)=='table','invalid frames')
 defaults.frame=constants(frames,{p1=true,p2=true},checkpoint)
 for _,s in ipairs({'p1','p2'}) do
  local ps,ins={},{}
  for i,f in ipairs(frames) do
   if type(f[s])=='table' then
    ps[#ps+1]=f[s];if type(f[s].input)=='table' then ins[#ins+1]=f[s].input end
   end
   if checkpoint and i%256==0 then checkpoint() end
  end
  defaults.players[s]=constants(ps,{input=true},checkpoint);defaults.inputs[s]=constants(ins,nil,checkpoint)
 end
 local projected={}
 for i,f in ipairs(frames) do
  if checkpoint then checkpoint() end
  local row=copy(f,defaults.frame);forced[row]='object'
  for _,s in ipairs({'p1','p2'}) do
   if type(f[s])=='table' and shape(f[s])=='object' then
    local p=copy(f[s],defaults.players[s]);forced[p]='object'
    if type(p.input)=='table' and shape(p.input)=='object' then
     p.input=copy(p.input,defaults.inputs[s]);forced[p.input]='object'
    end
    row[s]=p
   end
  end
  projected[i]=row
 end
 local body=copy(data,{meta=true});forced[body]='object'
 if #frames>0 then body.frames=projected;forced[projected]='array' end
 local schemas,schema_ids,records,intern,groups={},{},{},{},{}
 local recent_schemas={}
 local function schema_for(obj,count)
  local candidates=recent_schemas[count]
  if not candidates then candidates={};recent_schemas[count]=candidates end
  local first=next(obj) or false
  local sid=candidates[first]
  -- The cache narrows the search. Equal counts and membership prove equal key sets.
  if sid~=nil then
   local fields=schemas[sid+1]
   local matches=true
   for _,k in ipairs(fields) do if obj[k]==nil then matches=false;break end end
   if matches then return sid,fields end
  end
  local fields=sorted_fields(obj)
  local signature=fields_key(fields)
  sid=schema_ids[signature]
  if sid==nil then
   sid=#schemas;schemas[sid+1]=fields;schema_ids[signature]=sid;groups[sid+1]={}
  end
  candidates[first]=sid
  return sid,fields
 end
 local active={}
 local function value_key(v)
  if type(v)=='table' then return 'r'..v[1] end
  return key(v)
 end
 local function same_encoded(a,b)
  if type(a)=='table' then return type(b)=='table' and a[1]==b[1] end
  return same(a,b)
 end
 local function encode(v,depth)
  if primitive(v) then return v end -- The enclosing record's signature validates scalars.
  if type(v)~='table' then return {-1} end -- native JSON writes unsupported values as null
  if checkpoint then checkpoint() end
  assert(depth<128 and not active[v],'cyclic or excessive JSON depth');active[v]=true
  local kind=shape(v)
  if kind=='null' then active[v]=nil;return {-1} end
  local sid,row=-1,{-1}
  if kind=='array' then
   for i,x in ipairs(v) do
    row[i+1]=encode(x,depth+1)
    if checkpoint and i%256==0 then checkpoint() end
   end
  else
   local obj,count=object(v)
   local fields
   sid,fields=schema_for(obj,count)
   row[1]=sid
   for i,k in ipairs(fields) do row[i+1]=encode(obj[k],depth+1) end
  end
  active[v]=nil
  local sig={tostring(sid)}
  for i=2,#row do
   local s=value_key(row[i]);sig[i]=#s..':'..s
   if checkpoint and i%256==0 then checkpoint() end
  end
  local signature=table.concat(sig,'|');local id=intern[signature]
  if id==nil then
   id=#records
   records[id+1]=row;intern[signature]=id
   if sid>=0 then groups[sid+1][#groups[sid+1]+1]=id+1 end
  end
  return {id}
 end
 local payload=encode(body,0);local schema_meta={}
 for si,fields in ipairs(schemas) do
  local indices=groups[si];local first=records[indices[1]];local fixed={};local cols,cv={},{}
  for j,k in ipairs(fields) do
   local equal=true
   for n=2,#indices do
    if not same_encoded(first[j+1],records[indices[n]][j+1]) then equal=false;break end
    if checkpoint and n%256==0 then checkpoint() end
   end
   if equal then fixed[j]=true;cv[k]=first[j+1] else cols[#cols+1]=k end
  end
  schema_meta[si]={fields=cols,constants=cv}
  for _,ri in ipairs(indices) do
   if checkpoint then checkpoint() end
   local old=records[ri];local row={old[1]}
   for j=1,#fields do if not fixed[j] then row[#row+1]=old[j+1] end end
   records[ri]=row
  end
 end
 -- Verify the encoded graph against every projected observation. This catches
 -- interning/schema errors without making another full expanded capture buffer.
 local field_counts={}
 local function verify(v,encoded,depth)
  assert(depth<128,'verification depth')
  if primitive(v) then assert(same(v,encoded),'scalar mismatch');return end
  if checkpoint then checkpoint() end
  assert(type(encoded)=='table' and #encoded==1,'missing reference')
  local kind=type(v)=='table' and shape(v) or 'null'
  if kind=='null' then assert(encoded[1]==-1,'null mismatch');return end
  local row=assert(records[encoded[1]+1],'invalid reference')
  if kind=='array' then
   assert(row[1]==-1 and #row==#v+1,'array mismatch')
   for i,x in ipairs(v) do
    verify(x,row[i+1],depth+1)
    if checkpoint and i%256==0 then checkpoint() end
   end
  else
   assert(row[1]>=0,'object mismatch')
   local si=row[1]+1
   local sch=assert(schema_meta[si],'invalid schema reference')
   local obj,count=object(v)
   -- A matching count and the presence of every distinct schema field rule out extra keys.
   assert(count==field_counts[si] and #row==#sch.fields+1,'object field count mismatch')
   for k,x in pairs(sch.constants) do assert(obj[k]~=nil,'missing constant');verify(obj[k],x,depth+1) end
   for i,k in ipairs(sch.fields) do assert(obj[k]~=nil,'missing field');verify(obj[k],row[i+1],depth+1) end
  end
 end
 if checkpoint then checkpoint('Verifying') end
 local verify_started=timings and os.clock()
 for si,sch in ipairs(schema_meta) do
  local seen,count={},0
  for k in pairs(sch.constants) do seen[k]=true;count=count+1 end
  for _,k in ipairs(sch.fields) do
   assert(not seen[k],'duplicate schema field')
   seen[k]=true;count=count+1
  end
  field_counts[si]=count
 end
 verify(body,payload,0)
 if timings then
  timings.encode=verify_started-encode_started
  timings.verify=os.clock()-verify_started
 end
 return {storage_format=M.format,meta=data.meta,storage_metadata={defaults=defaults,
  meta_present=data.meta~=nil,null_reference=-1,schemas=schema_meta,
  default_scope='observed constants in this file only',reference_encoding='[record_index]; [-1] is JSON null',
  writer={version=M.version,native_empty_table_json=empty_json,verified=true}},records=records,payload=payload}
end

-- Assemble the document in bounded native JSON calls before opening the file.
function M.write_sliced(path,data,checkpoint)
 local rows_per_batch,bytes_per_write=64,65536
 local chunks,parts,bytes={},{},0
 local function flush()
  if bytes==0 then return end
  chunks[#chunks+1]=table.concat(parts)
  parts={};bytes=0
 end
 local function append(value)
  parts[#parts+1]=value;bytes=bytes+#value
  if bytes>=bytes_per_write then flush() end
  checkpoint()
 end
 local function json_text(value)
  local text=json.dump_string(value,-1)
  assert(type(text)=='string' and #text>0,'JSON serialization failed')
  return text
 end
 local function write_array(values,split_long_rows)
  local count=#values
  if count==0 then append(json_text(values));return end
  append('[')
  local first=1
  while first<=count do
   local last=math.min(first+rows_per_batch-1,count)
   if split_long_rows then
    for i=first,last do
     if #values[i]>rows_per_batch then last=i-1;break end
    end
   end
   if first>1 then append(',') end
   if last<first then
    -- A compact record can contain a whole list of frame or event references.
    write_array(values[first],false)
    last=first
   else
    local text=json_text(table.move(values,first,last,1,{}))
    assert(text:sub(1,1)=='[' and text:sub(-1)==']','JSON array batch expected')
    append(text:sub(2,-2))
   end
   first=last+1
  end
  append(']')
 end
 local function write_object(obj,root)
  if next(obj)==nil then append(json_text(obj));return end
  append('{')
  local first=true
  for key,value in pairs(obj) do
   if not first then append(',') end
   first=false
   append(json_text(key)..':')
   if root and key=='records' then write_array(value,true)
   elseif (root and key=='frames') or (not root and key=='events') then write_array(value,false)
   elseif root and key=='runtime_facts' then write_object(value,false)
   else append(json_text(value)) end
  end
  append('}')
 end
 write_object(data,true)
 flush()

 local file=assert(io.open(path,'wb'))
 local ok,err=pcall(function()
  for _,chunk in ipairs(chunks) do
   assert(file:write(chunk))
   checkpoint()
  end
 end)
 local closed,close_error=file:close()
 if not ok then error(err,0) end
 assert(closed,close_error)
 return true
end
return M
