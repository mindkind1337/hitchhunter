-- test: things that block the server thread, each with a known size
local function busy(ms) local t = os.nanotime() while os.nanotime() - t < ms * 1000000 do end end

-- a thread that blocks 250 ms every 4 s (line 5 = the thread's function)
CreateThread(function()
    Wait(3000)
    while true do
        busy(250)
        Wait(4000)
    end
end)

AddEventHandler('hh_lua_a:busy', function(ms) busy(ms or 200) end)

exports('heavy', function(ms) busy(ms or 150) return 'done', ms end)

RegisterCommand('hhbusy', function(src, args) busy(tonumber(args[1]) or 180) end, false)

-- blocking file write (io span)
AddEventHandler('hh_lua_a:save', function()
    SaveResourceFile(GetCurrentResourceName(), 'big.txt', string.rep('x', 40 * 1024 * 1024), -1)
end)

-- sends: a big broadcast every 2 s, state bag writes
CreateThread(function()
    local payload = string.rep('y', 20000)
    while true do
        Wait(2000)
        TriggerClientEvent('hh_lua_a:big', -1, payload)
        TriggerLatentClientEvent('hh_lua_a:latent', -1, 100000, payload)
        GlobalState.hh_counter = (GlobalState.hh_counter or 0) + 1
    end
end)
