-- hitchhunter test: `hhx <test> [args]` in the server console makes one kind of hitch on purpose, so you can see
-- what hitchhunter says about it. NEVER on a server with players: it freezes the server.
--   hhx event <ms>          an event handler busy <ms>
--   hhx thread <ms>         a thread busy <ms>
--   hhx export <ms>         an export busy <ms>, called through a ref call
--   hhx nested <ms>         an event handler that calls the export (own time vs the export's time)
--   hhx io <MB>             SaveResourceFile of <MB> megabytes
--   hhx json <n>            json.encode + decode of <n> small tables
--   hhx js <kind> <ms>      a JS freeze: kind = event | timer | tick | await
--   hhx entities <n>        create <n> networked objects at once, delete them 10 s later (sync thread context)
--   hhx bags <n> <bytes>    <n> GlobalState writes of <bytes> each
--   hhx send <n> <bytes>    <n> TriggerClientEvent(-1) of <bytes> each
--   hhx aliases             threads / timeouts started with and without `Citizen.`
--   hhx natives <n>         entity natives by name and by hash (Lua, JS), state bags from JS: all counted
--   hhx emit <event> <ms>   TriggerEvent(<event>, <ms>) (a handler of another resource)
--   hhx all                 everything above, 6 s apart
local RES = GetCurrentResourceName()

local function busy(ms)
    local t = os.nanotime()
    while os.nanotime() - t < ms * 1000000 do end
end

AddEventHandler('hh_trigger:busy', function(ms) busy(ms) end)
exports('busy', function(ms) busy(ms) return ms end)
AddEventHandler('hh_trigger:nested', function(ms)
    busy(20)
    exports[RES]:busy(ms)
end)

local spawned = {}
local tests = {}
tests.event = function(ms) TriggerEvent('hh_trigger:busy', tonumber(ms) or 300) end
tests.thread = function(ms) CreateThread(function() busy(tonumber(ms) or 250) end) end
tests.export = function(ms) exports[RES]:busy(tonumber(ms) or 200) end
tests.nested = function(ms) TriggerEvent('hh_trigger:nested', tonumber(ms) or 200) end
tests.io = function(mb)
    SaveResourceFile(RES, 'big.tmp', string.rep('x', (tonumber(mb) or 60) * 1048576), -1)
end
tests.json = function(n)
    local t = {}
    for i = 1, tonumber(n) or 300000 do t[i] = { i, 'abc', { x = i } } end
    json.decode(json.encode(t))
end
tests.js = function(kind, ms) TriggerEvent('hh_trigger:js', kind or 'timer', tonumber(ms) or 200) end
tests.entities = function(n)
    for i = 1, tonumber(n) or 2000 do
        spawned[#spawned + 1] = CreateObjectNoOffset(GetHashKey("prop_barrier_work05"), 200.0 + (i % 50), 200.0 + (i // 50), 70.0, true, true, false)
    end
    SetTimeout(10000, function()
        for _, e in ipairs(spawned) do if DoesEntityExist(e) then DeleteEntity(e) end end
        spawned = {}
    end)
end
tests.bags = function(n, bytes)
    local v = string.rep('z', tonumber(bytes) or 4000)
    for i = 1, tonumber(n) or 500 do GlobalState['hh_trigger_' .. (i % 50)] = v .. i end
end
tests.send = function(n, bytes)
    local p = string.rep('y', tonumber(bytes) or 50000)
    for _ = 1, tonumber(n) or 200 do TriggerClientEvent('hh_trigger:x', -1, p) end
end
-- the same functions with and without `Citizen.`: each must show as its own thread / timeout line
tests.aliases = function()
    Citizen.CreateThread(function() busy(110) end)
    CreateThread(function() busy(120) end)
    Citizen.SetTimeout(0, function() busy(130) end)
    SetTimeout(0, function() busy(140) end)
    CreateThread(function() Citizen.Wait(0) busy(150) Wait(0) busy(160) end)
end
-- entity natives by name and by hash (Citizen.InvokeNative), in Lua; by name in JS; state bags from JS
tests.natives = function(n)
    n = tonumber(n) or 20
    local model = GetHashKey('prop_barrier_work05')
    local made = {}
    for i = 1, n do
        made[#made + 1] = CreateObjectNoOffset(model, 400.0 + i, 400.0, 70.0, true, true, false)
        made[#made + 1] = Citizen.InvokeNative(0x58040420, model, 400.0 + i, 410.0, 70.0, true, true, false,
            Citizen.ReturnResultAnyway(), Citizen.ResultAsInteger())
    end
    TriggerEvent('hh_trigger:jsnatives', n)
    SetTimeout(2000, function()
        for i, e in ipairs(made) do
            if i % 2 == 0 then Citizen.InvokeNative(0xfaa3d236, e) else DeleteEntity(e) end
        end
    end)
end
-- any local event, e.g. a handler of another test resource: hhx emit hh_sharedjs:busy 200
tests.emit = function(name, ms) TriggerEvent(name, tonumber(ms) or 200) end
tests.all = function()
    CreateThread(function()
        for _, step in ipairs({ { 'event', 300 }, { 'thread', 250 }, { 'export', 200 }, { 'nested', 200 }, { 'io', 60 },
            { 'json', 300000 }, { 'js', 'event', 200 }, { 'js', 'timer', 220 }, { 'js', 'tick', 180 },
            { 'js', 'await', 160 }, { 'entities', 2000 }, { 'bags', 500, 4000 }, { 'send', 200, 50000 } }) do
            print(('[hh_trigger] %s %s %s'):format(step[1], tostring(step[2] or ''), tostring(step[3] or '')))
            tests[step[1]](step[2], step[3])
            Wait(6000)
        end
        print('[hh_trigger] all done')
    end)
end

RegisterCommand('hhx', function(src, args)
    local fn = tests[args[1] or '']
    if not fn then return print('[hh_trigger] hhx event|thread|export|nested|io|json|js|entities|bags|send|aliases|natives|emit|all [args]') end
    print('[hh_trigger] ' .. table.concat(args, ' '))
    fn(args[2], args[3])
end, true)
