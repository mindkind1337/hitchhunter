-- hitchhunter: the part that runs INSIDE every other resource (server side only).
--
-- tools/inject.py puts one line first in a resource's fxmanifest.lua:
--     shared_script '@hitchhunter/inject/server.lua' -- hitchhunter
-- (server_script for resources without client Lua). This file then measures how long that resource keeps the
-- server thread busy and what it sends, and reports to the hitchhunter resource. It changes nothing in what the
-- resource's code does: same arguments, same return values, same errors.
--
-- No FXServer file is modified (citizen/scripting/lua/scheduler.lua, v8/main.js stay stock): this file replaces
-- functions in THIS resource's own Lua runtime only, in memory, before the resource's own scripts load. scheduler.lua
-- runs every event handler and every ref call (exports, callbacks, commands, state bag handlers) through
-- Citizen.CreateThreadNow(fn, name), looked up in the Citizen table each time: replacing that one function here is what
-- makes every handler of this resource timed. The full list of replaced functions: README.md, "What is hooked".
--
-- What is measured:
--   * CPU time of every event handler, callback / export call (FiveM "ref calls"), thread and timeout, cut into
--     slices at each Wait / Await (only the time the code really runs counts, never the time it waits).
--     Time spent in a nested handler of the same resource is not counted twice.
--   * Sends: TriggerClientEvent / TriggerLatentClientEvent (bytes x players), TriggerEvent (count).
--   * State bag writes (SetStateBagValue: entity / player / global bags, bytes).
--   * Entity natives: CreateVehicle, CreatePed, CreateObject, DeleteEntity, routing buckets...
--   * Slow blocking calls inside the code: LoadResourceFile, SaveResourceFile, io.open, json.encode / decode.
-- A slice of at least `hitchhunter_span_ms` ms (default 5) is sent to hitchhunter at once (that is what a hitch
-- report is made of); everything else stays in counters here until hitchhunter asks for them.
--
-- Kill switch: `set hitchhunter_inject 0` in server.cfg makes this file do nothing (for resources that start after).

if not IsDuplicityVersion() then return end -- shared_script: the client copy does nothing
if rawget(_G, '__hitchhunter') then return end -- included twice

local HH = (debug.getinfo(1, 'S').source or ''):match('^@@?([^/]+)/') or 'hitchhunter'
local RES = GetCurrentResourceName()
if RES == HH or GetConvarInt('hitchhunter_inject', 1) == 0 then return end
rawset(_G, '__hitchhunter', true)

local VERSION = 1
local type, pairs, next, select, pcall, error, rawget = type, pairs, next, select, pcall, error, rawget
local tostring, tonumber = tostring, tonumber
local co_running, co_status = coroutine.running, coroutine.status
local debug_getinfo = debug.getinfo
local msgpack_pack_args = msgpack.pack_args
local rawTrigger = TriggerEvent
local GetResourceState = GetResourceState

local nanotime = os.nanotime
local now = nanotime or function() return GetGameTimer() * 1000000 end
local MS = 1000000

local spanNs = math.max(1, GetConvarInt('hitchhunter_span_ms', 5)) * MS
local MAX_KEYS = 3000 -- per table; anything past it is counted under "other" (resources that make a new event name per request)

local EV_SPAN, EV_HELLO, EV_REPORT = HH .. ':span', HH .. ':hello', HH .. ':report'

