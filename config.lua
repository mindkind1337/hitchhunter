Config = {}

-- A server frame that takes at least this long is a hitch, even when FiveM prints nothing (it only prints from
-- 150 ms on). Lower = more reports.
Config.frameHitchMs = 100

-- A hitch report waits this long before it is written, so the console warnings that come after the freeze and
-- the slices that end with it are all in it.
Config.reportDelayMs = 400

-- Print every hitch report in the server console. 'short' = one line per hitch, 'full' = the whole report,
-- false = nothing (they are still in logs/ and in `hh last`).
Config.console = 'short'

-- Only hitches of at least this many ms are printed / logged / sent to Discord (the others are still counted).
Config.minReportMs = 100

-- Write every report as one JSON line in logs/hitches-YYYY-MM-DD.jsonl (inside this resource's folder).
Config.logFile = true

-- Discord: the webhook URL is read from the convar `hitchhunter_webhook` (put `set hitchhunter_webhook "https://..."`
-- in server.cfg: `set`, not `setr`, so players never receive it). Empty = off.
Config.discord = {
    minMs = 300,          -- only hitches at least this long
    maxPerHour = 12,
}

-- Every N seconds hitchhunter asks every wrapped resource for its counters, to know what changed just before a
-- network or sync hitch ("sent 4 MB of events in the last 30 s"). 0 = only when a hitch happens or a command asks.
Config.sampleSeconds = 30

-- How many hitch reports are kept in memory for `hh last` / `hh show`.
Config.keepReports = 200

-- Who may use the `hh` command in game (the server console always can): an ace, e.g.
-- `add_ace group.admin command.hh allow` in server.cfg. true = restricted to that ace.
Config.restrictedCommand = true

-- logs/status.json, rewritten every minute: which resources are wrapped and how, hitch counts, the last report.
Config.statusFile = true

-- Copy every SCRIPT ERROR of the console (with its stack lines) to logs/script-errors-YYYY-MM-DD.log.
Config.scriptErrorLog = true
