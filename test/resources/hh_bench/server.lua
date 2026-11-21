-- overhead: the same loops with and without the wrapper (hitchhunter_inject 0)
local function bench(name, n, fn)
    local t = os.nanotime()
    for i = 1, n do fn(i) end
    print(('BENCH %-28s %8.3f us/op'):format(name, (os.nanotime() - t) / n / 1000))
end
local hits = 0
AddEventHandler('hh_bench:ev', function(a) hits = hits + a end)
exports('noop', function(a) return a end)
CreateThread(function()
    Wait(9000)
    for round = 1, 2 do
        bench('TriggerEvent local handler', 20000, function(i) TriggerEvent('hh_bench:ev', 1) end)
        bench('export call (same resource)', 20000, function(i) exports.hh_bench:noop(i) end)
        bench('TriggerClientEvent -1 (0 pl)', 20000, function(i) TriggerClientEvent('hh_bench:x', -1, i, 'abc') end)
        bench('json.encode small', 100000, function(i) json.encode({ i, 'a' }) end)
        bench('CreateThreadNow empty', 20000, function(i) Citizen.CreateThreadNow(function() end) end)
        local t = os.nanotime()
        local done = 0
        for i = 1, 200 do
            CreateThread(function() for j = 1, 20 do Wait(0) end done = done + 1 end)
        end
        while done < 200 do Wait(0) end
        print(('BENCH %-28s %8.1f ms total (200 threads x 20 Wait)'):format('threads+Wait', (os.nanotime() - t) / 1e6))
    end
end)
