#!/usr/bin/env lua
-- Unit + static tests for guild-share encode/decode/merge.
-- Run: lua tests/test_guildshare.lua
-- Loads the chunk in isolation with a stub NS.Comms (it registers handlers at load).

local handlers = {}
local sent = {}
local function clearSent() for i = #sent, 1, -1 do sent[i] = nil end end
local NS = {
    Comms = {
        RegisterHandler = function(t, fn) handlers[t] = fn end,
        Send = function(t, payload, channel, target) sent[#sent + 1] = { t = t, payload = payload, channel = channel, target = target } end,
    },
    Delay = function() end,
    compCache = {},
}
_G.UnitName = function() return "Self" end
local chunk = assert(loadfile("EbonClearance_GuildShare.lua"))
chunk("EbonClearance", NS)
local gs = NS.GuildShare

local fails = 0
local function ok(name, cond)
    if cond then print("PASS  " .. name) else print("FAIL  " .. name); fails = fails + 1 end
end
local function eq(name, a, b) ok(name .. " (" .. tostring(a) .. ")", a == b) end

-- topZones: sort desc, cap to n
local top = gs.topZones({ ["Durotar"] = 50, ["Barrens"] = 200, ["Mulgore"] = 10 }, 2)
eq("topZones count", #top, 2)
eq("topZones[1] name", top[1].name, "Barrens")
eq("topZones[1] copper", top[1].copper, 200)

-- encode/decode round-trip
local payload = gs.encodePayload({ { name = "Barrens", copper = 200 } }, { totalCopper = 999, itemsSold = 12, bestGPH = 3456 })
ok("payload has stats", payload:find("stats:", 1, true) ~= nil)
ok("payload has zones", payload:find("zones:", 1, true) ~= nil)
local dec = gs.decodePayload(payload)
eq("decode totalCopper", dec.stats.totalCopper, 999)
eq("decode itemsSold", dec.stats.itemsSold, 12)
eq("decode bestGPH", dec.stats.bestGPH, 3456)
eq("decode zone name", dec.zones[1].name, "Barrens")
eq("decode zone copper", dec.zones[1].copper, 200)

-- cap to 5 zones + skip delimiter-bad names
local many = {}
for i = 1, 9 do many[i] = { name = "Zone" .. i, copper = i * 10 } end
many[10] = { name = "Bad=Zone", copper = 5 }
local capped = gs.encodePayload(many, { totalCopper = 0, itemsSold = 0, bestGPH = 0 })
local dc = gs.decodePayload(capped)
ok("capped to <= 5 zones", #dc.zones <= 5)
ok("delimiter zone skipped", capped:find("Bad=Zone", 1, true) == nil)
ok("payload under 255 bytes", #capped < 255)

-- merge: pool two replies
local agg = gs.newAggregate()
gs.mergeReply(agg, gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 100 } }, { totalCopper = 100, itemsSold = 5, bestGPH = 1000 })))
gs.mergeReply(agg, gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 50 } }, { totalCopper = 200, itemsSold = 3, bestGPH = 2000 })))
eq("merge memberCount", agg.memberCount, 2)
eq("merge Barrens copper", agg.zones["Barrens"].copper, 150)
eq("merge Barrens contributors", agg.zones["Barrens"].contributors, 2)
eq("merge totalCopper", agg.totalCopper, 300)
eq("merge totalItems", agg.totalItems, 8)
eq("merge bestGPH (max)", agg.bestGPH, 2000)

-- ---- transport handler behavior (privacy-critical paths) ----
EbonClearanceDB = { copperByZone = { Barrens = 100 }, totalCopper = 100, soldItemsByQuality = { 5 }, bestGPH = 50 }

