-- test: entity natives + fake network / sync warnings (the bench has no players, so the real ones never come)
CreateThread(function()
    Wait(31000)
    for i = 1, 40 do
        CreateObjectNoOffset(`prop_barrier_work05`, 100.0 + i, 100.0, 70.0, true, true, false)
    end
    Wait(2000)
    print('network thread hitch warning: timer interval of 300 milliseconds')
    print('sync thread hitch warning: timer interval of 280 milliseconds')
end)
