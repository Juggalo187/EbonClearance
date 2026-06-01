-- EbonClearance_Comms.lua
-- Addon-to-addon comms for EbonClearance.
--
-- Modeled on a proven 3.3.5a version-gossip pattern: broadcast a version
-- request on a group channel, peers reply by whisper, nudge once per
-- session. (Neutral framing per repo rule; no third-party addon named.)
--
-- 3.3.5a constraints baked in:
--   * No RegisterAddonMessagePrefix (4.0+): filter CHAT_MSG_ADDON by prefix.
--   * SendAddonMessage channels: PARTY / RAID / GUILD / BATTLEGROUND / WHISPER.
--   * Group events are PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE (the event-hub
--     wiring in EbonClearance_Events.lua uses those, not the 4.0 GROUP_ROSTER_UPDATE).
local NS = select(2, ...)

local Comms = {}
NS.Comms = Comms

local VER_MAJ_FACTOR = 1000000
local VER_MIN_FACTOR = 1000
local VER_COMPONENT_MAX = 1000

-- Encode "v?MAJOR.MINOR.PATCH" as MAJOR*1000000 + MINOR*1000 + PATCH so peers
-- compare numerically. A plain string compare breaks at two digits
-- ("2.10.0" < "2.9.0" lexically); numeric encoding fixes that. Each component
-- must be < 1000; anything malformed returns nil and is ignored upstream.
function Comms.parseVersion(str)
    if type(str) ~= "string" then
        return nil
    end
    local s = str:gsub("^[vV]", "")
    local maj, min, pat = s:match("^(%d+)%.(%d+)%.(%d+)")
    maj, min, pat = tonumber(maj), tonumber(min), tonumber(pat)
    if not (maj and min and pat) then
        return nil
    end
    if maj >= VER_COMPONENT_MAX or min >= VER_COMPONENT_MAX or pat >= VER_COMPONENT_MAX then
        return nil
    end
    return maj * VER_MAJ_FACTOR + min * VER_MIN_FACTOR + pat
end

-- ---- transport ----------------------------------------------------------
local PREFIX = "ECLR1" -- short, distinctive; trailing 1 = protocol version
local SEP = "\t" -- field separator; never appears in version strings or links

local handlers = {} -- msgType -> fn(payload, sender, channel)
local lastSendAt = {} -- throttle key -> GetTime() of last send
local SEND_THROTTLE_S = 30

function Comms.RegisterHandler(msgType, fn)
    handlers[msgType] = fn
end

function Comms.Send(msgType, payload, channel, target)
    local now = GetTime()
    -- Whisper replies throttle per target so we don't re-whisper the same
    -- peer repeatedly; broadcasts throttle per channel.
    local key = (channel == "WHISPER") and ("WHISPER:" .. tostring(target)) or channel
    if lastSendAt[key] and (now - lastSendAt[key]) < SEND_THROTTLE_S then
        return
    end
    lastSendAt[key] = now
    SendAddonMessage(PREFIX, msgType .. SEP .. tostring(payload), channel, target)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(self, event, prefix, message, channel, sender)
    if prefix ~= PREFIX then
        return -- cheap early-out: unrelated addon traffic costs one compare
    end
    local msgType, payload = message:match("^(.-)" .. SEP .. "(.*)$")
    if not msgType then
        return
    end
    local fn = handlers[msgType]
    if fn then
        fn(payload, sender, channel)
    end
end)

-- ---- version-check consumer ---------------------------------------------
local DOWNLOAD_URL = "github.com/powerfulqa/EbonClearance"
local NUDGE_DELAY_S = 3
local versionNudgeShown = false -- once per session

local function myVersionStr()
    return NS.GetVersion and NS.GetVersion() or nil
end

local function playerName()
    return UnitName("player")
end

local function showVersionNudge(peerVerStr)
    if versionNudgeShown then
        return
    end
    versionNudgeShown = true
    NS.PrintNicef(
        "|cffffff00Update available: %s|r (you have %s). |cff33ff33%s|r",
        peerVerStr,
        tostring(myVersionStr()),
        DOWNLOAD_URL
    )
end

