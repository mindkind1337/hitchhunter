-- test: cross-resource nesting. Every 5 s (offset) this resource's handler calls hh_lua_a's export (150 ms) and
-- triggers hh_lua_a's busy event (200 ms); its own part is 20 ms
local function busy(ms) local t = os.nanotime() while os.nanotime() - t < ms * 1000000 do end end

AddEventHandler('hh_lua_b:go', function()
    busy(20)
    exports.hh_lua_a:heavy(150)
    TriggerEvent('hh_lua_a:busy', 200)
end)

-- same-resource nesting: outer 30 ms of its own, inner 50 ms
AddEventHandler('hh_lua_b:inner', function() busy(50) end)
AddEventHandler('hh_lua_b:outer', function()
    busy(15)
    TriggerEvent('hh_lua_b:inner')
    busy(15)
end)

CreateThread(function()
    Wait(5000)
    while true do
        TriggerEvent('hh_lua_b:go')
        Wait(1500)
        TriggerEvent('hh_lua_b:outer')
        Wait(1500)
        TriggerEvent('hh_lua_a:save')
        Wait(6000)
    end
end)
