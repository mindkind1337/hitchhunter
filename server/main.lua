-- hitchhunter collector: detects hitches, gathers what the wrapped resources (inject/server.lua, inject/server.js)
-- were doing at that moment, and says which resource / handler / thread caused it.
--
-- Three kinds of hitch, the three warnings FXServer prints:
--   server  = the main thread (all resource scripts run there) stalled. Seen two ways: this resource's own frame
--             timer (from Config.frameHitchMs, also catches the ones FiveM never prints) and the console warning.
--   network = the network thread stalled (console warning only).
--   sync    = the OneSync sync thread stalled (console warning only).

local HH = GetCurrentResourceName()
local nanotime = os.nanotime
local now = nanotime or function() return GetGameTimer() * 1000000 end
local MS = 1000000
local SEC = 1000 * MS
local fmt = string.format

local cfg = Config

-- ------------------------------------------------------------------------------------------------------------------
-- wrapped runtimes
local runtimes = {} -- [res] = { lua = { v, seen }, js = { v, seen, offset } }

AddEventHandler(HH .. ':hello', function(res, kind, version, theirNow, hooks)
    if type(res) ~= 'string' or (kind ~= 'lua' and kind ~= 'js') then return end
    local r = runtimes[res]
    if not r then
        r = {}
        runtimes[res] = r
    end
    local e = { v = version, seen = os.time(), hooks = type(hooks) == 'table' and hooks or {} }
    -- JS reads another clock (process.hrtime): the hello is delivered while the sender waits, so the difference
    -- between both clocks right now is the offset to put its times on ours
    if kind == 'js' and type(theirNow) == 'number' then e.offset = now() - theirNow end
    r[kind] = e
end)

local function offsetOf(res, kind)
    local r = runtimes[res]
    local e = r and r[kind]
    return e and e.offset or 0
end

-- ------------------------------------------------------------------------------------------------------------------
-- frame timeline: when this resource's frame thread ran (a span that contains one of these instants was not one
-- continuous block of the main thread: it was inflated by a yield the wrapper did not see)
local TICKS = 6000
local ticks, tickN = {}, 0

local function tickAdd(t)
    tickN = tickN + 1
    ticks[(tickN - 1) % TICKS + 1] = t
end

-- normal frame gaps (the time between two frames when nothing is wrong), for "outside scripts"
local GAPS = 600
local gaps, gapN = {}, 0
local function gapAdd(d)
    gapN = gapN + 1
    gaps[(gapN - 1) % GAPS + 1] = d