-- Decide whether a peer's advertised version should trigger a nudge.
local function considerPeerVersion(verStr, sender)
    if not EbonClearanceDB or not EbonClearanceDB.versionAlerts then
        return
    end
    if sender and sender == playerName() then
        return -- ignore our own broadcast echoed back
    end
    local peerInt = Comms.parseVersion(verStr)
    local myInt = Comms.parseVersion(myVersionStr() or "")
    if not peerInt or not myInt then
        return
    end
    -- Sanity cap: ignore an absurd version (e.g. a troll whispering v99.99.99).
    -- Worst case a spoof costs one harmless chat line, so the guard stays light.
    local myMaj = math.floor(myInt / VER_MAJ_FACTOR)
    local peerMaj = math.floor(peerInt / VER_MAJ_FACTOR)
    if peerMaj > myMaj + 1 then
        return
    end
    if peerInt > myInt and NS.Delay then
        NS.Delay(NUDGE_DELAY_S, function()
            showVersionNudge(verStr)
        end)
    end
end

-- A VERQ carries the sender's version (learn it directly) AND asks us to
-- reply: whisper our version straight back to the requester.
Comms.RegisterHandler("VERQ", function(payload, sender, channel)
    considerPeerVersion(payload, sender)
    if EbonClearanceDB and EbonClearanceDB.versionAlerts and sender and sender ~= playerName() then
        local v = myVersionStr()
        if v then
            Comms.Send("VERR", v, "WHISPER", sender)
        end
    end
end)

-- A VERR is a direct reply carrying the replier's version.
Comms.RegisterHandler("VERR", function(payload, sender, channel)
    considerPeerVersion(payload, sender)
end)

-- ---- self-test diagnostic (/ec commtest) --------------------------------
-- Lets a solo player verify two things without a second client:
--   1. the wire: does this server actually deliver addon messages? (a guild
--      addon message echoes back to the sender on stock 3.3.5a)
--   2. the logic: does a higher peer version produce one nudge, and does the
--      opt-out toggle suppress it?
local commtestToken = nil
local commtestEchoed = false

-- A ping we sent comes back to us (self-echo on GUILD) or a peer answers PONG.
Comms.RegisterHandler("PING", function(payload, sender, channel)
    if commtestToken and payload == commtestToken then
        commtestEchoed = true
        NS.PrintNicef("Comms relay OK: message delivered (echo from %s).", tostring(sender))
    end
    -- If a real peer pinged us, answer so their test can pass too.
    if sender and sender ~= UnitName("player") then
        Comms.Send("PONG", payload, "WHISPER", sender)
    end
end)

Comms.RegisterHandler("PONG", function(payload, sender, channel)
    if commtestToken and payload == commtestToken then
        commtestEchoed = true
        NS.PrintNicef("Comms relay OK: reply received from %s.", tostring(sender))
    end
end)

function Comms.RunSelfTest()
    local myVer = NS.GetVersion and NS.GetVersion() or "unknown"
    NS.PrintNicef("Comms self-test. Your version: %s (parsed %s).",
        myVer, tostring(Comms.parseVersion(myVer)))

    -- 1. Wire relay check (needs a guild; bypasses the normal send throttle).
    if GetGuildInfo("player") then
        commtestToken = tostring(GetTime())
        commtestEchoed = false
        SendAddonMessage(PREFIX, "PING" .. SEP .. commtestToken, "GUILD")
        NS.PrintNicef("Sent a guild ping; waiting for it to echo back...")
        NS.Delay(3, function()
            if not commtestEchoed then
                NS.PrintNicef("Comms relay inconclusive: no echo in 3s. This core may not echo your own guild messages, or addon messages are filtered. Confirm with a second player.")
            end
        end)
    else
        NS.PrintNicef("Not in a guild, skipping the wire echo test. Join any guild to test message delivery.")
    end

    -- 2. Logic + UX check: simulate a higher-version peer through the real path.
    versionNudgeShown = false -- reset so the test is repeatable
    local myInt = Comms.parseVersion(myVer)
    if myInt then
        local maj = math.floor(myInt / 1000000)
        local min = math.floor((myInt % 1000000) / 1000)
        local fakeVer = string.format("v%d.%d.%d", maj, min + 1, 0)
        local alertsOn = EbonClearanceDB and EbonClearanceDB.versionAlerts
        NS.PrintNicef("Simulating a peer on %s. Alerts are %s; %s.",
            fakeVer,
            alertsOn and "ON" or "OFF",
            alertsOn and "an Update available line should appear in ~3s" or "no nudge expected (toggle is off)")
        considerPeerVersion(fakeVer, "CommTest")
    end
end

-- Send-trigger entry point. Called by the event hub in EbonClearance_Events.lua
-- with "GUILD" / "PARTY" / "RAID". Gated + throttled internally.
function Comms.FireVersionProbe(channel)
    if not EbonClearanceDB or not EbonClearanceDB.versionAlerts then
        return
    end
    local v = myVersionStr()
    if not v then
        return
    end
    Comms.Send("VERQ", v, channel)
end
