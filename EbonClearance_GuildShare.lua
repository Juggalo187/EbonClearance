-- EbonClearance_GuildShare.lua
-- Guild/group-scoped anonymous sharing of best farming zones + headline stats.
-- Rides on NS.Comms (GREQ request / GDAT reply). Anonymous = the GDAT sender is
-- ignored and never stored or shown; only pooled aggregates are displayed. (A
-- 3.3.5a addon message always carries its sender, so this is anonymity at the
-- display/storage layer, not concealment from anyone logging addon traffic.)
local NS = select(2, ...)

local GuildShare = {}
NS.GuildShare = GuildShare

local MAX_ZONES = 5
local MAX_PAYLOAD = 240 -- stay safely under the ~255-byte addon-message limit

-- Return an array of {name, copper} for the top n zones, highest copper first.
function GuildShare.topZones(copperByZone, n)
    local arr = {}
    for name, copper in pairs(copperByZone or {}) do
        arr[#arr + 1] = { name = name, copper = tonumber(copper) or 0 }
    end
    table.sort(arr, function(a, b) return a.copper > b.copper end)
    while #arr > (n or MAX_ZONES) do
        arr[#arr] = nil
    end
    return arr
end

-- A zone name is unsafe if it contains one of our payload delimiters.
local function zoneNameSafe(name)
    return type(name) == "string" and name ~= "" and not name:find("[=;|,\t]")
end

-- Build the compact wire payload. Caps to MAX_ZONES, skips delimiter-unsafe
-- names, and trims trailing zones until the whole thing fits MAX_PAYLOAD.
function GuildShare.encodePayload(zones, stats)
    local s = stats or {}
    local statsPart = string.format(
        "stats:%d,%d,%d",
        math.floor(tonumber(s.totalCopper) or 0),
        math.floor(tonumber(s.itemsSold) or 0),
        math.floor(tonumber(s.bestGPH) or 0)
    )
    local picked = {}
    for _, z in ipairs(zones or {}) do
        if #picked >= MAX_ZONES then
            break
        end
        if zoneNameSafe(z.name) then
            picked[#picked + 1] = z
        end
    end
    local function assemble(list)
        local parts = {}
        for _, z in ipairs(list) do
            parts[#parts + 1] = z.name .. "=" .. tostring(math.floor(tonumber(z.copper) or 0))
        end
        return statsPart .. "|zones:" .. table.concat(parts, ";")
    end
    local payload = assemble(picked)
    while #payload > MAX_PAYLOAD and #picked > 0 do
        picked[#picked] = nil
        payload = assemble(picked)
    end
    return payload
end

-- Parse a payload back into { stats = {...}, zones = { {name, copper}, ... } }.
function GuildShare.decodePayload(str)
    local out = { stats = { totalCopper = 0, itemsSold = 0, bestGPH = 0 }, zones = {} }
    if type(str) ~= "string" then
        return out
    end
    local c, i, g = str:match("stats:(%d+),(%d+),(%d+)")
    if c then
        out.stats.totalCopper = tonumber(c) or 0
        out.stats.itemsSold = tonumber(i) or 0
        out.stats.bestGPH = tonumber(g) or 0
    end
    local zonesPart = str:match("zones:(.*)$")
    if zonesPart then
        for entry in zonesPart:gmatch("[^;]+") do
            local name, copper = entry:match("^(.-)=(%d+)$")
            if name and name ~= "" then
                out.zones[#out.zones + 1] = { name = name, copper = tonumber(copper) or 0 }
            end
        end
    end
    return out
end

-- Fresh transient aggregate (session-only; never saved).
function GuildShare.newAggregate()
    return { zones = {}, totalCopper = 0, totalItems = 0, bestGPH = 0, memberCount = 0 }
end

-- Merge one decoded reply into the aggregate.
function GuildShare.mergeReply(agg, decoded)
    if not agg or not decoded then
        return
    end
    agg.memberCount = agg.memberCount + 1
    agg.totalCopper = agg.totalCopper + (decoded.stats.totalCopper or 0)
    agg.totalItems = agg.totalItems + (decoded.stats.itemsSold or 0)
    if (decoded.stats.bestGPH or 0) > agg.bestGPH then
        agg.bestGPH = decoded.stats.bestGPH
    end
    for _, z in ipairs(decoded.zones or {}) do
        local e = agg.zones[z.name]
        if not e then
            e = { copper = 0, contributors = 0 }
            agg.zones[z.name] = e
        end
        e.copper = e.copper + (z.copper or 0)
        e.contributors = e.contributors + 1
    end
end

-- ---- transport consumer + on-demand request ----------------------------
local GREQ_THROTTLE_S = 8 -- min seconds between our own GREQ broadcasts
local lastReqAt = 0

-- Build this player's anonymous payload from data EC already tracks.
local function localPayload()
    local DB = EbonClearanceDB or {}
    local itemsSold = 0
    for _, n in pairs(DB.soldItemsByQuality or {}) do
        itemsSold = itemsSold + (tonumber(n) or 0)
    end
    local stats = { totalCopper = DB.totalCopper or 0, itemsSold = itemsSold, bestGPH = DB.bestGPH or 0 }
    return GuildShare.encodePayload(GuildShare.topZones(DB.copperByZone, MAX_ZONES), stats)
end

-- The live aggregate the panel reads. Lives on the shared cache (session-only).
local function agg()
    if not NS.compCache.guildAgg then
        NS.compCache.guildAgg = GuildShare.newAggregate()
    end
    return NS.compCache.guildAgg
end

function GuildShare.GetAggregate()
    return agg()
end

-- Broadcast a request and reset the aggregate for a fresh snapshot. Throttled
-- so spam-clicking Refresh cannot flood the guild channel.
function GuildShare.RequestNow()
    local now = GetTime()
    if (now - lastReqAt) < GREQ_THROTTLE_S then
        return
    end
    lastReqAt = now
    NS.compCache.guildAgg = GuildShare.newAggregate()
    if GetGuildInfo("player") then
        NS.Comms.Send("GREQ", "", "GUILD")
    end
    if GetNumRaidMembers() > 0 then
        NS.Comms.Send("GREQ", "", "RAID")
    elseif GetNumPartyMembers() > 0 then
        NS.Comms.Send("GREQ", "", "PARTY")
    end
end

local function playerName()
    return UnitName("player")
end

-- A peer asked for data: reply by whisper IF we opted in. The sender is used
-- only as the whisper target; it is never stored or displayed (anonymity).
NS.Comms.RegisterHandler("GREQ", function(_, sender, _)
    if not (EbonClearanceDB and EbonClearanceDB.shareGuildData) then
        return
    end
    if sender and sender ~= playerName() then
        NS.Comms.Send("GDAT", localPayload(), "WHISPER", sender)
    end
end)

-- A reply arrived: merge it anonymously (sender ignored entirely).
NS.Comms.RegisterHandler("GDAT", function(payload, _, _)
    GuildShare.mergeReply(agg(), GuildShare.decodePayload(payload))
    if NS.RefreshGuildPanel then
        NS.RefreshGuildPanel()
    end
end)