end
local function gapStats()
    local list = {}
    for i = 1, math.min(gapN, GAPS) do list[i] = gaps[i] end
    table.sort(list)
    local n = #list
    if n == 0 then return nil end
    return { median = list[(n + 1) // 2], p95 = list[math.max(1, math.floor(n * 0.95))], max = list[n], n = n }
end

local function tickedWithin(a, b)
    local i, stop = tickN, math.max(1, tickN - TICKS + 1)
    while i >= stop do
        local t = ticks[(i - 1) % TICKS + 1]
        if t <= a then return false end
        if t < b then return true end
        i = i - 1
    end
    return false
end

-- ------------------------------------------------------------------------------------------------------------------
-- spans sent by the wrapped resources
local SPANS = 8000
local spans, spanN = {}, 0

AddEventHandler(HH .. ':span', function(res, key, t0, d, kind)
    if type(t0) ~= 'number' or type(d) ~= 'number' then return end
    kind = kind == 'io' and 'io' or (kind == 'js' and 'js' or 'cpu')
    t0 = t0 + offsetOf(res, kind == 'js' and 'js' or 'lua')
    spanN = spanN + 1
    spans[(spanN - 1) % SPANS + 1] = { res = res, key = key, t0 = t0, t1 = t0 + d, d = d, kind = kind }
end)

-- resource starts: loading a resource's scripts runs outside any handler (its top-level code), so it is timed here,
-- from onResourceStarting to onResourceStart (a live `restart x` / `ensure x` is a classic hitch)
local SPAN_NS = math.max(1, GetConvarInt('hitchhunter_span_ms', 5)) * MS
local startingAt, startTimes = {}, {}
AddEventHandler('onResourceStarting', function(res)
    if type(res) == 'string' then startingAt[res] = now() end
end)
AddEventHandler('onResourceStart', function(res)
    local t0 = type(res) == 'string' and startingAt[res]
    if not t0 then return end
    startingAt[res] = nil
    local t = now()
    local d = t - t0
    startTimes[res] = d
    if d >= SPAN_NS then
        spanN = spanN + 1
        spans[(spanN - 1) % SPANS + 1] = { res = res, key = 'resource start (loading its scripts)', t0 = t0, t1 = t, d = d, kind = 'start' }
    end
end)

local function spansIn(from, to)
    local out = {}
    local i, stop = spanN, math.max(1, spanN - SPANS + 1)
    while i >= stop do
        local s = spans[(i - 1) % SPANS + 1]
        if s.t1 >= from - 2 * SEC and s.t0 <= to then
            if s.t1 > from and s.t0 < to then out[#out + 1] = s end
        elseif s.t1 < from - 10 * SEC then
            break
        end
        i = i - 1
    end
    return out
end

-- ------------------------------------------------------------------------------------------------------------------
-- counters: periodic samples (spread over frames) so a network / sync hitch can say what changed just before it
local reqSeq = 0
local pending = {}   -- [reqId] = { res -> snapshot }
local lastSample, prevSample = nil, nil -- { at, res -> snapshot }

AddEventHandler(HH .. ':report', function(reqId, res, kind, snap)
    local p = pending[reqId]
    if not p or type(res) ~= 'string' or type(snap) ~= 'table' then return end
    local key = kind == 'js' and (res .. ' (js)') or res
    p[key] = snap
    -- the report is delivered while the sender waits: re-measure the JS clock offset. On Linux os.nanotime follows the
    -- wall clock (std::chrono::high_resolution_clock, LuaOS.cpp) and process.hrtime does not, so a clock adjustment
    -- (NTP) would move JS spans; on Windows both are QueryPerformanceCounter based
    if kind == 'js' and type(snap.at) == 'number' then
        local r = runtimes[res]
        if r and r.js then r.js.offset = now() - snap.at end
    end
end)

local function collectAll(limit, doReset)
    reqSeq = reqSeq + 1
    local id = reqSeq
    pending[id] = {}
    TriggerEvent(HH .. ':collect', id, limit, doReset) -- every wrapped runtime answers right away (same frame)
    local got = pending[id]
    pending[id] = nil
    return got
end

-- ------------------------------------------------------------------------------------------------------------------
-- every entity the server hears about, whoever made it (a script, or a player's game: ambient peds and cars,
-- spawned props, vehicles). The sync thread's work grows with them: a flood of creations is the usual cause of a sync
-- hitch, and most never go through a server script. Kept per second for the last 2 minutes.
local ENT_SECS = 120
local entSec = {}
local ENTITY_TYPES = { [1] = 'ped', [2] = 'vehicle', [3] = 'object' }

local function entBucket()
    local sec = os.time()
    local i = sec % ENT_SECS
    local b = entSec[i]
    if not b or b.sec ~= sec then
        b = { sec = sec, created = 0, removed = 0, kinds = {}, owners = {} }
        entSec[i] = b
    end
    return b
end

AddEventHandler('entityCreated', function(ent)
    local b = entBucket()
    b.created = b.created + 1
    local ok, kind, owner = pcall(function()
        local ty = ENTITY_TYPES[GetEntityType(ent)] or 'other'
        local pop = GetEntityPopulationType(ent)
        -- population type 7 = made on purpose (a script, a player spawning it); the others = GTA's ambient population
        local k = ty .. (pop == 7 and ' (script / spawned)' or ' (ambient)')
        local o = NetworkGetFirstEntityOwner and NetworkGetFirstEntityOwner(ent) or NetworkGetEntityOwner(ent)
        return k, o
    end)
    if ok then
        b.kinds[kind] = (b.kinds[kind] or 0) + 1
        local key = (owner and owner > 0) and tostring(owner) or 'server'
        b.owners[key] = (b.owners[key] or 0) + 1
    end
end)

-- entityCreated only fires for entities a player's game made (ServerGameState.cpp, after entityCreating); the ones a
-- server script makes (CreateVehicle, CreateObject...) fire serverEntityCreated instead
AddEventHandler('serverEntityCreated', function(ent)
    local b = entBucket()
    b.created = b.created + 1
    local ok, kind = pcall(function() return (ENTITY_TYPES[GetEntityType(ent)] or 'other') .. ' (server script)' end)
    kind = ok and kind or 'other (server script)'
    b.kinds[kind] = (b.kinds[kind] or 0) + 1
    b.owners.server = (b.owners.server or 0) + 1
end)

AddEventHandler('entityRemoved', function()
    local b = entBucket()
    b.removed = b.removed + 1
end)

-- the last `seconds` seconds: totals, by kind, by player who created them (name + server id)
local function recentEntities(seconds)
    local now_ = os.time()
    local out = { seconds = seconds, created = 0, removed = 0, kinds = {}, owners = {} }
    local kinds, owners = {}, {}
    for s = now_ - seconds + 1, now_ do
        local b = entSec[s % ENT_SECS]
        if b and b.sec == s then
            out.created = out.created + b.created
            out.removed = out.removed + b.removed
            for k, n in pairs(b.kinds) do kinds[k] = (kinds[k] or 0) + n end
            for k, n in pairs(b.owners) do owners[k] = (owners[k] or 0) + n end
        end
    end
    for k, n in pairs(kinds) do out.kinds[#out.kinds + 1] = { key = k, value = n } end
    for k, n in pairs(owners) do
        local label = k
        if k ~= 'server' then label = (GetPlayerName(k) or '?') .. ' [' .. k .. ']' end
        out.owners[#out.owners + 1] = { key = label, value = n }
    end
    table.sort(out.kinds, function(a, b) return a.value > b.value end)
    table.sort(out.owners, function(a, b) return a.value > b.value end)
    for i = #out.owners, 6, -1 do out.owners[i] = nil end
    return out
end

-- ------------------------------------------------------------------------------------------------------------------
-- host (Linux): load, CPU steal / iowait, this process's CPU; from server/host.js
local function host()
    local ok, h = pcall(function() return exports[HH]:host() end)
    return ok and type(h) == 'table' and h or nil
end

-- ------------------------------------------------------------------------------------------------------------------
-- reports
local reports, reportSeq = {}, 0
local openList = {} -- incidents still gathering (finalized Config.reportDelayMs after their last news)
local discordSent = {}

local KINDS = { 'server', 'network', 'sync' }

local function ms(ns) return math.floor(ns / MS + 0.5) end

local function union(list)
    table.sort(list, function(a, b) return a[1] < b[1] end)
    local total, cs, ce = 0, nil, nil
    for _, iv in ipairs(list) do
        if not cs then
            cs, ce = iv[1], iv[2]
        elseif iv[1] <= ce then
            if iv[2] > ce then ce = iv[2] end
        else
            total = total + (ce - cs)
            cs, ce = iv[1], iv[2]
        end
    end
    if cs then total = total + (ce - cs) end
    return total
end

-- spans in the window -> list with each span's parent (the smallest span containing it) and own time
local function analyse(from, to)
    local list = {}
    for _, s in ipairs(spansIn(from, to)) do
        -- a span that contains one of our frame instants was not one block (unseen yield): left out
        if not tickedWithin(s.t0 + 2 * MS, s.t1 - 2 * MS) then
            list[#list + 1] = { res = s.res, key = s.key, t0 = s.t0, t1 = s.t1, d = s.d, kind = s.kind }
        end
    end
    table.sort(list, function(a, b)
        if a.t0 ~= b.t0 then return a.t0 < b.t0 end
        return a.d > b.d
    end)
    -- Lua and JS slices come from two clocks lined up to within a few microseconds: a span counts as inside another
    -- when it is within 2 ms of its edges
    local TOL = 2 * MS
    for i, s in ipairs(list) do
        local best
        for j, p in ipairs(list) do
            if j ~= i and p.t0 <= s.t0 + TOL and p.t1 >= s.t1 - TOL and (p.d > s.d or (p.d == s.d and j < i)) then
                if not best or p.d < best.d then best = p end
            end
        end
        s.parent = best
    end
    for _, s in ipairs(list) do
        local kids = {}
        for _, c in ipairs(list) do
            if c.parent == s then kids[#kids + 1] = { math.max(c.t0, s.t0), math.min(c.t1, s.t1) } end
        end
        s.self = math.max(0, s.d - union(kids))
    end
    local ivs = {}
    for _, s in ipairs(list) do
        if not s.parent then ivs[#ivs + 1] = { math.max(s.t0, from), math.min(s.t1, to) } end
    end
    return list, union(ivs)
end

local function topDiff(cur, prev, section, field, n, fallback)
    -- biggest increase of snap[section][key][field] per resource since prev
    local rows = {}
    for res, snap in pairs(cur or {}) do
        local p = prev and prev[res]
        local t = snap[section]
        if type(t) == 'table' then
            for k, v in pairs(t) do
                local f = field
                if fallback and type(v) == 'table' and (v[field] or 0) == 0 then f = fallback end
                local val = type(v) == 'table' and (v[f] or 0) or v
                local before = p and p[section] and p[section][k]
                before = type(before) == 'table' and (before[f] or 0) or (before or 0)
                if before > val then before = 0 end -- reset in between
                local delta = val - before
                if delta > 0 then rows[#rows + 1] = { res = res, key = k, value = delta } end
            end
        end
    end
    table.sort(rows, function(a, b) return a.value > b.value end)
    for i = #rows, n + 1, -1 do rows[i] = nil end
    return rows
end

local function entityCounts()
    local ok, v, p, o = pcall(function() return #GetAllVehicles(), #GetAllPeds(), #GetAllObjects() end)
    if ok then return { vehicles = v, peds = p, objects = o } end
end

local function verdict(r)
    local server = r.kinds.server
    local top = r.spans[1]
    local others = (r.kinds.network and 1 or 0) + (r.kinds.sync and 1 or 0)
    local h = r.host
    local f = r.entityFlow
    local machineBusy = h and ((h.machine or 0) >= 90 or (h.load1 and h.load1 > (h.cores or 1) * 1.5))
    if server and r.attributedMs < server * 0.3 and machineBusy then
        return fmt('no wrapped script explains it and the machine is overloaded (%s%d cores, CPU %.0f %%): '
            .. 'the server was starved by something else on the machine', h.load1 and fmt('load %.1f on ', h.load1) or '',
            h.cores or 0, h.machine or 0)
    end
    if server and others >= 1 and r.attributedMs < server * 0.3 then
        return 'several server threads stalled together while no wrapped script was running: the whole process was '
            .. 'held up (host CPU starvation, disk / swap, a VM pause, or an engine / C# stall), not one resource script'
    end
    if server and top and top.self >= server * 0.5 then
        return fmt('%s, %s: %d ms of the %d ms freeze', top.res, top.label, top.self, server)
    end
    if server and r.attributedMs >= server * 0.5 then
        return fmt('scripts ran %d ms of the %d ms freeze (several resources, see the list)', r.attributedMs, server)
    end
    -- mostly outside scripts: what the resources did just before (state bag writes, entities, big sends are processed by
    -- the engine after the script returns)
    if server and r.recent then
        local parts = {}
        if f and (f.created >= 100 or f.removed >= 100) then
            parts[#parts + 1] = fmt('%d entities created and %d removed', f.created, f.removed)
        end
        for _, e in ipairs(r.recent.ents or {}) do
            if #parts >= 3 then break end
            parts[#parts + 1] = fmt('%s called %s %d times', e.res, e.key, e.value)
        end
        local bag = r.recent.bags and r.recent.bags[1]
        if bag then parts[#parts + 1] = fmt('%s wrote state bag %s %d times', bag.res, bag.key, bag.value) end
        local snd = r.recent.sent and r.recent.sent[1]
        if snd then parts[#parts + 1] = fmt('%s sent %s (%d KB)', snd.res, snd.key, snd.value // 1024) end
        if #parts > 0 then
            return fmt('%d of the %d ms were outside wrapped scripts (the engine at work). In the %d s before: %s',
                r.unattributedMs or 0, server, r.recent.seconds or 0, table.concat(parts, '; '))
        end
    end
    if server then
        return fmt('only %d ms of the %d ms freeze were in wrapped Lua / JS code: the rest was the engine, C#, '
            .. 'JS async callbacks or a resource without the wrapper', r.attributedMs, server)
    end
    if r.kinds.sync and f and f.created >= 100 then
        local who = f.owners[1]
        return fmt('the main thread kept running; %d entities were created in the last %d s%s: the sync thread had to '
            .. 'take them all in', f.created, f.seconds, who and fmt(' (most by %s: %d)', who.key, who.value) or '')
    end
    return 'the main thread kept running: see what was sent / created just before (recent)'
end

local function shortLine(r)
    local k = {}
    for _, kind in ipairs(KINDS) do
        if r.kinds[kind] then k[#k + 1] = kind .. ' ' .. r.kinds[kind] .. ' ms' end
    end
    local tops = {}
    for _, s in ipairs(r.spans) do
        if #tops >= 3 then break end
        if s.self >= 1 then tops[#tops + 1] = fmt('%s %s %d ms', s.res, s.label, s.self) end
    end
    -- when scripts do not explain it, the verdict says what does (or what happened just before)
    local mostlyOutside = not r.kinds.server or (r.unattributedMs or 0) >= (r.kinds.server or 0) * 0.5
    return fmt('^3[hitchhunter]^7 #%d %s | %d players | %s%s%s', r.id, table.concat(k, ' + '), r.players or 0,
        #tops > 0 and table.concat(tops, '; ') or 'no wrapped script in the window',
        (r.kinds.server and r.unattributedMs and r.unattributedMs > 20) and fmt(' | outside scripts %d ms', r.unattributedMs) or '',
        mostlyOutside and (' | ' .. r.verdict) or '')
end

local function printFull(r)
    print(fmt('^3[hitchhunter]^7 hitch #%d at %s', r.id, r.time))
    for _, kind in ipairs(KINDS) do
        if r.kinds[kind] then
            print(fmt('  %-8s thread stalled %d ms (%s)%s', kind, r.kinds[kind], table.concat(r.via[kind] or {}, '+'),
                (kind == 'server' and r.consoleMs) and fmt(', FXServer printed %d ms', r.consoleMs) or ''))
        end
    end
    print('  verdict: ' .. r.verdict)
    if #r.spans > 0 then
        print('  what ran (own time / total, resource, what):')
        for _, s in ipairs(r.spans) do
            print(fmt('   %s%5d / %5d ms  %s  %s%s', string.rep('  ', s.depth), s.self, s.ms, s.res, s.label,
                s.at and fmt('  (+%d ms)', s.at) or ''))
        end
    end
    if r.unattributedMs then
        print(fmt('  in wrapped scripts %d ms, outside them %d ms (a normal frame is %d ms here)', r.attributedMs,
            r.unattributedMs, r.frameMs or 0))
    end
    print(fmt('  players %d%s', r.players or 0, r.entities and fmt(', entities: %d vehicles, %d peds, %d objects',
        r.entities.vehicles, r.entities.peds, r.entities.objects) or ''))
    local f = r.entityFlow
    if f and (f.created > 0 or f.removed > 0) then
        local kinds, owners = {}, {}
        for _, k in ipairs(f.kinds) do kinds[#kinds + 1] = k.key .. ' ' .. k.value end
        for _, o in ipairs(f.owners) do owners[#owners + 1] = o.key .. ' ' .. o.value end
        print(fmt('  entities in the last %d s: %d created, %d removed. Created: %s. By: %s', f.seconds, f.created,
            f.removed, table.concat(kinds, ', '), table.concat(owners, ', ')))
    end
    if r.host then
        local h = r.host
        print(fmt('  machine: %s%d cores, CPU %.0f %% busy, FXServer process %.0f %% of one core, %d MB free',
            h.load1 and fmt('load %.2f on ', h.load1) or '', h.cores or 0, h.machine or 0, h.proc or 0, h.memFreeMb or 0))
    end
    if r.recent then
        for _, sec in ipairs({ { 'sent', 'client events, bytes x players' }, { 'bags', 'state bag writes' },
            { 'ents', 'entity natives' }, { 'events', 'local TriggerEvent' } }) do
            local rows = r.recent[sec[1]]
            if rows and #rows > 0 then
                local parts = {}
                for _, row in ipairs(rows) do parts[#parts + 1] = fmt('%s %s %d', row.res, row.key, row.value) end
                print(fmt('  last %ds, %s: %s', r.recent.seconds or 0, sec[2], table.concat(parts, '; ')))
            end
        end
    end
end

local function logReport(r)
    if not cfg.logFile then return end
    local f = io.open(fmt('@%s/logs/hitches-%s.jsonl', HH, os.date('%Y-%m-%d')), 'a')
    if not f then return end
    f:write(json.encode(r) .. '\n')
    f:close()
end

local function discord(r)
    local url = GetConvar('hitchhunter_webhook', '')
    if url == '' or (r.worst or 0) < (cfg.discord.minMs or 300) then return end
    local hour = os.time() // 3600
    discordSent[hour] = (discordSent[hour] or 0) + 1
    if discordSent[hour] > (cfg.discord.maxPerHour or 12) then return end
    local lines = {}
    for i = 1, math.min(8, #r.spans) do
        local s = r.spans[i]
        lines[#lines + 1] = fmt('`%5d ms` **%s** %s', s.self, s.res, s.label)
    end
    local k = {}
    for _, kind in ipairs(KINDS) do if r.kinds[kind] then k[#k + 1] = kind .. ' ' .. r.kinds[kind] .. ' ms' end end
    PerformHttpRequest(url, function() end, 'POST', json.encode({
        username = 'hitchhunter',
        embeds = { {
            title = fmt('Hitch #%d: %s', r.id, table.concat(k, ' + ')),
            description = r.verdict .. (#lines > 0 and ('\n\n' .. table.concat(lines, '\n')) or ''),
            color = (r.worst or 0) >= 1000 and 15158332 or 15105570,
            footer = { text = fmt('%d players · %s', r.players or 0, r.time) },
        } },
    }), { ['Content-Type'] = 'application/json' })
end

local lastFreshCollect = 0

local function finalize(inc)
    reportSeq = reportSeq + 1
    local r = { id = reportSeq, time = os.date('%Y-%m-%d %H:%M:%S', inc.wall), kinds = {}, via = {} }
    local worst = 0
    for kind, v in pairs(inc.kinds) do
        r.kinds[kind] = v
        r.via[kind] = inc.via[kind]
        if v > worst then worst = v end
    end
    r.worst = worst
    local from, to = inc.from, inc.to
    local list, attributed = analyse(from, to)
    table.sort(list, function(a, b) return a.self > b.self end)
    r.spans = {}
    local function depthOf(s)
        local d, p = 0, s.parent
        while p do d, p = d + 1, p.parent end
        return d
    end
    for i = 1, math.min(15, #list) do
        local s = list[i]
        r.spans[i] = { res = s.res, label = s.key, ms = ms(s.d), self = ms(s.self), kind = s.kind,
            at = ms(s.t0 - from), depth = depthOf(s), parent = s.parent and (s.parent.res .. ' ' .. s.parent.key) or nil }
    end
    r.windowMs = ms(to - from)
    r.attributedMs = ms(attributed)
    r.consoleMs = inc.consoleMs
    if r.kinds.server then
        local g = gapStats()
        r.frameMs = g and ms(g.median) or 0
        if inc.consoleMs then
            r.unattributedMs = math.min(r.kinds.server, math.max(0, inc.consoleMs - r.attributedMs))
        else
            r.unattributedMs = math.max(0, r.kinds.server - r.attributedMs - r.frameMs)
        end
    end
    r.players = GetNumPlayerIndices()
    r.entities = entityCounts()
    r.entityFlow = recentEntities(30)
    r.host = host()
    -- what the resources did just before: for network / sync hitches, and for server hitches mostly outside scripts
    -- (state bag writes, entity creation and big sends are processed by the engine AFTER the script returns)
    local mostlyOutside = r.kinds.server and r.unattributedMs and r.unattributedMs >= 100
        and r.unattributedMs >= r.kinds.server * 0.5
    if (r.kinds.network or r.kinds.sync or mostlyOutside) and lastSample then
        local t = now()
        local cur = lastSample
        if t - lastFreshCollect > 10 * SEC then
            lastFreshCollect = t
            cur = { at = t, data = collectAll(25) }
        end
        local base = (cur == lastSample) and prevSample or lastSample
        if base then
            r.recent = {
                seconds = math.floor((cur.at - base.at) / SEC + 0.5),
                sent = topDiff(cur.data, base.data, 'sent', 3, 5, 2),
                bags = topDiff(cur.data, base.data, 'bags', 1, 5),
                ents = topDiff(cur.data, base.data, 'ents', nil, 5),
                events = topDiff(cur.data, base.data, 'events', nil, 5),
            }
        end
    end
    r.verdict = verdict(r)

    reports[#reports + 1] = r
    if #reports > cfg.keepReports then table.remove(reports, 1) end
    if worst >= cfg.minReportMs then
        if cfg.console == 'full' then printFull(r) elseif cfg.console then print(shortLine(r)) end
        logReport(r)
        discord(r)
    end
end

local function newIncident(from, to, measured)
    local inc = { from = from, to = to, kinds = {}, via = {}, wall = os.time(), measured = measured }
    openList[#openList + 1] = inc
    return inc
end

local function addKind(inc, kind, msVal, via)
    -- the server thread: our measured window when there is one (FXServer's number is kept in consoleMs)
    if kind == 'server' and via == 'console' and inc.measured then
        -- nothing: the frame gap stays the length
    elseif not inc.kinds[kind] or msVal > inc.kinds[kind] then
        inc.kinds[kind] = msVal
    end
    if kind == 'server' and via == 'console' then inc.consoleServer = true end
    inc.via[kind] = inc.via[kind] or {}
    local seen = false
    for _, v in ipairs(inc.via[kind]) do if v == via then seen = true end end
    if not seen then table.insert(inc.via[kind], via) end
    inc.due = now() + cfg.reportDelayMs * MS
end

-- every long frame is a hitch of its own (two freezes in a row are two reports)
local function onFrameHitch(from, to, msVal)
    addKind(newIncident(from, to, true), 'server', msVal, 'frame')
end

-- a console warning arrives after the freeze and only says how long. FXServer's frames are not in phase with
-- this resource's frame thread, so one warning can cover two of our frames in a row (a Lua freeze, then a JS one):
-- a server warning joins the frame hitch of the closest length, or the run of back-to-back frame hitches that
-- matches it (they become one hitch); network / sync join the nearest hitch within 2 s; else a new hitch
local function lenMs(inc) return (inc.to - inc.from) / MS end

local function onConsoleHitch(kind, t, n)
    local near = {}
    for _, inc in ipairs(openList) do
        if t - inc.to <= 2 * SEC and inc.from - t <= 2 * SEC then near[#near + 1] = inc end
    end
    local best
    if kind == 'server' then
        local frames = {}
        for _, inc in ipairs(near) do
            if inc.measured and not inc.consoleServer then frames[#frames + 1] = inc end
        end
        table.sort(frames, function(a, b) return a.from < b.from end)
        local bestScore
        for i = 1, #frames do
            local from, to = frames[i].from, frames[i].to
            for j = i, #frames do
                if j > i and frames[j].from - to > 5 * MS then break end -- not back to back
                to = frames[j].to
                local score = math.abs((to - from) / MS - n)
                if (to - from) / MS >= n - 60 and (not bestScore or score < bestScore) then
                    bestScore, best = score, { i = i, j = j }
                end
            end
        end
        if best then
            local first = frames[best.i]
            for j = best.i + 1, best.j do
                local inc = frames[j]
                first.to = inc.to
                for k, v in pairs(inc.kinds) do
                    if not first.kinds[k] or v > first.kinds[k] then first.kinds[k] = v end
                end
                for k, list in pairs(inc.via) do
                    first.via[k] = first.via[k] or {}
                    for _, v in ipairs(list) do table.insert(first.via[k], v) end
                end
                inc.merged = true
            end
            if best.j > best.i then
                local keep = {}
                for _, inc in ipairs(openList) do if not inc.merged then keep[#keep + 1] = inc end end
                openList = keep
                first.kinds.server = math.floor(lenMs(first) + 0.5)
            end
            best = first
        end
    else
        local bestScore
        for _, inc in ipairs(near) do
            local score = math.abs(t - inc.to)
            if not bestScore or score < bestScore then best, bestScore = inc, score end
        end
    end
    if not best then best = newIncident(t - n * MS - 50 * MS, t, false) end
    if kind == 'server' then best.consoleMs = n end
    addKind(best, kind, n, 'console')
end

-- console warnings. The listener sees every console line: it only queues, the frame thread does the rest
local consoleQueue = {}
local errorQueue, errorTail = {}, 0
if RegisterConsoleListener then
    -- FXServer prints them on its own channel (citizen-server-impl); a script printing the same text is ignored
    -- (`set hitchhunter_test_console 1` accepts script lines too, to test without real hitches)
    local scriptsToo = GetConvarInt('hitchhunter_test_console', 0) == 1
    -- never throws: an error here would print a line that comes back here
    local function listen(channel, message)
        if type(message) ~= 'string' then return end
        if message:find('hitch warning', 1, true)
            and (scriptsToo or not (type(channel) == 'string' and channel:sub(1, 7) == 'script:')) then
            consoleQueue[#consoleQueue + 1] = { now(), message }
        elseif cfg.scriptErrorLog and type(channel) == 'string' and channel:sub(1, 7) == 'script:'
            and channel ~= 'script:' .. HH then
            -- a SCRIPT ERROR and the stack lines right after it ("> ..."), written to logs/ by the frame thread
            local keep = false
            if message:find('SCRIPT ERROR', 1, true) then
                errorTail, keep = 20, true
            elseif errorTail > 0 then
                local m = message:match('^%s*(.-)%s*$')
                if m:sub(1, 1) == '>' then
                    errorTail, keep = errorTail - 1, true
                elseif m ~= '' then
                    errorTail = 0
                end
            end
            if keep and #errorQueue < 400 then
                errorQueue[#errorQueue + 1] = os.date('%H:%M:%S ') .. '[' .. channel:sub(8) .. '] ' .. (message:gsub('\x1b%[[%d;]*m', ''):gsub('%^%d', ''))
            end
        end
    end
    RegisterConsoleListener(function(channel, message) pcall(listen, channel, message) end)
else
    print('^3[hitchhunter]^7 this FXServer build has no RegisterConsoleListener: network / sync hitches are not seen')
end

local counts = { server = 0, network = 0, sync = 0, frames = 0 }
local frameHitchNs = cfg.frameHitchMs * MS

CreateThread(function()
    local last = now()
    tickAdd(last)
    while true do
        Wait(0)
        local t = now()
        tickAdd(t)
        local gap = t - last
        if gap < frameHitchNs then gapAdd(gap) end
        if gap >= frameHitchNs then
            counts.frames = counts.frames + 1
            onFrameHitch(last, t, ms(gap))
        end
        last = t
        if #consoleQueue > 0 then
            local q = consoleQueue
            consoleQueue = {}
            for _, item in ipairs(q) do
                local kind, n = item[2]:match('(%a+) thread hitch warning: timer interval of (%d+) milliseconds')
                n = tonumber(n)
                if n and counts[kind] then
                    counts[kind] = counts[kind] + 1
                    -- the warning is printed right after the stall ended
                    onConsoleHitch(kind, item[1], n)
                end
            end
        end
        if #errorQueue > 0 then
            local q = errorQueue
            errorQueue = {}
            local f = io.open(fmt('@%s/logs/script-errors-%s.log', HH, os.date('%Y-%m-%d')), 'a')
            if f then
                for _, line in ipairs(q) do f:write(line:sub(-1) == '\n' and line or (line .. '\n')) end
                f:close()
            end
        end
        if #openList > 0 then
            local keep = {}
            for _, inc in ipairs(openList) do
                if t >= inc.due then finalize(inc) else keep[#keep + 1] = inc end
            end
            openList = keep
        end
    end
end)

-- periodic samples, a few resources per frame (each answers on its own event name)
CreateThread(function()
    if (cfg.sampleSeconds or 0) <= 0 then return end
    while true do
        Wait(cfg.sampleSeconds * 1000)
        local names = {}
        for res, r in pairs(runtimes) do
            if r.lua or r.js then names[#names + 1] = res end
        end
        reqSeq = reqSeq + 1
        local id = reqSeq
        pending[id] = {}
        for i, res in ipairs(names) do
            TriggerEvent(HH .. ':collect:' .. res, id, 25)
            if i % 20 == 0 then Wait(0) end
        end
        prevSample = lastSample
        lastSample = { at = now(), data = pending[id] }
        pending[id] = nil
    end
end)

-- ------------------------------------------------------------------------------------------------------------------
-- logs/status.json every minute: what is wrapped (and how), what was seen. For other tools (a panel, a bot) and to
-- check an install without the console.
CreateThread(function()
    if not cfg.statusFile then return end
    Wait(20000)
    while true do
        local res = {}
        for name, r in pairs(runtimes) do
            res[name] = {
                lua = r.lua and { v = r.lua.v, hooks = #r.lua.hooks } or nil,
                js = r.js and { v = r.js.v, hooks = #r.js.hooks } or nil,
            }
        end
        local g = gapStats()
        local status = {
            at = os.date('%Y-%m-%d %H:%M:%S'), resource = HH, wrapped = res, counts = counts, reports = #reports,
            frames = g and { medianMs = g.median / MS, p95Ms = g.p95 / MS, maxNormalMs = g.max / MS } or nil,
            consoleListener = RegisterConsoleListener ~= nil, lastReport = reports[#reports],
        }
        SaveResourceFile(HH, 'logs/status.json', json.encode(status), -1)
        Wait(60000)
    end
end)

-- ------------------------------------------------------------------------------------------------------------------
-- commands
local function out(src, msg)
    if src == 0 then
        print(msg)
    else
        TriggerClientEvent('chat:addMessage', src, { args = { 'hitchhunter', (msg:gsub('%^%d', '')) } })
    end
end

local function hasServerScripts(res)
    for _, key in ipairs({ 'server_script', 'shared_script' }) do
        if (GetNumResourceMetadata(res, key) or 0) > 0 then return true end
    end
    return false
end

local function since(sec)
    if sec < 120 then return sec .. ' s' end
    if sec < 7200 then return (sec // 60) .. ' min' end
    return fmt('%.1f h', sec / 3600)
end

local function cmdTop(src, args, resFilter)
    local n = tonumber(args[2]) or 15
    local data = collectAll(nil)
    local rows, perRes = {}, {}
    for res, snap in pairs(data) do
        if not resFilter or res == resFilter or res == resFilter .. ' (js)' then
            local secs = math.max(1, (snap.at - snap.since) / SEC)
            for key, s in pairs(snap.cpu or {}) do
                rows[#rows + 1] = { res = res, key = key, calls = s[1], ns = s[2], max = s[3], secs = secs }
                perRes[res] = (perRes[res] or 0) + s[2] / secs
            end
        end
    end
    table.sort(rows, function(a, b) return a.ns / a.secs > b.ns / b.secs end)
    out(src, '^3[hitchhunter]^7 script time on the server thread (since start or `hh reset`), ms per minute:')
    out(src, '   ms/min    calls   avg ms  longest  resource  what   (own time; longest = held the thread in one go, calls included)')
    for i = 1, math.min(n, #rows) do
        local r = rows[i]
        out(src, fmt('  %7.1f %8d %8.2f %8.1f  %s  %s', r.ns / r.secs * 60 / MS, r.calls,
            r.calls > 0 and r.ns / r.calls / MS or 0, r.max / MS, r.res, r.key))
    end
    if not resFilter then
        local list = {}
        for res, v in pairs(perRes) do list[#list + 1] = { res, v } end
        table.sort(list, function(a, b) return a[2] > b[2] end)
        local parts = {}
        for i = 1, math.min(10, #list) do parts[#parts + 1] = fmt('%s %.0f', list[i][1], list[i][2] * 60 / MS) end
        out(src, 'by resource (ms/min): ' .. table.concat(parts, ', '))
    end
end

local function cmdNet(src, args)
    local n = tonumber(args[2]) or 15
    local data = collectAll(nil)
    local rows = {}
    for res, snap in pairs(data) do
        local secs = math.max(1, (snap.at - snap.since) / SEC)
        for ev, s in pairs(snap.sent or {}) do
            rows[#rows + 1] = { res = res, ev = ev, n = s[1], bytes = s[2], out = s[3], latent = s[4], secs = secs }
        end
    end
    table.sort(rows, function(a, b) return a.out / a.secs > b.out / b.secs end)
    out(src, '^3[hitchhunter]^7 client events sent (bytes x players = what leaves the server):')
    out(src, '     KB/s out   sends/min  avg bytes  resource  event')
    for i = 1, math.min(n, #rows) do
        local r = rows[i]
        out(src, fmt('  %10.1f %10.1f %10d  %s  %s%s', r.out / r.secs / 1024, r.n / r.secs * 60,
            r.n > 0 and r.bytes // r.n or 0, r.res, r.ev, r.latent > 0 and ' (latent)' or ''))
    end
end

local function cmdSync(src, args)
    local n = tonumber(args[2]) or 15
    local data = collectAll(nil)
    local bags, ents = {}, {}
    for res, snap in pairs(data) do
        local secs = math.max(1, (snap.at - snap.since) / SEC)
        for k, s in pairs(snap.bags or {}) do bags[#bags + 1] = { res = res, key = k, n = s[1], bytes = s[2], secs = secs } end
        for k, c in pairs(snap.ents or {}) do
            if c > 0 then ents[#ents + 1] = { res = res, key = k, n = c, secs = secs } end
        end
    end
    table.sort(bags, function(a, b) return a.n / a.secs > b.n / b.secs end)
    table.sort(ents, function(a, b) return a.n / a.secs > b.n / b.secs end)
    local e = entityCounts()
    out(src, fmt('^3[hitchhunter]^7 entities now: %s', e and fmt('%d vehicles, %d peds, %d objects', e.vehicles, e.peds, e.objects) or '?'))
    local f = recentEntities(60)
    out(src, fmt('last 60 s, every entity (scripts and players\' games): %d created, %d removed', f.created, f.removed))
    for _, k in ipairs(f.kinds) do out(src, fmt('  %6d  %s', k.value, k.key)) end
    if #f.owners > 0 then
        local parts = {}
        for _, o in ipairs(f.owners) do parts[#parts + 1] = o.key .. ' ' .. o.value end
        out(src, '  created by: ' .. table.concat(parts, ', '))
    end
    out(src, 'state bag writes (per min, avg bytes):')
    for i = 1, math.min(n, #bags) do
        local r = bags[i]
        out(src, fmt('  %8.1f/min %7d B  %s  %s', r.n / r.secs * 60, r.n > 0 and r.bytes // r.n or 0, r.res, r.key))
    end
    out(src, 'entity natives (per min):')
    for i = 1, math.min(n, #ents) do
        local r = ents[i]
        out(src, fmt('  %8.1f/min  %s  %s', r.n / r.secs * 60, r.res, r.key))
    end
end

local function cmdIo(src, args)
    local n = tonumber(args[2]) or 15
    local data = collectAll(nil)
    local rows = {}
    for res, snap in pairs(data) do
        for k, s in pairs(snap.io or {}) do
            if s[1] > 0 then rows[#rows + 1] = { res = res, key = k, n = s[1], ns = s[2], max = s[3] } end
        end
    end
    table.sort(rows, function(a, b) return a.ns > b.ns end)
    out(src, '^3[hitchhunter]^7 blocking calls (total ms, calls, max ms):')
    for i = 1, math.min(n, #rows) do
        local r = rows[i]
        out(src, fmt('  %9.1f %9d %8.1f  %s  %s', r.ns / MS, r.n, r.max / MS, r.res, r.key))
    end
end

local function cmdCoverage(src)
    TriggerEvent(HH .. ':announce')
    local missing, lua, js = {}, 0, 0
    for i = 0, GetNumResources() - 1 do
        local res = GetResourceByFindIndex(i)
        if res and res ~= HH and GetResourceState(res) == 'started' and hasServerScripts(res) then
            local r = runtimes[res]
            if r and r.lua then lua = lua + 1 end
            if r and r.js then js = js + 1 end
            if not r then missing[#missing + 1] = res end
        end
    end
    table.sort(missing)
    out(src, fmt('^3[hitchhunter]^7 wrapped: %d Lua, %d JS runtimes. Started with server scripts but NOT wrapped: %d',
        lua, js, #missing))
    if #missing > 0 then out(src, '  ' .. table.concat(missing, ', ')) end
    out(src, '  (tools/inject.py adds the line; a resource picks it up at its next start)')
end

-- what the wrapper replaced in each resource (nothing in FXServer's own files)
local function cmdHooks(src, args)
    local res = args[2]
    if res then
        local r = runtimes[res]
        if not r then return out(src, fmt('^3[hitchhunter]^7 %s has no wrapper (or has not started since hitchhunter did)', res)) end
        for _, kind in ipairs({ 'lua', 'js' }) do
            local e = r[kind]
            if e then
                out(src, fmt('^3[hitchhunter]^7 %s, %s runtime (wrapper v%s, said hello %s ago), %d functions replaced in memory:',
                    res, kind, tostring(e.v), since(os.time() - e.seen), #e.hooks))
                for _, h in ipairs(e.hooks) do out(src, '   ' .. h) end
            end
        end
        return
    end
    local count, total = {}, { lua = 0, js = 0 }
    for _, r in pairs(runtimes) do
        for _, kind in ipairs({ 'lua', 'js' }) do
            local e = r[kind]
            if e then
                total[kind] = total[kind] + 1
                for _, h in ipairs(e.hooks) do
                    local k = kind .. '|' .. h
                    count[k] = (count[k] or 0) + 1
                end
            end
        end
    end
    out(src, '^3[hitchhunter]^7 no FXServer file is modified (scheduler.lua, main.js stay stock). Functions replaced '
        .. 'in memory inside each wrapped resource, and in how many:')
    local list = {}
    for k, n in pairs(count) do list[#list + 1] = { k, n } end
    table.sort(list, function(a, b) return a[1] < b[1] end)
    for _, it in ipairs(list) do
        local kind, h = it[1]:match('^(%a+)|(.*)$')
        out(src, fmt('  %-3s %4d / %-4d %s', kind, it[2], total[kind], h))
    end
    out(src, '  (hh hooks <resource> for one resource)')
end

local function cmdStarts(src, args)
    local n = tonumber(args[2]) or 15
    local list = {}
    for res, d in pairs(startTimes) do list[#list + 1] = { res, d } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    out(src, '^3[hitchhunter]^7 slowest resource starts since hitchhunter started (loading their scripts, on the server thread):')
    for i = 1, math.min(n, #list) do out(src, fmt('  %8.1f ms  %s', list[i][2] / MS, list[i][1])) end
end

local function cmdLast(src, args)
    local n = tonumber(args[2]) or 10
    if #reports == 0 then return out(src, '^3[hitchhunter]^7 no hitch since start') end
    for i = math.max(1, #reports - n + 1), #reports do out(src, shortLine(reports[i]) .. ' (' .. reports[i].time .. ')') end
end

local function cmdShow(src, args)
    local id = tonumber(args[2])
    local r = id and nil or reports[#reports]
    if id then for _, x in ipairs(reports) do if x.id == id then r = x end end end
    if not r then return out(src, '^3[hitchhunter]^7 no such report') end
    if src == 0 then printFull(r) else out(src, shortLine(r)) end
end

local startedWall = os.time()

local function cmdStatus(src)
    local lua, js = 0, 0
    for _, r in pairs(runtimes) do
        if r.lua then lua = lua + 1 end
        if r.js then js = js + 1 end
    end
    out(src, fmt('^3[hitchhunter]^7 up %s, wrapped runtimes: %d Lua, %d JS. Hitches seen: %d frames >= %d ms, '
        .. 'console warnings: server %d, network %d, sync %d. Reports kept: %d.',
        since(os.time() - startedWall), lua, js, counts.frames, cfg.frameHitchMs, counts.server, counts.network,
        counts.sync, #reports))
    local g = gapStats()
    if g then
        out(src, fmt('  server frames: median %.1f ms, 95 %% under %.1f ms, longest normal %.1f ms (last %d)',
            g.median / MS, g.p95 / MS, g.max / MS, g.n))
    end
    if not RegisterConsoleListener then out(src, '  (no RegisterConsoleListener on this build: network / sync not seen)') end
end

-- `hh how`: how the resource finds each problem (the same as README.md, "What it finds, and how")
local HOW = {
    '^3[hitchhunter]^7 how a hitch is found:',
    ' 1. While code runs, the wrapper inside each resource times every handler, thread, callback, export, timer.',
    '    A block of 5 ms or more is sent here at once (start + length); the rest adds up in counters.',
    ' 2. The freeze is noticed: this resource\'s frame thread sees a gap of ' .. cfg.frameHitchMs .. ' ms or more between two',
    '    server frames (it cannot run while something blocks the thread), and/or FXServer prints its hitch warning',
    '    for the server, network or sync thread (read with RegisterConsoleListener).',
    ' 3. ' .. cfg.reportDelayMs .. ' ms later the report is built: the blocks inside the freeze, which one called which (own time vs',
    '    total), the part no script explains, players, entities, machine load, and what resources did just before.',
    ' 4. Written to the console, logs/hitches-*.jsonl, `hh last` / `hh show`, Discord if set.',
    'what each problem looks like:',
    '  handler doing too much ....... event <name> <file>:<line> N ms',
    '  thread with a heavy loop ..... thread <file>:<line> N ms',
    '  slow export from elsewhere ... export <name> N ms, the caller\'s own time apart',
    '  file / json ................... io SaveResourceFile <file>, io json.decode N ms (hh io)',
    '  resource restarted live ....... resource start (loading its scripts) N ms (hh starts)',
    '  JS ............................ event <name>, js timers, js setTick + code after await',
    '  many small calls .............. hh top: ms per minute per handler',
    '  engine after a script ......... outside wrapped scripts + what was done just before (entities, state bags)',
    '  network thread ................ FXServer warning + what was sent just before (hh net)',
    '  sync thread ................... FXServer warning + entities created/removed and by whom (hh sync)',
    '  whole process stalled ......... server + network + sync together, no script: the machine, not a resource',
    '  C# / no wrapper ............... outside wrapped scripts (hh coverage)',
    '  escrowed (encrypted) code ..... timed like the rest; no file name: <kind> <name> escrow:<line>',
}

local HELP = {
    'hh status            what is watched, how many hitches',
    'hh last [n]          the last hitches, one line each',
    'hh show [id]         a whole report (the last one by default)',
    'hh top [n]           where the server thread time goes, by handler / thread',
    'hh res <resource>    the same for one resource',
    'hh net [n]           client events sent, by bytes leaving the server',
    'hh sync [n]          state bag writes and entity natives',
    'hh io [n]            file / json calls that block the thread',
    'hh coverage          which running resources are not wrapped',
    'hh hooks [resource]  what the wrapper replaced in memory (no FXServer file is modified)',
    'hh starts [n]        the slowest resource starts (loading scripts blocks the server thread)',
    'hh reset             start all counters again',
    'hh test <ms>         busy-wait <ms> in an event handler of this resource (to see a report)',
    'hh how               how each problem is found, and what its report looks like',
}

RegisterCommand('hh', function(src, args)
    local sub = (args[1] or 'status'):lower()
    if sub == 'status' then cmdStatus(src)
    elseif sub == 'last' then cmdLast(src, args)
    elseif sub == 'show' then cmdShow(src, args)
    elseif sub == 'top' then cmdTop(src, args)
    elseif sub == 'res' and args[2] then cmdTop(src, { 'res', args[3] }, args[2])
    elseif sub == 'net' then cmdNet(src, args)
    elseif sub == 'sync' then cmdSync(src, args)
    elseif sub == 'io' then cmdIo(src, args)
    elseif sub == 'coverage' then cmdCoverage(src)
    elseif sub == 'hooks' then cmdHooks(src, args)
    elseif sub == 'starts' then cmdStarts(src, args)
    elseif sub == 'how' then for _, l in ipairs(HOW) do out(src, l) end
    elseif sub == 'reset' then
        collectAll(0, true)
        out(src, '^3[hitchhunter]^7 counters reset in every wrapped resource')
    elseif sub == 'test' then
        local n = math.min(tonumber(args[2]) or 300, 5000)
        TriggerEvent(HH .. ':selftest', n)
    else
        for _, l in ipairs(HELP) do out(src, l) end
    end
end, cfg.restrictedCommand)

-- `hh test`: this resource is not wrapped, so the freeze shows as "outside wrapped scripts" unless another resource
-- answers it; the point is to see a report come out
AddEventHandler(HH .. ':selftest', function(n)
    local t0 = now()
    while now() - t0 < n * MS do end
end)

-- ask the resources that started before us to say hello
TriggerEvent(HH .. ':announce')

print(('^3[hitchhunter]^7 started. No FXServer file is modified: each resource with the manifest line '
    .. '(tools/inject.py) loads @%s/inject/server.lua / .js first and times its own handlers in memory. '
    .. '`hh` for the commands, `hh hooks` for what is replaced.'):format(HH))

exports('reports', function() return reports end)
