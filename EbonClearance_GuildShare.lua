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
local MAX_ITEMS = 3
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

-- Build the compact wire payload. Caps to MAX_ZONES/MAX_ITEMS, skips
-- delimiter-unsafe names, and trims trailing zones until the whole thing fits
-- MAX_PAYLOAD. Items are tiny and wanted, so zones are trimmed first.
-- selfName is an optional 4th arg: when the sharer has opted in to attribution,
-- pass UnitName("player") here and it travels as a name: section.
function GuildShare.encodePayload(zones, stats, items, selfName)
    local s = stats or {}
    local statsPart = string.format(
        "stats:%d,%d,%d",
        math.floor(tonumber(s.totalCopper) or 0),
        math.floor(tonumber(s.itemsSold) or 0),
        math.floor(tonumber(s.bestGPH) or 0)
    )
    local namePart = (type(selfName) == "string" and selfName ~= "" and zoneNameSafe(selfName))
        and ("name:" .. selfName)
        or nil
    local itemParts = {}
    for _, it in ipairs(items or {}) do
        if #itemParts >= MAX_ITEMS then
            break
        end
        local n = math.floor(tonumber(it.count) or 0)
        if zoneNameSafe(it.name) and n > 0 then
            itemParts[#itemParts + 1] = it.name .. "=" .. n
        end
    end
    local itemsPart = (#itemParts > 0) and ("items:" .. table.concat(itemParts, ";")) or nil
    local picked = {}
    for _, z in ipairs(zones or {}) do
        if #picked >= MAX_ZONES then
            break
        end
        if zoneNameSafe(z.name) then
            picked[#picked + 1] = z
        end
    end
    local function assemble(zlist)
        local parts = {}
        for _, z in ipairs(zlist) do
            parts[#parts + 1] = z.name .. "=" .. tostring(math.floor(tonumber(z.copper) or 0))
        end
        local out = statsPart
        if namePart then
            out = out .. "|" .. namePart
        end
        if itemsPart then
            out = out .. "|" .. itemsPart
        end
        out = out .. "|zones:" .. table.concat(parts, ";")
        return out
    end
    local payload = assemble(picked)
    while #payload > MAX_PAYLOAD and #picked > 0 do
        picked[#picked] = nil
        payload = assemble(picked)
    end
    return payload
end

-- Parse a payload back into { stats = {...}, zones = { {name, copper}, ... },
-- items = { {name, count}, ... }, name = <string or nil> }.
function GuildShare.decodePayload(str)
    local out = { stats = { totalCopper = 0, itemsSold = 0, bestGPH = 0 }, zones = {}, items = {} }
    if type(str) ~= "string" then
        return out
    end
    for section in str:gmatch("[^|]+") do
        local prefix, body = section:match("^(%w+):(.*)$")
        if prefix == "stats" then
            local c, i, g = body:match("^(%d+),(%d+),(%d+)")
            if c then
                out.stats.totalCopper = tonumber(c) or 0
                out.stats.itemsSold = tonumber(i) or 0
                out.stats.bestGPH = tonumber(g) or 0
            end
        elseif prefix == "name" then
            if body ~= "" then
                out.name = body
            end
        elseif prefix == "zones" then
            for entry in body:gmatch("[^;]+") do
                local name, copper = entry:match("^(.-)=(%d+)$")
                if name and name ~= "" then
                    out.zones[#out.zones + 1] = { name = name, copper = tonumber(copper) or 0 }
                end
            end
        elseif prefix == "items" then
            for entry in body:gmatch("[^;]+") do
                local name, cnt = entry:match("^(.-)=(%d+)$")
                if name and name ~= "" then
                    out.items[#out.items + 1] = { name = name, count = tonumber(cnt) or 0 }
                end
            end
        end
    end
    return out
end

-- Fresh transient aggregate (session-only; never saved).
function GuildShare.newAggregate()
    return { zones = {}, items = {}, contributors = {}, totalCopper = 0, totalItems = 0, bestGPH = 0, memberCount = 0 }
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
    agg.items = agg.items or {}
    for _, it in ipairs(decoded.items or {}) do
        local e = agg.items[it.name]
        if not e then
            e = { count = 0, contributors = 0 }
            agg.items[it.name] = e
        end
        e.count = e.count + (it.count or 0)
        e.contributors = e.contributors + 1
    end
    if decoded.name and decoded.name ~= "" then
        agg.contributors = agg.contributors or {}
        agg.contributors[decoded.name] = true
    end
end

-- ---- transport consumer + on-demand request ----------------------------
-- Match the Comms per-channel send throttle (30s). RequestNow resets the
-- aggregate before sending, so its window must not be shorter than the
-- transport's, or a Refresh in between would blank the panel without re-querying.
local GREQ_THROTTLE_S = 30
local lastReqAt = 0

-- Build this player's anonymous payload from data EC already tracks.
local function localPayload()
    local DB = EbonClearanceDB or {}
    local itemsSold = 0
    for _, n in pairs(DB.soldItemsByQuality or {}) do
        itemsSold = itemsSold + (tonumber(n) or 0)
    end
    local stats = { totalCopper = DB.totalCopper or 0, itemsSold = itemsSold, bestGPH = DB.bestGPH or 0 }
    local itemsTop = {}
    do
        local arr = {}
        for id, n in pairs(DB.soldItemCounts or {}) do
            arr[#arr + 1] = { id = id, count = tonumber(n) or 0 }
        end
        table.sort(arr, function(a, b) return a.count > b.count end)
        for _, e in ipairs(arr) do
            if #itemsTop >= MAX_ITEMS then
                break
            end
            local name = GetItemInfo and GetItemInfo(e.id)
            if name and zoneNameSafe(name) then
                itemsTop[#itemsTop + 1] = { name = name, count = e.count }
            end
        end
    end
    local selfName = (EbonClearanceDB.shareGuildName and UnitName("player")) or nil
    return GuildShare.encodePayload(GuildShare.topZones(DB.copperByZone, MAX_ZONES), stats, itemsTop, selfName)
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

-- Diagnostic (/ec guildtest): simulate guildmates replying so the panel can be
-- exercised on one account. Resets the transient aggregate, merges a few fake
-- peers through the real merge path, and repaints. Sends nothing over the wire
-- and touches no saved data (the aggregate is session-only).
function GuildShare.InjectTestPeers()
    NS.compCache.guildAgg = GuildShare.newAggregate()
    local fakes = {
        { name = "Alaric", stats = { totalCopper = 5000000, itemsSold = 120, bestGPH = 450000 }, zones = { { name = "The Barrens", copper = 3000000 }, { name = "Durotar", copper = 800000 } }, items = { { name = "Linen Cloth", count = 50 }, { name = "Silk Cloth", count = 30 } } },
        { name = "Brynn", stats = { totalCopper = 3200000, itemsSold = 80, bestGPH = 600000 }, zones = { { name = "The Barrens", copper = 1500000 }, { name = "Elwynn Forest", copper = 2200000 } }, items = { { name = "Linen Cloth", count = 40 }, { name = "Malachite", count = 20 } } },
        { stats = { totalCopper = 900000, itemsSold = 40, bestGPH = 300000 }, zones = { { name = "Westfall", copper = 700000 } }, items = { { name = "Silk Cloth", count = 15 } } },
    }
    for _, f in ipairs(fakes) do
        GuildShare.mergeReply(GuildShare.GetAggregate(), f)
    end
    if NS.RefreshGuildPanel then
        NS.RefreshGuildPanel()
    end
    return #fakes
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