-- opt-in OFF: a GREQ from someone else produces no reply
EbonClearanceDB.shareGuildData = false
clearSent()
handlers.GREQ("", "Other", "GUILD")
ok("no reply when opted out", #sent == 0)

-- opt-in ON: a GREQ from someone else produces exactly one GDAT whisper to them
EbonClearanceDB.shareGuildData = true
clearSent()
handlers.GREQ("", "Other", "GUILD")
ok("one reply when opted in", #sent == 1)
ok("reply is GDAT", sent[1] and sent[1].t == "GDAT")
ok("reply is a whisper to requester", sent[1] and sent[1].channel == "WHISPER" and sent[1].target == "Other")

-- a GREQ that appears to come from ourselves produces no reply
clearSent()
handlers.GREQ("", "Self", "GUILD")
ok("no self-reply", #sent == 0)

-- GDAT merges into the aggregate, and the sender name is never stored
NS.compCache.guildAgg = nil
local gdatPayload = gs.encodePayload({ { name = "Barrens", copper = 100 } }, { totalCopper = 100, itemsSold = 5, bestGPH = 50 })
handlers.GDAT(gdatPayload, "SecretSenderName", "WHISPER")
local a = gs.GetAggregate()
eq("GDAT merged memberCount", a.memberCount, 1)
eq("GDAT merged zone copper", a.zones["Barrens"].copper, 100)
local flat = {}
local function flatten(t)
    for k, v in pairs(t) do
        flat[#flat + 1] = tostring(k)
        if type(v) == "table" then flatten(v) else flat[#flat + 1] = tostring(v) end
    end
end
flatten(a)
ok("sender name not stored in aggregate", table.concat(flat, "|"):find("SecretSenderName", 1, true) == nil)

-- items now travel by NAME (3rd arg). 4th arg is an optional consenting player name.
local pItems = gs.encodePayload(
    { { name = "Barrens", copper = 200 } },
    { totalCopper = 1, itemsSold = 1, bestGPH = 1 },
    { { name = "Silk Cloth", count = 7 }, { name = "Linen Cloth", count = 3 } },
    "Alaric"
)
ok("payload has items section", pItems:find("items:", 1, true) ~= nil)
ok("payload has name section", pItems:find("name:Alaric", 1, true) ~= nil)
local dItems = gs.decodePayload(pItems)
eq("decode item count", #dItems.items, 2)
eq("decode item name", dItems.items[1].name, "Silk Cloth")
eq("decode item count val", dItems.items[1].count, 7)
eq("decode name", dItems.name, "Alaric")
eq("decode still has zone", dItems.zones[1].name, "Barrens")

-- no 4th arg -> anonymous (no name section)
local dAnon = gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 5 } }, { totalCopper = 0, itemsSold = 0, bestGPH = 0 }, { { name = "Wool Cloth", count = 9 } }))
eq("anonymous payload has no name", dAnon.name, nil)
eq("item still parses", dAnon.items[1].name, "Wool Cloth")

-- backward compat: 2-arg encode (no items, no name)
local dNoItems = gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 5 } }, { totalCopper = 0, itemsSold = 0, bestGPH = 0 }))
eq("no items section -> empty items", #dNoItems.items, 0)

-- merge pools items by name; collects consenting contributor names
local aItems = gs.newAggregate()
gs.mergeReply(aItems, gs.decodePayload(gs.encodePayload({}, { totalCopper = 0, itemsSold = 0, bestGPH = 0 }, { { name = "Silk Cloth", count = 5 } }, "Alaric")))
gs.mergeReply(aItems, gs.decodePayload(gs.encodePayload({}, { totalCopper = 0, itemsSold = 0, bestGPH = 0 }, { { name = "Silk Cloth", count = 2 } })))
eq("merged item pooled by name", aItems.items["Silk Cloth"].count, 7)
eq("merged item contributors", aItems.items["Silk Cloth"].contributors, 2)
ok("named contributor recorded", aItems.contributors["Alaric"] == true)

-- ---- static-pattern invariants (scan live code, not comments) ----
local function readCode(p)
    local fh = assert(io.open(p, "r"))
    local s = fh:read("*a")
    fh:close()
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        local t = line:match("^%s*(.-)%s*$") or ""
        if t:sub(1, 2) ~= "--" then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end
local share = readCode("EbonClearance_GuildShare.lua")
ok("exposes NS.GuildShare", share:find("NS.GuildShare", 1, true) ~= nil)
ok("exposes InjectTestPeers diagnostic", share:find("function GuildShare.InjectTestPeers", 1, true) ~= nil)
ok("uses NS.Comms transport", share:find("NS.Comms", 1, true) ~= nil)
ok("reply gated on shareGuildData", share:find("shareGuildData", 1, true) ~= nil)
ok("registers GREQ", share:find('"GREQ"', 1, true) ~= nil)
ok("registers GDAT", share:find('"GDAT"', 1, true) ~= nil)
ok("zone cap constant present", share:find("MAX_ZONES", 1, true) ~= nil)
ok("no 4.0 group event", not share:find("GROUP_ROSTER_UPDATE", 1, true))
local panel = readCode("EbonClearance_GuildPanel.lua")
ok("panel reads aggregate", panel:find("GetAggregate", 1, true) ~= nil)
ok("panel opt-in writes shareGuildData", panel:find("shareGuildData", 1, true) ~= nil)
ok("panel self-registers", panel:find("InterfaceOptions_AddCategory", 1, true) ~= nil)

print()
if fails > 0 then io.stderr:write("RESULT: " .. fails .. " test(s) failed\n"); os.exit(1) end
print("RESULT: all tests passed")
os.exit(0)