-- every function this file replaced in this resource's runtime, sent to hitchhunter (`hh hooks <resource>`)
local hooks = {}
local function hooked(name) hooks[#hooks + 1] = name end

-- [key] = { calls, cpu ns, max slice ns, slices }
local cpu, cpuKeys = {}, 0
-- [event] = { sends, bytes, bytes x players, latent sends }
local sent, sentKeys = {}, 0
-- [kind:key] = { writes, bytes }
local bags, bagKeys = {}, 0
-- [native] = count
local ents = {}
-- [what] = { calls, ns, max ns }
local io_ = {}
local localEvents, localEventCount = {}, 0

local function cpuStat(key)
	local s = cpu[key]
	if s then return s end
	if cpuKeys >= MAX_KEYS then
		key = 'other'
		s = cpu[key]
		if s then return s end
	end
	s = { 0, 0, 0, 0 }
	cpu[key] = s
	cpuKeys = cpuKeys + 1
	return s
end

-- ------------------------------------------------------------------------------------------------------------------
-- spans: slices long enough to matter for a hitch go to hitchhunter right away (at most 40 per second)
local spanBudget, spanSecond = 40, 0
local hhUp, hhChecked = false, 0

local function pushSpan(key, t0, d, kind)
	local sec = t0 // 1000000000
	if sec ~= spanSecond then spanSecond, spanBudget = sec, 40 end
	if spanBudget <= 0 then return end
	spanBudget = spanBudget - 1
	if sec ~= hhChecked then
		hhChecked = sec
		hhUp = GetResourceState(HH) == 'started'
	end
	if hhUp then rawTrigger(EV_SPAN, RES, key, t0, d, kind or 'cpu') end
end

-- ------------------------------------------------------------------------------------------------------------------
-- running records. Code in one resource runs strictly nested (a handler that triggers an event of the same resource
-- waits for it), so a stack gives each record its own time only: the record below is paused while one above runs.
local stack, depth = {}, 0
local active = setmetatable({}, { __mode = 'k' }) -- coroutine -> its record while it is suspended in Wait / Await

-- two measures per record:
--   own time (s[2]): paused while this code calls into other code (a nested handler of this resource, another
--     resource's event or export): what `hh top` adds up, never counted twice
--   blocks (s[3] longest, s[4] count): from the moment the code starts / resumes until it ends or waits, calls
--     included = how long it held the server thread in one go. A block of spanNs or more is sent as a span
--     (the collector splits own time across resources by looking at which spans contain which)
local function pause(rec, t)
	local d = t - rec.t0
	rec.t0 = t
	if d > 0 then rec.s[2] = rec.s[2] + d end
end

local function blockEnd(rec, t)
	local d = t - rec.b0
	local s = rec.s
	s[4] = s[4] + 1
	if d > s[3] then s[3] = d end
	if d >= spanNs then pushSpan(rec.key, rec.b0, d) end
end

local function dead(rec)
	return rec.co and co_status(rec.co) == 'dead'
end

local function push(rec, t)
	-- records left by code that threw an error (its coroutine is dead) are dropped, not timed
	while depth > 0 and dead(stack[depth]) do
		stack[depth] = nil
		depth = depth - 1
	end
	if depth > 0 then pause(stack[depth], t) end -- the caller waits for us
	depth = depth + 1
	stack[depth] = rec
	rec.t0 = t
	rec.b0 = t
end

local function pop(rec, t)
	if stack[depth] ~= rec then
		local i = depth
		while i > 0 and stack[i] ~= rec do i = i - 1 end
		if i == 0 then return end -- not on the stack (already popped)
		for j = depth, i + 1, -1 do stack[j] = nil end
		depth = i
	end
	pause(rec, t)
	blockEnd(rec, t)
	stack[depth] = nil
	depth = depth - 1
	if depth > 0 then stack[depth].t0 = t end -- the caller runs again
end

-- around a call that runs other code synchronously (TriggerEvent, another resource's export / callback): the
-- running record's own time stops; its block goes on (it still holds the thread)
local function callOut()
	local rec = stack[depth]
	if rec then pause(rec, now()) end
	return rec
end

local function callBack(rec, ...)
	if rec and stack[depth] == rec then rec.t0 = now() end
	return ...
end

local function leave(rec, ...)
	pop(rec, now())
	active[rec.co] = nil
	return ...
end

local function run(key, fn, ...)
	local s = cpuStat(key)
	s[1] = s[1] + 1
	local rec = { key = key, s = s, t0 = 0, b0 = 0, co = co_running() }
	push(rec, now())
	return leave(rec, fn(...))
end

-- ------------------------------------------------------------------------------------------------------------------
-- labels
local function shortSrc(src)
	src = src:gsub('^@', '')
	if src:sub(1, #RES + 1) == RES .. '/' then src = src:sub(#RES + 2) end
	return (src:gsub('^citizen:/scripting/lua/', ''))
end

local function where(fn)
	local di = debug_getinfo(fn, 'S')
	if not di then return '?' end
	return shortSrc(di.short_src) .. ':' .. tostring(di.linedefined)
end

-- "src:linedefined" -> 'export x' / 'command x' / 'statebag x', so a ref call says what it is
local refNames = {}
local function nameRef(fn, label)
	if type(fn) ~= 'function' then
		local mt = getmetatable(fn)
		fn = mt and mt.__call
		if type(fn) ~= 'function' then return end
	end
	refNames[where(fn)] = label
end

local labelCache, labelCount = {}, 0
local SKIP = {} -- hitchhunter's own events are never timed

local function labelOf(name)
	local l = labelCache[name]
	if l then return l end
	-- 'event NAME [src[a..b]]' / 'ref call [src[a..b]]' (scheduler.lua's thread names)
	local ev, src, a = name:match('^event (.-) %[(.*)%[(%-?%d+)%.%.%-?%d+%]%]$')
	if ev then
		if ev:sub(1, #HH + 1) == HH .. ':' then
			l = SKIP
		else
			l = 'event ' .. ev .. ' ' .. shortSrc(src) .. ':' .. a
		end
	else
		src, a = name:match('^ref call %[(.*)%[(%-?%d+)%.%.%-?%d+%]%]$')
		if src then
			local k = shortSrc(src) .. ':' .. a
			l = refNames[k] or ('callback ' .. k)
		else
			l = name
		end
	end
	if labelCount < MAX_KEYS then
		labelCache[name] = l
		labelCount = labelCount + 1
	end
	return l
end

-- ------------------------------------------------------------------------------------------------------------------
-- threads, events, callbacks
local rawCreateThreadNow = Citizen.CreateThreadNow
local rawCreateThread = Citizen.CreateThread
local rawSetTimeout = Citizen.SetTimeout
local rawWait = Citizen.Wait
local rawAwait = Citizen.Await

-- every event handler and every ref call (exports, callbacks, commands, state bag handlers) of this resource is run
-- by scheduler.lua through Citizen.CreateThreadNow(fn, name): one place sees them all, with their names
Citizen.CreateThreadNow = function(fn, name, ...)
	if type(fn) ~= 'function' then return rawCreateThreadNow(fn, name, ...) end
	local key = type(name) == 'string' and labelOf(name) or ('thread ' .. where(fn))
	if key == SKIP then return rawCreateThreadNow(fn, name, ...) end
	return rawCreateThreadNow(function(...) return run(key, fn, ...) end, name, ...)
end

Citizen.CreateThread = function(fn, ...)
	if type(fn) ~= 'function' then return rawCreateThread(fn, ...) end
	local key = 'thread ' .. where(fn)
	return rawCreateThread(function(...) return run(key, fn, ...) end, ...)
end

Citizen.SetTimeout = function(ms, fn, ...)
	if type(fn) ~= 'function' then return rawSetTimeout(ms, fn, ...) end
	local key = 'timeout ' .. where(fn)
	return rawSetTimeout(ms, function(...) return run(key, fn, ...) end, ...)
end

local function resumed(rec, ...)
	if rec then
		active[rec.co] = nil
		push(rec, now())
	end
	return ...
end

Citizen.Wait = function(...)
	local co = co_running()
	local rec = stack[depth]
	if rec and rec.co == co then
		pop(rec, now())
		active[co] = rec
	else
		rec = nil
	end
	return resumed(rec, rawWait(...))
end

-- Await may throw (a rejected promise): pcall, then throw again from here at level 2, which gives the exact message
-- stock Citizen.Await gives (its own error(..., 2) points at the line that called Await)
Citizen.Await = function(p)
	local co = co_running()
	local rec = stack[depth]
	if rec and rec.co == co then
		pop(rec, now())
		active[co] = rec
	else
		rec = nil
	end
	local ok, v = pcall(rawAwait, p)
	resumed(rec)
	if not ok then error(v, 2) end
	return v
end

CreateThread = Citizen.CreateThread
SetTimeout = Citizen.SetTimeout
Wait = Citizen.Wait
hooked('Citizen.CreateThreadNow')
hooked('Citizen.CreateThread / CreateThread')
hooked('Citizen.SetTimeout / SetTimeout')
hooked('Citizen.Wait / Wait')
hooked('Citizen.Await')

-- names for ref calls
local exportsMeta = getmetatable(exports)
if exportsMeta and type(exportsMeta.__call) == 'function' then
	local rawCall = exportsMeta.__call
	exportsMeta.__call = function(t, name, func, ...)
		pcall(nameRef, func, 'export ' .. tostring(name))
		return rawCall(t, name, func, ...)
	end
	hooked('exports(name, fn)')
end

local rawRegisterCommand = RegisterCommand
RegisterCommand = function(name, handler, ...)
	pcall(nameRef, handler, 'command ' .. tostring(name))
	return rawRegisterCommand(name, handler, ...)
end
hooked('RegisterCommand')

if AddStateBagChangeHandler then
	local rawBagHandler = AddStateBagChangeHandler
	AddStateBagChangeHandler = function(key, filter, handler, ...)
		pcall(nameRef, handler, 'statebag ' .. tostring(key))
		return rawBagHandler(key, filter, handler, ...)
	end
	hooked('AddStateBagChangeHandler')
end

-- ------------------------------------------------------------------------------------------------------------------
-- what the resource sends
local function players(target)
	if target == -1 or target == '-1' then return GetNumPlayerIndices() end
	return 1
end

local function countSend(name, len, target, latent)
	local s = sent[name]
	if not s then
		if sentKeys >= MAX_KEYS then
			name = 'other'
			s = sent[name]
		end
		if not s then
			s = { 0, 0, 0, 0 }
			sent[name] = s
			sentKeys = sentKeys + 1
		end
	end
	s[1] = s[1] + 1
	s[2] = s[2] + len
	s[3] = s[3] + len * players(target)
	if latent then s[4] = s[4] + 1 end
end

if TriggerClientEventInternal then
	local TCEI = TriggerClientEventInternal
	-- same body as scheduler.lua's: the payload is packed once, as before
	TriggerClientEvent = function(eventName, playerId, ...)
		local payload = msgpack_pack_args(...)
		local len = #payload
		pcall(countSend, eventName, len, playerId, false)
		return TCEI(eventName, playerId, payload, len)
	end
	hooked('TriggerClientEvent')
end

if TriggerLatentClientEventInternal then
	local TLCEI = TriggerLatentClientEventInternal
	TriggerLatentClientEvent = function(eventName, playerId, bps, ...)
		local payload = msgpack_pack_args(...)
		local len = #payload
		pcall(countSend, eventName, len, playerId, true)
		return TLCEI(eventName, playerId, payload, len, tonumber(bps))
	end
	hooked('TriggerLatentClientEvent')
end

TriggerEvent = function(eventName, ...)
	local n = localEvents[eventName]
	if n then
		localEvents[eventName] = n + 1
	elseif localEventCount < MAX_KEYS then
		localEvents[eventName] = 1
		localEventCount = localEventCount + 1
	end
	return callBack(callOut(), rawTrigger(eventName, ...))
end
hooked('TriggerEvent')

-- calls into another resource's function (exports, callbacks, ESX objects...) all go through the funcref
-- metatable's __call: one shared metatable per runtime, reached through a funcref made here
do
	local ok, probe = pcall(function() return msgpack.unpack(msgpack.pack(function() end)) end)
	local mt = ok and type(probe) == 'table' and getmetatable(probe)
	if mt and type(mt.__call) == 'function' and rawget(mt, '__ext') then
		local rawCall = mt.__call
		mt.__call = function(ref, ...)
			return callBack(callOut(), rawCall(ref, ...))
		end
		hooked('funcref __call (calls into other resources)')
	end
end

-- state bags: scheduler.lua's bag objects (Entity(x).state, Player(x).state, GlobalState) call this global
if SetStateBagValue then
	local rawSet = SetStateBagValue
	local function countBag(bagName, key, size)
		local kind = type(bagName) == 'string' and (bagName:match('^(%a+)') or bagName) or '?'
		local k = kind .. ':' .. tostring(key)
		local s = bags[k]
		if not s then
			if bagKeys >= MAX_KEYS then
				k = 'other'
				s = bags[k]
			end
			if not s then
				s = { 0, 0 }
				bags[k] = s
				bagKeys = bagKeys + 1
			end
		end
		s[1] = s[1] + 1
		s[2] = s[2] + (tonumber(size) or 0)
	end
	SetStateBagValue = function(bagName, key, data, size, replicated, ...)
		pcall(countBag, bagName, key, size)
		return rawSet(bagName, key, data, size, replicated, ...)
	end
	hooked('SetStateBagValue')
end

-- entity natives: load on the sync thread (creation, deletion, routing buckets)
for _, name in ipairs({ 'CreateVehicle', 'CreateVehicleServerSetter', 'CreatePed', 'CreatePedInsideVehicle',
	'CreateObject', 'CreateObjectNoOffset', 'DeleteEntity', 'SetEntityRoutingBucket', 'SetPlayerRoutingBucket',
	'SetEntityDistanceCullingRadius', 'SetEntityOrphanMode' }) do
	local raw = _G[name]
	if type(raw) == 'function' then
		ents[name] = 0
		_G[name] = function(...)
			ents[name] = ents[name] + 1
			return raw(...)
		end
		hooked(name)
	end
end

-- blocking calls: timed one by one; a slow one becomes a span of its own ('io SaveResourceFile x'), shown inside
-- the handler that made it
local function ioStat(what)
	local s = io_[what]
	if not s then
		s = { 0, 0, 0 }
		io_[what] = s
	end
	return s
end

local function ioDone(what, detail, t0, ...)
	local d = now() - t0
	local s = io_[what]
	s[1] = s[1] + 1
	s[2] = s[2] + d
	if d > s[3] then s[3] = d end
	if d >= spanNs then pushSpan('io ' .. what .. (detail and (' ' .. tostring(detail)) or ''), t0, d, 'io') end
	return ...
end

local function timed(what, raw, detailArg)
	ioStat(what)
	return function(...)
		local detail = detailArg and select(detailArg, ...) or nil
		return ioDone(what, detail, now(), raw(...))
	end
end

if LoadResourceFile then LoadResourceFile = timed('LoadResourceFile', LoadResourceFile, 2) hooked('LoadResourceFile') end
if SaveResourceFile then SaveResourceFile = timed('SaveResourceFile', SaveResourceFile, 2) hooked('SaveResourceFile') end
if io and io.open then io.open = timed('io.open', io.open, 1) hooked('io.open') end
if json and json.encode then json.encode = timed('json.encode', json.encode) hooked('json.encode') end
if json and json.decode then json.decode = timed('json.decode', json.decode) hooked('json.decode') end

-- ------------------------------------------------------------------------------------------------------------------
-- reports to hitchhunter
local startedAt = now()

local function copyTop(t, field, limit)
	-- the `limit` biggest entries of t by field (by value when field is nil; all when limit is nil)
	local list = {}
	for k, v in pairs(t) do list[#list + 1] = { k, v } end
	if limit and #list > limit then
		if field then
			table.sort(list, function(a, b) return a[2][field] > b[2][field] end)
		else
			table.sort(list, function(a, b) return a[2] > b[2] end)
		end
		for i = #list, limit + 1, -1 do list[i] = nil end
	end
	local out = {}
	for i = 1, #list do out[list[i][1]] = list[i][2] end
	return out
end

local function snapshot(limit)
	return {
		since = startedAt,
		at = now(),
		cpu = copyTop(cpu, 2, limit),
		sent = copyTop(sent, 3, limit),
		bags = copyTop(bags, 2, limit),
		ents = ents,
		io = io_,
		events = copyTop(localEvents, nil, limit),
	}
end

local function reset()
	cpu, cpuKeys = {}, 0
	sent, sentKeys = {}, 0
	bags, bagKeys = {}, 0
	for k in pairs(ents) do ents[k] = 0 end
	for _, s in pairs(io_) do s[1], s[2], s[3] = 0, 0, 0 end
	localEvents, localEventCount = {}, 0
	startedAt = now()
	for i = 1, depth do stack[i].s = cpuStat(stack[i].key) end
end

local function onCollect(reqId, limit, doReset)
	rawTrigger(EV_REPORT, reqId, RES, 'lua', snapshot(tonumber(limit)))
	if doReset then reset() end
end
AddEventHandler(HH .. ':collect', onCollect)            -- everybody at once (commands, hitch reports)
AddEventHandler(HH .. ':collect:' .. RES, onCollect)    -- one by one (periodic samples, spread over frames)

AddEventHandler(HH .. ':announce', function()
	rawTrigger(EV_HELLO, RES, 'lua', VERSION, now(), hooks)
end)

rawTrigger(EV_HELLO, RES, 'lua', VERSION, now(), hooks)
