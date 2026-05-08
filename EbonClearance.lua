-- EbonClearance - auto-vendoring + clearance addon for Project Ebonhold (3.3.5a)
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.

local ADDON_NAME = "EbonClearance"
-- TARGET_NAME / PET_NAME hold the live display names of the two Project
-- Ebonhold companion NPCs. The defaults below are the enUS strings the
-- addon shipped with; v2.9.0 made them user-configurable via DB.merchantName
-- / DB.scavengerName so a realm with a renamed or localised pet can be
-- driven without forking. EnsureDB (and EC_compCache.refreshNames for UI
-- edits) writes back into these locals every time DB is re-read, and
-- PET_NAME_LC is recomputed alongside. Companion lookup is now ID-first via the cache
-- declared in the forward-decl block; the spellID 600126 fallback in
-- FindGoblinMerchantIndex remains the safety net for first-run resolution
-- when the cache is empty AND the merchant has been renamed in DB.
local TARGET_NAME = "Goblin Merchant"
local PET_NAME = "Greedy scavenger"

-- Provenance. Mirrored into globals so the origin/author are visible to any
-- /run introspection, addon-management tool, or crash trace. LICENSE section
-- 2(d) requires these globals to be preserved in any derivative. The
-- double-underscore-prefix-with-addon-name form follows a convention shared
-- elsewhere in the 3.3.5a addon ecosystem; see NOTICE.md for the prior-art
-- acknowledgement.
local ADDON_DISPLAY = "EbonClearance"
local ADDON_AUTHOR = "Serv"
local ADDON_URL = "https://github.com/powerfulqa/EbonClearance"
_G["EBONCLEARANCE_IDENT"] = ADDON_DISPLAY
_G["EBONCLEARANCE_AUTHOR"] = ADDON_AUTHOR
_G["EBONCLEARANCE_ORIGIN"] = ADDON_URL
_G["__EbonClearance_origin"] = ADDON_URL
_G["__EbonClearance_author"] = ADDON_AUTHOR

-- Build-time version. The release workflow rewrites the v2.9.1 placeholder
-- with the pushed git tag (`vX.Y.Z`) via the same `s/v2.9.1/$VERSION/g`
-- sed rule that updates the .toc, so the in-game UI surfaces (settings
-- panel header, bug-report builder, anything routed through EC_GetVersion)
-- always match the .toc on a release build. Dev checkouts keep the literal
-- `v2.9.1`; EC_GetVersion's match check fails on the placeholder and the
-- function falls back to GetAddOnMetadata, which on dev returns the .toc's
-- last-shipped value -- a legitimate "what's actually installed" indicator.
-- Carrying the version here means a stale .toc cache (WoW only re-reads
-- .toc files on full client restart, not /reload) cannot make the displayed
-- version lie on a release build. Pre-v2.9.1 builds shipped a stale "v2.5.0"
-- literal because the workflow's sed pattern didn't match this line; fixed
-- in v2.9.1 by switching to the v2.11.0 placeholder convention.
local ADDON_VERSION = "v2.13.5"
local function EC_GetVersion()
    if ADDON_VERSION:match("^v%d+%.%d+%.%d+") then
        return ADDON_VERSION
    end
    return GetAddOnMetadata("EbonClearance", "Version") or "unknown"
end

-- Salted, deterministic 24-bit hash. Not cryptographic; the goal is trivial
-- verifiability of EbonClearance origin in any derivative work. The salt
-- below is a deliberately visible signature: anyone with our source has it,
-- but to use our fingerprint format they must either (a) carry the salt
-- verbatim - which is the evidence - or (b) re-implement and diverge from
-- the canonical export format, also detectable. Do NOT "clean up" or
-- refactor the salt string away; its presence in code is the point. See
-- docs/ADDON_GUIDE.md "Fingerprint and watermark" for the full convention.
-- The salt lives inside the function body (not at module scope) only so it
-- doesn't consume a main-chunk local slot - Lua 5.1 caps that at 200.
local function EC_Fingerprint(payload)
    local SALT = "EbonClearance|Serv|powerfulqa|2026"
    local s = (payload or "") .. "|" .. SALT
    local h = 5381
    for i = 1, #s do
        -- djb2 step, folded to 24 bits so the printed form fits in 6 hex chars.
        h = ((h * 33) + string.byte(s, i)) % 16777216
    end
    return string.format("%06x", h)
end

-- Build watermark: a precomputed fingerprint of "EbonClearance@<version>".
-- Exposed as a global so /run inspection and external auditors can read it.
-- If this exact 6-char hex value (computed for our version) ever appears in
-- another addon's source, that addon is a verbatim copy of EbonClearance.
-- Written straight to _G to avoid spending a local slot in the main chunk
-- (Lua 5.1's 200-local cap is real and we sit near it).
_G["__EbonClearance_watermark"] = EC_Fingerprint("EbonClearance@" .. ADDON_VERSION)

local EC_GetPlayerName
local EC_IsAddonEnabledForChar

-- Cached WoW 3.3.5a API upvalues. Local lookups beat _G hash on hot paths
-- (bag scans, vendor loop, pet-check OnUpdate). See docs/ADDON_GUIDE.md.
local GetItemInfo = GetItemInfo
local GetContainerItemID = GetContainerItemID
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerNumSlots = GetContainerNumSlots
local UseContainerItem = UseContainerItem
local PickupContainerItem = PickupContainerItem
local DeleteCursorItem = DeleteCursorItem
-- Merchant API (GetMerchantNumItems / GetMerchantItemInfo / GetMerchantItemLink)
-- removed from the cached-upvalue block: not currently called on any hot path.
-- Re-add here if a future feature needs them.
local GetNumCompanions = GetNumCompanions
local GetCompanionInfo = GetCompanionInfo
local CallCompanion = CallCompanion
local IsMounted = IsMounted
local IsEquippedItem = IsEquippedItem
local UnitExists = UnitExists
local UnitName = UnitName
local GetCursorInfo = GetCursorInfo
local GetTime = GetTime
local GetUnitSpeed = GetUnitSpeed

-- Forward declarations. These must exist as upvalues before any function
-- that references them is compiled, or references inside those closures
-- resolve to _G.<name> instead of the intended local. See docs/CODE_REVIEW.md.
local STATE = {
    IDLE = "idle",
    LOOTING = "looting",
    WAITING_MERCHANT = "waiting_merchant",
    SELLING = "selling",
}
local EC_lootCycleState = STATE.IDLE
local EC_addonDismissed = false
-- Cached companion creature IDs and v2.9.0 dismiss-vs-leash classifier state,
-- colocated on a single table to keep the main-chunk local count down (Lua
-- 5.1 caps that at 200; see docs/ADDON_GUIDE.md).
--
-- scav / merch: the CRITTER companion list is keyed by creature ID at the
-- API level; matching on creatureName alone is brittle against rename /
-- localisation. We learn the ID on first successful name match and prefer
-- it on subsequent lookups, falling back to name + re-cache if the slot
-- reshuffles. Both nil means "not yet resolved this session".
--
-- lastSummonAt / userUntil / USER_WINDOW_S / USER_GRACE_S: classifier for
-- "the user just clicked the portrait off" vs "range-leash failure". When
-- WE summon the Scavenger we write GetTime() to lastSummonAt. When the
-- pet's "summoned" flag flips out -> not-out without our own dismiss flag
-- set, and the transition lands within USER_WINDOW_S of that summon, we
-- treat it as a manual portrait click and suppress restore until userUntil.
-- Range-leash transitions take longer to surface, so the timing
-- distinguishes cleanly without misclassifying stationary casts. Restores
-- the discrimination v2.6.1 removed when it dropped the speed-based
-- classifier without a replacement.
local EC_compCache = {
    scav = nil,
    merch = nil,
    lastSummonAt = 0,
    userUntil = 0,
    USER_WINDOW_S = 5.0,
    USER_GRACE_S = 30.0,
    -- v2.9.2 loot-silence false-positive guard. The loot-silence stuck signal
    -- (EC_IsLootSilenceStuck) trips when 2+ LOOT_CLOSED fire inside its
    -- 60 s window without the Scavenger speaking. LOOT_CLOSED also fires
    -- for non-corpse loot sources - disenchanting, milling, prospecting,
    -- lockpicking, opening engineered containers - which the Scavenger
    -- never reacts to, so a player crafting in town would dismiss-and-
    -- resummon the pet every minute. UNIT_SPELLCAST_SUCCEEDED for the
    -- player updates lastProfLootCastAt; the LOOT_CLOSED handler skips
    -- the loot-ring push when (now - lastProfLootCastAt) < PROF_LOOT_WINDOW_S
    -- because the loot frame that just closed was the result of that
    -- profession cast, not a corpse loot. Fishing is excluded via
    -- IsFishingLoot() in the same path.
    lastProfLootCastAt = 0,
    PROF_LOOT_WINDOW_S = 3.0,
    PROF_LOOT_SPELLS = {
        ["Disenchant"] = true,
        ["Milling"] = true,
        ["Prospecting"] = true,
        ["Pick Lock"] = true,
        ["Opening"] = true, -- lockpick + engineering container open
    },
    -- v2.10.0 bind-type cache. Drives the per-rarity bindFilter rule
    -- ("any" / "boe" / "bop") in EC_IsSellable. Bind type is immutable for
    -- a given itemID, so a session-scoped { [itemID] = "boe"|"bop"|"any" }
    -- cache eliminates rescans on every bag walk. The cache is populated
    -- lazily by EC_compCache.getBindType (defined further down once the
    -- shared EC_scanTooltip frame exists). Entries are never invalidated;
    -- the cache resets naturally on /reload because it lives in this
    -- module-local table and isn't persisted.
    bindCache = {},
    -- v2.10.0 resummon-print debounce. v2.9.2 added the "Greedy Scavenger
    -- resummoned." chat line on every successful CallCompanion in the
    -- recovery path, plus a 2 s post-call cooldown to avoid back-to-back
    -- prints. Under heavy combat the server can take 4-6 s to flip the
    -- companion's summoned flag to true, which means the 2 s cooldown
    -- expires while addonDismissed is still set, the pet-tick re-fires
    -- CallCompanion, and the user sees 3-5 "resummoned" lines for one
    -- visible recovery. pendingAnnounce isolates the print from the
    -- retry: every dismiss path that wants the recovery announced sets
    -- it to true; EC_TryResummonScavenger prints only if it's true and
    -- clears it. Subsequent CallCompanion retries within the same cycle
    -- stay silent. The pet-tick clearing of EC_addonDismissed (false ->
    -- true scavenger transition) also clears this flag defensively.
    pendingAnnounce = false,
    -- v2.10.0 silent-realm guard for the v2.7.0 / v2.8.0 loot-silence
    -- stuck signal. The signal assumed the Scavenger pet audibly chats
    -- on every loot pickup, but on Project Ebonhold the pet's chat
    -- events don't always reach the chat filter (server-side throttling,
    -- custom pet behaviour, or the pet just doesn't broadcast on this
    -- realm at all). With the on-summon synthetic refresh of
    -- EC_lastScavSpokeAt, the signal then fires every ~60 s of farming
    -- in a feedback loop. This flag tracks "have we ever observed a
    -- real Scavenger speech event this session" - set to true only by
    -- the chat filter's actual matches (NOT by the on-summon refresh)
    -- and read by EC_IsLootSilenceStuck to early-return when false. If
    -- the pet never speaks on this realm, the flag stays false and the
    -- signal is permanently disabled for the session. Movement-time
    -- stuck detection (EC_STUCK_MOVEMENT_THRESHOLD, 180 s) remains the
    -- primary signal in all cases.
    scavSpeechEverHeard = false,
    -- v2.11.0 bag-full hysteresis. Without this, a single transient
    -- BAG_UPDATE that crosses DB.bagFullThreshold (a vendor opening up,
    -- an item splitting, an inventory shuffle) immediately fires the
    -- dismiss-Scav / summon-Goblin cycle even if the next tick puts the
    -- count back over the threshold. AutoDelete v3.17.x ships a 1.5 s
    -- confirm window for the same reason. bagFullSince is timestamped at
    -- the first tick the threshold is crossed and cleared the moment the
    -- count rises back above it; EC_HandleBagFullForCycle only fires
    -- when (GetTime() - bagFullSince) >= BAG_FULL_CONFIRM_S.
    bagFullSince = nil,
    BAG_FULL_CONFIRM_S = 1.5,
    -- v2.11.0 GCD-aware busy gate. EC_IsPlayerBusy() can detect cast,
    -- channel, and movement, but 3.3.5a has no clean GCD query - so a
    -- heavy instant-cast rotation runs the GCD continuously while every
    -- check between casts reports "not busy". CallCompanion goes through
    -- the spell pipeline and is silently rejected by the GCD, the 2 s
    -- verify reports not-summoned, retry budget exhausts, and the user
    -- sees "Goblin Merchant failed to summon. Resuming looting." even
    -- though they were just spamming instants the whole time.
    --
    -- Workaround: derive the GCD from UNIT_SPELLCAST_SUCCEEDED. After
    -- any player cast we treat the next GCD_WINDOW_S as "busy" too. The
    -- 1.5 s window matches the standard GCD; rotations with shorter
    -- haste-reduced GCDs will see the gate clear too early occasionally,
    -- but those CallCompanion attempts that DO fall in a GCD slot now
    -- just defer (via the busy gate) rather than burning the retry
    -- budget. The fix is for the goblin summon path; the Scavenger
    -- resummon path retries indefinitely anyway via EC_addonDismissed,
    -- so it just defers a bit longer.
    lastPlayerCastAt = 0,
    GCD_WINDOW_S = 1.5,
    -- Auto-open containers combat-deferred announce flag. The driver bails
    -- early on InCombatLockdown() because UseContainerItem on a lockbox
    -- triggers an "Opening" cast that gets interrupted by damage. Without a
    -- signal, deferral looks identical to the addon being broken. This flag
    -- gates a one-shot "[EC] Deferred N container(s) until out of combat."
    -- chat line per combat instance and is cleared on PLAYER_REGEN_ENABLED.
    combatDeferredAnnounced = false,
}
-- Last-tick value of "is the Scavenger summoned?". Drives the OnUpdate
-- movement accumulator (only counts while the pet is out) and the
-- bag-full / mount-cycle paths. Forward-declared here so the closures
-- further down capture it. v2.6.1 dropped the speed-based transition
-- classifier that paired with this flag; see docs/ADDON_GUIDE.md.
local EC_lastScavengerOut = false
-- Player time-spent-moving (seconds) accumulated while the Scavenger is out.
-- Drives the stuck-detection heuristic in EC_HandleScavengerOut. Resets on
-- every Scavenger out<->in transition and after a stuck-dismiss fires.
local EC_scavMovementAccum = 0
-- One-shot guard: at PLAYER_ENTERING_WORLD (post-/reload, post-zone) we scan
-- the companion list once to bootstrap EC_lastScavengerOut. Without this the
-- gate above stays false until the first 5 s tick observes the state, which
-- eats ~5 s of accumulation if the Scavenger was already out at /reload.
local EC_scavStateBootstrapped = false
-- Last GetTime() at which we observed the Scavenger speak (matched in
-- EC_GreedyEventFilter, either by author or by the textual fallback). Drives
-- the loot-silence stuck signal: if the player has looted N+ corpses inside
-- the window without the Scavenger speaking, the pet is presumed lost
-- out-of-range and the addon dismisses-then-resummons. Updated only while
-- DB.autoLootCycle is on, so users not running the cycle pay no extra work
-- on the chat-event path.
local EC_lastScavSpokeAt = 0
-- Ring of GetTime() values pushed on every LOOT_CLOSED (player corpse loot
-- completed). Pruned in place inside EC_IsLootSilenceStuck on each pet-tick
-- check, so it cannot grow unboundedly across a session.
local EC_recentLootTimes = {}
-- v2.9.0 manual-sell attribution. inSelfSell brackets every UseContainerItem
-- call DoNextAction makes so the hooksecurefunc bound at ADDON_LOADED skips
-- it (counters are bumped directly by the worker queue). snapshot is a
-- slot -> { link, count, itemID } map taken at MERCHANT_SHOW and refreshed
-- per-slot after every observed sell; the hook reads it to identify what
-- just left a bag slot once the slot is empty.
local EC_manualSell = {
    inSelfSell = false,
    snapshot = {},
    hookInstalled = false,
}
local running = false

local EC_greedyMessages = {}
local EC_greedyFiltersInstalled = false

-- Forward-declared so EC_AddItemToList (defined below) can call it before the
-- helper body is reached further down the file. Returns the name of a list
-- that already holds the item with a different intent (keep / sell / delete),
-- or nil when the add is safe. Same-intent scopes (character whitelist plus
-- account whitelist) do not conflict.
local EC_FindAddConflict

local function EC_StripCodes(s)
    if type(s) ~= "string" then
        return nil
    end
    return s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
end

local PET_NAME_LC = PET_NAME:lower()
local function EC_IsGreedyAuthor(author)
    if type(author) ~= "string" then
        return false
    end
    author = EC_StripCodes(author)
    if not author or author == "" then
        return false
    end
    return author:lower() == PET_NAME_LC
end

local function EC_TrackGreedySpeech(msg)
    msg = EC_StripCodes(msg)
    if not msg or msg == "" then
        return
    end
    msg = msg:lower()
    -- Store the time of speech rather than a boolean; the bubble OnUpdate
    -- prunes entries older than 8 s each tick (chat bubbles in 3.3.5 are
    -- visible for ~5-7 s, so an 8 s TTL covers a bubble's lifetime). The
    -- truthy value still satisfies the existing
    -- `if EC_greedyMessages[clean] then` match in the bubble walker.
    EC_greedyMessages[msg] = GetTime()
end

local function EC_GreedyEventFilter(self, _event, msg, author)
    local hideChat = true
    local hideBubbles = true
    if DB then
        hideChat = (DB.muteGreedy == true) or (DB.hideGreedyChat == true)
        hideBubbles = (DB.muteGreedy == true) or (DB.hideGreedyBubbles == true)
    end

    -- Record the Scavenger's speech timestamp BEFORE the mute-disabled
    -- early-return below, so the loot-silence stuck signal works even when
    -- the user has both chat and bubble mute off. Gated on DB.autoLootCycle
    -- so users not running the cycle don't pay the author-check on every
    -- chat line.
    --
    -- v2.8.0: substring match on author OR body. Strict equality on
    -- "greedy scavenger" missed Project Ebonhold's customised pet names
    -- (e.g. "Serv's Scavenger") and emote-style messages whose body
    -- contains the species name but no "says/yells/whispers" pattern
    -- ("Greedy Scavenger gnaws on the corpse"). Either source naming the
    -- pet is enough to refresh the speech baseline. Without this, normal
    -- farming triggered false positives every time the player looted
    -- 2 items in 60 s.
    if DB and DB.autoLootCycle then
        local lcAuthor = type(author) == "string" and author:lower() or ""
        if lcAuthor:find("scavenger", 1, true) then
            EC_lastScavSpokeAt = GetTime()
            -- v2.10.0: arm the silent-realm guard. Set ONLY by real chat
            -- matches; the on-summon synthetic refresh further down does
            -- not touch this flag. Once true, the loot-silence stuck
            -- signal is allowed to fire for the rest of the session.
            EC_compCache.scavSpeechEverHeard = true
        elseif type(msg) == "string" then
            local lcMsg = EC_StripCodes(msg):lower()
            if lcMsg:find("scavenger", 1, true) then
                EC_lastScavSpokeAt = GetTime()
                EC_compCache.scavSpeechEverHeard = true
            end
        end
    end

    -- Both feature flags off -> filter has no effect; skip the string-op tail.
    -- Fires on 10 chat events for every line of chat received.
    if not hideChat and not hideBubbles then
        return false
    end

    if EC_IsGreedyAuthor(author) then
        if hideBubbles and type(msg) == "string" then
            EC_TrackGreedySpeech(msg)
        end
        if hideChat then
            return true
        end
    end

    if type(msg) == "string" then
        local clean = EC_StripCodes(msg):lower()
        if
            clean:find("greedy scavenger", 1, true)
            and (clean:find(" says", 1, true) or clean:find(" yells", 1, true) or clean:find(" whispers", 1, true))
        then
            -- Textual-fallback path. Refresh the speech timestamp here too so
            -- the loot-silence signal stays accurate when the chat line
            -- arrives via an event that doesn't set the author field.
            -- v2.10.0: also arm the silent-realm guard here, on the same
            -- "real-speech-observed" rule as the author/body matches above.
            if DB and DB.autoLootCycle then
                EC_lastScavSpokeAt = GetTime()
                EC_compCache.scavSpeechEverHeard = true
            end
            if hideBubbles then
                local said = clean:match("greedy scavenger%s*says[:%s]*(.*)")
                    or clean:match("greedy scavenger%s*yells[:%s]*(.*)")
                    or clean:match("greedy scavenger%s*whispers[:%s]*(.*)")
                if said then
                    EC_TrackGreedySpeech(said)
                end
            end
            if hideChat then
                return true
            end
        end
    end

    return false
end

local function EC_InstallGreedyMuteOnce()
    if EC_greedyFiltersInstalled then
        return
    end
    EC_greedyFiltersInstalled = true

    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_SAY", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_YELL", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_WHISPER", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_EMOTE", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_PARTY", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SAY", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_YELL", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_TEXT_EMOTE", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_EMOTE", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", EC_GreedyEventFilter)
end

local EC_bubbleFrame = CreateFrame("Frame")
local EC_killedBubbles = setmetatable({}, { __mode = "k" })

local function EC_KillBubbleFrame(frame)
    if not frame or frame.__EC_killed then
        return
    end
    frame.__EC_killed = true
    EC_killedBubbles[frame] = true

    frame:SetAlpha(0)
    frame:EnableMouse(false)
    frame:Hide()

    if frame.HookScript then
        frame:HookScript("OnShow", function(self)
            self:SetAlpha(0)
            self:Hide()
        end)
    end
end
EC_bubbleFrame.elapsed = 0
EC_bubbleFrame:SetScript("OnUpdate", function(self, elapsed)
    local hideBubbles = true
    if DB then
        hideBubbles = (DB.muteGreedy == true) or (DB.hideGreedyBubbles == true)
    end
    if not hideBubbles then
        return
    end

    -- Tick gate. 200 ms is short enough that a fresh bubble dies in 1-2
    -- ticks of its visibility window (bubbles last ~5-7 s) and long enough
    -- that the WorldFrame-children walk does not run more than five times
    -- per second in raids, where the child count is highest. Capping the
    -- gated work this way is the cheapest defence against a busy world.
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < 0.20 then
        return
    end
    self.elapsed = 0

    -- Prune expired greedy-speech timestamps (8 s TTL). Without this the
    -- set never empties on its own and the OnUpdate body keeps walking
    -- WorldFrame children long after the Scavenger has gone quiet.
    local now = GetTime()
    local hasLive = false
    for k, t in pairs(EC_greedyMessages) do
        if (now - t) > 8 then
            EC_greedyMessages[k] = nil
        else
            hasLive = true
        end
    end

    -- Nothing tracked: no killed frames to re-hide and no live Greedy speech
    -- to match against. Becomes a constant-time no-op until either set fills.
    if not next(EC_killedBubbles) and not hasLive then
        return
    end

    for bubble in pairs(EC_killedBubbles) do
        if bubble and bubble.IsShown and bubble:IsShown() then
            bubble:SetAlpha(0)
            bubble:Hide()
        end
    end

    if not hasLive then
        return
    end

    local numChildren = WorldFrame and WorldFrame.GetNumChildren and WorldFrame:GetNumChildren() or 0
    for i = 1, numChildren do
        local child = select(i, WorldFrame:GetChildren())
        if child and child.GetObjectType and child:GetObjectType() == "Frame" and child:IsVisible() then
            local numRegions = child.GetNumRegions and child:GetNumRegions() or 0
            for j = 1, numRegions do
                local region = select(j, child:GetRegions())
                if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                    local text = region:GetText()
                    if text then
                        local clean = EC_StripCodes(text):lower()
                        if EC_greedyMessages[clean] then
                            EC_KillBubbleFrame(child)
                            break
                        end
                    end
                end
            end
        end
    end
end)

local CHAT_FILTER_EVENTS = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_EMOTE",
    "CHAT_MSG_TEXT_EMOTE",
}

local function GreedyScavengerChatFilter(self, _event, _msg, author)
    if EC_IsGreedyAuthor(author) then
        return true
    end
    return false
end

local function ApplyGreedyChatFilter()
    for i = 1, #CHAT_FILTER_EVENTS do
        local ev = CHAT_FILTER_EVENTS[i]
        if ChatFrame_RemoveMessageEventFilter then
            ChatFrame_RemoveMessageEventFilter(ev, GreedyScavengerChatFilter)
        end
        if DB and ((DB.muteGreedy == true) or (DB.hideGreedyChat == true)) and ChatFrame_AddMessageEventFilter then
            ChatFrame_AddMessageEventFilter(ev, GreedyScavengerChatFilter)
        end
    end
end

local DB
-- Account-wide SavedVariable. Holds a single `whitelist` table that unions with
-- the per-character whitelist at sell time. Bootstrapped by EnsureAccountDB().
local ADB

-- Resolves list names (used by CreateListUI) to the underlying table. Extra
-- scopes (e.g. account whitelist) register themselves here so CreateListUI can
-- render them without knowing about the scope.
local EC_ExtraListTables = {}

local function EC_GetListTable(name)
    local extra = EC_ExtraListTables[name]
    if extra ~= nil then
        return extra
    end
    return DB and DB[name]
end

local function EnsureAccountDB()
    if EbonClearanceAccountDB == nil then
        EbonClearanceAccountDB = {}
    end
    ADB = EbonClearanceAccountDB
    if type(ADB.whitelist) ~= "table" then
        ADB.whitelist = {}
    end
    EC_ExtraListTables["accountWhitelist"] = ADB.whitelist
end

local function EnsureDB()
    -- Fresh-install detection. We're a fresh install only if neither the
    -- current SavedVariable nor the legacy EbonholdStuff one existed
    -- before this session. Captured BEFORE the rename migration below
    -- so an EbonholdStuff upgrader doesn't get treated as fresh and
    -- have ON-by-default fields enabled without consent. Drives the
    -- "default autoAddEquipped ON for new installs only" rule below.
    local isFreshInstall = (EbonClearanceDB == nil) and (EbonholdStuffDB == nil)

    -- Legacy-rename migration. MUST run before field defaults below, because
    -- the profile-migration block (further down) reads existing DB.whitelist
    -- to decide whether to snapshot it into an "Imported" profile. If field
    -- defaults ran first, DB.whitelist would be {}, and any data the user
    -- had under the old EbonholdStuffDB name would be lost. Order-dependent.
    if EbonholdStuffDB and not EbonClearanceDB then
        EbonClearanceDB = EbonholdStuffDB
        EbonholdStuffDB = nil
    end
    if EbonClearanceDB == nil then
        EbonClearanceDB = {}
    end
    DB = EbonClearanceDB
    EnsureAccountDB()

    if type(DB.deleteList) ~= "table" then
        DB.deleteList = {}
    end
    if type(DB.allowedChars) ~= "table" then
        DB.allowedChars = {}
    end

    if type(DB.totalCopper) ~= "number" then
        DB.totalCopper = 0
    end

    if type(DB.totalItemsSold) ~= "number" then
        DB.totalItemsSold = 0
    end
    if type(DB.totalItemsDeleted) ~= "number" then
        DB.totalItemsDeleted = 0
    end
    if type(DB.totalRepairs) ~= "number" then
        DB.totalRepairs = 0
    end
    if type(DB.totalRepairCopper) ~= "number" then
        DB.totalRepairCopper = 0
    end

    if type(DB.soldItemCounts) ~= "table" then
        DB.soldItemCounts = {}
    end
    if type(DB.deletedItemCounts) ~= "table" then
        DB.deletedItemCounts = {}
    end

    if type(DB.repairGear) ~= "boolean" then
        DB.repairGear = true
    end
    -- v2.9.0: opt-in guild-bank repair. Off by default so existing users
    -- keep paying out of personal funds; turning it on routes through
    -- RepairAllItems(1) when the player is in a guild AND has bank-funded
    -- repair permission AND the bank holds at least the required amount.
    if type(DB.repairUseGuildBank) ~= "boolean" then
        DB.repairUseGuildBank = false
    end

    if type(DB.enableDeletion) ~= "boolean" then
        DB.enableDeletion = true
    end
    if type(DB.summonGreedy) ~= "boolean" then
        DB.summonGreedy = true
    end
    if type(DB.summonOnlyOutOfCombat) ~= "boolean" then
        DB.summonOnlyOutOfCombat = false
    end
    if type(DB.summonDelay) ~= "number" then
        DB.summonDelay = 1.6
    end

    if type(DB.vendorInterval) ~= "number" then
        DB.vendorInterval = 0.1
    end
    if DB.vendorInterval < 0.05 then
        DB.vendorInterval = 0.1
    end
    if type(DB.maxItemsPerRun) ~= "number" then
        DB.maxItemsPerRun = 80
    end
    if type(DB.fastMode) ~= "boolean" then
        DB.fastMode = false
    end
    if type(DB.autoLootCycle) ~= "boolean" then
        -- v2.12.0: fresh installs default ON. The auto-loot cycle is the
        -- headline PE feature (Greedy Scavenger pet looting, Goblin
        -- Merchant auto-summon at bag-full); a brand-new user finishing
        -- the welcome popup with this still off would feel like the
        -- addon "isn't doing anything". Existing characters keep their
        -- saved value via the type-check above. The cycle gracefully
        -- no-ops on realms that lack the PE companion pets.
        DB.autoLootCycle = isFreshInstall
    end
    if type(DB.bagFullThreshold) ~= "number" then
        DB.bagFullThreshold = 2
    end
    if type(DB.autoOpenContainers) ~= "boolean" then
        DB.autoOpenContainers = false
    end
    if DB.merchantMode ~= "goblin" and DB.merchantMode ~= "any" and DB.merchantMode ~= "both" then
        -- v2.13.x: default flipped from "goblin" to "both" so brand-new users
        -- who haven't unlocked the Goblin Merchant pet yet still get useful
        -- auto-vendor behaviour at any normal merchant out of the box.
        -- Existing users with a saved valid value (including "goblin") keep
        -- their choice; this branch only fires when DB.merchantMode is nil
        -- or has somehow corrupted to a non-string value.
        DB.merchantMode = "both"
    end

    -- v2.9.0: companion display names are now user-editable. Defaults are the
    -- enUS strings we shipped with through v2.8.0. EnsureDB and
    -- EC_compCache.refreshNames mirror these into PET_NAME / TARGET_NAME /
    -- PET_NAME_LC locals so every existing reference picks them up without
    -- an audit of every call site.
    --
    -- v2.10.0: removed the user-facing input boxes from the Scavenger
    -- Settings panel after PE-ElvUI clickability issues made the field
    -- unreliable. The DB fields stay as a power-user override (`/run
    -- EbonClearanceDB.merchantName = ...`) but the typical case is now
    -- "fixed at default". One-time migration below resets clearly-broken
    -- values from the v2.9.0 UI session: any name that does not contain
    -- v2.13.3: dropped the v2.10.0 name-reset migration block. Once
    -- DB._v210NameReset became true on every existing user, the inner
    -- string.find guards short-circuited unconditionally; on fresh
    -- installs the EnsureDB defaults assigned just above already
    -- contain "scavenger" / "merchant", so the find checks always
    -- pass and the migration never altered anything. The cluster was
    -- write-only across all reachable code paths post-v2.10.0.
    if type(DB.scavengerName) ~= "string" or DB.scavengerName == "" then
        DB.scavengerName = "Greedy scavenger"
    end
    if type(DB.merchantName) ~= "string" or DB.merchantName == "" then
        DB.merchantName = "Goblin Merchant"
    end

    if type(DB.muteGreedy) ~= "boolean" then
        DB.muteGreedy = true
    end
    if type(DB.hideGreedyChat) ~= "boolean" then
        DB.hideGreedyChat = DB.muteGreedy
    end
    if type(DB.hideGreedyBubbles) ~= "boolean" then
        DB.hideGreedyBubbles = DB.muteGreedy
    end

    if type(DB.enabled) ~= "boolean" then
        DB.enabled = true
    end
    if type(DB.enableOnlyListedChars) ~= "boolean" then
        DB.enableOnlyListedChars = false
    end

    if type(DB.inventoryWorthTotal) ~= "number" then
        DB.inventoryWorthTotal = 0
    end
    if type(DB.inventoryWorthCount) ~= "number" then
        DB.inventoryWorthCount = 0
    end
    if type(DB.whitelist) ~= "table" then
        DB.whitelist = {}
    end
    -- v2.10.0: parallel "source" map flagging which Blacklist (Keep) entries
    -- arrived via the auto-protect-equipped path versus a manual user add.
    -- Used by EC_AnnotateTooltip to surface "(auto-protected: equipped)" so
    -- users who expected an item to sell can see why it's being kept and
    -- follow the existing context-menu remove path to override. The
    -- blacklist check itself (IsInSet(DB.blacklist, ...)) only reads
    -- DB.blacklist; this map is purely diagnostic. Cleared in lockstep
    -- with DB.blacklist on every remove path so it can never carry a
    -- stale entry.
    if type(DB.blacklistAuto) ~= "table" then
        DB.blacklistAuto = {}
    end
    -- v2.10.0: master toggle for the auto-protect-equipped behaviour. When
    -- on, equipping an item auto-adds its ID to the per-character Blacklist
    -- (Keep) list and stamps DB.blacklistAuto. The auto-rules' blacklist
    -- veto then prevents that item from ever auto-selling. Default off so
    -- existing users see no behaviour change until they enable it from
    -- the Blacklist (Keep) panel.
    if type(DB.autoAddEquipped) ~= "boolean" then
        -- Fresh installs from v2.12.0+ default to ON so brand-new users
        -- get equipped-gear protection out of the box - matches AutoDelete
        -- v3.18+ UX. Existing users (v2.10.0+ already have the field as a
        -- boolean and skip this branch; pre-v2.10.0 users hit this branch
        -- but with isFreshInstall = false) keep OFF so they don't see a
        -- silent behaviour change on upgrade.
        DB.autoAddEquipped = isFreshInstall
        if isFreshInstall and DB.autoAddEquipped then
            -- Defer the one-shot equipped-gear sync to PLAYER_LOGIN
            -- (handled at the bottom of the file) - inventory APIs
            -- aren't reliably populated at ADDON_LOADED time.
            EC_compCache.pendingFreshInstallSync = true
        end
        -- v2.12.0: arm the first-run welcome message + setup popup.
        -- Persisted via DB._needsWelcome (not session-scoped) so a
        -- /reload between ADDON_LOADED and PLAYER_LOGIN doesn't lose it.
        -- Existing characters never reach this branch because their
        -- EbonClearanceDB existed before the session and isFreshInstall
        -- is false. The flag is consumed (set to nil) by the
        -- PLAYER_LOGIN handler after the welcome fires.
        if isFreshInstall then
            DB._needsWelcome = true
        end
    end
    if type(DB.autoProtectUpgrades) ~= "boolean" then
        DB.autoProtectUpgrades = false
    end
    -- v2.13.0 Equipment Manager protection. When ON, every item in any of
    -- the player's saved equipment sets (Blizzard's stock 3.3.5a Equipment
    -- Manager, NOT a third-party set addon) lands on the Keep list with
    -- origin tag "set". Solves the dual-spec / off-set problem: items
    -- assigned to your alternate gear set sit in bags between swaps and
    -- are unprotected by autoAddEquipped (which only catches currently-
    -- equipped slots). Default OFF; opt-in. EQUIPMENT_SETS_CHANGED drives
    -- live re-syncs when the user adds / modifies / deletes a set.
    if type(DB.autoProtectEquipmentSets) ~= "boolean" then
        DB.autoProtectEquipmentSets = false
    end
    if type(DB.whitelistMinQuality) ~= "number" then
        DB.whitelistMinQuality = 1
    end
    if DB.whitelistMinQuality > 3 then
        DB.whitelistMinQuality = 3
    end
    if type(DB.whitelistQualityEnabled) ~= "boolean" then
        DB.whitelistQualityEnabled = false
    end

    -- Per-rarity quality threshold rules (v2.4.0+). Replaces the old single
    -- whitelistMinQuality dropdown. Each rarity has its own enabled flag and
    -- optional max iLvl (0 = no cap). Default all off (opt-in). Existing
    -- users get a one-time migration: their old cumulative dropdown maps
    -- to per-rarity flags up to and including the chosen rarity, with no
    -- iLvl cap. The legacy keys stay for one release in case of rollback.
    if type(DB.qualityRules) ~= "table" then
        DB.qualityRules = {
            [1] = { enabled = false, maxILvl = 0 },
            [2] = { enabled = false, maxILvl = 0 },
            [3] = { enabled = false, maxILvl = 0 },
            [4] = { enabled = false, maxILvl = 0 },
        }
        if DB.whitelistQualityEnabled and type(DB.whitelistMinQuality) == "number" then
            -- Legacy migration: the old dropdown only ever offered up to
            -- quality 3. Clamp the migration source to 3 so we don't
            -- accidentally light up Epic on legacy upgraders. Existing
            -- post-v2.4 installs without the legacy keys go through the
            -- per-quality default (all off).
            local minQ = math.min(math.max(DB.whitelistMinQuality, 1), 3)
            for q = 1, minQ do
                DB.qualityRules[q].enabled = true
            end
        end
        -- v2.12.0: fresh installs default to dynamic-cap mode for whites
        -- and greens so brand-new players get useful auto-vendoring out
        -- of the box without risk - the cap follows their equipped iLvl
        -- in the same slot, so anything they're already wearing stays
        -- safe and any quest reward they haven't equipped yet would
        -- have to be a strict downgrade vs current gear to vendor.
        -- Blues and purples stay disabled - whitelist territory.
        if isFreshInstall then
            DB.qualityRules[1].enabled = true
            DB.qualityRules[1].useEquippedILvl = true
            DB.qualityRules[2].enabled = true
            DB.qualityRules[2].useEquippedILvl = true
        end
    end
    for q = 1, 4 do
        if type(DB.qualityRules[q]) ~= "table" then
            DB.qualityRules[q] = { enabled = false, maxILvl = 0 }
        end
        if type(DB.qualityRules[q].enabled) ~= "boolean" then
            DB.qualityRules[q].enabled = false
        end
        if type(DB.qualityRules[q].maxILvl) ~= "number" then
            DB.qualityRules[q].maxILvl = 0
        end
        if DB.qualityRules[q].maxILvl < 0 then
            DB.qualityRules[q].maxILvl = 0
        end
        if DB.qualityRules[q].maxILvl > 300 then
            DB.qualityRules[q].maxILvl = 300
        end
        -- v2.10.0: per-rarity bind-type filter. "any" preserves the v2.4.0+
        -- behaviour (rule applies regardless of bind type); "boe" / "bop"
        -- restrict matches to items the tooltip says bind on equip / on
        -- pickup. Items with no bind line at all (consumables, reagents)
        -- read as "any" from EC_compCache.getBindType and are protected
        -- when bindFilter is "boe" or "bop". Existing users see the "any"
        -- default; idempotent re-init matches the rest of EnsureDB.
        if type(DB.qualityRules[q].bindFilter) ~= "string" then
            DB.qualityRules[q].bindFilter = "any"
        end
        if
            DB.qualityRules[q].bindFilter ~= "any"
            and DB.qualityRules[q].bindFilter ~= "boe"
            and DB.qualityRules[q].bindFilter ~= "bop"
        then
            DB.qualityRules[q].bindFilter = "any"
        end
        -- v2.12.0: per-rarity dynamic-cap mode. When true, the maxILvl
        -- input is ignored at runtime and the cap is the equipped item's
        -- iLvl in the same slot (per-item lookup via
        -- EC_compCache.isDowngradeVsEquipped). Existing users default
        -- to false (fixed-cap mode preserved); fresh installs flip
        -- whites and greens to true via the table-init branch above.
        if type(DB.qualityRules[q].useEquippedILvl) ~= "boolean" then
            DB.qualityRules[q].useEquippedILvl = false
        end
    end
    if type(DB.minimapButtonAngle) ~= "number" then
        DB.minimapButtonAngle = 220
    end
    if type(DB.keepBagsOpen) ~= "boolean" then
        -- v2.12.0: flipped from true to false per UX feedback - the
        -- "bags stay open after merchant closes" behaviour was felt
        -- as intrusive. Existing users with the field already set to
        -- true keep their saved value and can untick the panel toggle
        -- if they want bags closing again. New installs default off.
        DB.keepBagsOpen = false
    end
    -- v2.13.3: dropped the DB.vendorBtnShown defaulter alongside the
    -- vendor-button cluster removal. The field had no readers in any
    -- live code path post-v2.13.0 (the only consumer was
    -- EC_UpdateVendorButtonVisibility which itself was orphaned).
    if type(DB.blacklist) ~= "table" then
        DB.blacklist = {}
    end

    -- Whitelist profiles migration. First-run of the profile-aware schema:
    -- if the user already has items in the flat DB.whitelist (from pre-profile
    -- builds, or from the EbonholdStuffDB rename above), snapshot them into
    -- an "Imported" profile and auto-activate it so nothing is lost. Fresh
    -- installs get an empty Default profile as the active one. Depends on
    -- DB.whitelist having been initialised upstream -- do not reorder.
    if type(DB.whitelistProfiles) ~= "table" then
        DB.whitelistProfiles = {}
        DB.whitelistProfiles["Default"] = {}
        local hasItems = next(DB.whitelist) ~= nil
        if hasItems then
            local snapshot = {}
            for k, v in pairs(DB.whitelist) do
                snapshot[k] = v
            end
            DB.whitelistProfiles["Imported"] = snapshot
            DB.activeProfileName = "Imported"
        else
            DB.activeProfileName = "Default"
        end
    end
    if type(DB.activeProfileName) ~= "string" then
        DB.activeProfileName = "Default"
    end
    DB.whitelistProfiles["Default"] = {}
    if type(DB.blacklistProfiles) ~= "table" then
        DB.blacklistProfiles = {}
    end

    -- v2.13.3: dropped the DB._seededLists write-only guard. The seed body
    -- it once gated (item IDs 300581 / 300574, removed in the v2.0.13
    -- quality pass) hasn't existed for many releases; the flag was being
    -- written but never read. New first-install seeding, if ever needed,
    -- should use a feature-specific guard rather than reviving this one.

    -- Mirror name fields into PET_NAME / TARGET_NAME / PET_NAME_LC. Done in
    -- EnsureDB rather than in a separate helper so every caller (event hub,
    -- slash commands, settings panels) inherits the same up-to-date strings
    -- without each having to refresh manually. The companion-ID cache is
    -- wiped so the next lookup re-learns under the new names.
    if type(DB.scavengerName) == "string" and DB.scavengerName ~= "" then
        PET_NAME = DB.scavengerName
    end
    if type(DB.merchantName) == "string" and DB.merchantName ~= "" then
        TARGET_NAME = DB.merchantName
    end
    PET_NAME_LC = PET_NAME:lower()
    EC_compCache.scav = nil
    EC_compCache.merch = nil
end

-- Session stats (in-memory only; reset on /reload or by user button).
local EC_session = {
    copper = 0,
    sold = 0,
    deleted = 0,
    repairs = 0,
    repairCopper = 0,
}

local function EC_ResetSession()
    EC_session.copper = 0
    EC_session.sold = 0
    EC_session.deleted = 0
    EC_session.repairs = 0
    EC_session.repairCopper = 0
end

-- Keep bags open when merchant closes
local EC_keepBagsFlag = false

local function EC_OpenAllBags()
    if OpenAllBags then
        OpenAllBags()
    elseif OpenBackpack then
        OpenBackpack()
        for i = 1, 4 do
            if OpenBag then
                OpenBag(i)
            end
        end
    end
end

EC_GetPlayerName = function()
    local n = UnitName("player")
    if not n or n == "" then
        return ""
    end
    return n
end

local function EC_IsCharacterAllowed()
    if not DB or not DB.enableOnlyListedChars then
        return true
    end
    if not DB.allowedChars then
        return false
    end
    local name = EC_GetPlayerName()
    -- Fast path: exact-case match (the common case for entries added via
    -- the Add Me button or typed identically).
    if DB.allowedChars[name] == true then
        return true
    end
    -- v2.13.1 robustness: case-insensitive + invisible-whitespace-stripped
    -- fallback. Catches entries added with different capitalisation
    -- (user typed "zittla" but UnitName returns "Zittla"), entries
    -- pasted from chat / web with embedded non-breaking space (U+00A0)
    -- or zero-width joiner (U+200B), and similar look-alike strings the
    -- v2.13.0 add-time trim missed. On a single PE-style private server
    -- character names are unique by case, so a lowercase match cannot
    -- collide with another player's name.
    local function strip(s)
        return (s or ""):lower():gsub("[%s\194\160\226\128\139]+", "")
    end
    local target = strip(name)
    if target == "" then
        return false
    end
    for key, val in pairs(DB.allowedChars) do
        if val == true and type(key) == "string" and strip(key) == target then
            return true
        end
    end
    return false
end

EC_IsAddonEnabledForChar = function()
    if DB and DB.enabled == false then
        return false
    end
    return EC_IsCharacterAllowed()
end

local function IsInSet(setTable, itemID)
    if not itemID or not setTable then
        return false
    end
    local v = setTable[itemID]
    return (v == true) or (v == 1)
end

-- Whitelist profile functions
local function EC_ValidateProfileName(name)
    if type(name) ~= "string" then
        return false, "Invalid name."
    end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        return false, "Profile name cannot be empty."
    end
    if name:find("[:|]") then
        return false, "Profile name cannot contain : or | characters."
    end
    return true, name
end

local function EC_CountItems(tbl)
    local n = 0
    for k, v in pairs(tbl) do
        if type(k) == "number" and (v == true or v == 1) then
            n = n + 1
        end
    end
    return n
end

local function EC_SaveProfile(name)
    local ok, cleaned = EC_ValidateProfileName(name)
    if not ok then
        return false, cleaned
    end
    name = cleaned
    if name == "Default" then
        return false, "The Default profile is locked to empty and cannot be overwritten."
    end
    local snapshot = {}
    for k, v in pairs(DB.whitelist) do
        snapshot[k] = v
    end
    DB.whitelistProfiles[name] = snapshot
    local blSnapshot = {}
    for k, v in pairs(DB.blacklist) do
        blSnapshot[k] = v
    end
    DB.blacklistProfiles[name] = blSnapshot
    DB.activeProfileName = name
    local wlCount = EC_CountItems(snapshot)
    local blCount = EC_CountItems(blSnapshot)
    return true, string.format('Saved profile "|cffffff00%s|r" (%d whitelist, %d blacklist).', name, wlCount, blCount)
end

local function EC_LoadProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format('Profile "%s" not found.', tostring(name))
    end
    wipe(DB.whitelist)
    -- v2.10.0: profiles persist Whitelist + Blacklist item IDs but not the
    -- "auto-added when equipped" source flag. Loading a profile is a fresh
    -- intent (the user is changing what they want protected); reset the
    -- Blacklist auto map so leftover entries from the previous profile
    -- don't bleed their tooltip annotation through.
    if type(DB.blacklistAuto) == "table" then
        wipe(DB.blacklistAuto)
    end
    for k, v in pairs(DB.whitelistProfiles[name]) do
        DB.whitelist[k] = v
    end
    wipe(DB.blacklist)
    if DB.blacklistProfiles[name] then
        for k, v in pairs(DB.blacklistProfiles[name]) do
            DB.blacklist[k] = v
        end
    end
    DB.activeProfileName = name
    local wlCount = EC_CountItems(DB.whitelist)
    local blCount = EC_CountItems(DB.blacklist)
    -- Refresh panels if they exist
    local wp = _G["EbonClearanceOptionsWhitelist"]
    if wp and wp.listUI then
        wp.listUI:Refresh()
    end
    local bp = _G["EbonClearanceOptionsBlacklist"]
    if bp and bp.listUI then
        bp.listUI:Refresh()
    end
    return true, string.format('Loaded profile "|cffffff00%s|r" (%d whitelist, %d blacklist).', name, wlCount, blCount)
end

local function EC_DeleteProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format('Profile "%s" not found.', tostring(name))
    end
    if name == "Default" then
        return false, "The Default profile cannot be deleted."
    end
    -- Count remaining profiles
    local count = 0
    for _ in pairs(DB.whitelistProfiles) do
        count = count + 1
    end
    if count <= 1 then
        return false, "Cannot delete the only remaining profile."
    end
    DB.whitelistProfiles[name] = nil
    DB.blacklistProfiles[name] = nil
    if DB.activeProfileName == name then
        DB.activeProfileName = next(DB.whitelistProfiles) or "Default"
    end
    return true, string.format('Deleted profile "|cffffff00%s|r".', name)
end

local function EC_RenameProfile(oldName, newName)
    if type(oldName) ~= "string" or not DB.whitelistProfiles[oldName] then
        return false, string.format('Profile "%s" not found.', tostring(oldName))
    end
    if oldName == "Default" then
        return false, "The Default profile cannot be renamed."
    end
    local ok, cleaned = EC_ValidateProfileName(newName)
    if not ok then
        return false, cleaned
    end
    newName = cleaned
    if newName == "Default" then
        return false, 'Cannot rename a profile to "Default".'
    end
    if newName == oldName then
        return true, "Name unchanged."
    end
    if DB.whitelistProfiles[newName] then
        return false, string.format('A profile named "%s" already exists.', newName)
    end
    DB.whitelistProfiles[newName] = DB.whitelistProfiles[oldName]
    DB.whitelistProfiles[oldName] = nil
    if DB.blacklistProfiles[oldName] then
        DB.blacklistProfiles[newName] = DB.blacklistProfiles[oldName]
        DB.blacklistProfiles[oldName] = nil
    end
    if DB.activeProfileName == oldName then
        DB.activeProfileName = newName
    end
    return true, string.format('Renamed "|cffffff00%s|r" to "|cffffff00%s|r".', oldName, newName)
end

local function CopperToColoredText(copper)
    if not copper or copper < 0 then
        copper = 0
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100

    local g = string.format("|cffF8D943%dg|r", gold)
    local s = string.format("|cffC0C0C0%ds|r", silver)
    local c = string.format("|cffB87333%dc|r", cop)
    return string.format("%s %s %s", g, s, c)
end

local function PrintNice(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[EbonClearance]|r " .. msg)
end

-- Format + print convenience. Use instead of PrintNice(string.format(fmt, ...)).
local function PrintNicef(fmt, ...)
    PrintNice(string.format(fmt, ...))
end

-- Price provider seam. Vendor price is the only source today; probes for
-- Auctionator-WotLK / Auctioneer can be dropped in here without touching
-- callers. The _-prefixed args are reserved for those probes -- rename them
-- when activating a probe.
local function EC_GetItemPrice(_itemLink, _itemID, sellPrice, count)
    -- if _G.Auctionator_GetPrice then
    --     local v = _G.Auctionator_GetPrice(_itemLink)
    --     if v and v > 0 then return v * (count or 1) end
    -- end
    -- if _G.AucAdvanced and _G.AucAdvanced.API and _G.AucAdvanced.API.GetMarketValue then
    --     local v = _G.AucAdvanced.API.GetMarketValue(_itemLink)
    --     if v and v > 0 then return v * (count or 1) end
    -- end
    return (sellPrice or 0) * (count or 1)
end

local function EC_CalcInventoryWorthCopper()
    local total = 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local _, itemCount = GetContainerItemInfo(bag, slot)
                if itemCount and itemCount > 0 then
                    local sellPrice = select(11, GetItemInfo(itemID))
                    if sellPrice and sellPrice > 0 then
                        total = total + (sellPrice * itemCount)
                    end
                end
            end
        end
    end
    return total
end

local function EC_RecordInventoryWorthSample()
    if not DB then
        return
    end
    local worth = EC_CalcInventoryWorthCopper()
    DB.inventoryWorthTotal = (DB.inventoryWorthTotal or 0) + worth
    DB.inventoryWorthCount = (DB.inventoryWorthCount or 0) + 1
end

local EC_activeIDBox = nil
local EC_Original_ChatEdit_InsertLink = ChatEdit_InsertLink

local function EC_ExtractItemID(link)
    if type(link) ~= "string" then
        return nil
    end
    local id = link:match("item:(%d+)")
    if id then
        return tonumber(id)
    end
    return nil
end

ChatEdit_InsertLink = function(link)
    if EC_activeIDBox and EC_activeIDBox:IsShown() then
        local id = EC_ExtractItemID(link)
        if id then
            EC_activeIDBox:SetText(tostring(id))
            EC_activeIDBox:HighlightText()
            return true
        end
    end
    return EC_Original_ChatEdit_InsertLink(link)
end

-- True if the player is in a state that will silently swallow CallCompanion.
-- Catches: cast-time spells (UnitCastingInfo), channels (UnitChannelInfo),
-- and movement (GetUnitSpeed > 0). Doesn't catch the bare GCD from instant-
-- cast abilities -- 3.3.5a doesn't expose a clean GCD query -- but the
-- retry-until-confirmed loops above this layer compensate for that gap.
local function EC_IsPlayerBusy()
    if UnitCastingInfo and UnitCastingInfo("player") then
        return true
    end
    if UnitChannelInfo and UnitChannelInfo("player") then
        return true
    end
    if GetUnitSpeed and GetUnitSpeed("player") > 0 then
        return true
    end
    -- v2.11.0: GCD proxy. UNIT_SPELLCAST_SUCCEEDED stamps lastPlayerCastAt
    -- on every player cast (instant or otherwise); the GCD blocks
    -- CallCompanion for ~1.5 s afterwards. Without this, rapid instant-
    -- cast rotations slipped through the busy gate and burned the goblin
    -- summon retry budget on calls the server silently dropped.
    if (GetTime() - EC_compCache.lastPlayerCastAt) < EC_compCache.GCD_WINDOW_S then
        return true
    end
    return false
end

-- Companion lookup primitives. Match by name (case-insensitive equality), or
-- by a previously-cached creature ID. The ID path is the cheap path: a single
-- numeric compare per slot. The name path is the cold-cache fallback and the
-- post-rename recovery path. Both return (index, isSummoned, creatureID) or
-- (nil, false, nil); callers re-cache the ID on every successful hit.
-- Hung off EC_compCache rather than as module-scope locals so the helpers
-- and the cache they read share a namespace and we save two main-chunk
-- local slots (Lua 5.1 caps that at 200).
function EC_compCache.findByName(name)
    if not name or name == "" then
        return nil, false, nil
    end
    local num = GetNumCompanions("CRITTER") or 0
    local needle = string.lower(name)
    for i = 1, num do
        local cId, cName, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if cName and string.lower(cName) == needle then
            return i, isSummoned, cId
        end
    end
    return nil, false, nil
end

function EC_compCache.findByID(cachedID, fallbackName)
    if cachedID then
        local num = GetNumCompanions("CRITTER") or 0
        for i = 1, num do
            local cId, _, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
            if cId == cachedID then
                return i, isSummoned, cId
            end
        end
    end
    return EC_compCache.findByName(fallbackName)
end

-- Apply DB-side companion display names to the file-scope PET_NAME /
-- TARGET_NAME / PET_NAME_LC locals and wipe the ID cache. EnsureDB does
-- the same work at the end of its body; this lightweight method is for
-- UI handlers that change a name without wanting the full DB validation
-- pass.
function EC_compCache.refreshNames()
    if not DB then
        return
    end
    if type(DB.scavengerName) == "string" and DB.scavengerName ~= "" then
        PET_NAME = DB.scavengerName
    end
    if type(DB.merchantName) == "string" and DB.merchantName ~= "" then
        TARGET_NAME = DB.merchantName
    end
    PET_NAME_LC = PET_NAME:lower()
    EC_compCache.scav = nil
    EC_compCache.merch = nil
end

local function SummonGreedyScavenger()
    -- Don't summon while mounted (delayed calls from dismount can race with remounting)
    if IsMounted and IsMounted() then
        return
    end

    local idx, isSummoned, cId = EC_compCache.findByID(EC_compCache.scav, PET_NAME)
    if cId then
        EC_compCache.scav = cId
    end
    if not idx then
        return
    end

    if not isSummoned then
        -- v2.7.1: cast-busy gate. CallCompanion goes through the
        -- spell-cast pipeline; if the player is mid-cast / channel /
        -- moving, the server silently rejects it. Marking
        -- EC_addonDismissed=true and bailing out routes recovery
        -- through EC_TryResummonScavenger's tick path, which has
        -- the same busy gate plus retry-until-confirmed.
        if EC_IsPlayerBusy() or (DB and DB.summonOnlyOutOfCombat and InCombatLockdown()) then
            EC_addonDismissed = true
            -- v2.10.0: arm the resummon-print debounce so the eventual
            -- pet-tick retry that catches a clear cast/movement window
            -- prints once. Without this, FinishRun-initiated summons that
            -- bounce off the busy gate would silently recover. v2.11.0
            -- extends the gate with the optional combat-only setting:
            -- when DB.summonOnlyOutOfCombat is true, defer the summon
            -- until combat ends. The pet-tick retry path picks it up
            -- the moment InCombatLockdown clears.
            EC_compCache.pendingAnnounce = true
            return
        end
        -- Dismiss any active critter first, then summon Scavenger
        if DismissCompanion then
            DismissCompanion("CRITTER")
        end
        CallCompanion("CRITTER", idx)
        -- v2.9.0: anchor the user-dismiss-vs-leash classification window.
        -- A subsequent out -> not-out transition within EC_compCache.USER_WINDOW_S
        -- of this timestamp is treated as "the user clicked the portrait off".
        EC_compCache.lastSummonAt = GetTime()
        -- v2.11.0: do NOT clear EC_addonDismissed or pendingAnnounce here.
        -- A combat keypress that lands in the same client tick as
        -- CallCompanion can take the cast slot and silently reject the
        -- summon; if we'd already cleared EC_addonDismissed the pet-tick
        -- retry path (the only thing that would catch the rejection) is
        -- disarmed and the Scavenger stays gone for the rest of the
        -- session. The pet-tick at the EC_PetCheckTick transition handler
        -- is the canonical "summon confirmed" signal and clears both
        -- flags after observing scavengerOut=true. Same model v2.6.1
        -- applied to EC_TryResummonScavenger.
    else
        -- Already out on entry: CallCompanion is a no-op, safe to clear
        -- both flags here (no rejection window to worry about).
        EC_addonDismissed = false
        EC_compCache.pendingAnnounce = false
    end
    -- Sync the stuck-detection gate immediately so the OnUpdate
    -- accumulator starts counting from this summon, not from the
    -- next 5 s tick observation.
    EC_lastScavengerOut = true
    EC_scavMovementAccum = 0
    if DB and DB.autoLootCycle then
        EC_lootCycleState = STATE.LOOTING
    end
end

local function DismissGreedyScavenger()
    EC_addonDismissed = true
    EC_lastScavengerOut = false
    EC_scavMovementAccum = 0
    if DismissCompanion then
        DismissCompanion("CRITTER")
    else
        local num = GetNumCompanions("CRITTER")
        if not num or num <= 0 then
            return
        end
        for i = 1, num do
            local _, creatureName, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
            if creatureName == PET_NAME and isSummoned then
                CallCompanion("CRITTER", i)
                return
            end
        end
    end
end

-- The spellID branch is the localisation escape hatch. If a future Ebonhold
-- realm ships with a non-enUS name for the Goblin Merchant companion, the
-- name match fails but the spellID match still finds it. See TARGET_NAME
-- note at the top of the file.
local GOBLIN_MERCHANT_SPELL_ID = 600126

-- The "CRITTER" companion type in the 3.3.5a API covers both cosmetic vanity
-- pets AND functional companions like the Goblin Merchant on Project Ebonhold
-- -- they share one companion slot. That's why summoning the Merchant
-- dismisses the Scavenger and vice versa: they can't coexist.
--
-- Lookup is ID-first (cheap, survives a future rename / localisation), with a
-- name fallback that also matches on spellID 600126 so the very first lookup
-- on a fresh client still resolves the merchant before any cache exists.
local function FindGoblinMerchantIndex()
    if EC_compCache.merch then
        local num = GetNumCompanions("CRITTER") or 0
        for i = 1, num do
            local cId, _, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
            if cId == EC_compCache.merch then
                return i, isSummoned
            end
        end
    end
    local num = GetNumCompanions("CRITTER") or 0
    for i = 1, num do
        local cId, creatureName, spellID, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if creatureName == TARGET_NAME or spellID == GOBLIN_MERCHANT_SPELL_ID then
            EC_compCache.merch = cId
            return i, isSummoned
        end
    end
    return nil
end

-- Locate the Greedy Scavenger in the player's companion list. Returns
-- (index, isSummoned). index is nil if the pet isn't in the list at all
-- (e.g. user hasn't learned it). ID-first lookup keeps the rename / L10n
-- escape hatch consistent with the merchant path.
local function EC_FindGreedyScavenger()
    local idx, isSummoned, cId = EC_compCache.findByID(EC_compCache.scav, PET_NAME)
    if cId then
        EC_compCache.scav = cId
    end
    if not idx then
        return nil, false
    end
    return idx, isSummoned
end

-- SummonGoblinMerchant / DismissGoblinMerchant helpers were removed: the
-- auto-loot-cycle pet management now drives the merchant companion via
-- EC_TickGoblinSummon and friends; nothing else called these wrappers.

-- Returns a coloured string describing the user's current binding for the
-- "Target Goblin Merchant" action, or a prompt if none is bound. Used in
-- the summon-confirmation chat line so users can discover the keybind.
local function EC_FormatTargetMerchantBinding()
    if not GetBindingKey then
        return "your bound key"
    end
    local key = GetBindingKey("CLICK EbonClearanceTargetMerchantButton:LeftButton")
    if key and key ~= "" then
        return "|cffffff00" .. key .. "|r"
    end
    return "|cffaaaaaaa key|r (bind one in ESC > Key Bindings > EbonClearance)"
end

local EC_wasMounted = false
local EC_mountDismissTime = 0
-- STATE, EC_lootCycleState, EC_addonDismissed are forward-declared at the
-- top of the file so functions compiled earlier capture them as upvalues.

local EC_delayFrame = CreateFrame("Frame")
local EC_timers = {}

local function EC_Delay(seconds, func)
    if type(func) ~= "function" then
        return
    end
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        func()
        return
    end
    EC_timers[#EC_timers + 1] = { t = seconds, f = func }
end

EC_delayFrame:SetScript("OnUpdate", function(self, elapsed)
    if #EC_timers == 0 then
        return
    end
    for i = #EC_timers, 1, -1 do
        local item = EC_timers[i]
        item.t = item.t - elapsed
        if item.t <= 0 then
            table.remove(EC_timers, i)
            local ok, err = pcall(item.f)
            if not ok and geterrorhandler then
                geterrorhandler()(err)
            end
        end
    end
end)

local function EC_SummonGreedyWithDelay()
    if not DB or not DB.summonGreedy then
        return
    end
    EC_Delay((DB and DB.summonDelay) or 1.6, SummonGreedyScavenger)
end

local function EC_GetFreeBagSlots()
    local free = 0
    for bag = 0, 4 do
        local numFree = GetContainerNumFreeSlots(bag)
        if numFree then
            free = free + numFree
        end
    end
    return free
end

-- Stuck-detection threshold (seconds of player movement) above which we
-- assume the Scavenger has been left behind and dismiss-then-re-summon at
-- the player's current position. The CRITTER companion tries to follow but
-- stops on rough terrain or once the player outruns it.
--
-- We use a movement-time accumulator instead of measuring distance because
-- UnitPosition("pet") doesn't return data for CRITTER-type companions on
-- 3.3.5a (the unit ID "pet" refers to combat pets only). GetUnitSpeed works
-- universally and is what we accumulate against in the OnUpdate.
--
-- v2.6.1 raised this from 20 s to 180 s (in two steps: 20->60 then 60->180
-- after in-game testing). 20 s of cumulative movement happens inside
-- ~60-90 s of normal questing, so the original value triggered a dismiss-
-- and-resummon roughly every minute or two even when the pet wasn't
-- actually stuck. 60 s was less twitchy but still fired during ordinary
-- kill-loot-move play. 180 s leaves the pet alone through normal questing
-- cadence -- mob fight, loot, move on, repeat -- and only intervenes when
-- the player has been moving for a sustained period that's almost
-- certainly outpaced the leash.
local EC_STUCK_MOVEMENT_THRESHOLD = 180

-- Fast Mode: when enabled, pin the per-item vendor interval to the 0.05 s
-- floor and double the per-run cap. Opt-in via DB.fastMode.
local function EC_EffectiveVendorInterval()
    if DB and DB.fastMode then
        return 0.05
    end
    local i = (DB and DB.vendorInterval) or 0.1
    if i < 0.05 then
        i = 0.05
    end
    return i
end

local function EC_EffectiveMaxItemsPerRun()
    if DB and DB.fastMode then
        return 160
    end
    return (DB and DB.maxItemsPerRun) or 80
end

-- Pet-cycle timer/flag locals. MUST be declared before EC_HandleBagFullForCycle:
-- that function (BAG_UPDATE handler) writes EC_summonGoblinPending /
-- EC_summonGoblinTimer, and Lua resolves writes to whatever is in scope at the
-- function's parse site. If these aren't locals yet, the writes leak to _G and
-- the OnUpdate consumer at the bottom (which captures them as locals) never
-- sees them - the cycle hangs in WAITING_MERCHANT forever. This is the same
-- trap v2.0.13 fixed for STATE / running / EC_lootCycleState; see CLAUDE.md
-- convention #4.
-- Pet-check tick interval. Below this, the OnUpdate body returns early.
-- 5 s is the cadence used for state reconciliation, stuck detection, and
-- re-summon - low enough to react to a despawn within a reasonable window
-- but high enough to avoid scanning companion state every frame.
local EC_PET_CHECK_INTERVAL = 5
local EC_petCheckElapsed = 0
local EC_summonGoblinPending = false
local EC_summonGoblinTimer = 0
local EC_targetGoblinPending = false
local EC_targetGoblinTimer = 0
-- Counter of CallCompanion attempts in the current bag-full cycle. When the
-- 2 s verify (EC_TickGoblinTarget) sees the Goblin not summoned, we re-arm
-- the dismiss-then-summon path with a short delay so EC_TickGoblinSummon's
-- cast-busy gate gets another chance to fire during a clear window. v2.6.2
-- raised the cap from a single retry (boolean) to EC_GOBLIN_MAX_RETRIES
-- attempts: under heavy combat the bare GCD from instant-cast rotations
-- can swallow several attempts in a row before one lands cleanly.
-- Reset to 0 at every fresh bag-full cycle in EC_HandleBagFullForCycle.
local EC_goblinRetryCount = 0
local EC_GOBLIN_MAX_RETRIES = 3
local EC_merchantReminderPending = false
local EC_merchantReminderTimer = 0
-- Auto-open container in-flight flag. Same forward-declaration discipline as
-- the timers above: EC_HandleAutoOpenContainers writes this, and we don't want
-- the write to leak into _G if the function is parsed before the local exists.
local EC_autoOpenInFlight = false

-- Auto-loot cycle: react to bag-full as soon as the game tells us a bag
-- changed. Same body as the old 5-second poll; called from BAG_UPDATE so the
-- Goblin Merchant is summoned within a tick of the threshold being crossed.
-- Idempotent: the STATE.LOOTING guard prevents double-summon under burst events.
local function EC_HandleBagFullForCycle()
    if not DB or not DB.autoLootCycle then
        return
    end
    if EC_lootCycleState ~= STATE.LOOTING then
        return
    end
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if running then
        return
    end
    if IsMounted() then
        return
    end
    local free = EC_GetFreeBagSlots()
    if free > (DB.bagFullThreshold or 2) then
        -- v2.11.0: clear the hysteresis stamp the moment we rise back
        -- above the threshold. A subsequent dip will start a fresh
        -- confirm window from the new GetTime().
        EC_compCache.bagFullSince = nil
        return
    end
    -- v2.11.0 hysteresis: require the threshold to be continuously
    -- crossed for BAG_FULL_CONFIRM_S before tearing down the looting
    -- pet and summoning the merchant. Suppresses spurious cycles on
    -- transient bag fluctuations. The scheduled re-check guarantees
    -- the cycle still fires if no further BAG_UPDATE arrives during
    -- the confirm window (e.g. one big loot leaves the player idle).
    if not EC_compCache.bagFullSince then
        EC_compCache.bagFullSince = GetTime()
        EC_Delay(EC_compCache.BAG_FULL_CONFIRM_S + 0.05, EC_HandleBagFullForCycle)
        return
    end
    if (GetTime() - EC_compCache.bagFullSince) < EC_compCache.BAG_FULL_CONFIRM_S then
        return
    end
    EC_compCache.bagFullSince = nil
    EC_lootCycleState = STATE.WAITING_MERCHANT
    PrintNicef("|cffffff00%d free bag slots remaining. Summoning Goblin Merchant...|r", free)
    if DismissCompanion then
        DismissCompanion("CRITTER")
    end
    -- v2.9.0: signal that this dismiss is addon-driven so the dismiss-vs-leash
    -- classifier in EC_PetCheckTick doesn't mis-classify the bag-full
    -- transition as a manual portrait click and trip a 30 s grace that
    -- would block the post-merchant Scavenger restore (especially during
    -- heavy combat, where the busy-gated retry path needs every tick).
    -- The flag stays true through WAITING_MERCHANT/SELLING (pet-tick is
    -- gated on those states so it can't act on it) and is cleared by
    -- SummonGreedyScavenger when FinishRun brings the Scavenger back.
    EC_addonDismissed = true
    -- v2.10.0: arm the resummon-print debounce. If FinishRun's
    -- SummonGreedyScavenger hits the busy-gate the recovery falls through
    -- to EC_TryResummonScavenger; that path's chat line should fire once
    -- so the user gets a matching close-out for the bag-full / Goblin-
    -- summoned messages.
    EC_compCache.pendingAnnounce = true
    EC_summonGoblinPending = true
    EC_summonGoblinTimer = 1.5
    EC_goblinRetryCount = 0
end

-- ===========================================================================
-- Auto-open lootable containers
-- ---------------------------------------------------------------------------
-- Hidden tooltip used to scan bag items for the "Right Click to Open" line.
-- Anchored offscreen via SetOwner(UIParent, "ANCHOR_NONE") so it never flashes
-- on the user's screen during scans.
local EC_scanTooltip = CreateFrame("GameTooltip", "EbonClearanceScanTooltip", UIParent, "GameTooltipTemplate")
EC_scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")

-- True iff the slotted item shows ITEM_OPENABLE in its tooltip and is not
-- locked. ITEM_OPENABLE is the standard Blizzard locale string ("<Right
-- Click to Open>" in enUS) used by every container, gift bag, and
-- treasure pouch in 3.3.5a. LOCKED is the same string that gets shown on
-- junkboxes / lockpickable containers; we exclude those because the user
-- needs a key or lockpicking skill to open them.
local function EC_IsOpenable(bag, slot)
    local _, itemCount, locked = GetContainerItemInfo(bag, slot)
    if not itemCount or itemCount <= 0 or locked then
        return false
    end
    EC_scanTooltip:ClearLines()
    EC_scanTooltip:SetBagItem(bag, slot)
    -- Cap iterations: tooltips can technically grow long; 30 lines is more
    -- than any container we care about will produce.
    for i = 1, 30 do
        local line = _G["EbonClearanceScanTooltipTextLeft" .. i]
        if not line then
            break
        end
        local txt = line:GetText()
        if txt == ITEM_OPENABLE then
            return true
        end
        if txt == LOCKED then
            return false
        end
    end
    return false
end

-- v2.10.0: bind-type detection for the per-rarity bindFilter rule. Returns
-- "boe", "bop", or "any" by scanning the same hidden EC_scanTooltip frame
-- the openable-container check uses. Results are cached on
-- EC_compCache.bindCache for the session because bind type is immutable
-- for a given itemID. Strings matched are the enUS Blizzard tooltip lines
-- (`Binds when picked up`, `Soulbound`, `Binds when equipped`); same enUS
-- constraint that already governs EC_IsOpenable's use of ITEM_OPENABLE /
-- LOCKED locale strings.
--
-- Items with no bind line at all (consumables, reagents, trade goods,
-- quest items) return "any" - they aren't subject to BoE-only or BoP-only
-- filters, which is the user-intended behaviour: "Sell BoE only" should
-- not sweep up reagents.
function EC_compCache.getBindType(bag, slot)
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return "any"
    end
    local cached = EC_compCache.bindCache[itemID]
    if cached then
        return cached
    end
    EC_scanTooltip:ClearLines()
    EC_scanTooltip:SetBagItem(bag, slot)
    local result = "any"
    -- 30-line cap matches the openable-container scan; well above any
    -- realistic tooltip we'd encounter on Project Ebonhold.
    for i = 1, 30 do
        local line = _G["EbonClearanceScanTooltipTextLeft" .. i]
        if not line then
            break
        end
        local txt = line:GetText()
        if txt then
            if txt == "Binds when picked up" or txt == "Soulbound" then
                result = "bop"
                break
            elseif txt == "Binds when equipped" then
                result = "boe"
                break
            end
        end
    end
    EC_compCache.bindCache[itemID] = result
    return result
end

-- v2.10.0: bind-type detection that reads a live tooltip's lines instead
-- of scanning a freshly-built EC_scanTooltip via SetBagItem. Used by
-- EC_AnnotateTooltip so the bind-filter rule can colour-code an item the
-- user is hovering when we don't have a (bag, slot) pair (the annotation
-- entry point is itemLink, not a container slot). Reads the cache first
-- so a previously-scanned bag item never re-scans; otherwise walks the
-- live tooltip's TextLeft lines for the same enUS bind-type strings the
-- bag-scan path matches. Stamps the cache on a successful result so a
-- subsequent EC_IsSellable call on the same itemID stays cheap.
function EC_compCache.getBindTypeFromTooltip(tooltip, itemID)
    if itemID and EC_compCache.bindCache[itemID] then
        return EC_compCache.bindCache[itemID]
    end
    if not tooltip or not tooltip.NumLines or not tooltip.GetName then
        return "any"
    end
    local tname = tooltip:GetName()
    if not tname then
        return "any"
    end
    local n = tooltip:NumLines() or 0
    local result = "any"
    -- Start at line 2: line 1 is the item name; bind line is always one of
    -- the early header lines (line 2 or 3 in 3.3.5a item tooltips).
    for i = 2, n do
        local fs = _G[tname .. "TextLeft" .. i]
        if fs and fs.GetText then
            local txt = fs:GetText()
            if txt then
                if txt == "Binds when picked up" or txt == "Soulbound" then
                    result = "bop"
                    break
                elseif txt == "Binds when equipped" then
                    result = "boe"
                    break
                end
            end
        end
    end
    if itemID then
        EC_compCache.bindCache[itemID] = result
    end
    return result
end

-- Driver. Walks bags, opens the first openable item, and recurses via
-- EC_Delay if more remain. EC_autoOpenInFlight coalesces BAG_UPDATE bursts
-- so we never stack `UseContainerItem` calls within the inter-item delay.
local function EC_HandleAutoOpenContainers()
    if not DB or not DB.autoOpenContainers then
        return
    end
    if running then
        return
    end
    if InCombatLockdown() then
        -- One-shot deferral announce per combat instance. Walk bags only on
        -- the first BAG_UPDATE-during-combat that finds the queue non-empty;
        -- subsequent BAG_UPDATEs in the same combat skip the scan entirely.
        -- The flag clears on PLAYER_REGEN_ENABLED so the next combat
        -- announces fresh.
        if not EC_compCache.combatDeferredAnnounced then
            local count = 0
            for bag = 0, 4 do
                local slots = GetContainerNumSlots(bag)
                for slot = 1, slots do
                    if EC_IsOpenable(bag, slot) then
                        count = count + 1
                    end
                end
            end
            if count > 0 then
                PrintNicef("Deferred %d container(s) until out of combat.", count)
            end
            EC_compCache.combatDeferredAnnounced = true
        end
        return
    end
    if EC_autoOpenInFlight then
        return
    end
    if not EC_IsAddonEnabledForChar() then
        return
    end
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            if EC_IsOpenable(bag, slot) then
                EC_autoOpenInFlight = true
                UseContainerItem(bag, slot)
                -- 0.4 s gives the prior open's cast room to finish before we
                -- trigger the next one. Tunable; lower would feel snappier
                -- but risks interrupting the previous use.
                EC_Delay(0.4, function()
                    EC_autoOpenInFlight = false
                    EC_HandleAutoOpenContainers()
                end)
                return
            end
        end
    end
end

-- ===========================================================================

-- ===========================================================================
-- Right-click bag-item context menu (Alt+Right-Click)
-- ---------------------------------------------------------------------------
-- Adds an EbonClearance popup to bag items: Whitelist (Character/Account),
-- Blacklist, Deletion List, Sell Now. Triggered by Alt+Right-Click so it
-- doesn't override the default right-click-to-use behaviour. We replace
-- (rather than hooksecurefunc) ContainerFrameItemButton_OnClick because we
-- need to *suppress* the default action on our modifier combo, not just
-- append.
--
-- Implementation: a hand-built popup frame with regular Buttons. We avoid
-- UIDropDownMenu in "MENU" mode because 3.3.5a's implementation has a known
-- issue where the click handlers on menu items silently no-op when parented
-- to a custom frame.

local EC_CTX_PANEL_FOR = {
    whitelist = "EbonClearanceOptionsWhitelist",
    accountWhitelist = "EbonClearanceOptionsAccountWhitelist",
    blacklist = "EbonClearanceOptionsBlacklist",
    deleteList = "EbonClearanceOptionsDeletion",
}

-- v2.10.0: optional `quiet` flag suppresses the success / dedupe / conflict
-- chat lines and returns true on a successful add, false on dedupe, conflict
-- or unresolved list. Used by the auto-protect-equipped one-shot sync (which
-- prints a single summary line for the whole 19-slot walk) and by the
-- PLAYER_EQUIPMENT_CHANGED reactive handler (which prints one targeted line
-- per add). The default-mode call sites are unchanged - they pass nil for
-- quiet and ignore the return value.
local function EC_AddItemToList(setName, itemID, label, quiet)
    if not itemID then
        return false
    end
    local t = EC_GetListTable(setName)
    if not t then
        if not quiet then
            PrintNicef("|cffff4444Could not resolve list: %s|r", tostring(setName))
        end
        return false
    end
    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    if t[itemID] then
        if not quiet then
            PrintNicef("|cffaaaaaa%s already on %s.|r", itemName, label)
        end
        return false
    end
    -- Cross-intent conflict guard. Refuse adds that would create a multi-list
    -- conflict; the user must explicitly remove the item from the other list
    -- first. Same-intent scopes (character + account whitelist) do not trip
    -- this and the add proceeds normally.
    local conflictName = EC_FindAddConflict(itemID, setName)
    if conflictName then
        if not quiet then
            PrintNicef("|cffff8888%s is already on %s. Remove it from there first.|r", itemName, conflictName)
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
        return false
    end
    t[itemID] = true
    if not quiet then
        PrintNicef("Added |cffb6ffb6%s|r to %s.", itemName, label)
    end
    -- Refresh the corresponding settings panel if it's been opened.
    local panelName = EC_CTX_PANEL_FOR[setName]
    if panelName then
        local p = _G[panelName]
        if p and p.listUI then
            p.listUI:Refresh()
        end
    end
    return true
end

-- v2.13.0 ElvUI bag buttons: cursor-drop helper. Called by the bag-frame
-- buttons' OnReceiveDrag handler. Reads the cursor item via GetCursorInfo
-- (returns "item", itemID, itemLink for items), clears the cursor, and
-- routes through EC_AddItemToList so cross-list conflict guards and
-- duplicate checks apply. The label is the human-readable list name used
-- in the chat reply ("Whitelist", "Blacklist (Keep)", "Delete List").
-- Hung off EC_compCache (rather than a file-scope local) to stay under
-- Lua 5.1's 200-locals-per-main-chunk cap.
function EC_compCache.handleItemDrop(setName, label)
    local cursorType, cursorID, cursorLink = GetCursorInfo()
    if cursorType ~= "item" then
        ClearCursor()
        return
    end
    local id = (type(cursorID) == "number") and cursorID
        or (cursorLink and tonumber(cursorLink:match("item:(%d+)")))
    ClearCursor()
    if not id then
        return
    end
    -- v2.13.3: removed redundant panel refresh - EC_AddItemToList already
    -- refreshes the panel via the same EC_CTX_PANEL_FOR lookup. The label
    -- arg is what the user sees in the chat reply.
    EC_AddItemToList(setName, id, label)
end

-- v2.13.0 ElvUI bag buttons: opens the EC options frame and jumps straight
-- to the panel that owns the requested list. Mirrors the slash-command's
-- double-call pattern (3.3.5a quirk: the first call only registers the
-- category, the second actually focuses it). Hung off EC_compCache so it
-- doesn't consume a main-chunk local slot.
function EC_compCache.openPanelToList(setName)
    local panelName = EC_CTX_PANEL_FOR and EC_CTX_PANEL_FOR[setName]
    if not panelName then
        return
    end
    local panel = _G[panelName]
    if not panel then
        return
    end
    InterfaceOptionsFrame_OpenToCategory(panel)
    InterfaceOptionsFrame_OpenToCategory(panel)
end

-- v2.13.0 ElvUI bag buttons. Three small icon buttons attached to the
-- top-right of ElvUI's main bag frame in Sell | Keep | Delete order.
-- Each button:
--   - Drag-drop: adds the cursor item to the corresponding EC list,
--     routed through EC_compCache.handleItemDrop -> EC_AddItemToList so cross-list
--     conflicts and dedupe checks apply.
--   - Right-click: jumps the EC options frame to the relevant list panel.
--   - Sell button only: left-click at a merchant fires a manual sell run
--     via the existing EbonClearance_ForceSell entry point.
-- Audience: ElvUI users on Project Ebonhold (a meaningful slice of the
-- player base). Non-ElvUI users see no change; the gate is the existence
-- of _G.ElvUI_ContainerFrame at call time. Idempotent: a guard on
-- EC_compCache.elvuiButtonsBuilt makes a second call cheap if anything
-- ever calls this twice.
function EC_compCache.buildElvUIBagButtons()
    if EC_compCache.elvuiButtonsBuilt then
        return
    end
    local bagFrame = _G.ElvUI_ContainerFrame
    if not bagFrame then
        return
    end
    EC_compCache.elvuiButtonsBuilt = true

    -- Shared backdrop for the three buttons. Subtle dark fill with a 1px
    -- mid-grey edge that brightens on hover; matches AutoDelete's bag
    -- buttons so users running both addons get a consistent visual.
    local function applyBackdrop(btn)
        btn:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            tileSize = 16,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        btn:SetBackdropColor(0, 0, 0, 0.6)
        btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
    end

    -- Mints a button with shared chrome. iconHover is the (r,g,b) the icon
    -- texture vertex-tints to on hover; matches EC's tooltip color scheme
    -- (green for sell, orange for keep, red for delete).
    local function makeButton(name, parent, iconTexture, hoverR, hoverG, hoverB)
        local btn = CreateFrame("Button", name, parent)
        btn:SetSize(20, 20)
        applyBackdrop(btn)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", -2, 2)
        icon:SetTexture(iconTexture)
        if iconTexture:find("Icons\\") then
            -- Icon textures need the 0.07/0.93 inset to crop the default
            -- Blizzard border; UI-GroupLoot textures don't.
            icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        end
        btn._icon = icon
        btn._hoverR, btn._hoverG, btn._hoverB = hoverR, hoverG, hoverB
        btn:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            self:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
            self._icon:SetVertexColor(1, 1, 1)
        end)
        return btn
    end

    -- Sell button (whitelist) - leftmost. Gold coin icon. Drag adds to
    -- whitelist; right-click opens Whitelist panel; left-click at a
    -- merchant triggers EbonClearance_ForceSell.
    local sellBtn = makeButton("EbonClearance_ElvUISellBtn", bagFrame,
        "Interface\\Icons\\INV_Misc_Coin_01", 0.71, 1.0, 0.71)
    sellBtn:SetPoint("TOPRIGHT", bagFrame, "TOPRIGHT", -98, -4)
    sellBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("|cff66ccff[EC]|r |cffb6ffb6Sell|r", 0.71, 1, 0.71)
        GameTooltip:AddLine("Drop item to add to Whitelist (sell list).", 1, 1, 1)
        GameTooltip:AddLine("Click at a vendor to start selling now.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click to open the Whitelist panel.", 0.7, 0.7, 0.7)
        if not (MerchantFrame and MerchantFrame:IsShown()) then
            GameTooltip:AddLine("Not at a vendor.", 1, 0.4, 0.4)
        end
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    sellBtn:RegisterForDrag("LeftButton")
    sellBtn:RegisterForClicks("AnyUp")
    sellBtn:SetScript("OnReceiveDrag", function()
        EC_compCache.handleItemDrop("whitelist", "Whitelist")
    end)
    sellBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            EC_compCache.openPanelToList("whitelist")
        elseif CursorHasItem() then
            EC_compCache.handleItemDrop("whitelist", "Whitelist")
        elseif EbonClearance_ForceSell then
            EbonClearance_ForceSell()
        end
    end)

    -- Keep button (blacklist) - middle. Shield icon (semantically clearer
    -- than AutoDelete's chocolate box for "protected"). Drag adds to
    -- Blacklist (Keep); right-click opens the Blacklist panel.
    local keepBtn = makeButton("EbonClearance_ElvUIKeepBtn", bagFrame,
        "Interface\\Icons\\INV_Shield_06", 1.0, 0.78, 0.30)
    keepBtn:SetPoint("LEFT", sellBtn, "RIGHT", 4, 0)
    keepBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("|cff66ccff[EC]|r |cffffb84dKeep|r", 1, 0.78, 0.30)
        GameTooltip:AddLine("Drop item to add to Blacklist (Keep list).", 1, 1, 1)
        GameTooltip:AddLine("Items here are never auto-sold or auto-deleted.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click to open the Blacklist panel.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    keepBtn:RegisterForDrag("LeftButton")
    keepBtn:RegisterForClicks("AnyUp")
    keepBtn:SetScript("OnReceiveDrag", function()
        EC_compCache.handleItemDrop("blacklist", "Blacklist (Keep)")
    end)
    keepBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            EC_compCache.openPanelToList("blacklist")
        elseif CursorHasItem() then
            EC_compCache.handleItemDrop("blacklist", "Blacklist (Keep)")
        end
    end)

    -- Delete button - rightmost. Red X icon (Blizzard's loot-pass texture,
    -- no icon-inset crop needed). Drag adds to delete list; right-click
    -- opens the Delete List panel.
    local delBtn = makeButton("EbonClearance_ElvUIDeleteBtn", bagFrame,
        "Interface\\Buttons\\UI-GroupLoot-Pass-Up", 1.0, 0.30, 0.30)
    delBtn:SetPoint("LEFT", keepBtn, "RIGHT", 4, 0)
    delBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("|cff66ccff[EC]|r |cffff4444Delete|r", 1, 0.3, 0.3)
        GameTooltip:AddLine("Drop item to add to Delete List.", 1, 1, 1)
        GameTooltip:AddLine("Items here are auto-destroyed at any merchant visit.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click to open the Delete List panel.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    delBtn:RegisterForDrag("LeftButton")
    delBtn:RegisterForClicks("AnyUp")
    delBtn:SetScript("OnReceiveDrag", function()
        EC_compCache.handleItemDrop("deleteList", "Delete List")
    end)
    delBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            EC_compCache.openPanelToList("deleteList")
        elseif CursorHasItem() then
            EC_compCache.handleItemDrop("deleteList", "Delete List")
        end
    end)
end

local function EC_RemoveItemFromList(setName, itemID, label)
    if not itemID then
        return
    end
    local t = EC_GetListTable(setName)
    if not t or not t[itemID] then
        return
    end
    t[itemID] = nil
    -- v2.10.0: keep the auto-protected source map in lockstep so the
    -- tooltip annotation can never claim "(auto-protected: equipped)" for
    -- an item the user has explicitly removed. Cleared regardless of
    -- which list we removed from; blacklistAuto entries are only ever
    -- valid against the per-character Blacklist (Keep), but the no-op
    -- branch is fast on the other lists.
    if DB and type(DB.blacklistAuto) == "table" then
        DB.blacklistAuto[itemID] = nil
    end
    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    PrintNicef("Removed |cffb6ffb6%s|r from %s.", itemName, label)
    -- Refresh the corresponding settings panel if it's been opened.
    local panelName = EC_CTX_PANEL_FOR[setName]
    if panelName then
        local p = _G[panelName]
        if p and p.listUI then
            p.listUI:Refresh()
        end
    end
end

-- v2.10.0: equipped-gear protection. Slot 4 is the shirt, slot 19 the tabard;
-- both are cosmetic-only and skipped. Helpers hang off EC_compCache (same
-- pattern as the v2.9.2 PROF_LOOT_SPELLS set) to keep this addon under Lua
-- 5.1's 200-local cap.

-- Auto-protect a single equipped slot. Routes through EC_AddItemToList in
-- quiet mode so the success / dedupe / conflict chat lines are suppressed
-- during the 19-slot one-shot sync; the reactive PLAYER_EQUIPMENT_CHANGED
-- caller prints one targeted line per add. Stamps DB.blacklistAuto on a
-- successful add so EC_AnnotateTooltip can attach the "(auto-protected:
-- equipped)" suffix at hover time. Returns true iff the slot was newly
-- added to the whitelist.
function EC_compCache.protectEquipSlot(slot)
    if not slot or slot == 4 or slot == 19 then
        return false
    end
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
    if not link then
        return false
    end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then
        return false
    end
    -- v2.10.0: equipped gear lands on the BLACKLIST (Keep / do-not-sell)
    -- list, not the Whitelist (sell list). The Whitelist is the list of
    -- items the addon WILL sell - adding equipped gear there would mean
    -- "vendor everything I'm wearing the moment I swap to anything else".
    -- Blacklist is the protected list; that's the correct semantic for
    -- "remember what I'm wearing and don't auto-sell it".
    DB.blacklistAuto = DB.blacklistAuto or {}
    if EC_AddItemToList("blacklist", id, "Blacklist (Keep)", true) then
        -- v2.12.0: tag the entry with its origin so the tooltip can
        -- show "(Worn)" vs "(Upgrade)" instead of a generic
        -- Auto-Protected label. Legacy boolean-true entries from
        -- v2.10.0 / v2.11.0 fall back to the generic label at hover
        -- time.
        DB.blacklistAuto[id] = "equipped"
        return true
    elseif DB.blacklistAuto[id] then
        -- v2.12.0: item was already on the blacklist with an existing
        -- auto-tag ("upgrade" from autoProtectUpgrades, or "set" from
        -- v2.13.0's Equipment Manager protection). The user has now
        -- explicitly equipped it, so the more accurate tag is
        -- "equipped" - refresh in place. Manual blacklist entries
        -- (where blacklistAuto[id] is nil) stay untouched - the user
        -- added those deliberately.
        DB.blacklistAuto[id] = "equipped"
        return false
    end
    return false
end

-- One-shot sync helper. Called by the Blacklist (Keep) panel's
-- "Auto-protect equipped gear" checkbox when the user flips it from off to
-- on. Walks every gear slot once and prints a single summary line for the
-- whole batch. The reactive PLAYER_EQUIPMENT_CHANGED handler covers all
-- subsequent equipment swaps; this one-shot is only needed at toggle time.
function EC_compCache.syncEquipped()
    local added = 0
    for slot = 1, 19 do
        if EC_compCache.protectEquipSlot(slot) then
            added = added + 1
        end
    end
    if added > 0 then
        PrintNicef("|cffb6ffb6Auto-protected %d currently equipped item%s.|r", added, added == 1 and "" or "s")
    else
        PrintNice("|cffaaaaaaNo new equipped items to auto-protect; current gear was already on the keep list.|r")
    end
end

-- v2.13.0 Equipment Manager protection. Adds an item from a saved equipment
-- set to the Keep list with origin tag "set". Routes through EC_AddItemToList
-- so cross-list conflicts and duplicate guards apply. Items already equipped
-- (tag "equipped") and looted upgrades (tag "upgrade") keep their existing
-- tag - "set" is the weakest tag and shouldn't downgrade more specific
-- ones. Manual blacklist entries (no auto-tag) are not touched. Returns
-- true iff a new entry was added.
function EC_compCache.protectEquipmentSetItem(itemID)
    -- Slot values 0 (empty) and 1 (ignore) come back from GetEquipmentSetItemIDs;
    -- itemID 1 is technically a real item but isn't auto-protectable equipment,
    -- so the > 1 check is safe in practice and dodges the ignore-marker overload.
    if not itemID or itemID <= 1 then
        return false
    end
    DB.blacklistAuto = DB.blacklistAuto or {}
    if EC_AddItemToList("blacklist", itemID, "Blacklist (Keep)", true) then
        DB.blacklistAuto[itemID] = "set"
        return true
    end
    -- Already on the blacklist. Do not promote or downgrade an existing
    -- tag - "equipped" / "upgrade" are more specific and should win.
    return false
end

-- One-shot sync helper. Called by the Blacklist (Keep) panel's
-- "Auto-protect equipment-manager sets" checkbox when the user flips it from
-- off to on, and by the EQUIPMENT_SETS_CHANGED reactive handler. Walks every
-- saved equipment set, dedupes itemIDs across sets via a session-local seen
-- map, and stamps each onto the Keep list. The Blizzard 3.3.5a Equipment
-- Manager API (GetNumEquipmentSets, GetEquipmentSetInfo, GetEquipmentSetItemIDs)
-- exists since 3.1.2; defensive nil-guards are kept for clients that
-- somehow lack it. `silent` skips the chat summary - used by the live
-- EQUIPMENT_SETS_CHANGED path so set-edits don't spam.
function EC_compCache.syncEquipmentSets(silent)
    if not (GetNumEquipmentSets and GetEquipmentSetInfo and GetEquipmentSetItemIDs) then
        return 0
    end
    local n = GetNumEquipmentSets()
    if not n or n == 0 then
        if not silent then
            PrintNice("|cffaaaaaaNo equipment sets saved. Use the Blizzard Equipment Manager to create one, then re-tick this option.|r")
        end
        return 0
    end
    local added, sets = 0, 0
    local seen = {}
    local buf = {}
    for i = 1, n do
        local name = GetEquipmentSetInfo(i)
        if name then
            sets = sets + 1
            for k in pairs(buf) do
                buf[k] = nil
            end
            GetEquipmentSetItemIDs(name, buf)
            for _, id in pairs(buf) do
                if id and id > 1 and not seen[id] then
                    seen[id] = true
                    if EC_compCache.protectEquipmentSetItem(id) then
                        added = added + 1
                    end
                end
            end
        end
    end
    if not silent then
        if added > 0 then
            PrintNicef("|cffb6ffb6Auto-protected %d item%s from %d equipment set%s.|r",
                added, added == 1 and "" or "s",
                sets, sets == 1 and "" or "s")
        else
            PrintNicef("|cffaaaaaaScanned %d equipment set%s; all items already on the keep list.|r",
                sets, sets == 1 and "" or "s")
        end
    end
    return added
end

-- v2.11.0 auto-protect upgraded gear (BAG_UPDATE-driven). Closes the gap
-- left by v2.10.0's PLAYER_EQUIPMENT_CHANGED-driven path: that path only
-- protected the *previously-equipped* item the moment the user swaps in
-- an upgrade. A higher-iLvl drop sitting in bags waiting to be equipped
-- was unprotected, and any active per-rarity iLvl-cap rule could vendor
-- it on the next merchant visit. The new path scans bag items on every
-- BAG_UPDATE, computes their slot type and base iLvl from GetItemInfo,
-- and stamps the Keep list when a bag item's iLvl exceeds the equipped
-- item in any of its candidate slots. Multi-slot equipLocs (rings,
-- trinkets, weapons) compare against the LOWER of the two equipped
-- iLvls so any genuine upgrade triggers.
--
-- Cost: GetItemInfo + a few inventory link reads per never-seen-before
-- itemID. EC_compCache.upgradeProcessed dedupes per-itemID for the
-- session - a /reload reseeds. EC_AddItemToList's quiet+dedupe path
-- short-circuits items already on the blacklist, so the only chat
-- output is the per-add notice.
EC_compCache.INVTYPE_SLOTS = {
    INVTYPE_HEAD = { 1 },
    INVTYPE_NECK = { 2 },
    INVTYPE_SHOULDER = { 3 },
    INVTYPE_CHEST = { 5 },
    INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 },
    INVTYPE_WRIST = { 9 },
    INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_2HWEAPON = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_HOLDABLE = { 17 },
    INVTYPE_SHIELD = { 17 },
    INVTYPE_RANGED = { 18 },
    INVTYPE_RANGEDRIGHT = { 18 },
    INVTYPE_THROWN = { 18 },
    INVTYPE_RELIC = { 18 },
}

EC_compCache.upgradeProcessed = {}

function EC_compCache.getEquippedILvl(slotID)
    local link = GetInventoryItemLink and GetInventoryItemLink("player", slotID)
    if not link then
        return 0
    end
    local _, _, _, iLvl = GetItemInfo(link)
    return iLvl or 0
end

-- v2.12.0 mirror of checkBagsForUpgrades' iLvl-vs-equipped comparison,
-- inverted: returns true iff a looted item's iLvl is strictly LESS than
-- the lowest populated equipped iLvl across the item's candidate slots.
-- Drives the per-rarity "Use equipped iLvl" sell mode in EC_IsSellable.
--
-- Multi-slot conservative rule: a ring / trinket / 1H weapon sells only
-- when worse than EVERY equipped slot - if any slot would treat it as
-- an upgrade, keep it. Empty slots are skipped entirely (the user might
-- want to fill that slot with the looted item, so we don't auto-sell).
--
-- Trade goods, reagents, consumables, and quest items have no equipLoc
-- in EC_compCache.INVTYPE_SLOTS, so they're naturally protected by the
-- early-return below.
function EC_compCache.isDowngradeVsEquipped(itemID, lootedILvl, equipLoc)
    -- v2.12.0+ returns (boolean, reason) so the tooltip annotation can
    -- distinguish "rule fired and decided keep" from "rule short-
    -- circuited on an empty slot". EC_IsSellable's call site only reads
    -- the boolean (Lua multi-return is transparent there).
    -- reason values:
    --   "not_equippable" - missing itemID / iLvl / equipLoc
    --   "no_slot_mapping" - equipLoc not in INVTYPE_SLOTS (relics, bags, etc.)
    --   "empty_slot"      - any candidate slot was empty; rule bailed without
    --                       comparing iLvls so the looted item could fill it
    --   "below_lowest"    - looted iLvl is below the lowest populated slot
    --                       (this is the only reason the boolean is true)
    --   "at_or_above"     - looted iLvl met or exceeded the lowest populated
    --                       slot's iLvl - actual iLvl comparison happened
    if not itemID or not lootedILvl or lootedILvl <= 0 then
        return false, "not_equippable"
    end
    if not equipLoc or equipLoc == "" then
        return false, "not_equippable"
    end
    local slots = EC_compCache.INVTYPE_SLOTS[equipLoc]
    if not slots then
        return false, "no_slot_mapping"
    end
    local lowestEquipped = nil
    for _, sid in ipairs(slots) do
        local eq = EC_compCache.getEquippedILvl(sid)
        if eq <= 0 then
            return false, "empty_slot"
        end
        if lowestEquipped == nil or eq < lowestEquipped then
            lowestEquipped = eq
        end
    end
    if lowestEquipped == nil then
        return false, "no_slot_mapping"
    end
    if lootedILvl < lowestEquipped then
        return true, "below_lowest"
    end
    return false, "at_or_above"
end

function EC_compCache.checkBagsForUpgrades()
    if not DB or not DB.autoProtectUpgrades then
        return
    end
    -- Skip while a vendor cycle is mid-flight: the worker queue was
    -- built before any add we'd make now, so a fresh blacklist stamp
    -- wouldn't influence the current run anyway. Next BAG_UPDATE post-
    -- MERCHANT_CLOSED picks up the same items cleanly.
    if running then
        return
    end
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local itemID = GetContainerItemID(bag, slot)
            if itemID and not EC_compCache.upgradeProcessed[itemID] then
                EC_compCache.upgradeProcessed[itemID] = true
                if not (DB.blacklist and DB.blacklist[itemID]) then
                    local _, _, _, iLvl, _, _, _, _, equipLoc = GetItemInfo(itemID)
                    local slots = equipLoc and EC_compCache.INVTYPE_SLOTS[equipLoc]
                    if iLvl and iLvl > 0 and slots then
                        -- For multi-slot equipLocs (rings, trinkets,
                        -- 1H weapons), compute the LOWEST iLvl among
                        -- the populated candidate slots. Empty slots
                        -- are ignored - otherwise an empty ring-2 slot
                        -- (iLvl 0) would suppress upgrade detection
                        -- against an iLvl-250 ring-1.
                        local lowestEquipped = nil
                        for _, sid in ipairs(slots) do
                            local eq = EC_compCache.getEquippedILvl(sid)
                            if eq > 0 and (lowestEquipped == nil or eq < lowestEquipped) then
                                lowestEquipped = eq
                            end
                        end
                        -- v2.12.0: require at least one populated slot to
                        -- give us a real baseline. The pre-fix behaviour
                        -- fell back to threshold = 0 when every candidate
                        -- slot was empty (e.g. logging in with no weapons),
                        -- which mass-stamped every iLvl > 0 item in bags
                        -- as an "upgrade" - polluting the Keep list with
                        -- dozens of low-iLvl daggers / spare gear that
                        -- weren't actually upgrades against anything. Now
                        -- if no slot is populated we skip this iteration
                        -- entirely; we'll re-check this itemID when
                        -- upgradeProcessed is reset (a /reload). When the
                        -- user equips something later, PLAYER_EQUIPMENT_
                        -- CHANGED + autoAddEquipped covers the equipped
                        -- side; subsequent BAG_UPDATEs cover the bag side
                        -- once at least one slot is populated.
                        if lowestEquipped and iLvl > lowestEquipped then
                            if EC_AddItemToList("blacklist", itemID, "Blacklist (Keep)", true) then
                                DB.blacklistAuto = DB.blacklistAuto or {}
                                -- v2.12.0: origin tag for tooltip fork.
                                DB.blacklistAuto[itemID] = "upgrade"
                                local name = GetItemInfo(itemID) or ("Item:" .. itemID)
                                PrintNicef("|cffb6ffb6Auto-protected upgrade %s (added to Keep list).|r", name)
                            end
                        end
                    end
                end
            end
        end
    end
end

local function EC_SellNowAt(bag, slot)
    if not (MerchantFrame and MerchantFrame:IsShown()) then
        PrintNice("|cffff4444Open a merchant first to sell.|r")
        return
    end
    if not bag or not slot then
        return
    end
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return
    end
    if IsEquippedItem(itemID) then
        PrintNice("|cffff4444Cannot sell equipped items.|r")
        return
    end
    UseContainerItem(bag, slot)
    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    PrintNicef("Sold |cffb6ffb6%s|r.", itemName)
end

-- Row metadata for the popup. Each "list" row toggles between "Add to ..."
-- (white) and "Remove from ..." (orange) based on the item's live list
-- membership at show time. Special rows ("sellNow", "cancel") get plain text
-- and fixed handlers. EC_ShowItemContextMenu sets per-row text + OnClick on
-- every show; the buttons created in EC_BuildCtxFrame are empty placeholders.
local EC_CTX_ROWS = {
    { kind = "list", setName = "whitelist", label = "Whitelist (Character)" },
    { kind = "list", setName = "accountWhitelist", label = "Whitelist (Account)" },
    { kind = "list", setName = "blacklist", label = "Blacklist (Do Not Sell)" },
    { kind = "list", setName = "deleteList", label = "Deletion List" },
    { kind = "sellNow" },
    { kind = "cancel" },
}

local EC_ctxFrame

local function EC_BuildCtxFrame()
    if EC_ctxFrame then
        return EC_ctxFrame
    end
    local rowCount = #EC_CTX_ROWS
    -- Layout: 8 top pad + 22 title + 6 gap + rows*22 + 8 bottom pad
    local frameHeight = 8 + 22 + 6 + (rowCount * 22) + 8
    local frame = CreateFrame("Frame", "EbonClearanceCtxFrame", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:SetSize(240, frameHeight)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:EnableMouse(true)
    frame:Hide()

    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetPoint("TOPRIGHT", -10, -8)
    title:SetJustifyH("LEFT")
    if title.SetWordWrap then
        title:SetWordWrap(false)
    end
    frame.title = title

    frame.buttons = {}
    for i = 1, #EC_CTX_ROWS do
        local btn = CreateFrame("Button", nil, frame)
        btn:SetSize(220, 20)
        btn:SetPoint("TOPLEFT", 10, -(8 + 22 + 6) - (i - 1) * 22)
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetHighlightFontObject("GameFontGreenSmall")
        btn:SetDisabledFontObject("GameFontDisableSmall")
        local fs = btn:GetFontString()
        if fs then
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", btn, "LEFT", 4, 0)
            fs:SetJustifyH("LEFT")
        end
        -- Highlight texture so hover gives feedback.
        local hl = btn:CreateTexture(nil, "BACKGROUND")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAllPoints(btn)
        hl:SetAlpha(0)
        btn:SetScript("OnEnter", function()
            hl:SetAlpha(0.4)
        end)
        btn:SetScript("OnLeave", function()
            hl:SetAlpha(0)
        end)
        -- Text + OnClick are populated per-show by EC_ShowItemContextMenu
        -- so the row labels reflect the item's live list membership.
        frame.buttons[i] = btn
    end

    -- Escape closes the popup. Standard Blizzard pattern: anything in the
    -- UISpecialFrames table is auto-hidden on Escape. Avoids the previous
    -- fullscreen-overlay approach which could intercept bag clicks if it ever
    -- got stuck shown after a disable/enable cycle.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "EbonClearanceCtxFrame")
    end
    frame:SetScript("OnHide", function()
        frame.bag = nil
        frame.slot = nil
    end)

    EC_ctxFrame = frame
    return frame
end

local function EC_ShowItemContextMenu(button)
    local frame = EC_BuildCtxFrame()
    local bag = button:GetParent():GetID()
    local slot = button:GetID()
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return
    end
    frame.bag = bag
    frame.slot = slot

    -- Pull sellPrice alongside the name so the smart-row filter below can
    -- decide which actions are meaningful for this item.
    local name, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
    local itemName = name or ("ItemID:" .. itemID)
    frame.title:SetText("|cff66ccffEbonClearance|r: " .. itemName)

    -- Smart-row filter. When we know the item has no vendor value (sellPrice
    -- 0 or nil from a cache hit) the only useful "Add to X" action is the
    -- Deletion List - the auto-rules already ignore unsellable items so
    -- whitelisting/blacklisting them is no-op, and Sell Now is meaningless
    -- because no vendor will buy it. Existing list memberships still expose
    -- a "Remove from X" row so users can clean up stale entries (e.g. an
    -- item that was added to the whitelist before its sellPrice was known).
    -- The cross-list conflict greying remains unchanged: an unsellable item
    -- already on the Whitelist still shows the Deletion List row as a
    -- greyed "Add to Deletion List" so the user knows they need to remove
    -- it from Whitelist first - same UX rule the panel-side adds enforce,
    -- which is why the tooltip annotation also stays as the canonical
    -- "why is this item being treated this way?" indicator.
    --
    -- The cache-miss path (name == nil) falls back to showing every row;
    -- we don't know yet whether the item is unsellable. Reopen the menu
    -- after a moment to let GetItemInfo populate.
    local cacheKnown = (name ~= nil)
    local noVendorValue = cacheKnown and (not sellPrice or sellPrice == 0)

    local merchantOpen = MerchantFrame and MerchantFrame:IsShown()
    local visibleSlot = 0
    for i, row in ipairs(EC_CTX_ROWS) do
        local btn = frame.buttons[i]
        local rowHidden = false
        if row.kind == "list" then
            local t = EC_GetListTable(row.setName)
            local onList = t and t[itemID] == true
            if onList then
                -- Orange "Remove from ..." when the item is already on this
                -- list. Clicking removes it. Always shown - this is how
                -- users clean up stale entries, including for unsellable
                -- items that may have been added before their price was
                -- known.
                btn:SetText("|cffff8000Remove from " .. row.label .. "|r")
                btn:SetScript("OnClick", function()
                    EC_RemoveItemFromList(row.setName, itemID, row.label)
                    frame:Hide()
                end)
                btn:Enable()
            elseif noVendorValue and row.setName ~= "deleteList" then
                -- Hide whitelist/account-whitelist/blacklist Add rows for
                -- items the auto-rules can't act on anyway. Add-to-Deletion
                -- stays visible because that's the actually-useful action.
                rowHidden = true
            else
                -- If a different-intent list already holds the item, grey
                -- out the row so the user can see the option exists but
                -- can't currently take it (mirrors how Sell Now disables
                -- itself when no merchant is open). The which-list-holds-it
                -- info is already visually announced by the highlighted
                -- "Remove from X" row above, so we don't repeat it here
                -- (the parenthetical version overflowed the 220-px button).
                -- Same-intent scopes (per-character + account whitelist)
                -- do not trip this.
                local conflictName = EC_FindAddConflict(itemID, row.setName)
                if conflictName then
                    btn:SetText("Add to " .. row.label)
                    btn:SetScript("OnClick", function() end)
                    btn:Disable()
                else
                    btn:SetText("Add to " .. row.label)
                    btn:SetScript("OnClick", function()
                        EC_AddItemToList(row.setName, itemID, row.label)
                        frame:Hide()
                    end)
                    btn:Enable()
                end
            end
        elseif row.kind == "sellNow" then
            if noVendorValue then
                -- No vendor will buy it - row is meaningless. Hide rather
                -- than disable so the menu collapses to what's actually
                -- useful.
                rowHidden = true
            else
                btn:SetText("Sell Now")
                btn:SetScript("OnClick", function()
                    EC_SellNowAt(frame.bag, frame.slot)
                    frame:Hide()
                end)
                if merchantOpen then
                    btn:Enable()
                else
                    btn:Disable()
                end
            end
        elseif row.kind == "cancel" then
            btn:SetText("Cancel")
            btn:SetScript("OnClick", function()
                frame:Hide()
            end)
            btn:Enable()
        end

        if rowHidden then
            btn:Hide()
        else
            -- Pack visible rows contiguously starting at slot 0; the frame
            -- height below resizes to match the count so the trailing
            -- padding is consistent regardless of how many rows are shown.
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", 10, -(8 + 22 + 6) - visibleSlot * 22)
            btn:Show()
            visibleSlot = visibleSlot + 1
        end
    end

    -- Resize the frame to match the visible row count. Same layout formula
    -- the build path uses; visibleSlot is the count of rows we just laid
    -- out (it ended at last_index + 1).
    frame:SetHeight(8 + 22 + 6 + (visibleSlot * 22) + 8)

    -- Position at the cursor. WoW's GetCursorPosition returns screen pixels;
    -- divide by UIParent's effective scale to get UIParent-local coords.
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    frame:Show()
end

local EC_bagContextHookInstalled = false

-- 3.3.5a routes any modifier+click on a bag item through
-- ContainerFrameItemButton_OnModifiedClick (NOT _OnClick). _OnModifiedClick
-- has Shift/Ctrl handlers, then falls through to _OnClick for the unhandled
-- modifiers. We intercept pure Alt+RightClick (no Shift, no Ctrl) before that
-- fall-through. Replace rather than hooksecurefunc because we need to suppress
-- the fall-through, not just append.
local function EC_InstallBagContextHookOnce()
    if EC_bagContextHookInstalled then
        return
    end
    if type(ContainerFrameItemButton_OnModifiedClick) ~= "function" then
        return
    end
    EC_bagContextHookInstalled = true
    local orig = ContainerFrameItemButton_OnModifiedClick
    ContainerFrameItemButton_OnModifiedClick = function(self, button)
        if button == "RightButton" and IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown() then
            EC_ShowItemContextMenu(self)
            return
        end
        return orig(self, button)
    end
end

-- ===========================================================================

-- Pet stuck detection + auto-loot cycle bag monitoring
local EC_petCheckFrame = CreateFrame("Frame")

-- Pet-check OnUpdate is split into named helpers below. The dispatch itself
-- (at the bottom) handles three per-frame timer countdowns and one 5 s-gated
-- tick body. See docs/CODE_REVIEW.md item 3.
--
-- The three timer-countdown helpers return true if they consumed the tick
-- (caller should return early), or false to fall through.

-- 1.5 s post-dismiss delay before summoning the Goblin Merchant. The dismiss
-- has to land server-side before CallCompanion, otherwise the slot is still
-- occupied by the Scavenger and the call no-ops. v2.6.2 adds a cast-busy
-- gate: if the timer fires while the player is mid-cast / channeling /
-- moving, push the timer 0.5 s and try again so the summon doesn't get
-- silently rejected by the spell system.
local function EC_TickGoblinSummon(elapsed)
    if not EC_summonGoblinPending then
        return false
    end
    EC_summonGoblinTimer = EC_summonGoblinTimer - elapsed
    if EC_summonGoblinTimer <= 0 then
        if EC_IsPlayerBusy() then
            -- Defer 0.5 s and let the next tick re-evaluate. Stays pending
            -- so the OnUpdate will keep entering this branch until a clear
            -- cast/movement window opens.
            EC_summonGoblinTimer = 0.5
            return true
        end
        EC_summonGoblinPending = false
        local idx = FindGoblinMerchantIndex()
        if idx then
            CallCompanion("CRITTER", idx)
            EC_goblinRetryCount = EC_goblinRetryCount + 1
            EC_targetGoblinPending = true
            EC_targetGoblinTimer = 2.0
        else
            PrintNice("|cffff4444Goblin Merchant not found in companion list!|r")
            EC_lootCycleState = STATE.LOOTING
        end
    end
    return true
end

-- 2.0 s post-summon verify: GetCompanionInfo lags the actual summon, so we
-- wait before checking whether the merchant came out, then arm the 8 s
-- "right-click me" reminder if it did. v2.6.2 expanded the retry budget
-- from 1 to EC_GOBLIN_MAX_RETRIES attempts: under heavy combat the bare
-- GCD from instant-cast rotations can swallow several attempts before
-- one lands. On a miss we re-arm EC_summonGoblinPending with a 0.5 s
-- delay so the next attempt routes through EC_TickGoblinSummon's
-- cast-busy gate before firing CallCompanion.
local function EC_TickGoblinTarget(elapsed)
    if not EC_targetGoblinPending then
        return false
    end
    EC_targetGoblinTimer = EC_targetGoblinTimer - elapsed
    if EC_targetGoblinTimer <= 0 then
        EC_targetGoblinPending = false
        local idx, nowSummoned = FindGoblinMerchantIndex()
        if nowSummoned then
            EC_goblinRetryCount = 0
            PrintNicef(
                "|cff00ff00Goblin Merchant summoned|r - press %s or right-click to sell.",
                EC_FormatTargetMerchantBinding()
            )
            EC_merchantReminderPending = true
            EC_merchantReminderTimer = 8.0
        elseif idx and EC_goblinRetryCount < EC_GOBLIN_MAX_RETRIES then
            -- v2.11.0: nudge the user when we're about to fire the last
            -- attempt. Two missed retries means the previous CallCompanions
            -- bounced off the GCD - the v2.11.0 GCD-aware busy gate covers
            -- the common case but can't see haste-reduced GCDs or any other
            -- server-side reject reason. Telling the user gives them a
            -- ~2.5 s window (0.5 s pre-fire + 2.0 s verify) to pause their
            -- rotation so the next CallCompanion catches a clear window.
            -- Only fires once per cycle (transition from N-1 -> N retries).
            if EC_goblinRetryCount == EC_GOBLIN_MAX_RETRIES - 1 then
                PrintNice(
                    "|cffffb84dGoblin Merchant retrying. Hold off your rotation briefly so the summon can land.|r"
                )
            end
            -- Re-route through the summon path so the next CallCompanion
            -- waits for a clear cast/movement window first.
            EC_summonGoblinPending = true
            EC_summonGoblinTimer = 0.5
        else
            EC_goblinRetryCount = 0
            PrintNice("|cffff4444Goblin Merchant failed to summon. Resuming looting.|r")
            EC_lootCycleState = STATE.LOOTING
        end
    end
    return true
end

-- 8 s nudge for users who summoned the merchant but then got distracted.
-- Falls through (returns false) so the 5 s-gated body still runs this frame.
local function EC_TickMerchantReminder(elapsed)
    if not EC_merchantReminderPending then
        return false
    end
    EC_merchantReminderTimer = EC_merchantReminderTimer - elapsed
    if EC_merchantReminderTimer <= 0 then
        EC_merchantReminderPending = false
        if EC_lootCycleState == STATE.WAITING_MERCHANT then
            PrintNice("|cffffff00Reminder: right-click the Goblin Merchant to open the vendor window.|r")
        end
    end
    return false
end

-- Reconcile cycle state with companion-out reality: if the Scavenger is
-- already out at IDLE, advance to LOOTING so the auto-loot cycle picks up.
local function EC_AutoLootStateSync()
    if not (DB.autoLootCycle and EC_lootCycleState == STATE.IDLE) then
        return
    end
    local num = GetNumCompanions("CRITTER")
    for i = 1, (num or 0) do
        local _, creatureName, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if creatureName == PET_NAME and isSummoned then
            EC_lootCycleState = STATE.LOOTING
            break
        end
    end
end

-- Secondary stuck-detection signal. Movement-time alone misses cases where
-- the player kills and loots in place (channels, melee, kiting in tight
-- circles): the Scavenger gets left behind on terrain but the accumulator
-- never accrues. This signal fires when the player has looted at least
-- MIN_LOOTS corpses inside the WINDOW and the Scavenger has not been heard
-- to speak since the oldest of those loots. Prunes the loot ring as a side
-- effect on every check, so it cannot grow unboundedly.
local function EC_IsLootSilenceStuck()
    -- v2.10.0 silent-realm guard. The signal assumes the Scavenger pet
    -- audibly chats on each loot pickup. On Project Ebonhold the pet's
    -- chat events don't reliably reach the chat filter (verified: a
    -- user's heavy-farming chat log shows zero pet-speech messages
    -- across an entire session). Without this guard the on-summon
    -- synthetic refresh of EC_lastScavSpokeAt resets the silence clock
    -- at every dismiss-and-resummon cycle, producing a feedback loop
    -- where the signal fires every ~60 s of farming. Gating on
    -- EC_compCache.scavSpeechEverHeard - which only flips true via a
    -- real chat-filter match, never via the on-summon refresh - makes
    -- the signal self-disable on silent realms while preserving the
    -- v2.7.0 / v2.8.0 behaviour for any future realm where the pet
    -- does broadcast normally. Movement-time stuck detection
    -- (EC_STUCK_MOVEMENT_THRESHOLD, 180 s) remains the catch-all.
    if not EC_compCache.scavSpeechEverHeard then
        return false
    end
    local WINDOW, MIN_LOOTS = 60, 2
    local now = GetTime()
    local kept = {}
    for i = 1, #EC_recentLootTimes do
        local t = EC_recentLootTimes[i]
        if (now - t) <= WINDOW then
            kept[#kept + 1] = t
        end
    end
    EC_recentLootTimes = kept
    if #kept < MIN_LOOTS then
        return false
    end
    return EC_lastScavSpokeAt < kept[1]
end

-- Stuck-Scavenger handling. Two signals OR'd together:
--   1. EC_scavMovementAccum >= EC_STUCK_MOVEMENT_THRESHOLD - the player has
--      moved enough that the pet should have caught up but hasn't (since
--      the OnUpdate accumulator only ticks while the pet is flagged out).
--   2. EC_IsLootSilenceStuck() - the player kept looting while the pet went
--      silent, suggesting it's geographically lost even though the player
--      isn't moving much.
-- On either signal the Scavenger is dismissed; the next 5 s tick re-summons
-- at the player's current position via EC_TryResummonScavenger.
-- Returns true if the Scavenger is out (caller bails out of re-summon path).
local function EC_HandleScavengerOut(scavengerOut)
    if not scavengerOut then
        return false
    end
    local stuckByMovement = EC_scavMovementAccum >= EC_STUCK_MOVEMENT_THRESHOLD
    local stuckByLootSilence = EC_IsLootSilenceStuck()
    if stuckByMovement or stuckByLootSilence then
        EC_addonDismissed = true
        -- v2.10.0: arm the resummon-print debounce. The recovery path may
        -- fire CallCompanion several times before the server confirms the
        -- summon; this flag ensures only the first successful CallCompanion
        -- in the cycle prints "Greedy Scavenger resummoned.".
        EC_compCache.pendingAnnounce = true
        EC_scavMovementAccum = 0
        EC_recentLootTimes = {}
        if stuckByMovement then
            PrintNice("|cffffff00Scavenger fell behind. Resummoning when you stop moving.|r")
        else
            PrintNice("|cffffff00Scavenger went quiet during looting. Resummoning when you stop moving.|r")
        end
        DismissGreedyScavenger()
    end
    return true
end

-- Re-summon the Scavenger if and only if we (this addon) dismissed it.
-- Manual portrait dismisses leave EC_addonDismissed=false, so this gate
-- naturally honours them. Concurrent companions (bank mule, mailbox)
-- suppress; the 10 s mount-dismiss cooldown suppresses.
--
-- Cast-busy gate (v2.6.2, broadened from the v2.6.1 movement-only gate):
-- on Project Ebonhold a CRITTER summon issued while the player is moving
-- spawns the pet as a zombie that never follows; under heavy combat,
-- summons issued mid-cast or mid-channel get silently rejected by the
-- spell system (it lands inside someone else's cast / GCD slot). Both
-- failure modes are handled by deferring until EC_IsPlayerBusy() is
-- false. EC_addonDismissed stays true while we wait, so the next tick
-- after the player is clear will fire the summon.
--
-- EC_addonDismissed is NOT cleared here either. CallCompanion can also
-- be silently rejected (separate from the zombie case) and we want the
-- retry budget. EC_PetCheckTick clears the flag when it observes
-- scavengerOut=true on the next enumeration -- the canonical
-- "summon landed" signal.
local function EC_TryResummonScavenger(greedyIndex, anyPetOut, goblinStillOut)
    -- v2.9.0: honour the user-dismiss-vs-leash grace window. If a recent
    -- transition was classified as a manual portrait dismiss, suppress the
    -- restore until the grace expires so the addon does not fight the user.
    -- Worst case is a 30 s gap before auto-recovery resumes; the manual
    -- /ec slash command is an explicit override path that bypasses this.
    if GetTime() < EC_compCache.userUntil then
        return
    end
    -- v2.9.0 / v2.10.0: post-CallCompanion server-confirm window. After
    -- we fire a CallCompanion the server can take 4-6 s under heavy combat
    -- to flip the companion's summoned flag to true; the next pet-tick
    -- (1 s cadence while EC_addonDismissed is true) would otherwise see
    -- scavengerOut=false still and fire a redundant CallCompanion. Five
    -- seconds covers the long-tail confirm; if the call was actually
    -- rejected the retry resumes after the wait. The print suppression
    -- below ensures even the retried CallCompanion stays silent if the
    -- announce already fired earlier in the cycle.
    if (GetTime() - EC_compCache.lastSummonAt) < 5 then
        return
    end
    -- Slot occupancy: if SOME other companion is in the slot, distinguish
    -- "user's manually-summoned critter" (respect it) from "our own
    -- leftover Goblin Merchant from the bag-full cycle that never got
    -- dismissed because the merchant window doesn't auto-clear it"
    -- (we should clear it to make room for the Scavenger).
    if anyPetOut and not goblinStillOut then
        return
    end
    if (GetTime() - EC_mountDismissTime) <= 10 then
        return
    end
    if not EC_addonDismissed then
        return
    end
    if not greedyIndex then
        return
    end
    if EC_IsPlayerBusy() then
        return
    end
    -- v2.11.0: optional combat-only summon. Defers stuck-recovery and
    -- post-merchant-restore CallCompanions until combat ends.
    if DB and DB.summonOnlyOutOfCombat and InCombatLockdown() then
        return
    end
    if goblinStillOut and DismissCompanion then
        -- Server-side; CallCompanion below toggles the slot atomically on
        -- most realms but a small minority queue both calls and only the
        -- last takes effect. Explicit dismiss is safer.
        DismissCompanion("CRITTER")
    end
    CallCompanion("CRITTER", greedyIndex)
    -- v2.9.0 / v2.10.0: surface the recovery in chat exactly once per
    -- dismiss-and-resummon cycle. Each dismiss site that wants the
    -- recovery announced sets EC_compCache.pendingAnnounce; the first
    -- successful CallCompanion in the cycle prints and clears the flag.
    -- Subsequent retries inside the same cycle (server slow to confirm
    -- the summon) call CallCompanion again but stay silent so the chat
    -- log doesn't fill with duplicate "resummoned" lines during heavy
    -- combat farming.
    if EC_compCache.pendingAnnounce then
        PrintNice("|cff00ff00Greedy Scavenger resummoned.|r")
        EC_compCache.pendingAnnounce = false
    end
    -- Anchor the user-dismiss-vs-leash classification window for this summon
    -- too, so a fast portrait click that happens immediately after a recovery
    -- gets honoured the same way as one immediately after a manual /ec.
    EC_compCache.lastSummonAt = GetTime()
    if DB and DB.autoLootCycle then
        EC_lootCycleState = STATE.LOOTING
    end
end

-- 5 s-gated body. Pre-flight guards, state sync, stuck check, re-summon.
local function EC_PetCheckTick()
    if not DB or not DB.summonGreedy then
        return
    end
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if IsMounted() then
        return
    end
    if running then
        return
    end

    EC_AutoLootStateSync()
    -- Bag-full detection lives in BAG_UPDATE (EC_HandleBagFullForCycle).

    if EC_lootCycleState == STATE.WAITING_MERCHANT or EC_lootCycleState == STATE.SELLING then
        return
    end

    local num = GetNumCompanions("CRITTER")
    if not num or num <= 0 then
        return
    end
    local greedyIndex, scavengerOut, anyPetOut, goblinStillOut = nil, false, false, false
    for i = 1, num do
        local _, creatureName, spellID, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if isSummoned then
            anyPetOut = true
            -- Track whether the in-slot pet is OUR leftover goblin from a
            -- recent bag-full cycle. The goblin doesn't auto-dismiss when
            -- the merchant window closes; if we treat it as "user's other
            -- companion" the resummon path will respect it forever and
            -- never bring the Scavenger back. Distinguished from a
            -- genuine third-party companion (bank mule, mailbox) which
            -- the addon never summons.
            if creatureName == TARGET_NAME or spellID == GOBLIN_MERCHANT_SPELL_ID then
                goblinStillOut = true
            end
        end
        if creatureName == PET_NAME then
            greedyIndex = i
            if isSummoned then
                scavengerOut = true
            end
        end
    end

    -- Reset the movement accumulator on every out<->in transition so each
    -- new summon (and each fresh dismiss) starts the stuck-counter cleanly.
    -- Also confirm the dismiss-and-resummon retry loop in EC_TryResummonScavenger
    -- here: a false->true transition while EC_addonDismissed is still true
    -- means our last CallCompanion landed, so we can clear the flag and stop
    -- retrying. (If the player summoned manually via /ec, SummonGreedyScavenger
    -- has already cleared the flag itself.)
    if EC_lastScavengerOut ~= scavengerOut then
        EC_scavMovementAccum = 0
        -- Drop any prior loot timestamps so a fresh out<->in transition starts
        -- the loot-silence counter cleanly (otherwise stale pre-transition
        -- loots could trigger an immediate re-fire after a benign respawn).
        EC_recentLootTimes = {}
        -- v2.9.0: classify true -> false transitions as a possible manual
        -- portrait dismiss. The `not EC_addonDismissed` guard is the
        -- definitive signal: every addon-driven dismiss path
        -- (DismissGreedyScavenger, EC_HandleBagFullForCycle, the auto-loot
        -- cycle's mid-cycle dismiss before summoning the Goblin Merchant)
        -- sets EC_addonDismissed = true, so any transition that reaches
        -- here with the flag still false was not us. If the timing also
        -- lands inside EC_compCache.USER_WINDOW_S of our last summon we
        -- mark a 30 s grace via EC_compCache.userUntil and EC_TryResummonScavenger
        -- honours it. Range-leash transitions take longer than 5 s to
        -- surface, so they fall outside the window and the existing
        -- recovery path runs unchanged.
        if EC_lastScavengerOut and not scavengerOut and not EC_addonDismissed then
            if (GetTime() - EC_compCache.lastSummonAt) < EC_compCache.USER_WINDOW_S then
                EC_compCache.userUntil = GetTime() + EC_compCache.USER_GRACE_S
            end
        end
        if scavengerOut and EC_addonDismissed then
            EC_addonDismissed = false
            -- v2.10.0: cycle ended cleanly - the server has confirmed the
            -- summon. Drop any leftover pendingAnnounce so the next
            -- dismiss-and-resummon cycle starts from a known-clean state.
            EC_compCache.pendingAnnounce = false
        end
        -- v2.8.0: refresh the loot-silence baseline on every fresh out
        -- transition (false->true). Pet just appeared; even if the speech
        -- detection misses something, the silence clock should not start
        -- counting from the moment of summon -- the pet hasn't had time
        -- to vacuum anything yet.
        if scavengerOut then
            EC_lastScavSpokeAt = GetTime()
        end
    end
    EC_lastScavengerOut = scavengerOut

    if EC_HandleScavengerOut(scavengerOut) then
        return
    end
    EC_TryResummonScavenger(greedyIndex, anyPetOut, goblinStillOut)
end

EC_petCheckFrame:SetScript("OnUpdate", function(_, elapsed)
    -- Accumulate player movement time while the Scavenger is flagged as out.
    -- EC_HandleScavengerOut reads this on the 5 s tick to detect "stuck" cases.
    if EC_lastScavengerOut and GetUnitSpeed and GetUnitSpeed("player") > 0 then
        EC_scavMovementAccum = EC_scavMovementAccum + elapsed
    end

    if EC_TickGoblinSummon(elapsed) then
        return
    end
    if EC_TickGoblinTarget(elapsed) then
        return
    end
    EC_TickMerchantReminder(elapsed)

    EC_petCheckElapsed = EC_petCheckElapsed + elapsed
    -- v2.6.2: when actively trying to resummon (EC_addonDismissed = true),
    -- sample at 1 s instead of 5 s so we catch cast-clear windows much
    -- faster during heavy combat. Falls back to the 5 s baseline once the
    -- pet is back and we're just polling for the next stuck/dismiss event.
    local interval = EC_addonDismissed and 1 or EC_PET_CHECK_INTERVAL
    if EC_petCheckElapsed < interval then
        return
    end
    EC_petCheckElapsed = 0
    EC_PetCheckTick()
end)

local pendingDelete = nil
local deletePopupHooked = false

-- v2.9.0: bag snapshot for manual-sell attribution. Run at MERCHANT_SHOW so
-- the post-call hook can look up what was in (bag, slot) before the player
-- right-clicked it. By the time hooksecurefunc fires the slot is empty, so
-- a synchronous read inside the hook can't see what was sold. All three
-- helpers hang off EC_manualSell to keep main-chunk local count down (Lua
-- 5.1 caps that at 200).
function EC_manualSell.snapshotBags()
    wipe(EC_manualSell.snapshot)
    for bag = 0, 4 do
        local n = GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, count = GetContainerItemInfo(bag, slot)
                EC_manualSell.snapshot[bag * 1000 + slot] = {
                    link = link,
                    count = count or 1,
                    itemID = GetContainerItemID(bag, slot),
                }
            end
        end
    end
end

function EC_manualSell.refreshSlot(bag, slot)
    if not bag or not slot then
        return
    end
    local key = bag * 1000 + slot
    local link = GetContainerItemLink(bag, slot)
    if link then
        local _, count = GetContainerItemInfo(bag, slot)
        EC_manualSell.snapshot[key] = {
            link = link,
            count = count or 1,
            itemID = GetContainerItemID(bag, slot),
        }
    else
        EC_manualSell.snapshot[key] = nil
    end
end

-- Hook UseContainerItem ONCE at addon load. hooksecurefunc preserves the
-- original (we cannot replace it: UseContainerItem is in the secure-dispatch
-- path for items that trigger spells/casts, and Blizzard's secure system
-- silently rejects calls to a non-Blizzard implementation). The hook only
-- attributes a sell when (a) we did NOT do it ourselves (EC_manualSell.inSelfSell is
-- false) and (b) the merchant frame is open and (c) the snapshot has an
-- entry for that slot - i.e. the item was present at MERCHANT_SHOW or after
-- the last refresh. Stat fields match what DoNextAction bumps for the
-- worker-driven path so lifetime/session totals are uniform regardless of
-- which path actually completed the sale.
function EC_manualSell.installHookOnce()
    if EC_manualSell.hookInstalled then
        return
    end
    EC_manualSell.hookInstalled = true
    hooksecurefunc("UseContainerItem", function(bag, slot)
        if EC_manualSell.inSelfSell then
            return
        end
        if not (MerchantFrame and MerchantFrame:IsShown()) then
            return
        end
        if not bag or not slot then
            return
        end
        local snap = EC_manualSell.snapshot[bag * 1000 + slot]
        if snap and snap.link then
            local sellPrice = select(11, GetItemInfo(snap.link))
            if sellPrice and sellPrice > 0 then
                local copper = sellPrice * (snap.count or 1)
                if DB then
                    DB.totalCopper = (DB.totalCopper or 0) + copper
                    DB.totalItemsSold = (DB.totalItemsSold or 0) + 1
                    if snap.itemID then
                        DB.soldItemCounts = DB.soldItemCounts or {}
                        DB.soldItemCounts[snap.itemID] = (DB.soldItemCounts[snap.itemID] or 0) + 1
                    end
                end
                EC_session.copper = EC_session.copper + copper
                EC_session.sold = EC_session.sold + 1
            end
        end
        -- Refresh the snapshot for this slot after the sell completes. The
        -- 0.1 s delay gives the bag a tick to update before we re-read
        -- (hooksecurefunc fires synchronously inside the protected call,
        -- so the slot may still report the just-sold item if we read now).
        EC_Delay(0.1, function()
            EC_manualSell.refreshSlot(bag, slot)
        end)
    end)
end

local function HookDeletePopupOnce()
    if deletePopupHooked then
        return
    end
    deletePopupHooked = true

    local f = CreateFrame("Frame")
    local popupElapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        -- Skip entirely unless a deletion is queued. Without this gate the
        -- handler would tick ~60 times/s for the life of the session.
        if not pendingDelete then
            popupElapsed = 0
            return
        end
        popupElapsed = popupElapsed + (elapsed or 0)
        if popupElapsed < 0.1 then
            return
        end
        popupElapsed = 0

        local popup = StaticPopup1
        if popup and popup:IsShown() and popup.which == "DELETE_ITEM" then
            local id = pendingDelete.itemID
            if id and IsInSet(DB.deleteList, id) then
                local editBox = StaticPopup1EditBox
                if editBox then
                    editBox:SetText("DELETE")
                    editBox:HighlightText()
                end
                local button1 = StaticPopup1Button1
                if button1 and button1:IsEnabled() then
                    button1:Click()
                    pendingDelete = nil
                end
            else
                pendingDelete = nil
            end
        end
    end)
end

local EC_IsMerchantAllowed -- forward declaration for FinishRun
-- `running` is forward-declared at the top of the file.
local queue = {}
local queueIndex = 1
local goldThisVendoring = 0
local EC_batchTotalSold = 0
local EC_batchTotalGold = 0

local worker = CreateFrame("Frame")
worker:Hide()

-- v2.13.0 quest-item safety net. Returns true iff GetItemInfo classifies
-- the item as itemClass "Quest". Used by EC_IsSellable and BuildQueue's
-- delete branch to refuse auto-vendor / auto-delete on quest items even
-- when they're explicitly on the whitelist or delete list. Catches the
-- failure mode where a user added an item to a list months ago and then
-- later picked it up for a quest. Manual paths (Alt+Right-Click → Sell
-- Now / Delete Now) are NOT gated by this - those represent explicit
-- user intent. GetItemInfo's 6th return is the top-level item class
-- ("Armor", "Weapon", "Quest", "Consumable", etc.); "Quest" is the
-- enUS string and is what the localised client also returns here in
-- 3.3.5a (it's a category key, not display text).
function EC_compCache.isQuestItem(itemID)
    if not itemID then
        return false
    end
    local _, _, _, _, _, itemType = GetItemInfo(itemID)
    return itemType == "Quest"
end

-- Shared sell predicate. Used by BuildQueue to build the vendor queue and by
-- EC_PreviewSellable to drive the minimap mouse-over preview. Returns:
--   sellable (bool), link, sellPrice, itemCount.
-- `junkOnly` restricts matches to quality-0 items (used when the current
-- merchant mode disallows the whitelist/quality threshold).
--
-- INVARIANT: Grey items (quality == 0) with a positive sell price ALWAYS
-- match via isJunk, independent of DB.whitelist, DB.whitelistQualityEnabled,
-- or DB.whitelistMinQuality. The quality threshold only gates non-grey
-- items. Do not "simplify" the three independent passes (isJunk /
-- qualityPass / whitelistPass) into one combined check -- you will silently
-- break the grey-always-sold guarantee that users and docs rely on.
-- Blacklist and IsEquippedItem are the only things that can veto a sale.
local function EC_IsSellable(bag, slot, junkOnly)
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return false
    end
    local _, itemCount, locked = GetContainerItemInfo(bag, slot)
    if not itemCount or itemCount <= 0 or locked then
        return false
    end
    local _, link, quality, ilvl, _, _, _, _, equipLoc, _, sellPrice = GetItemInfo(itemID)
    local hasSellPrice = sellPrice and sellPrice > 0
    local isJunk = (quality ~= nil) and (quality == 0) and hasSellPrice
    local whitelistPass = not junkOnly
        and hasSellPrice
        and (IsInSet(DB.whitelist, itemID) or (ADB and IsInSet(ADB.whitelist, itemID)))
    -- Quality threshold: per-rarity rules (v2.4.0+). Each rarity is independently
    -- toggleable with its own optional max iLvl.
    --   cap == 0  -> no filter, sell every item of that rarity (cloth, trade goods, gear).
    --   cap > 0   -> STRICT filter: sell ONLY equippable items with iLvl <= cap.
    --                "Equippable" = the item has a non-empty equipLoc (its tooltip
    --                visibly displays "Item Level: X"). Trade goods, reagents,
    --                consumables, and quest items don't have an equipLoc so the
    --                cap doesn't engage on them - they're protected. This matches
    --                the user mental model "items I can SEE an iLvl on are the
    --                only ones the cap should filter". Internal itemLevel from
    --                GetItemInfo is non-zero on many trade goods (Runecloth = 50)
    --                but those don't display Item Level to the user.
    local qualityPass = false
    if not junkOnly and hasSellPrice and quality and quality >= 1 and quality <= 4 and DB.qualityRules then
        local rule = DB.qualityRules[quality]
        if rule and rule.enabled then
            if rule.useEquippedILvl then
                -- v2.12.0 dynamic-cap mode: per-slot comparison against the
                -- player's currently-equipped item. The Max-iLvl input is
                -- ignored entirely while this is checked. Empty-slot guard,
                -- multi-slot conservative rule, and equipLoc filtering all
                -- live inside EC_compCache.isDowngradeVsEquipped.
                if EC_compCache.isDowngradeVsEquipped(itemID, ilvl, equipLoc) then
                    qualityPass = true
                end
            else
                -- Existing v2.5.0+ fixed-cap mode unchanged.
                local cap = rule.maxILvl or 0
                local hasVisibleILvl = equipLoc and equipLoc ~= "" and ilvl and ilvl > 0
                if cap == 0 then
                    qualityPass = true
                elseif hasVisibleILvl and ilvl <= cap then
                    qualityPass = true
                end
            end
            -- v2.10.0: bind-type filter. "any" preserves v2.4.0+ behaviour;
            -- "boe" / "bop" restrict matches to items binding on equip /
            -- pickup. Items with no bind line at all (consumables, trade
            -- goods, quest items) read as "any" and are filtered out by
            -- both "boe" and "bop", matching the user mental model "Sell
            -- BoE only" should not sweep up reagents.
            if qualityPass then
                local bindFilter = rule.bindFilter or "any"
                if bindFilter ~= "any" then
                    local bindType = EC_compCache.getBindType(bag, slot)
                    if bindFilter ~= bindType then
                        qualityPass = false
                    end
                end
            end
        end
    end
    -- v2.13.x quest-item safety net narrowing. v2.13.0 originally vetoed
    -- ALL auto-actions on quest-class items via an early return at the
    -- top of EC_IsSellable, which broke the explicit-list-as-user-intent
    -- invariant: a user with quest-class items deliberately whitelisted
    -- for vendoring (e.g. Gorilla Fang itemID 2799 on PE, vendor 67c)
    -- saw "[EC] Will Sell - Whitelisted" in the tooltip but the merchant
    -- cycle silently skipped them. Mirror AutoDelete v3.14's design:
    -- explicit user lists override the safety net; the auto-rule sweep
    -- (qualityPass) keeps it. The original protection against "rule
    -- sweeps up an unanticipated quest item" is preserved; the original
    -- protection against "stale whitelist entry catches a fresh quest
    -- item" is now relegated to the user's awareness of their own list -
    -- which is the right tradeoff since the whitelist IS the
    -- authoritative "items I want to sell" list, and making it
    -- conditional broke that invariant.
    if qualityPass and EC_compCache.isQuestItem(itemID) then
        qualityPass = false
    end
    local blacklisted = IsInSet(DB.blacklist, itemID)
    if not (isJunk or qualityPass or whitelistPass) then
        return false
    end
    if IsEquippedItem(itemID) or blacklisted then
        return false
    end
    return true, link, itemID, sellPrice, itemCount
end

local function BuildQueue(junkOnly)
    wipe(queue)
    queueIndex = 1
    goldThisVendoring = 0
    -- Single bag walk that produces both the sell and delete queue entries.
    -- Sell pass first: grey items (quality 0) always match via isJunk;
    -- whitelist / quality threshold only fire when the merchant allows them.
    -- If the sell pass rejects a slot AND deletion is enabled, fall through
    -- to the delete-list check using its own slot fetch (EC_IsSellable returns
    -- a bare `false` on negative predicate, so we don't have its itemID here).
    local deletionOn = DB.enableDeletion == true
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local sellable, link, itemID, sellPrice, itemCount = EC_IsSellable(bag, slot, junkOnly)
            if sellable then
                queue[#queue + 1] = {
                    type = "sell",
                    bag = bag,
                    slot = slot,
                    itemID = itemID,
                    count = itemCount,
                    price = sellPrice or 0,
                }
                if sellPrice and sellPrice > 0 then
                    goldThisVendoring = goldThisVendoring + EC_GetItemPrice(link, itemID, sellPrice, itemCount)
                end
            elseif deletionOn then
                local id = GetContainerItemID(bag, slot)
                -- v2.13.x: quest-item safety net no longer gates the
                -- delete-list path. Mirror the sell-side narrowing:
                -- explicit user lists override the safety net (the
                -- delete-list entry IS explicit user intent). Catches
                -- the same complaint pattern as the Gorilla Fang fix:
                -- deliberately listed quest-class trash that the user
                -- wants destroyed was being silently kept. IsEquippedItem
                -- still vetoes destructively-significant cases.
                if id and IsInSet(DB.deleteList, id) and not IsEquippedItem(id) then
                    local _, count, locked = GetContainerItemInfo(bag, slot)
                    if count and count > 0 and not locked then
                        queue[#queue + 1] = {
                            type = "delete",
                            bag = bag,
                            slot = slot,
                            itemID = id,
                            count = count,
                        }
                    end
                end
            end
        end
    end

    local cap = EC_EffectiveMaxItemsPerRun()
    if #queue > cap then
        local removed = #queue - cap
        for i = #queue, cap + 1, -1 do
            queue[i] = nil
        end
        PrintNicef("|cffffff00Capped at %d items this run (%d skipped). Visit again to sell the rest.|r", cap, removed)
    end
end

local function FinishRun()
    running = false
    worker:Hide()

    DB.totalCopper = (DB.totalCopper or 0) + (goldThisVendoring or 0)
    EC_session.copper = EC_session.copper + (goldThisVendoring or 0)
    EC_batchTotalSold = EC_batchTotalSold + #queue
    EC_batchTotalGold = EC_batchTotalGold + (goldThisVendoring or 0)

    -- Check if merchant is still open - delay re-scan so server can process sold items
    if MerchantFrame and MerchantFrame:IsShown() then
        PrintNicef("Batch sold |cffffff00%d|r items. Checking for more...", EC_batchTotalSold)
        EC_Delay(1.0, function()
            if not MerchantFrame or not MerchantFrame:IsShown() then
                return
            end
            local merchantAllowed = EC_IsMerchantAllowed()
            BuildQueue(not merchantAllowed)
            if #queue > 0 then
                running = true
                worker.t = 0
                worker:Show()
            else
                -- Nothing left - print final summary
                PrintNicef(
                    "Vendoring complete! Sold |cffffff00%d|r items. |cffb6ffb6Money Collected:|r %s",
                    EC_batchTotalSold,
                    CopperToColoredText(EC_batchTotalGold)
                )
                -- v2.13.3: hoisted EC_SummonGreedyWithDelay out of an
                -- if/else where both branches called it unconditionally.
                -- Only the lootCycleState transition was branch-specific.
                if DB and DB.autoLootCycle then
                    EC_lootCycleState = STATE.IDLE
                end
                EC_SummonGreedyWithDelay()
            end
        end)
        return
    end

    -- All done - print final summary
    PrintNicef(
        "Vendoring complete! Sold |cffffff00%d|r items. |cffb6ffb6Money Collected:|r %s",
        EC_batchTotalSold,
        CopperToColoredText(EC_batchTotalGold)
    )

    if DB and DB.autoLootCycle then
        EC_lootCycleState = STATE.IDLE
    end
    EC_SummonGreedyWithDelay()
end

local function DoNextAction()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        running = false
        worker:Hide()
        return
    end

    local action = queue[queueIndex]
    if not action then
        FinishRun()
        return
    end

    -- Safety: verify the item at this slot still matches what we queued.
    -- Bags can shift between queue build and execution (player moves items, etc).
    local currentID = GetContainerItemID(action.bag, action.slot)
    if currentID ~= action.itemID then
        queueIndex = queueIndex + 1
        return
    end

    if action.type == "sell" then
        -- v2.9.0: bracket the worker-path UseContainerItem so the
        -- manual-sell hook (installed at ADDON_LOADED) skips this call.
        -- The counters below own the attribution for the worker path.
        EC_manualSell.inSelfSell = true
        UseContainerItem(action.bag, action.slot)
        EC_manualSell.inSelfSell = false
        DB.totalItemsSold = (DB.totalItemsSold or 0) + (action.count or 1)
        EC_session.sold = EC_session.sold + (action.count or 1)
        DB.soldItemCounts = DB.soldItemCounts or {}
        if action.itemID then
            DB.soldItemCounts[action.itemID] = (DB.soldItemCounts[action.itemID] or 0) + (action.count or 1)
        end
    elseif action.type == "delete" then
        ClearCursor()
        PickupContainerItem(action.bag, action.slot)
        local cursorType = GetCursorInfo()

        if cursorType == "item" then
            pendingDelete = { bag = action.bag, slot = action.slot, itemID = action.itemID }
            DeleteCursorItem()
            ClearCursor()
            DB.totalItemsDeleted = (DB.totalItemsDeleted or 0) + (action.count or 1)
            EC_session.deleted = EC_session.deleted + (action.count or 1)
            DB.deletedItemCounts = DB.deletedItemCounts or {}
            if action.itemID then
                DB.deletedItemCounts[action.itemID] = (DB.deletedItemCounts[action.itemID] or 0) + (action.count or 1)
            end
        else
            ClearCursor()
            pendingDelete = nil
        end
    end

    queueIndex = queueIndex + 1
end

-- The 0.05s interval floor is an anti-disconnect guarantee, not a performance
-- tuning choice. Faster per-item pacing floods the server with UseContainerItem
-- packets and trips a server-side rate limit that boots the client. See
-- docs/ADDON_GUIDE.md "Performance rules" and v2.0.11 in the README changelog.
worker:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    local interval = EC_EffectiveVendorInterval()
    if self.t >= interval then
        self.t = 0
        DoNextAction()
    end
end)

EC_IsMerchantAllowed = function()
    -- Defensive fallback when DB hasn't loaded yet. Matches the v2.13.x
    -- EnsureDB default of "both" (All Merchants) so a missing-DB call here
    -- gives the same answer as a freshly-initialised DB.
    local mode = DB and DB.merchantMode or "both"
    if mode == "any" then
        -- "any": only normal merchants (not the Goblin Merchant pet).
        local targetName = UnitExists("target") and UnitName("target") or ""
        return targetName ~= TARGET_NAME
    elseif mode == "both" then
        -- "both" (default since v2.13.x): any merchant. Renamed in the
        -- dropdown to "All Merchants" for clarity.
        return true
    else
        -- "goblin": only the Goblin Merchant pet (was the default through
        -- v2.13.0; flipped to "both" in v2.13.x to support new players who
        -- haven't unlocked the pet yet).
        return UnitExists("target") and UnitName("target") == TARGET_NAME
    end
end

-- Mouse-over preview: counts what BuildQueue would sell right now. When no
-- merchant is targeted, fall back to the broadest case (merchantAllowed=true)
-- so the preview reflects the whitelist/quality threshold, not only greys.
local function EC_PreviewSellable()
    if not DB then
        return 0, 0
    end
    local merchantAllowed = true
    if UnitExists("target") then
        merchantAllowed = EC_IsMerchantAllowed()
    end
    local junkOnly = not merchantAllowed
    local count, copper = 0, 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local sellable, link, itemID, sellPrice, itemCount = EC_IsSellable(bag, slot, junkOnly)
            if sellable then
                count = count + (itemCount or 1)
                if sellPrice and sellPrice > 0 then
                    copper = copper + EC_GetItemPrice(link, itemID, sellPrice, itemCount)
                end
            end
        end
    end
    return count, copper
end

local function StartRun()
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if running then
        return
    end

    local merchantAllowed = EC_IsMerchantAllowed()

    HookDeletePopupOnce()

    running = true

    EC_RecordInventoryWorthSample()

    -- Auto-repair. v2.9.0 added the optional guild-bank branch: when
    -- DB.repairUseGuildBank is on AND the player is in a guild AND the
    -- guild bank can fund the full repair cost, RepairAllItems(1) charges
    -- the bank instead of personal gold. Any miss in the guild chain
    -- falls through to the existing personal-gold branch.
    if
        DB
        and DB.repairGear == true
        and CanMerchantRepair
        and CanMerchantRepair()
        and GetRepairAllCost
        and RepairAllItems
    then
        local repairCost, canRepair = GetRepairAllCost()
        if canRepair and repairCost and repairCost > 0 then
            local useGuild = DB.repairUseGuildBank == true
                and IsInGuild
                and IsInGuild()
                and CanGuildBankRepair
                and CanGuildBankRepair()
                and GetGuildBankWithdrawMoney
                and GetGuildBankWithdrawMoney() >= repairCost
            if useGuild then
                RepairAllItems(1) -- 1 = use guild bank funds
                DB.totalRepairs = (DB.totalRepairs or 0) + 1
                DB.totalRepairCopper = (DB.totalRepairCopper or 0) + repairCost
                EC_session.repairs = EC_session.repairs + 1
                EC_session.repairCopper = EC_session.repairCopper + repairCost
                PrintNicef("Repaired from guild bank: %s", CopperToColoredText(repairCost))
            elseif GetMoney and GetMoney() >= repairCost then
                RepairAllItems()
                DB.totalRepairs = (DB.totalRepairs or 0) + 1
                DB.totalRepairCopper = (DB.totalRepairCopper or 0) + repairCost
                EC_session.repairs = EC_session.repairs + 1
                EC_session.repairCopper = EC_session.repairCopper + repairCost
            end
        end
    end

    BuildQueue(not merchantAllowed)

    if #queue == 0 then
        PrintNice("Found nothing to sell.")
        running = false
        if UnitExists("target") and UnitName("target") == TARGET_NAME and MerchantFrame and MerchantFrame:IsShown() then
            EC_SummonGreedyWithDelay()
        end
        return
    end

    worker.t = 0
    worker:Show()
end

-- Tooltip annotation. Adds a coloured line indicating whether EbonClearance
-- will sell, protect, or delete the hovered item. Hooked once on addon load
-- against GameTooltip and ItemRefTooltip (chat-linked items use the latter).
--
-- Dedupe: recipe tooltips fire OnTooltipSetItem twice (once for the recipe,
-- once for the embedded result), so we flag the tooltip after adding a line
-- and clear the flag when the tooltip is reset.
local EC_tooltipHooked = false

local function EC_AnnotateTooltip(tooltip)
    if not DB or not tooltip or not tooltip.GetItem then
        return
    end
    -- Honour the addon-enabled toggle and per-character allowlist. If the
    -- addon won't act on the item, don't mislead the user by annotating it.
    if EC_IsAddonEnabledForChar and not EC_IsAddonEnabledForChar() then
        return
    end
    if tooltip.__EC_annotated then
        return
    end
    local _, link = tooltip:GetItem()
    if not link then
        return
    end
    local id = tonumber(link:match("|Hitem:(%d+)"))
    if not id then
        return
    end

    local statusLine
    if IsInSet(DB.blacklist, id) then
        -- v2.10.0: distinguish "user manually blacklisted this" from "the
        -- auto-protect-equipped path added it". DB.blacklistAuto is stamped
        -- only by the equipment handler / one-shot sync; manual adds don't
        -- touch it. The suffix is concatenated onto the existing label so
        -- the annotation stays a single line. The suffix tells the user
        -- "this is on Keep because you equipped it, not because you hand-
        -- added it" - useful when they expected an item to vendor and want
        -- to know why the rules are leaving it alone. The override is the
        -- existing Alt+Right-Click context menu's "Remove from Blacklist"
        -- row.
        local autoTag = DB.blacklistAuto and DB.blacklistAuto[id]
        if autoTag then
            -- v2.12.0: origin-aware label. The auto-protect path stamps
            -- one of two string tags so the tooltip can tell the user
            -- WHICH rule kept the item. Legacy boolean-true entries from
            -- v2.10.0 / v2.11.0 fall back to the generic label.
            if autoTag == "equipped" then
                statusLine = "|cff66ccff[EC]|r |cffffb84dAuto-Protected (Worn)|r"
            elseif autoTag == "upgrade" then
                statusLine = "|cff66ccff[EC]|r |cffffb84dAuto-Protected (Upgrade)|r"
            elseif autoTag == "set" then
                -- v2.13.0: items from a saved Blizzard Equipment Manager set.
                -- Most likely an off-set / dual-spec piece sitting in bags
                -- between swaps; the tag promotes to "(Worn)" the next time
                -- the user actually equips it (via protectEquipSlot's
                -- existing tag-refresh branch).
                statusLine = "|cff66ccff[EC]|r |cffffb84dAuto-Protected (Set)|r"
            else
                statusLine = "|cff66ccff[EC]|r |cffffb84dAuto-Protected|r"
            end
        else
            statusLine = "|cff66ccff[EC]|r |cffffb84dProtected - Blacklisted|r"
        end
    elseif IsInSet(DB.deleteList, id) and DB.enableDeletion then
        statusLine = "|cff66ccff[EC]|r |cffff4444Will Delete - Deletion List|r"
    elseif IsInSet(DB.whitelist, id) or (ADB and IsInSet(ADB.whitelist, id)) then
        -- Honesty: EC_IsSellable also requires sellPrice > 0 and not currently
        -- equipped. Without these checks the tooltip used to claim "Will Sell"
        -- on items that the merchant cycle correctly refuses (custom items
        -- with no vendor price, or items the player has equipped). Surface
        -- both reasons in warning-yellow so the user sees them at the point
        -- of decision instead of wondering why the cycle skipped them.
        local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
        if IsEquippedItem(id) then
            statusLine = "|cff66ccff[EC]|r |cffffb84dWhitelisted - Currently Equipped (cannot sell)|r"
        elseif not (sellPrice and sellPrice > 0) then
            statusLine = "|cff66ccff[EC]|r |cffffb84dWhitelisted - No Vendor Price (cannot sell)|r"
        else
            statusLine = "|cff66ccff[EC]|r |cffb6ffb6Will Sell - Whitelisted|r"
        end
    elseif DB.qualityRules then
        local _, _, quality, ilvl, _, _, _, _, equipLoc, _, sellPrice = GetItemInfo(id)
        if quality and quality >= 1 and quality <= 4 and sellPrice and sellPrice > 0 then
            local rule = DB.qualityRules[quality]
            if rule and rule.enabled then
                local rarityName = (quality == 1) and "White"
                    or (quality == 2) and "Green"
                    or (quality == 3) and "Blue"
                    or "Epic"
                local hasVisibleILvl = equipLoc and equipLoc ~= "" and ilvl and ilvl > 0
                -- v2.12.0: split on useEquippedILvl mode. Dynamic-cap mode
                -- mirrors EC_compCache.isDowngradeVsEquipped semantics so
                -- the tooltip is honest about what will / won't sell.
                local matchesILvl = false
                local matchedAgainstEquipped = false
                local cap = rule.maxILvl or 0
                if rule.useEquippedILvl then
                    matchedAgainstEquipped = true
                    if hasVisibleILvl and EC_compCache.isDowngradeVsEquipped(id, ilvl, equipLoc) then
                        matchesILvl = true
                    end
                else
                    matchesILvl = (cap == 0) or (hasVisibleILvl and ilvl <= cap)
                end
                if matchesILvl and EC_compCache.isQuestItem(id) then
                    -- v2.13.x: quest-item safety-net honesty. After the
                    -- v2.13.x narrowing, EC_IsSellable returns false when
                    -- a qualityPass auto-rule would catch a quest-class
                    -- item. Reflect that here so the tooltip doesn't
                    -- claim "Will Sell" when the merchant cycle will
                    -- silently skip. The whitelist match path above is
                    -- unaffected (whitelist overrides safety net).
                    statusLine = "|cff66ccff[EC]|r |cffffb84dProtected - Quest item|r"
                elseif matchesILvl then
                    -- v2.10.0: bind-filter check. EC_IsSellable applies this
                    -- AFTER the iLvl gate; the tooltip annotation has to
                    -- mirror the same chain so users get an accurate read
                    -- of what the rules will do at the next vendor visit.
                    local bindFilter = rule.bindFilter or "any"
                    local bindRejected = false
                    if bindFilter ~= "any" then
                        local bindType = EC_compCache.getBindTypeFromTooltip(tooltip, id)
                        if bindType ~= bindFilter then
                            bindRejected = true
                        end
                    end
                    if bindRejected then
                        local fLabel = (bindFilter == "boe") and "BoE" or "BoP"
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84dProtected - %s rule wants %s only|r",
                            rarityName,
                            fLabel
                        )
                    elseif matchedAgainstEquipped then
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6Will Sell - %s iLvl %d below equipped|r",
                            rarityName,
                            ilvl
                        )
                    elseif cap == 0 then
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6Will Sell - %s (no iLvl cap)|r",
                            rarityName
                        )
                    else
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6Will Sell - %s iLvl %d (cap %d)|r",
                            rarityName,
                            ilvl,
                            cap
                        )
                    end
                elseif matchedAgainstEquipped then
                    -- Dynamic-cap mode and the item didn't qualify. Two
                    -- distinct cases collapse to one user-facing message:
                    --   * "empty_slot": rule short-circuited because at least
                    --     one candidate slot is empty - the looted item could
                    --     fill it (relevant for dual-wielders).
                    --   * "at_or_above": actual iLvl compare happened and the
                    --     looted item met or exceeded the lowest populated
                    --     slot - could be an upgrade for the weakest slot in
                    --     a multi-slot equipLoc, or a same-iLvl sidegrade.
                    -- Both cases mean "kept because this could be useful";
                    -- "Potential Upgrade" is the user-friendly framing.
                    if not hasVisibleILvl then
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84dProtected - %s has no iLvl|r",
                            rarityName
                        )
                    else
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84dProtected - %s iLvl %d (Potential Upgrade)|r",
                            rarityName,
                            ilvl
                        )
                    end
                elseif not hasVisibleILvl then
                    -- Fixed-cap mode; non-equippable has no visible iLvl.
                    statusLine = string.format(
                        "|cff66ccff[EC]|r |cffffb84dProtected - %s has no iLvl (cap %d active)|r",
                        rarityName,
                        cap
                    )
                else
                    -- Fixed-cap mode; equippable item iLvl above cap.
                    statusLine = string.format(
                        "|cff66ccff[EC]|r |cffffb84dProtected - %s above max iLvl (%d > %d)|r",
                        rarityName,
                        ilvl,
                        cap
                    )
                end
            end
        end
    end

    if statusLine then
        tooltip:AddLine(statusLine)
    end
    -- Discoverability hint for the v2.3.0 right-click context menu. Shown on
    -- every bag/item-link tooltip so users know the action is available.
    tooltip:AddLine("|cff666666Alt+Right-Click for EbonClearance menu|r")
    tooltip.__EC_annotated = true
    tooltip:Show()
end

local function EC_ClearTooltipFlag(tooltip)
    if tooltip then
        tooltip.__EC_annotated = nil
    end
end

local function EC_InstallTooltipHookOnce()
    if EC_tooltipHooked then
        return
    end
    EC_tooltipHooked = true
    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", EC_AnnotateTooltip)
        GameTooltip:HookScript("OnTooltipCleared", EC_ClearTooltipFlag)
    end
    if ItemRefTooltip and ItemRefTooltip.HookScript then
        ItemRefTooltip:HookScript("OnTooltipSetItem", EC_AnnotateTooltip)
        ItemRefTooltip:HookScript("OnTooltipCleared", EC_ClearTooltipFlag)
    end
end

local MainOptions = CreateFrame("Frame", "EbonClearanceOptionsMain", InterfaceOptionsFramePanelContainer)
MainOptions.name = "EbonClearance"

local function MakeHeader(parent, text, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    return fs
end

local EC_PANEL_WIDTH = 440 -- default fallback; updated dynamically in OnShow

local function EC_UpdatePanelWidth()
    local container = InterfaceOptionsFramePanelContainer
    if container and container.GetWidth then
        local w = container:GetWidth()
        if w and w > 100 then
            EC_PANEL_WIDTH = w - 40
        end
    end
end

-- v2.11.0 reactive layout registry. Pre-v2.11.0 the panel-build pass
-- snapshotted EC_PANEL_WIDTH at first OnShow into every label, every
-- scroll-content, every list internal width - and never touched them
-- again. Dragging the Interface Options frame's resize handle did
-- nothing to the addon's panels because none of those widgets re-read
-- EC_PANEL_WIDTH after their build call. v2.11.0 hooks
-- InterfaceOptionsFramePanelContainer's OnSizeChanged once; widgets
-- whose width snapshots EC_PANEL_WIDTH at construction register
-- themselves on EC_compCache.widthRegistry.widgets, scroll-wrapped
-- panels register their (content, last-widget) pair on
-- EC_compCache.widthRegistry.scrollFits, and the OnSizeChanged callback
-- walks both lists to re-apply widths and re-fit scroll content. No
-- widget rebuilds; pure width refresh.
EC_compCache.widthRegistry = {
    widgets = {},
    scrollFits = {},
}

function EC_compCache.registerWidth(widget, xOffset)
    if not widget then
        return
    end
    local list = EC_compCache.widthRegistry.widgets
    list[#list + 1] = { w = widget, x = xOffset or 0 }
end

function EC_compCache.registerScrollFit(content, last, padding)
    if not content or not last then
        return
    end
    local list = EC_compCache.widthRegistry.scrollFits
    list[#list + 1] = { c = content, l = last, p = padding }
end

-- Convenience: SetWidth + register in one call. Use this at every site
-- that snapshots EC_PANEL_WIDTH into a widget's width so the widget
-- tracks Interface Options frame resizes. Replaces the v2.10.0-and-
-- earlier pattern of "widget:SetWidth(EC_PANEL_WIDTH - X)" - that
-- worked fine on a non-resizable panel but leaves widgets clamped at
-- their snapshot width on resize.
function EC_compCache.setPanelWidth(widget, x)
    if not widget or not widget.SetWidth then
        return
    end
    widget:SetWidth(EC_PANEL_WIDTH - (x or 0))
    EC_compCache.registerWidth(widget, x or 0)
end

function EC_compCache.refreshLayouts()
    EC_UpdatePanelWidth()
    local widgets = EC_compCache.widthRegistry.widgets
    for i = 1, #widgets do
        local d = widgets[i]
        if d.w and d.w.SetWidth then
            d.w:SetWidth(math.max(EC_PANEL_WIDTH - d.x, 100))
        end
    end
    -- After widths are re-applied, the wrapped FontString heights change;
    -- re-fit each scroll content's height to the (now possibly taller)
    -- last-widget extent. Inlined rather than calling EC_FitScrollContent
    -- to avoid re-registering on every resize - the registry pair was
    -- already added at build time.
    local fits = EC_compCache.widthRegistry.scrollFits
    local function compute(f)
        if not f.c or not f.l or not f.l.GetBottom or not f.c.GetTop then
            return
        end
        local top = f.c:GetTop()
        local bottom = f.l:GetBottom()
        if top and bottom and top > bottom then
            f.c:SetHeight(top - bottom + (f.p or 24))
        end
    end
    -- Two-pass identical to EC_FitScrollContent's: first tick catches the
    -- common case, second tick covers FontStrings whose wrapped height
    -- isn't fully settled yet.
    EC_Delay(0.1, function()
        for i = 1, #fits do
            compute(fits[i])
        end
    end)
    EC_Delay(0.5, function()
        for i = 1, #fits do
            compute(fits[i])
        end
    end)
end

-- Auto-hide a UIPanelScrollFrameTemplate's scroll bar (up arrow, thumb,
-- down arrow) when content fits the visible area. Avoids the "orphan icons
-- floating at the right edge" look that lists with few items show.
--
-- Implementation note: a manual GetHeight comparison inside Refresh runs
-- before WoW has laid out the scroll frame on the very first OnShow, so the
-- initial visibility was always wrong. OnScrollRangeChanged is fired by WoW
-- whenever it (re)computes the scroll range, which is exactly the moment the
-- visibility decision is meaningful. The deferred initial update handles the
-- corner case where the script handler is wired after the first range change.
local function EC_HookScrollbarAutoHide(scrollFrame)
    if not scrollFrame or not scrollFrame.GetName then
        return
    end
    local scrollName = scrollFrame:GetName()
    if not scrollName then
        return
    end
    local sb = _G[scrollName .. "ScrollBar"]
    if not sb then
        return
    end
    local function update()
        local yRange = 0
        if scrollFrame.GetVerticalScrollRange then
            yRange = scrollFrame:GetVerticalScrollRange() or 0
        end
        if yRange <= 0 then
            sb:Hide()
        else
            sb:Show()
        end
    end
    scrollFrame:HookScript("OnScrollRangeChanged", update)
    -- Initial check: defer one short tick so layout dimensions are stable.
    EC_Delay(0.1, update)
end

-- Wrap a settings panel's body in a vertical scroll frame and return a
-- "content" Frame to use as the widget parent inside that panel's OnShow.
-- Used for panels whose content overflows the Interface Options sub-panel
-- safe area at narrow container widths (Scavenger, Merchant). Width is the
-- panel width minus a 26px scrollbar gutter; the gutter is filled by the
-- scroll bar itself (or empty when EC_HookScrollbarAutoHide hides it).
--
-- After all widgets are placed, the caller should call EC_FitScrollContent
-- to size the content frame to the actual widget extent.
local function EC_WrapPanelInScrollFrame(panel)
    local scrollName = (panel:GetName() or "EbonClearancePanel") .. "Scroll"
    local scroll = CreateFrame("ScrollFrame", scrollName, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    -- v2.10.0: extended the scroll frame down to within 6 px of the panel's
    -- bottom edge (was 30 px). With the v2.4.0 quality threshold + v2.10.0
    -- bind-filter dropdowns, the panel content tall enough for the
    -- scrollbar to be visible all the time, and the previous 30 px reserve
    -- left the down arrow floating above the OK/Cancel button strip with
    -- no visual relationship to the panel frame. EC_FitScrollContent's 24
    -- px padding still keeps the bottom-most widget clear of the OK/Cancel
    -- area; the gap that used to come from the 30 px reserve now comes
    -- from that padding instead.
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(math.max(EC_PANEL_WIDTH - 26, 100))
    content:SetHeight(1) -- expanded by EC_FitScrollContent once widgets are laid out
    scroll:SetScrollChild(content)
    -- v2.11.0: register the scroll content's width with the reactive
    -- layout registry so it tracks Interface Options frame resizes.
    EC_compCache.registerWidth(content, 26)

    -- v2.10.0: nudge the scrollbar's top anchor 4 px further down. The
    -- UIPanelScrollFrameTemplate default insets the bar 16 px from the
    -- ScrollFrame top; the up arrow that lives there ended up sitting
    -- above the panel's content area on Project Ebonhold's Interface
    -- Options layout. Bottom anchor stays at the template default (16 px
    -- inset from ScrollFrame bottom) - the new 6 px outer reserve already
    -- pulls the down arrow down to where it should be.
    local sb = _G[scrollName .. "ScrollBar"]
    if sb then
        sb:ClearAllPoints()
        sb:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -6, -20)
        sb:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -6, 16)
    end

    EC_HookScrollbarAutoHide(scroll)
    return content
end

-- Resize a scroll-wrapped content frame to fit the actual extent of its
-- widgets. Pass the bottom-most widget added during OnShow.
--
-- Two passes: the first at 0.1 s catches the common case quickly; the second
-- at 0.5 s covers FontStrings whose wrapped height isn't fully settled at
-- the first tick (multi-line tips were getting clipped on the Scavenger
-- panel because their wrapped GetBottom hadn't been computed yet).
-- Padding defaults to 24 px so the bottom-most widget always has visible
-- breathing room above the scroll frame's edge.
local function EC_FitScrollContent(content, lastWidget, padding)
    if not content or not lastWidget then
        return
    end
    local pad = padding or 24
    local function compute()
        if not lastWidget.GetBottom or not content.GetTop then
            return
        end
        local top = content:GetTop()
        local bottom = lastWidget:GetBottom()
        if top and bottom and top > bottom then
            content:SetHeight(top - bottom + pad)
        end
    end
    EC_Delay(0.1, compute)
    EC_Delay(0.5, compute)
    -- v2.11.0: register the (content, last) pair so the reactive layout
    -- handler can re-fit when the panel container resizes (label re-wrap
    -- changes lastWidget's GetBottom and the content height needs to
    -- track that). Idempotent re-fits are safe.
    EC_compCache.registerScrollFit(content, lastWidget, pad)
end

local function MakeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(EC_PANEL_WIDTH - x)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    -- v2.11.0: register the label's width with the reactive layout
    -- registry so it re-wraps when the panel container resizes.
    EC_compCache.registerWidth(fs, x)
    if fs.SetWordWrap then
        fs:SetWordWrap(true)
    end
    fs:SetText(text)
    return fs
end

local function StyleInputBox(editBox)
    if not editBox then
        return
    end
    if editBox.SetTextInsets then
        editBox:SetTextInsets(6, 6, 0, 0)
    end

    local fs = editBox.GetFontString and editBox:GetFontString()
    if fs and fs.SetDrawLayer then
        fs:SetDrawLayer("OVERLAY")
    end
    if fs and fs.SetAlpha then
        fs:SetAlpha(1)
    end

    local n = editBox.GetName and editBox:GetName()
    if n then
        local left = _G[n .. "Left"]
        local mid = _G[n .. "Middle"]
        local right = _G[n .. "Right"]
        if left and left.SetDrawLayer then
            left:SetDrawLayer("BACKGROUND")
        end
        if mid and mid.SetDrawLayer then
            mid:SetDrawLayer("BACKGROUND")
        end
        if right and right.SetDrawLayer then
            right:SetDrawLayer("BACKGROUND")
        end
    end
    editBox:SetFrameLevel((editBox:GetParent() and editBox:GetParent():GetFrameLevel() or editBox:GetFrameLevel()) + 2)

    if editBox.GetText and editBox.SetText then
        local t = editBox:GetText() or ""
        editBox:SetText(t)
        if editBox.SetCursorPosition then
            editBox:SetCursorPosition(0)
        end
    end
end

local function CreateListUI(parent, titleText, setTableName, x, y)
    local w = EC_PANEL_WIDTH - x
    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", x, y)
    -- Height chosen to keep the whole box inside a standard InterfaceOptions
    -- sub-panel. Callers may override via listUI:SetHeight(n) if they need more
    -- or less room (e.g. WhitelistPanel has extra controls above it).
    box:SetSize(w, 280)

    local title = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(titleText)

    local input = CreateFrame("EditBox", "EbonClearanceIDInput_" .. setTableName, box, "InputBoxTemplate")
    input:SetAutoFocus(false)
    input:SetSize(140, 20)
    input:SetPoint("TOPLEFT", 0, -24)
    input:SetNumeric(true)
    input:SetMaxLetters(10)
    input:SetText("")
    StyleInputBox(input)

    local addBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 20)
    addBtn:SetPoint("LEFT", input, "RIGHT", 8, 0)
    addBtn:SetText("Add")

    -- "Clear All" button on the input row, anchored hard-right and visually
    -- separated from the Add flow. Wipes every entry in the list with a
    -- confirmation popup. Wired below.
    local clearAllBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    clearAllBtn:SetSize(80, 20)
    clearAllBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -24)
    clearAllBtn:SetText("Clear All")

    input:SetScript("OnEditFocusGained", function(self)
        EC_activeIDBox = self
    end)
    input:SetScript("OnEditFocusLost", function(self)
        if EC_activeIDBox == self then
            EC_activeIDBox = nil
        end
    end)
    input:SetScript("OnReceiveDrag", function(self)
        local ctype, cid = GetCursorInfo()
        if ctype == "item" and cid then
            self:SetText(tostring(cid))
            self:HighlightText()
            ClearCursor()
        end
    end)

    local sortMode = "id_asc" -- default: sort by ID ascending

    -- Search row: Search box then ID, Name sort buttons all on one line
    local searchLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", 0, -52)
    searchLabel:SetText("Search:")

    local sortNameBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    sortNameBtn:SetSize(62, 20)
    sortNameBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -52)
    sortNameBtn:SetText("Name \226\150\178")

    local sortIDBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    sortIDBtn:SetSize(50, 20)
    sortIDBtn:SetPoint("RIGHT", sortNameBtn, "LEFT", -4, 0)
    sortIDBtn:SetText("ID \226\150\178")

    local search = CreateFrame("EditBox", "EbonClearanceSearchInput_" .. setTableName, box, "InputBoxTemplate")
    search:SetAutoFocus(false)
    search:SetHeight(20)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetPoint("RIGHT", sortIDBtn, "LEFT", -8, 0)
    search:SetMaxLetters(40)
    search:SetText("")
    StyleInputBox(search)

    -- Bag-scan "Add matching" row: scan bags for items whose name contains the
    -- typed substring and add each match to this list.
    local matchLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    matchLabel:SetPoint("TOPLEFT", 0, -76)
    matchLabel:SetText("Add matching in bags:")

    local matchBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    matchBtn:SetSize(80, 20)
    matchBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -76)
    matchBtn:SetText("Add Match")

    local matchInput = CreateFrame("EditBox", "EbonClearanceMatchInput_" .. setTableName, box, "InputBoxTemplate")
    matchInput:SetAutoFocus(false)
    matchInput:SetHeight(20)
    matchInput:SetPoint("LEFT", matchLabel, "RIGHT", 8, 0)
    matchInput:SetPoint("RIGHT", matchBtn, "LEFT", -8, 0)
    matchInput:SetMaxLetters(40)
    matchInput:SetText("")
    StyleInputBox(matchInput)

    local scroll =
        CreateFrame("ScrollFrame", "EbonClearanceListScroll_" .. setTableName, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -102)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(w - 26, 1)
    scroll:SetScrollChild(content)
    -- Auto-hide the scroll bar (arrows + thumb) when content fits the visible
    -- area. Wired once here; OnScrollRangeChanged fires on every Refresh that
    -- changes content height, so visibility tracks the list automatically.
    EC_HookScrollbarAutoHide(scroll)

    -- v2.11.0: when the panel resizes the box stretches via its
    -- BOTTOMRIGHT anchor (set externally), scroll stretches with the
    -- box, but content (a ScrollChild) needs explicit SetWidth -
    -- ScrollChild doesn't auto-track parent. Hook OnSizeChanged to keep
    -- content width in step. Rows inside the content already track via
    -- TOPLEFT/TOPRIGHT anchors so they stretch with content automatically.
    box:SetScript("OnSizeChanged", function(self, width)
        if not width or width <= 0 then
            return
        end
        if content and content.SetWidth then
            content:SetWidth(width - 26)
        end
    end)

    local rowPool = {}
    local activeRows = 0

    local function GetRow(index)
        if rowPool[index] then
            return rowPool[index]
        end
        local row = CreateFrame("Frame", nil, content)
        row:SetHeight(22)
        -- v2.11.0: rows track content width via TOPLEFT/TOPRIGHT anchors
        -- (re-applied at every position update in Refresh below). The text
        -- inside is anchored TOPLEFT/TOPRIGHT relative to row + Remove
        -- button so it auto-stretches; no SetWidth snapshot left to drift.

        local rm = CreateFrame(
            "Button",
            "EbonClearanceListRM_" .. setTableName .. "_" .. index,
            content,
            "UIPanelButtonTemplate"
        )
        rm:SetSize(72, 18)
        rm:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        rm:SetText("Remove")

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 2, 0)
        text:SetPoint("RIGHT", rm, "LEFT", -8, 0)
        text:SetJustifyH("LEFT")

        row.rm = rm
        row.text = text
        rowPool[index] = row
        return row
    end

    local function HideAllRows()
        for i = 1, activeRows do
            if rowPool[i] then
                rowPool[i]:Hide()
                rowPool[i].rm:Hide()
            end
        end
        activeRows = 0
    end

    local function MatchesSearch(id, name, searchText)
        if not searchText or searchText == "" then
            return true
        end
        local idStr = tostring(id or "")
        if idStr:find(searchText, 1, true) then
            return true
        end
        local nameStr = tostring(name or ""):lower()
        if nameStr:find(searchText, 1, true) then
            return true
        end
        return false
    end

    local pendingRetry = false

    local function Refresh()
        HideAllRows()

        local searchText = ""
        if search and search.GetText then
            searchText = (search:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        end

        local setTable = EC_GetListTable(setTableName)
        if type(setTable) ~= "table" then
            return
        end
        local keys = {}
        for k in pairs(setTable) do
            if type(k) == "number" then
                keys[#keys + 1] = k
            end
        end
        if sortMode == "id_desc" then
            table.sort(keys, function(a, b)
                return a > b
            end)
        elseif sortMode == "name_asc" then
            table.sort(keys, function(a, b)
                local na = GetItemInfo(a) or ""
                local nb = GetItemInfo(b) or ""
                return na:lower() < nb:lower()
            end)
        elseif sortMode == "name_desc" then
            table.sort(keys, function(a, b)
                local na = GetItemInfo(a) or ""
                local nb = GetItemInfo(b) or ""
                return na:lower() > nb:lower()
            end)
        else
            table.sort(keys) -- id_asc (default)
        end

        local shown = 0
        local rowY = -4
        local hasUncached = false
        for i = 1, #keys do
            local id = keys[i]
            local name = GetItemInfo(id)
            if not name then
                hasUncached = true
                -- Request item data from server via tooltip query
                if GameTooltip and GameTooltip.SetHyperlink then
                    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                    GameTooltip:SetHyperlink("item:" .. id .. ":0:0:0:0:0:0:0")
                    GameTooltip:Hide()
                end
                name = "ItemID: " .. id
            end

            if MatchesSearch(id, name, searchText) then
                shown = shown + 1
                local row = GetRow(shown)
                row:ClearAllPoints()
                -- v2.11.0: anchor both TOPLEFT and TOPRIGHT so the row
                -- stretches with the (resizable) content frame.
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, rowY)
                row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, rowY)
                row.text:SetText(string.format("|cffb6ffb6%d|r  %s", id, name))
                row.rm:SetScript("OnClick", function()
                    local t = EC_GetListTable(setTableName)
                    if t then
                        t[id] = nil
                    end
                    Refresh()
                end)
                row:Show()
                row.rm:Show()
                rowY = rowY - 22
            end
        end

        activeRows = shown
        content:SetHeight(math.max(1, (shown * 22) + 8))
        -- Scroll-bar visibility auto-updates via the OnScrollRangeChanged hook
        -- wired in EC_HookScrollbarAutoHide(scroll) below; SetHeight here
        -- triggers that hook, no manual call needed.

        -- If any items were uncached, retry after a delay to pick up server responses
        if hasUncached and not pendingRetry then
            pendingRetry = true
            EC_Delay(1.5, function()
                pendingRetry = false
                Refresh()
            end)
        end
    end

    addBtn:SetScript("OnClick", function()
        local v = tonumber(input:GetText() or "")
        if not v or v <= 0 then
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        -- v2.13.4: route through EC_AddItemToList for canonical add
        -- semantics (cross-list conflict guard, dedupe check, panel
        -- refresh, future origin-tag support). The previous inline
        -- code reimplemented the conflict guard + write, bypassing
        -- the canonical path and missing any future improvements to
        -- it. EC_AddItemToList prints its own conflict / dedupe /
        -- success chat lines using item names rather than raw IDs,
        -- which is a slight upgrade over the previous "Item NNN is
        -- already on..." format.
        EC_AddItemToList(setTableName, v, titleText)
        input:SetText("")
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    input:SetScript("OnEnterPressed", function()
        addBtn:Click()
        input:ClearFocus()
    end)

    clearAllBtn:SetScript("OnClick", function()
        local t = EC_GetListTable(setTableName)
        if not t or not next(t) then
            PrintNicef("|cff888888%s is already empty.|r", titleText)
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        local dialog = StaticPopup_Show("EC_CONFIRM_CLEAR_LIST", titleText)
        if dialog then
            dialog.data = function()
                local target = EC_GetListTable(setTableName)
                if target then
                    wipe(target)
                end
                Refresh()
                PrintNicef('Cleared every item from "|cffffff00%s|r".', titleText)
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    local function AddMatchingFromBags(substr)
        local t = EC_GetListTable(setTableName)
        if not t or not substr or substr == "" then
            return 0, 0
        end
        local needle = substr:lower()
        local added, skipped = 0, 0
        -- v2.13.4: route adds through EC_AddItemToList(quiet=true) so
        -- this bulk path picks up the canonical conflict guard, dedupe,
        -- and any future origin-tag support. The pre-check on `t[itemID]`
        -- preserves the existing semantic where already-present items
        -- silently do not increment either counter; only cross-list
        -- conflicts count as skipped.
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID and not t[itemID] then
                    local name = GetItemInfo(itemID)
                    if name and name:lower():find(needle, 1, true) then
                        if EC_AddItemToList(setTableName, itemID, titleText, true) then
                            added = added + 1
                        else
                            skipped = skipped + 1
                        end
                    end
                end
            end
        end
        return added, skipped
    end

    matchBtn:SetScript("OnClick", function()
        local txt = (matchInput:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if txt == "" then
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        local added, skipped = AddMatchingFromBags(txt)
        PrintNicef("Scanned bags: added |cffffff00%d|r matching item(s) (substring: |cffffff00%s|r).", added, txt)
        if skipped and skipped > 0 then
            PrintNicef("Skipped |cffffff00%d|r already on another list.", skipped)
        end
        matchInput:SetText("")
        Refresh()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    matchInput:SetScript("OnEnterPressed", function()
        matchBtn:Click()
        matchInput:ClearFocus()
    end)

    search:SetScript("OnTextChanged", function()
        Refresh()
    end)

    sortIDBtn:SetScript("OnClick", function()
        if sortMode == "id_asc" then
            sortMode = "id_desc"
        else
            sortMode = "id_asc"
        end
        sortIDBtn:SetText(sortMode == "id_asc" and "ID \226\150\178" or "ID \226\150\188")
        sortNameBtn:SetText("Name \226\150\178")
        Refresh()
    end)
    sortNameBtn:SetScript("OnClick", function()
        if sortMode == "name_asc" then
            sortMode = "name_desc"
        else
            sortMode = "name_asc"
        end
        sortNameBtn:SetText(sortMode == "name_asc" and "Name \226\150\178" or "Name \226\150\188")
        sortIDBtn:SetText("ID \226\150\178")
        Refresh()
    end)

    box.Refresh = Refresh
    return box
end

local function AddCheckbox(parent, name, anchor, labelText, getter, setter, yOff)
    local cb = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -6)
    cb:SetChecked(getter())

    local t = _G[name .. "Text"]
    if t then
        t:SetText(labelText)
        t:SetWidth(420)
        t:SetJustifyH("LEFT")
    end

    cb:SetScript("OnClick", function()
        setter(cb:GetChecked() and true or false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    return cb
end

local function ColorTextByQuality(quality, text)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    local hex = (c and c.hex) or "|cffffffff"
    return hex .. text .. "|r"
end

local function AddSlider(parent, name, anchor, labelText, minVal, maxVal, step, getter, setter, yOff, fmt)
    fmt = fmt or "%.3fs"
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -16)
    s:SetMinMaxValues(minVal, maxVal)
    if s.SetValueStep then
        s:SetValueStep(step)
    end
    if s.SetObeyStepOnDrag then
        s:SetObeyStepOnDrag(true)
    end
    s:SetValue(getter())

    local low = _G[name .. "Low"]
    local high = _G[name .. "High"]
    local text = _G[name .. "Text"]

    if low then
        low:SetText(string.format(fmt, minVal))
    end
    if high then
        high:SetText(string.format(fmt, maxVal))
    end

    local function RefreshText(v)
        if text then
            text:SetText(labelText .. ": " .. string.format(fmt, v))
        end
    end
    RefreshText(getter())

    s:SetScript("OnValueChanged", function(self, value)
        value = tonumber(value) or minVal
        if step and step > 0 then
            value = math.floor((value / step) + 0.5) * step
        end
        if value < minVal then
            value = minVal
        end
        if value > maxVal then
            value = maxVal
        end
        setter(value)
        RefreshText(value)
    end)

    return s
end

local function EC_UpdateMinimapPos()
    local btn = _G["EbonClearanceMinimapButton"]
    if not btn then
        return
    end
    local angle = math.rad(DB and DB.minimapButtonAngle or 220)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function EC_CreateMinimapButton()
    if not DB then
        return
    end
    if _G["EbonClearanceMinimapButton"] then
        return
    end -- only create once

    local btn = CreateFrame("Button", "EbonClearanceMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- Circular background
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Background")
    bg:SetSize(53, 53)
    bg:SetPoint("CENTER", btn, "CENTER", -1, 1)

    -- Icon
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.icon = icon

    -- Border ring
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("CENTER", btn, "CENTER", 10, -10)

    EC_UpdateMinimapPos()

    local dragging = false

    btn:SetScript("OnDragStart", function(self)
        dragging = true
    end)

    btn:SetScript("OnDragStop", function(self)
        dragging = false
        EC_UpdateMinimapPos()
    end)

    btn:SetScript("OnUpdate", function(self)
        if not dragging then
            return
        end
        if not IsMouseButtonDown("LeftButton") then
            dragging = false
            return
        end
        local mx, my = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        cx = cx / scale
        cy = cy / scale
        local angle = math.deg(math.atan2(cy - my, cx - mx))
        if DB then
            DB.minimapButtonAngle = angle
        end
        EC_UpdateMinimapPos()
    end)

    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
        elseif button == "RightButton" then
            if not DB then
                return
            end
            DB.enabled = not DB.enabled
            local state = DB.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
            PrintNice("Addon " .. state)
            if self.icon then
                self.icon:SetDesaturated(not DB.enabled)
            end
        end
    end)

    -- Apply initial desaturation if disabled
    if DB and DB.enabled == false then
        icon:SetDesaturated(true)
    end

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("EbonClearance")
        GameTooltip:AddLine("Left-click: Options  |  Right-click: Toggle Addon", 1, 1, 1)
        local stateStr = (DB and DB.enabled ~= false) and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
        GameTooltip:AddLine("Status: " .. stateStr)
        local freeSlots = EC_GetFreeBagSlots()
        local slotColor = freeSlots >= 10 and "|cff00ff00" or (freeSlots >= 5 and "|cffffff00" or "|cffff4444")
        GameTooltip:AddLine("Free bag slots: " .. slotColor .. freeSlots .. "|r")

        local sellCount, sellCopper = EC_PreviewSellable()
        GameTooltip:AddLine(string.format("Sellable now: |cffffff00%d|r items", sellCount))
        if sellCopper > 0 then
            GameTooltip:AddLine("Est. value: " .. CopperToColoredText(sellCopper))
        end
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
end

-- Hidden SecureActionButton that registers a keybinding to /target the Goblin
-- Merchant. The button is never shown; its only job is to sink the keybind
-- registered via BINDING_HEADER_EBONCLEARANCE near the slash commands. The
-- macrotext attribute is set at creation so it remains functional inside
-- InCombatLockdown() (secure click from a player hardware event).
local function EC_CreateTargetMerchantButton()
    if _G.EbonClearanceTargetMerchantButton then
        return
    end
    local btn = CreateFrame("Button", "EbonClearanceTargetMerchantButton", UIParent, "SecureActionButtonTemplate")
    btn:RegisterForClicks("AnyUp")
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", "/target " .. TARGET_NAME)
    btn:Hide()
end

-- Optional LibDataBroker-1.0 launcher. No-op if LibStub or LDB is not present,
-- so users on Titan Panel / Bazooka / ChocolateBar / etc. get an entry in
-- their display addon without us taking a hard dependency on anything.
local function EC_CreateLDBLauncher()
    if not _G.LibStub then
        return
    end
    local LDB = _G.LibStub("LibDataBroker-1.0", true)
    if not LDB then
        return
    end
    if LDB.GetDataObjectByName and LDB:GetDataObjectByName("EbonClearance") then
        return
    end

    LDB:NewDataObject("EbonClearance", {
        type = "launcher",
        label = "EbonClearance",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        OnClick = function(_, button)
            if button == "RightButton" then
                if not DB then
                    return
                end
                DB.enabled = not DB.enabled
                PrintNice("Addon " .. (DB.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"))
            else
                InterfaceOptionsFrame_OpenToCategory(MainOptions)
                InterfaceOptionsFrame_OpenToCategory(MainOptions)
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("EbonClearance")
            tt:AddLine("Left-click: Options  |  Right-click: Toggle", 1, 1, 1)
            local stateStr = (DB and DB.enabled ~= false) and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
            tt:AddLine("Status: " .. stateStr)
            local freeSlots = EC_GetFreeBagSlots()
            local slotColor = freeSlots >= 10 and "|cff00ff00" or (freeSlots >= 5 and "|cffffff00" or "|cffff4444")
            tt:AddLine("Free bag slots: " .. slotColor .. freeSlots .. "|r")
            local count, copper = EC_PreviewSellable()
            tt:AddLine(string.format("Sellable now: |cffffff00%d|r items", count))
            if copper > 0 then
                tt:AddLine("Est. value: " .. CopperToColoredText(copper))
            end
        end,
    })
end

-- v2.13.3: removed the dormant vendor-button cluster (EC_vendorButton,
-- EC_CreateVendorButton, EC_SaveVendorButtonPos, EC_UpdateVendorButtonVisibility,
-- and the vendorBtn{X,Y,Point,RelPoint,Shown} DB fields). The cluster had
-- carried a luacheck:ignore suppression because no caller existed since
-- before v2.13.0. If a future opt-in vendor button is desired, build it
-- fresh on top of EC_CreateTargetMerchantButton (the existing combat-safe
-- SecureActionButton helper) rather than reviving this dead surface.

StaticPopupDialogs["EC_CONFIRM_RESET_LIFETIME"] = {
    text = "Reset |cffb6ffb6EbonClearance|r lifetime stats?\n|cffaaaaaaThis clears money earned, items sold, items deleted, repair totals, and per-item counters. Session stats are not affected.|r",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EC_CONFIRM_RESET_SESSION"] = {
    text = "Reset session stats?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EC_CONFIRM_DELETE_PROFILE"] = {
    text = 'Delete profile "|cffffff00%s|r"?\n|cffaaaaaaThis cannot be undone.|r',
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EC_CONFIRM_CLEAR_PROFILE"] = {
    text = 'Clear all items from profile "|cffffff00%s|r"?\n|cffaaaaaaThe profile itself will remain.|r',
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Generic confirmation for the per-list "Clear All" button on every list panel
-- (Whitelist - Character / Whitelist - Account / Blacklist / Deletion List).
-- The %s slot is filled with the list's user-facing title.
StaticPopupDialogs["EC_CONFIRM_CLEAR_LIST"] = {
    text = 'Remove every item from "|cffffff00%s|r"?\n|cffaaaaaaThis cannot be undone.|r',
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.12.0 stale-upgrade cleanup confirmation popup. The %d slot is filled
-- with the count of stale entries detected by /ec clean upgrades. The
-- OnAccept invokes the callback function passed via StaticPopup_Show's
-- third "data" argument, mirroring the EC_CONFIRM_CLEAR_LIST pattern.
StaticPopupDialogs["EC_CONFIRM_CLEAN_UPGRADES"] = {
    text = "Remove |cffffff00%d|r stale 'Upgrade'-tagged entries from your Blacklist?\n"
        .. "|cffaaaaaaThese items were auto-tagged as upgrades but are no longer above your "
        .. "currently-equipped iLvl. Manual blacklist entries (no auto-tag) and 'Worn'-tagged "
        .. "entries are not affected.|r",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- v2.12.0 first-run welcome popup. Fired once on PLAYER_LOGIN when EnsureDB
-- detected a fresh install (DB._needsWelcome). Two-button choice:
-- Keep Defaults (closes silently after a chat ack) or Open Settings (jumps
-- the Interface Options frame to the EbonClearance main panel). The double
-- InterfaceOptionsFrame_OpenToCategory call is a known 3.3.5a workaround
-- for the first-time-this-session focus quirk - the same pattern used by
-- the slash command's "open settings" fallback at the bottom of the file.
StaticPopupDialogs["EC_WELCOME"] = {
    text = "Welcome to EbonClearance!\n\n"
        .. "Greys auto-sell. Whites and greens below your equipped iLvl also auto-sell. "
        .. "Items you equip and looted upgrades are auto-protected from auto-sell.\n\n"
        .. "Click |cffffff00Open Settings|r to review, or |cffffff00Keep Defaults|r "
        .. "to start farming.",
    button1 = "Keep Defaults",
    button2 = "Open Settings",
    OnAccept = function()
        PrintNice("|cffb6ffb6Defaults kept.|r Type |cffffff00/ec|r any time to customise.")
    end,
    OnCancel = function()
        if InterfaceOptionsFrame_OpenToCategory and MainOptions then
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Build the static widgets for the main options panel. Called once per panel
-- (guarded by `panel.inited` in OnShow). `refreshStats` is the dynamic refresh
-- callback captured by the Reset button.
local function BuildMainPanel(panel, content, refreshStats)
    -- v2.12.0: widgets are created on `content` (the scroll-frame child)
    -- so vertical overflow is handled by the scroll bar. Stat refs are
    -- still stored on `panel` (the outer Interface Options panel) so
    -- RefreshStats's self.statsX reads keep working across re-OnShows.
    local addonVersion = EC_GetVersion()
    MakeHeader(content, "EbonClearance " .. addonVersion, -16)

    -- Byline (required by LICENSE; do not remove in derivatives).
    local byline = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    byline:SetPoint("TOPLEFT", 16, -32)
    byline:SetText("|cff888866by " .. ADDON_AUTHOR .. "  \194\183  " .. ADDON_URL .. "|r")

    local welcomeLabel = MakeLabel(
        content,
        "Welcome to |cffb6ffb6EbonClearance|r! Automatic vendoring and item management for Project Ebonhold.",
        16,
        -52
    )
    local descLabel2 = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    descLabel2:SetPoint("TOPLEFT", welcomeLabel, "BOTTOMLEFT", 0, -4)
    EC_compCache.setPanelWidth(descLabel2, 16)
    descLabel2:SetJustifyH("LEFT")
    descLabel2:SetJustifyV("TOP")
    if descLabel2.SetWordWrap then
        descLabel2:SetWordWrap(true)
    end
    descLabel2:SetText(
        "Greys auto-sell. Whites and greens with iLvl below your equipped gear in the same slot also auto-sell by default, and upgrades you loot are auto-protected. Use the |cffb6ffb6Whitelist|r (per-character or account-wide) to mark specific items for sale, the |cffb6ffb6Blacklist|r to permanently protect items, and |cffb6ffb6Merchant Settings|r to tune the auto-sell rules per rarity. |cff888888Tip: Alt+Right-Click any bag item for a quick-action menu.|r"
    )

    -- Stats fontstrings. Stacked vertically; each attaches its ref to `panel`
    -- so RefreshStats can find them across subsequent OnShow calls.
    local money = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    money:SetPoint("TOPLEFT", descLabel2, "BOTTOMLEFT", 0, -16)
    panel.statsMoney = money

    local sold = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sold:SetPoint("TOPLEFT", money, "BOTTOMLEFT", 0, -6)
    panel.statsSold = sold

    local deleted = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    deleted:SetPoint("TOPLEFT", sold, "BOTTOMLEFT", 0, -6)
    panel.statsDeleted = deleted

    local repairs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairs:SetPoint("TOPLEFT", deleted, "BOTTOMLEFT", 0, -6)
    panel.statsRepairs = repairs

    local repairCost = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairCost:SetPoint("TOPLEFT", repairs, "BOTTOMLEFT", 0, -6)
    panel.statsRepairCost = repairCost

    local avgWorth = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    avgWorth:SetPoint("TOPLEFT", repairCost, "BOTTOMLEFT", 0, -6)
    panel.statsAvgWorth = avgWorth

    local mostSold = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    mostSold:SetPoint("TOPLEFT", avgWorth, "BOTTOMLEFT", 0, -6)
    EC_compCache.setPanelWidth(mostSold, 16)
    mostSold:SetJustifyH("LEFT")
    panel.statsMostSold = mostSold

    local statsNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statsNote:SetPoint("TOPLEFT", mostSold, "BOTTOMLEFT", 0, -4)
    EC_compCache.setPanelWidth(statsNote, 16)
    statsNote:SetJustifyH("LEFT")
    statsNote:SetText("|cff888888Stats don't account for items bought back from a merchant.|r")

    local resetBtn = CreateFrame("Button", "EbonClearanceResetStatsBtn", content, "UIPanelButtonTemplate")
    resetBtn:SetSize(170, 22)
    resetBtn:SetPoint("TOPLEFT", statsNote, "BOTTOMLEFT", 0, -8)
    resetBtn:SetText("Reset Lifetime Stats")
    resetBtn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("EC_CONFIRM_RESET_LIFETIME")
        if dialog then
            dialog.data = function()
                DB.totalCopper = 0
                DB.totalItemsSold = 0
                DB.totalItemsDeleted = 0
                DB.totalRepairs = 0
                DB.totalRepairCopper = 0
                DB.inventoryWorthTotal = 0
                DB.inventoryWorthCount = 0
                wipe(DB.soldItemCounts)
                wipe(DB.deletedItemCounts)
                refreshStats()
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    -- Session delta is inlined into each lifetime stat line by RefreshStats (EC_session).
    -- The Reset Session button sits side-by-side with Reset Lifetime to avoid adding vertical space.
    local resetSessionBtn = CreateFrame("Button", "EbonClearanceResetSessionBtn", content, "UIPanelButtonTemplate")
    resetSessionBtn:SetSize(170, 22)
    resetSessionBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
    resetSessionBtn:SetText("Reset Session Stats")
    resetSessionBtn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("EC_CONFIRM_RESET_SESSION")
        if dialog then
            dialog.data = function()
                EC_ResetSession()
                refreshStats()
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    -- Slash commands reference.
    local cmdHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    cmdHeader:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -16)
    cmdHeader:SetText("Slash Commands")

    local cmdText = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cmdText:SetPoint("TOPLEFT", cmdHeader, "BOTTOMLEFT", 0, -6)
    EC_compCache.setPanelWidth(cmdText, 16)
    cmdText:SetJustifyH("LEFT")
    if cmdText.SetWordWrap then
        cmdText:SetWordWrap(true)
    end
    cmdText:SetText(
        "|cffffff00/ec|r  Open settings\n"
            .. "|cffffff00/ec profile [list|save|load|delete <name>]|r  Manage saved profiles\n"
            .. "|cffffff00/ec clean [apply]|r  Find and resolve list conflicts\n"
            .. "|cffffff00/ec clean upgrades [apply]|r  Clean stale 'Upgrade'-tagged Blacklist entries\n"
            .. "Type |cffffff00/ec help|r in chat for the full reference."
    )

    -- v2.12.0: size the scroll content to fit the bottom-most widget so
    -- the scroll bar engages when the Interface Options frame is too
    -- short to show everything (matches the Scavenger / Merchant /
    -- Profiles / Import-Export panels' pattern).
    EC_FitScrollContent(content, cmdText)
end

MainOptions:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()

    local function GetMostItem(countTable)
        local bestID, bestCount = nil, 0
        if type(countTable) ~= "table" then
            return nil, 0
        end
        for id, cnt in pairs(countTable) do
            if type(id) == "number" and type(cnt) == "number" and cnt > bestCount then
                bestID, bestCount = id, cnt
            end
        end
        return bestID, bestCount
    end

    local function ItemLabel(id)
        if not id then
            return "None"
        end
        local name = GetItemInfo(id)
        if name then
            return string.format("|cff24ffb6%s|r", name)
        end
        return "ItemID: " .. tostring(id)
    end

    local function RefreshStats()
        if not self.statsMoney then
            return
        end
        local function sessionSuffix(n)
            return string.format("  |cff888888(session +%s)|r", tostring(n or 0))
        end
        local function sessionMoneySuffix(c)
            return "  |cff888888(session +" .. CopperToColoredText(c or 0) .. "|cff888888)|r"
        end
        self.statsMoney:SetText(
            "Total Money Made: " .. CopperToColoredText(DB.totalCopper or 0) .. sessionMoneySuffix(EC_session.copper)
        )
        self.statsSold:SetText(
            "Total Items Sold: " .. tostring(DB.totalItemsSold or 0) .. sessionSuffix(EC_session.sold)
        )
        self.statsDeleted:SetText(
            "Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0) .. sessionSuffix(EC_session.deleted)
        )
        self.statsRepairs:SetText(
            "Total Repairs: " .. tostring(DB.totalRepairs or 0) .. sessionSuffix(EC_session.repairs)
        )
        self.statsRepairCost:SetText(
            "Total Repair Cost: "
                .. CopperToColoredText(DB.totalRepairCopper or 0)
                .. sessionMoneySuffix(EC_session.repairCopper)
        )
        if self.statsAvgWorth then
            local cnt = DB.inventoryWorthCount or 0
            local total = DB.inventoryWorthTotal or 0
            local avg = 0
            if cnt > 0 then
                avg = math.floor((total / cnt) + 0.5)
            end
            self.statsAvgWorth:SetText("Average Inventory Worth: " .. CopperToColoredText(avg))
        end

        local mostID, mostCount = GetMostItem(DB.soldItemCounts)
        if mostID then
            self.statsMostSold:SetText("Most Sold Item: " .. ItemLabel(mostID) .. " (x" .. tostring(mostCount) .. ")")
        else
            self.statsMostSold:SetText("Most Sold Item: None")
        end
    end

    if self.inited then
        RefreshStats()
        return
    end
    self.inited = true

    -- v2.12.0: scroll-wrap the Main panel so the Slash Commands block
    -- at the bottom doesn't overlap the OK/Cancel button strip when
    -- the Interface Options frame is shorter than the panel content.
    -- Scavenger and Merchant Settings are wrapped the same way.
    local content = EC_WrapPanelInScrollFrame(self)
    BuildMainPanel(self, content, RefreshStats)
    RefreshStats()
end)

InterfaceOptions_AddCategory(MainOptions)

-- Quality-threshold options shared by the Merchant Settings panel. Declared
-- here so the panel's OnShow closure resolves it as an upvalue.
local EC_WHITELIST_QUALITIES = {
    { text = ColorTextByQuality(1, "White (Common)"), value = 1 },
    { text = ColorTextByQuality(2, "Green (Uncommon)"), value = 2 },
    { text = ColorTextByQuality(3, "Blue (Rare)"), value = 3 },
    { text = ColorTextByQuality(4, "Purple (Epic)"), value = 4 },
}

local MerchantPanel = CreateFrame("Frame", "EbonClearanceOptionsMerchant", InterfaceOptionsFramePanelContainer)
MerchantPanel.name = "Merchant Settings"
MerchantPanel.parent = "EbonClearance"

local EC_MERCHANT_MODES = {
    { text = "|cffb6ffb6Goblin Merchant|r Only", value = "goblin" },
    { text = "Normal Merchants Only", value = "any" },
    -- v2.13.x: renamed from "Both (All Merchants)" and made the new default
    -- in EnsureDB so brand-new users without the Goblin Merchant pet still
    -- get useful auto-vendor behaviour at normal merchants out of the box.
    { text = "All Merchants", value = "both" },
}

MerchantPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.repairCB then
            self.repairCB:SetChecked(DB.repairGear)
        end
        if self.guildRepairCB then
            self.guildRepairCB:SetChecked(DB.repairUseGuildBank)
        end
        if self.keepBagsCB then
            self.keepBagsCB:SetChecked(DB.keepBagsOpen)
        end
        if self.speedSlider then
            self.speedSlider:SetValue(DB.vendorInterval or 0.1)
        end
        if self.fastModeCB then
            self.fastModeCB:SetChecked(DB.fastMode)
        end
        if self.RefreshMerchantModeDropDown then
            self:RefreshMerchantModeDropDown()
        end
        for q = 1, 4 do
            local cb = self["qualityRow" .. q .. "CB"]
            local input = self["qualityRow" .. q .. "Input"]
            local dd = self["qualityRow" .. q .. "DD"]
            local useEqCB = self["qualityRow" .. q .. "UseEq"]
            if cb and DB.qualityRules and DB.qualityRules[q] then
                cb:SetChecked(DB.qualityRules[q].enabled)
            end
            if input and DB.qualityRules and DB.qualityRules[q] then
                input:SetText(tostring(DB.qualityRules[q].maxILvl or 0))
            end
            if dd and DB.qualityRules and DB.qualityRules[q] and self._BindFilterText then
                UIDropDownMenu_SetText(dd, self._BindFilterText(DB.qualityRules[q].bindFilter))
            end
            -- v2.12.0: refresh the per-rarity Use-equipped-iLvl tickbox
            -- and the maxILvl input's enabled state. The applyInputEnabled
            -- helper was stashed on the row's main checkbox at build time.
            if useEqCB and DB.qualityRules and DB.qualityRules[q] then
                useEqCB:SetChecked(DB.qualityRules[q].useEquippedILvl == true)
            end
            if cb and cb._applyInputEnabled then
                cb._applyInputEnabled()
            end
        end
        return
    end
    self.inited = true

    -- Scroll-wrap the panel: at narrow Interface Options widths the Blue
    -- (Rare) quality row overflows the safe area and is overlapped by the
    -- OK/Cancel button strip. Wrapping in a scroll frame keeps every widget
    -- reachable; the scrollbar auto-hides on wider containers where it fits.
    local content = EC_WrapPanelInScrollFrame(self)

    MakeHeader(content, "Merchant Settings", -16)
    -- Panel-specific intro only. Generic "grey junk auto-sells" cross-cut
    -- removed; it's covered on the Main panel.
    MakeLabel(content, "These settings control automatic vendoring behaviour.", 16, -44)

    -- Merchant mode dropdown
    local modeLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    modeLabel:SetPoint("TOPLEFT", 16, -76)
    modeLabel:SetText("Sell at:")

    local modeDD = CreateFrame("Frame", "EbonClearanceMerchantModeDD", content, "UIDropDownMenuTemplate")
    modeDD:SetPoint("LEFT", modeLabel, "RIGHT", -8, -2)

    local function GetModeText(mode)
        for _, entry in ipairs(EC_MERCHANT_MODES) do
            if entry.value == mode then
                return entry.text
            end
        end
        return EC_MERCHANT_MODES[1].text
    end

    local function MerchantModeInit(_frame, level)
        for _, entry in ipairs(EC_MERCHANT_MODES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.text
            info.value = entry.value
            info.checked = (DB.merchantMode == entry.value)
            info.func = function()
                DB.merchantMode = entry.value
                UIDropDownMenu_SetText(modeDD, entry.text)
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_SetWidth(modeDD, 180)
    UIDropDownMenu_SetText(modeDD, GetModeText(DB.merchantMode))
    UIDropDownMenu_Initialize(modeDD, MerchantModeInit)

    self.RefreshMerchantModeDropDown = function()
        UIDropDownMenu_SetText(modeDD, GetModeText(DB.merchantMode))
    end

    local repairCB =
        CreateFrame("CheckButton", "EbonClearanceRepairGearCB", content, "InterfaceOptionsCheckButtonTemplate")
    -- Shifted up 14 px (was -110) to follow the removed grey-junk line above
    -- the dropdown; preserves the original visual gap between dropdown and
    -- this checkbox.
    repairCB:SetPoint("TOPLEFT", 16, -96)
    repairCB:SetChecked(DB.repairGear)
    local rt = _G[repairCB:GetName() .. "Text"]
    if rt then
        rt:SetText("Repair Gear while Vendoring")
        rt:SetWidth(420)
        rt:SetJustifyH("LEFT")
    end
    repairCB:SetScript("OnClick", function()
        DB.repairGear = repairCB:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.repairCB = repairCB

    -- Guild-bank funded repair. Indented under the master repair toggle so
    -- the visual hierarchy reads "repair, and prefer guild bank if I can".
    -- The runtime path falls back to personal gold whenever the bank can't
    -- supply the full amount, so toggling this on is safe even on alts who
    -- aren't in a guild.
    local guildRepairCB = CreateFrame(
        "CheckButton",
        "EbonClearanceRepairGuildBankCB",
        content,
        "InterfaceOptionsCheckButtonTemplate"
    )
    guildRepairCB:SetPoint("TOPLEFT", repairCB, "BOTTOMLEFT", 22, -2)
    guildRepairCB:SetChecked(DB.repairUseGuildBank)
    local grt = _G[guildRepairCB:GetName() .. "Text"]
    if grt then
        grt:SetText("Use guild bank funds when available")
        EC_compCache.setPanelWidth(grt, 80)
        grt:SetJustifyH("LEFT")
    end
    guildRepairCB:SetScript("OnClick", function()
        DB.repairUseGuildBank = guildRepairCB:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.guildRepairCB = guildRepairCB

    local keepBagsCB =
        CreateFrame("CheckButton", "EbonClearanceKeepBagsOpenCB", content, "InterfaceOptionsCheckButtonTemplate")
    keepBagsCB:SetPoint("TOPLEFT", guildRepairCB, "BOTTOMLEFT", -22, -6)
    keepBagsCB:SetChecked(DB.keepBagsOpen)
    local kbt = _G[keepBagsCB:GetName() .. "Text"]
    if kbt then
        kbt:SetText("Keep bags open when merchant window closes")
        EC_compCache.setPanelWidth(kbt, 60)
        kbt:SetJustifyH("LEFT")
    end
    keepBagsCB:SetScript("OnClick", function()
        DB.keepBagsOpen = keepBagsCB:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.keepBagsCB = keepBagsCB

    local speedSlider = AddSlider(
        content,
        "EbonClearanceVendoringSpeedSlider",
        keepBagsCB,
        "Vendoring Speed",
        0.05,
        0.500,
        0.01,
        function()
            return DB.vendorInterval or 0.1
        end,
        function(v)
            DB.vendorInterval = v
        end,
        -16
    )
    self.speedSlider = speedSlider
    speedSlider:SetWidth(200)

    local fastModeCB = AddCheckbox(
        content,
        "EbonClearanceFastModeCB",
        speedSlider,
        "Fast Mode (0.05 s interval, 160-item cap)",
        function()
            return DB.fastMode
        end,
        function(v)
            DB.fastMode = v
        end,
        -16
    )
    self.fastModeCB = fastModeCB

    local fastModeNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fastModeNote:SetPoint("TOPLEFT", fastModeCB, "BOTTOMLEFT", 26, -2)
    EC_compCache.setPanelWidth(fastModeNote, 60)
    fastModeNote:SetJustifyH("LEFT")
    if fastModeNote.SetWordWrap then
        fastModeNote:SetWordWrap(true)
    end
    fastModeNote:SetText(
        "|cff888888Higher throughput. Increases disconnect risk on unstable connections - disable if you DC mid-vendor.|r"
    )

    -- Quality threshold (v2.4.0+): three per-rarity rows, each independently
    -- togglable with its own optional max iLvl. Replaces the old single-dropdown
    -- "sell up to quality X" model. Default all off; opt-in per rarity.
    local thresholdHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    thresholdHeader:SetPoint("TOPLEFT", fastModeNote, "BOTTOMLEFT", -26, -24)
    thresholdHeader:SetText("Quality Threshold")

    local thresholdDesc = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    thresholdDesc:SetPoint("TOPLEFT", thresholdHeader, "BOTTOMLEFT", 0, -4)
    EC_compCache.setPanelWidth(thresholdDesc, 16)
    thresholdDesc:SetJustifyH("LEFT")
    if thresholdDesc.SetWordWrap then
        thresholdDesc:SetWordWrap(true)
    end
    thresholdDesc:SetText(
        "Auto-sell rules per rarity. Each rarity has its own toggle, an optional cap, and a bind-type filter. Tick |cffffff00Use equipped iLvl|r for a dynamic cap that follows your equipped iLvl in the same slot (recommended; default ON for whites/greens on fresh installs). Untick for a fixed |cffffff00max iLvl|r - 0 = sell every item of that rarity. |cffaaaaaaWhitelist always sells; blacklist always protects.|r"
    )

    -- v2.10.0: bind-type filter options shared across all four rarity rows.
    -- "any" = today's behaviour (rule applies regardless of bind type);
    -- "boe" / "bop" restrict to items the tooltip says bind on equip /
    -- on pickup. Items with no bind line at all read as "any" from
    -- EC_compCache.getBindType so reagents/consumables/quest items are
    -- protected when bindFilter is "boe" or "bop".
    local EC_BIND_FILTER_OPTIONS = {
        { text = "Any bind type", value = "any" },
        { text = "BoE only", value = "boe" },
        { text = "BoP only", value = "bop" },
    }
    local function EC_BindFilterText(value)
        for _, entry in ipairs(EC_BIND_FILTER_OPTIONS) do
            if entry.value == value then
                return entry.text
            end
        end
        return EC_BIND_FILTER_OPTIONS[1].text
    end

    -- Build a row per rarity. Each row: checkbox on the left, "max iLvl:"
    -- label + numeric input on the right (0-300). Below the checkbox, a
    -- "Bind: <Any/BoE/BoP>" dropdown that gates the rule on bind type.
    -- Returns the bind dropdown so the next row's anchor descends past
    -- the second line cleanly.
    local function MakeQualityRow(anchor, qualityIdx, labelText, yOff)
        local cb = AddCheckbox(content, "EbonClearanceQualityRow" .. qualityIdx .. "CB", anchor, labelText, function()
            return DB.qualityRules[qualityIdx].enabled
        end, function(v)
            DB.qualityRules[qualityIdx].enabled = v
        end, yOff)

        local input =
            CreateFrame("EditBox", "EbonClearanceQualityRow" .. qualityIdx .. "Input", content, "InputBoxTemplate")
        input:SetSize(50, 20)
        -- Anchored to content's right edge with a small margin. Content's
        -- right edge already sits 26 px inside the panel (scrollbar gutter),
        -- so -6 here matches the original panel-anchored -32 offset visually.
        input:SetPoint("RIGHT", content, "RIGHT", -6, 0)
        input:SetPoint("TOP", cb, "TOP", 0, -2)
        input:SetAutoFocus(false)
        input:SetNumeric(true)
        input:SetMaxLetters(3)
        input:SetText(tostring(DB.qualityRules[qualityIdx].maxILvl or 0))
        StyleInputBox(input)

        local lbl = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        lbl:SetPoint("RIGHT", input, "LEFT", -6, 0)
        lbl:SetText("max iLvl:")

        -- v2.12.0: per-rarity "Use equipped iLvl" tickbox. When checked,
        -- the maxILvl input is ignored at runtime and the cap is the
        -- player's currently-equipped iLvl in the same slot (per-item
        -- via EC_compCache.isDowngradeVsEquipped). The input is visibly
        -- disabled while this is checked so the user understands the
        -- maxILvl number isn't being applied.
        local useEqCB = CreateFrame(
            "CheckButton",
            "EbonClearanceQualityRow" .. qualityIdx .. "UseEqCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        useEqCB:SetPoint("RIGHT", lbl, "LEFT", -8, 0)
        useEqCB:SetChecked(DB.qualityRules[qualityIdx].useEquippedILvl == true)
        -- The InterfaceOptionsCheckButtonTemplate auto-creates a label
        -- to the RIGHT of the box; that label would extend rightward
        -- into the "max iLvl:" field on this layout. Blank the
        -- auto-generated label and place a separate FontString to the
        -- LEFT of the box instead so the row reads
        -- "<rarity>  Use equipped iLvl [✓]  max iLvl: [   ]".
        local autoLabel = _G[useEqCB:GetName() .. "Text"]
        if autoLabel then
            autoLabel:SetText("")
        end
        local useEqText = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        useEqText:SetPoint("RIGHT", useEqCB, "LEFT", -2, 0)
        useEqText:SetText("Use equipped iLvl")
        useEqCB.tooltipText = "Use equipped iLvl"
        useEqCB.tooltipRequirement =
            "When checked, the cap for this rarity is your currently-equipped iLvl in the same slot. "
            .. "Items below auto-sell. Multi-slot items (rings, trinkets, weapons) compare against the "
            .. "worst equipped slot. Empty slots are skipped."

        local function applyInputEnabled()
            local on = DB.qualityRules[qualityIdx].useEquippedILvl == true
            if on then
                -- 3.3.5a EditBox doesn't expose Enable/Disable - use
                -- SetEditable + EnableMouse to actually block input,
                -- and grey both the field text and the "max iLvl:" label
                -- so the disabled state is obvious.
                if input.SetEditable then
                    input:SetEditable(false)
                end
                input:EnableMouse(false)
                if input.HasFocus and input:HasFocus() then
                    input:ClearFocus()
                end
                input:SetTextColor(0.5, 0.5, 0.5)
                if lbl.SetTextColor then
                    lbl:SetTextColor(0.5, 0.5, 0.5)
                end
            else
                if input.SetEditable then
                    input:SetEditable(true)
                end
                input:EnableMouse(true)
                input:SetTextColor(1, 1, 1)
                if lbl.SetTextColor then
                    lbl:SetTextColor(1, 0.82, 0)
                end
            end
        end
        applyInputEnabled()

        useEqCB:SetScript("OnClick", function(self_)
            DB.qualityRules[qualityIdx].useEquippedILvl = self_:GetChecked() and true or false
            applyInputEnabled()
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        cb._applyInputEnabled = applyInputEnabled

        local function commit()
            local v = tonumber(input:GetText() or "0") or 0
            if v < 0 then
                v = 0
            end
            if v > 300 then
                v = 300
            end
            DB.qualityRules[qualityIdx].maxILvl = v
            input:SetText(tostring(v))
        end
        input:SetScript("OnEnterPressed", function()
            input:ClearFocus()
        end)
        input:SetScript("OnEscapePressed", function()
            input:SetText(tostring(DB.qualityRules[qualityIdx].maxILvl or 0))
            input:ClearFocus()
        end)
        input:SetScript("OnEditFocusLost", commit)

        -- Bind-type filter dropdown on a second line below the checkbox.
        -- Indented to align with the checkbox label so the rule reads as
        -- "[x] Blue (Rare) max iLvl: [200] / Bind: [Any bind type]".
        local bindLbl = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        bindLbl:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 26, -4)
        bindLbl:SetText("Bind:")

        local bindDD = CreateFrame(
            "Frame",
            "EbonClearanceQualityRow" .. qualityIdx .. "BindDD",
            content,
            "UIDropDownMenuTemplate"
        )
        bindDD:SetPoint("LEFT", bindLbl, "RIGHT", -8, -2)

        local function BindFilterInit(_frame, _level)
            for _, entry in ipairs(EC_BIND_FILTER_OPTIONS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = entry.text
                info.value = entry.value
                info.checked = (DB.qualityRules[qualityIdx].bindFilter == entry.value)
                info.func = function()
                    DB.qualityRules[qualityIdx].bindFilter = entry.value
                    UIDropDownMenu_SetText(bindDD, entry.text)
                    PlaySound("igMainMenuOptionCheckBoxOn")
                end
                UIDropDownMenu_AddButton(info, _level)
            end
        end
        UIDropDownMenu_SetWidth(bindDD, 120)
        UIDropDownMenu_SetText(bindDD, EC_BindFilterText(DB.qualityRules[qualityIdx].bindFilter))
        UIDropDownMenu_Initialize(bindDD, BindFilterInit)

        return cb, input, bindDD, useEqCB
    end

    -- All four rarity rows anchor their checkbox to the threshold description,
    -- not to the previous row's dropdown. The dropdown's left edge is offset
    -- by the UIDropDownMenuTemplate's internal padding (~16 px), and chaining
    -- row N to row N-1's dropdown made each successive row staircase right.
    -- A single shared anchor with explicit -y offsets keeps every checkbox,
    -- bind label, and dropdown on the same X column.
    --
    -- Per-row vertical budget: ~28 px (checkbox + label) + ~6 px gap + ~30 px
    -- dropdown frame + ~10 px gap to next row = ~74 px. -78 leaves a small
    -- breathing margin between rows without overlapping the dropdown's
    -- bottom shadow.
    local row1CB, row1Input, row1DD, row1UseEq = MakeQualityRow(thresholdDesc, 1, EC_WHITELIST_QUALITIES[1].text, -10)
    local row2CB, row2Input, row2DD, row2UseEq = MakeQualityRow(thresholdDesc, 2, EC_WHITELIST_QUALITIES[2].text, -88)
    local row3CB, row3Input, row3DD, row3UseEq = MakeQualityRow(thresholdDesc, 3, EC_WHITELIST_QUALITIES[3].text, -166)
    local row4CB, row4Input, row4DD, row4UseEq = MakeQualityRow(thresholdDesc, 4, EC_WHITELIST_QUALITIES[4].text, -244)

    self.qualityRow1CB, self.qualityRow1Input, self.qualityRow1DD, self.qualityRow1UseEq =
        row1CB, row1Input, row1DD, row1UseEq
    self.qualityRow2CB, self.qualityRow2Input, self.qualityRow2DD, self.qualityRow2UseEq =
        row2CB, row2Input, row2DD, row2UseEq
    self.qualityRow3CB, self.qualityRow3Input, self.qualityRow3DD, self.qualityRow3UseEq =
        row3CB, row3Input, row3DD, row3UseEq
    self.qualityRow4CB, self.qualityRow4Input, self.qualityRow4DD, self.qualityRow4UseEq =
        row4CB, row4Input, row4DD, row4UseEq

    -- Stash the BindFilterText helper on the panel so the inited refresh
    -- block can update each dropdown's display text without re-defining
    -- the option set.
    self._BindFilterText = EC_BindFilterText

    -- Size the scroll content to fit the bottom-most widget so the scrollbar
    -- range matches actual content. Purple Epic's bind dropdown is now the
    -- lowest widget on the panel.
    EC_FitScrollContent(content, row4DD)
end)

-- Shared "Add from bags" scan row used by both whitelist panels.
-- setTableName resolves to the underlying list via EC_GetListTable, so the same
-- helper drives the per-character whitelist and the account whitelist.
-- Build the "Add from bags: [White] [Green] [Blue]" scan row. Returns a
-- container Frame whose BOTTOMLEFT is the natural anchor for the next
-- downstream widget (typically the list UI). Callers pass an anchorFrame
-- (usually the panel description) so the row cascades when the description
-- wraps to more lines on narrow Interface Options containers, instead of
-- using a brittle hardcoded y-offset.
local function EC_AddScanByQualityRow(parent, anchorFrame, setTableName, listLabel, refreshFn, xOff, yOff)
    local function ScanBagsForQuality(quality)
        local t = EC_GetListTable(setTableName)
        if not t then
            return 0, 0
        end
        local added, skipped = 0, 0
        -- v2.13.4: route adds through EC_AddItemToList(quiet=true) so
        -- this bulk path picks up the canonical conflict guard, dedupe,
        -- and any future origin-tag support. The pre-check on `t[itemID]`
        -- preserves the existing semantic where already-present items
        -- silently do not increment either counter; only cross-list
        -- conflicts count as skipped.
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID then
                    local _, _, q, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
                    if q == quality and sellPrice and sellPrice > 0 and not t[itemID] then
                        if EC_AddItemToList(setTableName, itemID, listLabel, true) then
                            added = added + 1
                        else
                            skipped = skipped + 1
                        end
                    end
                end
            end
        end
        return added, skipped
    end

    -- Wrap the row in a container Frame so callers can anchor the next widget
    -- to rowFrame:BOTTOMLEFT cleanly without having to know about button
    -- heights vs the (shorter) text label.
    local rowFrame = CreateFrame("Frame", nil, parent)
    rowFrame:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", xOff or 0, yOff or -10)
    rowFrame:SetSize(EC_PANEL_WIDTH, 22)

    local scanLabel = rowFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    scanLabel:SetPoint("LEFT", rowFrame, "LEFT", 0, 0)
    scanLabel:SetText("Add from bags:")

    local function MakeBtn(prevAnchor, leftPad, label, qualityNum, colorWord)
        local b = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
        b:SetSize(55, 20)
        b:SetPoint("LEFT", prevAnchor, "RIGHT", leftPad, 0)
        b:SetText(label)
        b:SetScript("OnClick", function()
            local added, skipped = ScanBagsForQuality(qualityNum)
            PrintNicef("Scanned bags: added |cffffff00%d|r %s items to %s.", added, colorWord, listLabel)
            if skipped and skipped > 0 then
                PrintNicef("Skipped |cffffff00%d|r already on another list.", skipped)
            end
            if refreshFn then
                refreshFn()
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        return b
    end

    local btnWhite = MakeBtn(scanLabel, 8, "|cffffffffWhite|r", 1, "white")
    local btnGreen = MakeBtn(btnWhite, 4, "|cff1eff00Green|r", 2, "green")
    MakeBtn(btnGreen, 4, "|cff0070ddBlue|r", 3, "blue")

    return rowFrame
end

local WhitelistPanel = CreateFrame("Frame", "EbonClearanceOptionsWhitelist", InterfaceOptionsFramePanelContainer)
WhitelistPanel.name = "Whitelist - Character"
WhitelistPanel.parent = "EbonClearance"

WhitelistPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Whitelist Settings", -16)

    -- Panel-specific description only. Cross-cutting info (grey junk
    -- auto-sell, quality threshold) lives on the Main panel to avoid
    -- repeating the same explanation on every list page.
    local descLabel = MakeLabel(
        self,
        "Specific items to always auto-sell on this character, regardless of rarity rules. Use the |cffb6ffb6Add from bags|r buttons below to bulk-add by colour, or shift-click / type IDs to add manually. |cffaaaaaaItems are saved and restored by profiles. For items you want sold on every alt, use |cffb6ffb6Whitelist - Account|r |cffaaaaaainstead.|r",
        16,
        -44
    )

    -- Cascade-anchor the scan row to the description's BOTTOMLEFT so it stays
    -- below the description regardless of how many lines it wraps to. Then
    -- the list UI cascades below the scan row and fills the remaining panel
    -- height via a BOTTOMRIGHT anchor (fixed SetHeight previously caused the
    -- bottom row to clip past the panel safe area at narrow widths).
    local scanRow = EC_AddScanByQualityRow(self, descLabel, "whitelist", "your character whitelist", function()
        if self.listUI then
            self.listUI:Refresh()
        end
    end, 0, -10)

    self.listUI = CreateListUI(self, "Manual Add (Shift-click item or type ID)", "whitelist", 16, -118)
    self.listUI:ClearAllPoints()
    self.listUI:SetPoint("TOPLEFT", scanRow, "BOTTOMLEFT", 0, -16)
    self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
    self.listUI:Refresh()
end)

-- ============================================================
-- Whitelist Profiles Panel
-- ============================================================
local ProfilesPanel = CreateFrame("Frame", "EbonClearanceOptionsProfiles", InterfaceOptionsFramePanelContainer)
ProfilesPanel.name = "Profiles"
ProfilesPanel.parent = "EbonClearance"

ProfilesPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.RefreshProfileList then
            self:RefreshProfileList()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Profiles", -16)
    local descLabel = MakeLabel(
        self,
        "Profiles save and restore your |cffb6ffb6Whitelist - Character|r and |cffb6ffb6Blacklist - Keep|r as a named pair. Switching profiles overwrites the live character lists with the saved snapshot. Handy for swapping between farming spots.",
        16,
        -44
    )
    -- Cascade-anchored to descLabel so the layout adapts to whatever number of
    -- lines the description wraps to (fixed-y caused overlap on narrower panels).
    local clarifyLabel = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    clarifyLabel:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -8)
    EC_compCache.setPanelWidth(clarifyLabel, 32)
    clarifyLabel:SetJustifyH("LEFT")
    clarifyLabel:SetJustifyV("TOP")
    if clarifyLabel.SetWordWrap then
        clarifyLabel:SetWordWrap(true)
    end
    clarifyLabel:SetText(
        "|cffaaaaaaProfiles do NOT touch the |cffb6ffb6Whitelist - Account|r|cffaaaaaa list (which is shared across every alt and never replaced). The |cffb6ffb6Default|r|cffaaaaaa profile is permanently empty - give your profile a real name before saving.|r"
    )

    -- Active profile indicator
    local activeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    activeLabel:SetPoint("TOPLEFT", clarifyLabel, "BOTTOMLEFT", 0, -16)
    EC_compCache.setPanelWidth(activeLabel, 16)
    activeLabel:SetJustifyH("LEFT")
    self.activeLabel = activeLabel

    -- Save row: input + Save button (relative to activeLabel so it follows
    -- whatever the wrap above ends up at).
    local saveLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    saveLabel:SetPoint("TOPLEFT", activeLabel, "BOTTOMLEFT", 0, -10)
    saveLabel:SetText("Profile name:")

    local saveInput = CreateFrame("EditBox", "EbonClearanceProfileSaveInput", self, "InputBoxTemplate")
    saveInput:SetAutoFocus(false)
    saveInput:SetSize(180, 20)
    saveInput:SetPoint("LEFT", saveLabel, "RIGHT", 8, 0)
    saveInput:SetMaxLetters(30)
    saveInput:SetText(DB.activeProfileName or "Default")
    StyleInputBox(saveInput)

    local saveBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    saveBtn:SetSize(80, 22)
    saveBtn:SetPoint("LEFT", saveInput, "RIGHT", 8, 0)
    saveBtn:SetText("Save")

    -- Status text (relative to the save row above it).
    local statusFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statusFS:SetPoint("TOPLEFT", saveLabel, "BOTTOMLEFT", 0, -10)
    EC_compCache.setPanelWidth(statusFS, 16)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("")
    self.statusFS = statusFS

    -- Profile list scroll area
    local listLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    listLabel:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -8)
    listLabel:SetText("Saved Profiles")

    local scroll = CreateFrame("ScrollFrame", "EbonClearanceProfileListScroll", self, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -4)
    scroll:SetSize(EC_PANEL_WIDTH - 42, 160)
    -- v2.11.0: register width so the scroll tracks Interface Options
    -- frame resizes. SetSize set the height to 160 here; registry's
    -- SetWidth-only refresh leaves height alone.
    EC_compCache.registerWidth(scroll, 42)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(EC_PANEL_WIDTH - 42, 1)
    EC_compCache.registerWidth(content, 42)
    scroll:SetScrollChild(content)
    -- Auto-hide the scroll bar (arrows + thumb) when content fits the visible
    -- area. Wired once here; OnScrollRangeChanged fires on every Refresh that
    -- changes content height, so visibility tracks the list automatically.
    EC_HookScrollbarAutoHide(scroll)

    local rowPool = {}
    local activeRows = 0

    local function GetRow(index)
        if rowPool[index] then
            return rowPool[index]
        end
        local row = CreateFrame("Frame", nil, content)
        row:SetHeight(22)

        local delBtn = CreateFrame("Button", "EbonClearanceProfileDel_" .. index, content, "UIPanelButtonTemplate")
        delBtn:SetSize(58, 18)
        delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        delBtn:SetText("Delete")

        local clearBtn = CreateFrame("Button", "EbonClearanceProfileClear_" .. index, content, "UIPanelButtonTemplate")
        clearBtn:SetSize(52, 18)
        clearBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
        clearBtn:SetText("Clear")

        local loadBtn = CreateFrame("Button", "EbonClearanceProfileLoad_" .. index, content, "UIPanelButtonTemplate")
        loadBtn:SetSize(52, 18)
        loadBtn:SetPoint("RIGHT", clearBtn, "LEFT", -4, 0)
        loadBtn:SetText("Load")

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 2, 0)
        text:SetPoint("RIGHT", loadBtn, "LEFT", -4, 0)
        text:SetJustifyH("LEFT")

        row.text = text
        row.loadBtn = loadBtn
        row.clearBtn = clearBtn
        row.delBtn = delBtn
        rowPool[index] = row
        return row
    end

    local function HideAllRows()
        for i = 1, activeRows do
            if rowPool[i] then
                rowPool[i]:Hide()
                rowPool[i].loadBtn:Hide()
                rowPool[i].clearBtn:Hide()
                rowPool[i].delBtn:Hide()
            end
        end
        activeRows = 0
    end

    -- Rename row
    local renameLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    renameLabel:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -12)
    renameLabel:SetText("Rename active profile:")

    local renameInput = CreateFrame("EditBox", "EbonClearanceProfileRenameInput", self, "InputBoxTemplate")
    renameInput:SetAutoFocus(false)
    renameInput:SetSize(150, 20)
    renameInput:SetPoint("LEFT", renameLabel, "RIGHT", 8, 0)
    renameInput:SetMaxLetters(30)
    renameInput:SetText("")
    StyleInputBox(renameInput)

    local renameBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    renameBtn:SetSize(70, 22)
    renameBtn:SetPoint("LEFT", renameInput, "RIGHT", 8, 0)
    renameBtn:SetText("Rename")

    -- Use field-assignment form rather than colon-method definition so the
    -- function closes over the outer `self` (the panel) rather than receiving
    -- a fresh `self` parameter that would shadow it. Body still references
    -- self.activeLabel etc via that captured upvalue.
    self.RefreshProfileList = function()
        HideAllRows()

        -- Update active indicator
        local activeName = DB.activeProfileName or "Default"
        activeLabel:SetText("Active profile: |cff00ff00" .. activeName .. "|r")
        saveInput:SetText(activeName)
        renameInput:SetText(activeName)

        -- Collect and sort profile names
        local names = {}
        for name in pairs(DB.whitelistProfiles) do
            if type(name) == "string" then
                names[#names + 1] = name
            end
        end
        table.sort(names, function(a, b)
            return a:lower() < b:lower()
        end)

        local shown = 0
        local rowY = -4
        for i = 1, #names do
            local pName = names[i]
            shown = shown + 1
            local row = GetRow(shown)
            row:ClearAllPoints()
            -- v2.11.0: anchor TOPLEFT + TOPRIGHT so the row stretches.
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, rowY)
            row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, rowY)

            local isActive = (pName == DB.activeProfileName)
            local wlCount = EC_CountItems(DB.whitelistProfiles[pName])
            local blCount = DB.blacklistProfiles[pName] and EC_CountItems(DB.blacklistProfiles[pName]) or 0
            -- Use compact "wl/bl" labels: row text shares horizontal space
            -- with up to three buttons (Load/Clear/Delete), so longer phrasing
            -- gets truncated at narrow Interface Options widths.
            local label = isActive
                    and string.format("|cff00ff00%s|r  |cff888888(%d wl, %d bl, active)|r", pName, wlCount, blCount)
                or string.format("|cffffff00%s|r  |cff888888(%d wl, %d bl)|r", pName, wlCount, blCount)
            row.text:SetText(label)

            row.loadBtn:SetScript("OnClick", function()
                local ok, msg = EC_LoadProfile(pName)
                statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
                if ok then
                    PrintNice(msg)
                    PlaySound("igMainMenuOptionCheckBoxOn")
                end
                self:RefreshProfileList()
            end)

            row.delBtn:SetScript("OnClick", function()
                local dialog = StaticPopup_Show("EC_CONFIRM_DELETE_PROFILE", pName)
                if dialog then
                    dialog.data = function()
                        local ok, msg = EC_DeleteProfile(pName)
                        statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
                        if ok then
                            PrintNice(msg)
                            PlaySound("igMainMenuOptionCheckBoxOn")
                        end
                        self:RefreshProfileList()
                    end
                end
            end)

            row.clearBtn:SetScript("OnClick", function()
                local dialog = StaticPopup_Show("EC_CONFIRM_CLEAR_PROFILE", pName)
                if dialog then
                    dialog.data = function()
                        if DB.whitelistProfiles[pName] then
                            wipe(DB.whitelistProfiles[pName])
                            if pName == DB.activeProfileName then
                                wipe(DB.whitelist)
                                local wp = _G["EbonClearanceOptionsWhitelist"]
                                if wp and wp.listUI then
                                    wp.listUI:Refresh()
                                end
                            end
                            statusFS:SetText('|cff00ff00Cleared profile "|cffffff00' .. pName .. '|r|cff00ff00".|r')
                            PrintNicef('Cleared profile "|cffffff00%s|r".', pName)
                            PlaySound("igMainMenuOptionCheckBoxOn")
                        end
                        self:RefreshProfileList()
                    end
                end
            end)

            local isDefault = (pName == "Default")
            row:Show()
            row.loadBtn:Show()
            if isDefault then
                row.clearBtn:Hide()
                row.delBtn:Hide()
            else
                row.clearBtn:Show()
                row.delBtn:Show()
            end
            rowY = rowY - 22
        end

        activeRows = shown
        content:SetHeight(math.max(1, (shown * 22) + 8))
        -- Scroll-bar visibility handled by the OnScrollRangeChanged hook.
    end

    saveBtn:SetScript("OnClick", function()
        local name = saveInput:GetText()
        local ok, msg = EC_SaveProfile(name)
        statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
        if ok then
            PrintNice(msg)
            PlaySound("igMainMenuOptionCheckBoxOn")
            self:RefreshProfileList()
        else
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
    end)

    saveInput:SetScript("OnEnterPressed", function()
        saveBtn:Click()
        saveInput:ClearFocus()
    end)

    renameBtn:SetScript("OnClick", function()
        local newName = renameInput:GetText()
        local ok, msg = EC_RenameProfile(DB.activeProfileName, newName)
        statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
        if ok then
            PrintNice(msg)
            PlaySound("igMainMenuOptionCheckBoxOn")
            self:RefreshProfileList()
        else
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
    end)

    renameInput:SetScript("OnEnterPressed", function()
        renameBtn:Click()
        renameInput:ClearFocus()
    end)

    self:RefreshProfileList()
end)

-- ============================================================
-- Whitelist Import / Export Panel
-- ============================================================
local ImportExportPanel = CreateFrame("Frame", "EbonClearanceOptionsImportExport", InterfaceOptionsFramePanelContainer)
ImportExportPanel.name = "Import/Export"
ImportExportPanel.parent = "EbonClearance"

local EC_EXPORT_PREFIX = "EC:"

-- Resolve the export/import target table. scope is "character" (default) or
-- "account"; the latter touches the account-wide whitelist (ADB).
local function EC_GetWhitelistForScope(scope)
    if scope == "account" then
        return ADB and ADB.whitelist
    end
    return DB and DB.whitelist
end

local function EC_ExportWhitelist(listName, scope)
    local source = EC_GetWhitelistForScope(scope)
    if not source then
        return ""
    end
    local ids = {}
    for k, v in pairs(source) do
        if type(k) == "number" and (v == true or v == 1) then
            ids[#ids + 1] = k
        end
    end
    table.sort(ids)
    local name = (listName and listName ~= "") and listName or "Unnamed"
    name = name:gsub("[:|]", "_")
    local payload = EC_EXPORT_PREFIX .. name .. ":" .. table.concat(ids, ",")
    -- Fingerprint suffix flags this export as EbonClearance-produced. See
    -- EC_FINGERPRINT_SALT and EC_Fingerprint near the top of the file.
    return payload .. ";fp=" .. EC_Fingerprint(payload)
end

local function EC_ImportWhitelist(str, mode, scope)
    if type(str) ~= "string" or str == "" then
        return false, "Empty string."
    end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    -- Strip a trailing ";fp=<hex>" fingerprint suffix before format
    -- validation so pre-fingerprint and hand-edited strings still parse.
    -- The fingerprint marks our exports going OUT; imports tolerate both
    -- fingerprinted and unfingerprinted strings without warning.
    str = (str:gsub(";fp=[0-9a-f]+%s*$", ""))
    if str:sub(1, #EC_EXPORT_PREFIX) ~= EC_EXPORT_PREFIX then
        return false, "Invalid format. String must start with EC:"
    end
    local body = str:sub(#EC_EXPORT_PREFIX + 1)
    local name, idStr = body:match("^([^:]*):(.+)$")
    if not idStr or idStr == "" then
        return false, "No item IDs found after the list name."
    end
    local ids = {}
    for token in idStr:gmatch("([^,]+)") do
        local n = tonumber(token:match("^%s*(%d+)%s*$"))
        if n and n > 0 then
            ids[#ids + 1] = n
        end
    end
    if #ids == 0 then
        return false, "No valid item IDs found."
    end
    local target = EC_GetWhitelistForScope(scope)
    if not target then
        return false, "Target list unavailable."
    end
    if mode == "replace" then
        wipe(target)
    end
    local added = 0
    for i = 1, #ids do
        if not target[ids[i]] then
            added = added + 1
        end
        target[ids[i]] = true
    end
    local scopeLabel = (scope == "account") and "account whitelist" or "character whitelist"
    return true,
        string.format(
            'Imported |cffffff00%d|r items from "%s" into the %s (%d new).',
            #ids,
            name or "Unnamed",
            scopeLabel,
            added
        )
end

ImportExportPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        return
    end
    self.inited = true

    MakeHeader(self, "Import / Export", -16)

    -- === EXPORT SECTION ===
    -- Each section owns its own scope radio so it's obvious which list a
    -- click reads from (Source list) versus writes to (Target list).
    MakeLabel(
        self,
        "Export a whitelist to a string you can share. Pick which list to read from, then give the export a name.",
        16,
        -44
    )

    local exportScope = "character"

    local exportScopeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    exportScopeLabel:SetPoint("TOPLEFT", 16, -72)
    exportScopeLabel:SetText("Source list:")

    local exportCharCB = CreateFrame("CheckButton", "EbonClearanceExportSourceCharCB", self, "UIRadioButtonTemplate")
    exportCharCB:SetPoint("LEFT", exportScopeLabel, "RIGHT", 8, 0)
    exportCharCB:SetChecked(true)
    local exportCharLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    exportCharLbl:SetPoint("LEFT", exportCharCB, "RIGHT", 2, 1)
    exportCharLbl:SetText("Character")

    local exportAcctCB = CreateFrame("CheckButton", "EbonClearanceExportSourceAcctCB", self, "UIRadioButtonTemplate")
    exportAcctCB:SetPoint("LEFT", exportCharLbl, "RIGHT", 12, -1)
    exportAcctCB:SetChecked(false)
    local exportAcctLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    exportAcctLbl:SetPoint("LEFT", exportAcctCB, "RIGHT", 2, 1)
    exportAcctLbl:SetText("Account")

    exportCharCB:SetScript("OnClick", function()
        exportScope = "character"
        exportCharCB:SetChecked(true)
        exportAcctCB:SetChecked(false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    exportAcctCB:SetScript("OnClick", function()
        exportScope = "account"
        exportAcctCB:SetChecked(true)
        exportCharCB:SetChecked(false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    local exportNameLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    exportNameLabel:SetPoint("TOPLEFT", 16, -100)
    exportNameLabel:SetText("List name:")

    local exportNameBox = CreateFrame("EditBox", "EbonClearanceExportNameBox", self, "InputBoxTemplate")
    exportNameBox:SetAutoFocus(false)
    exportNameBox:SetSize(200, 20)
    exportNameBox:SetPoint("LEFT", exportNameLabel, "RIGHT", 8, 0)
    exportNameBox:SetMaxLetters(40)
    exportNameBox:SetText("My Whitelist")
    StyleInputBox(exportNameBox)

    local exportBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    exportBtn:SetSize(80, 22)
    exportBtn:SetPoint("LEFT", exportNameBox, "RIGHT", 8, 0)
    exportBtn:SetText("Export")

    local exportScroll = CreateFrame("ScrollFrame", "EbonClearanceExportScroll", self, "UIPanelScrollFrameTemplate")
    exportScroll:SetPoint("TOPLEFT", 16, -128)
    exportScroll:SetSize(EC_PANEL_WIDTH - 36, 50)
    -- v2.11.0: track Interface Options frame resizes (registry refreshes
    -- width only; height stays at the value set above).
    EC_compCache.registerWidth(exportScroll, 36)

    local exportBox = CreateFrame("EditBox", "EbonClearanceExportBox", exportScroll)
    exportBox:SetAutoFocus(false)
    exportBox:SetMultiLine(true)
    exportBox:SetFontObject("GameFontHighlightSmall")
    -- Size the EditBox explicitly. Without SetHeight, an empty multiline
    -- EditBox has zero clickable area, so users can't focus it to paste.
    exportBox:SetSize(560, 50)
    exportBox:SetText("")
    exportBox:SetScript("OnEscapePressed", function(s)
        s:ClearFocus()
    end)
    exportScroll:SetScrollChild(exportBox)

    exportBtn:SetScript("OnClick", function()
        local str = EC_ExportWhitelist(exportNameBox:GetText(), exportScope)
        exportBox:SetText(str)
        exportBox:HighlightText()
        exportBox:SetFocus()
        PlaySound("igMainMenuOptionCheckBoxOn")
        local source = EC_GetWhitelistForScope(exportScope) or {}
        local count = 0
        for _, v in pairs(source) do
            if v == true or v == 1 then
                count = count + 1
            end
        end
        local scopeName = (exportScope == "account") and "account" or "character"
        PrintNicef("Exported |cffffff00%d|r %s whitelist items. Copy the text above.", count, scopeName)
    end)

    -- === IMPORT SECTION ===
    MakeLabel(self, "Paste a whitelist string and pick which list it imports into.", 16, -198)

    local importScope = "character"

    local importScopeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    importScopeLabel:SetPoint("TOPLEFT", 16, -226)
    importScopeLabel:SetText("Target list:")

    local importCharCB = CreateFrame("CheckButton", "EbonClearanceImportTargetCharCB", self, "UIRadioButtonTemplate")
    importCharCB:SetPoint("LEFT", importScopeLabel, "RIGHT", 8, 0)
    importCharCB:SetChecked(true)
    local importCharLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    importCharLbl:SetPoint("LEFT", importCharCB, "RIGHT", 2, 1)
    importCharLbl:SetText("Character")

    local importAcctCB = CreateFrame("CheckButton", "EbonClearanceImportTargetAcctCB", self, "UIRadioButtonTemplate")
    importAcctCB:SetPoint("LEFT", importCharLbl, "RIGHT", 12, -1)
    importAcctCB:SetChecked(false)
    local importAcctLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    importAcctLbl:SetPoint("LEFT", importAcctCB, "RIGHT", 2, 1)
    importAcctLbl:SetText("Account")

    importCharCB:SetScript("OnClick", function()
        importScope = "character"
        importCharCB:SetChecked(true)
        importAcctCB:SetChecked(false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    importAcctCB:SetScript("OnClick", function()
        importScope = "account"
        importAcctCB:SetChecked(true)
        importCharCB:SetChecked(false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    local importScroll = CreateFrame("ScrollFrame", "EbonClearanceImportScroll", self, "UIPanelScrollFrameTemplate")
    importScroll:SetPoint("TOPLEFT", 16, -254)
    importScroll:SetSize(EC_PANEL_WIDTH - 36, 50)
    -- v2.11.0: track Interface Options frame resizes (registry refreshes
    -- width only; height stays at the value set above).
    EC_compCache.registerWidth(importScroll, 36)

    local importBox = CreateFrame("EditBox", "EbonClearanceImportBox", importScroll)
    importBox:SetAutoFocus(false)
    importBox:SetMultiLine(true)
    importBox:SetFontObject("GameFontHighlightSmall")
    -- Explicit size required so an empty EditBox still has a clickable area
    -- for paste. Without SetHeight, multiline EditBoxes collapse to zero.
    importBox:SetSize(560, 50)
    importBox:SetText("")
    importBox:SetScript("OnEscapePressed", function(s)
        s:ClearFocus()
    end)
    importScroll:SetScrollChild(importBox)

    local importMergeBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    importMergeBtn:SetSize(120, 22)
    importMergeBtn:SetPoint("TOPLEFT", 16, -312)
    importMergeBtn:SetText("Import (Merge)")

    local importReplaceBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    importReplaceBtn:SetSize(120, 22)
    importReplaceBtn:SetPoint("LEFT", importMergeBtn, "RIGHT", 8, 0)
    importReplaceBtn:SetText("Import (Replace)")

    local statusFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statusFS:SetPoint("TOPLEFT", 16, -340)
    EC_compCache.setPanelWidth(statusFS, 16)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("")

    local function runImport(mode)
        local ok, msg = EC_ImportWhitelist(importBox:GetText(), mode, importScope)
        statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
        if ok then
            PlaySound("igMainMenuOptionCheckBoxOn")
            PrintNice(msg)
            local panelName = (importScope == "account") and "EbonClearanceOptionsAccountWhitelist"
                or "EbonClearanceOptionsWhitelist"
            local wp = _G[panelName]
            if wp and wp.listUI then
                wp.listUI:Refresh()
            end
        else
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
    end
    importMergeBtn:SetScript("OnClick", function()
        runImport("merge")
    end)
    importReplaceBtn:SetScript("OnClick", function()
        runImport("replace")
    end)

    -- Grey explanation is anchored to the status line so it naturally flows
    -- below, even when the status wraps to two lines (e.g. long error).
    local importNote = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    importNote:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -8)
    EC_compCache.setPanelWidth(importNote, 16)
    importNote:SetJustifyH("LEFT")
    importNote:SetJustifyV("TOP")
    if importNote.SetWordWrap then
        importNote:SetWordWrap(true)
    end
    importNote:SetText(
        "|cffaaaaaa'Merge' adds imported items to the target list. "
            .. "'Replace' clears the target list first, then adds the imported items.|r"
    )
end)

local DeletePanel = CreateFrame("Frame", "EbonClearanceOptionsDeletion", InterfaceOptionsFramePanelContainer)
DeletePanel.name = "Deletion List"
DeletePanel.parent = "EbonClearance"

DeletePanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Deletion Settings", -16)
    local delDesc = MakeLabel(self, "If enabled, items on this list will be deleted from your bags.", 16, -44)
    local delHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    delHint:SetPoint("TOPLEFT", delDesc, "BOTTOMLEFT", 0, -4)
    EC_compCache.setPanelWidth(delHint, 16)
    delHint:SetJustifyH("LEFT")
    delHint:SetJustifyV("TOP")
    if delHint.SetWordWrap then
        delHint:SetWordWrap(true)
    end
    delHint:SetText(
        "Add Items by Shift-Clicking an item, drag & drop into the text field below, or type the ItemID and press Add."
    )

    local delCB = CreateFrame("CheckButton", "EbonClearanceEnableDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
    delCB:SetPoint("TOPLEFT", delHint, "BOTTOMLEFT", 0, -6)
    delCB:SetChecked(DB.enableDeletion)
    local dt = _G[delCB:GetName() .. "Text"]
    if dt then
        dt:SetText("Enable Item Deletion")
        dt:SetWidth(420)
        dt:SetJustifyH("LEFT")
    end
    delCB:SetScript("OnClick", function()
        DB.enableDeletion = delCB:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    self.listUI = CreateListUI(self, "Deletion List", "deleteList", 16, -130)
    -- v2.11.0: anchor BOTTOMRIGHT so the list stretches with the panel
    -- on Interface Options frame resize - mirrors the Whitelist /
    -- Blacklist / Account-Whitelist setups. Without this the list box
    -- stays at its build-time width and the search row + add-matching
    -- row buttons drift outside the panel boundary on shrink.
    self.listUI:ClearAllPoints()
    self.listUI:SetPoint("TOPLEFT", 16, -130)
    self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
    self.listUI:Refresh()
end)

local ScavengerPanel = CreateFrame("Frame", "EbonClearanceOptionsScavenger", InterfaceOptionsFramePanelContainer)

ScavengerPanel.name = "Scavenger Settings"
ScavengerPanel.parent = "EbonClearance"

ScavengerPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.sumCB then
            self.sumCB:SetChecked(DB.summonGreedy)
        end
        if self.delaySlider then
            self.delaySlider:SetValue(DB.summonDelay or 1.6)
        end
        if self.muteCB then
            self.muteCB:SetChecked(DB.muteGreedy)
        end
        if self.chatCB then
            self.chatCB:SetChecked(DB.hideGreedyChat)
        end
        if self.bubCB then
            self.bubCB:SetChecked(DB.hideGreedyBubbles)
        end
        if self.cycleCB then
            self.cycleCB:SetChecked(DB.autoLootCycle)
        end
        if self.threshSlider then
            self.threshSlider:SetValue(DB.bagFullThreshold or 2)
        end
        if self.autoOpenCB then
            self.autoOpenCB:SetChecked(DB.autoOpenContainers)
        end
        return
    end
    self.inited = true

    -- Scroll-wrap the panel: at narrow Interface Options widths the bottom
    -- of this panel (Tip line) overflows the safe area. Wrapping in a scroll
    -- frame lets all widgets remain reachable; the scrollbar auto-hides on
    -- wider containers where everything fits.
    local content = EC_WrapPanelInScrollFrame(self)

    MakeHeader(content, "Scavenger Settings", -16)
    MakeLabel(
        content,
        "Controls summoning and muting of |cffff7f7fGreedy Scavenger|r. The auto-loot cycle will continuously loot and sell while your bags fill up.",
        16,
        -44
    )

    local sumCB =
        CreateFrame("CheckButton", "EbonClearanceSummonGreedyCB", content, "InterfaceOptionsCheckButtonTemplate")
    sumCB:SetPoint("TOPLEFT", 16, -96)
    sumCB:SetChecked(DB.summonGreedy)
    local st = _G[sumCB:GetName() .. "Text"]
    if st then
        st:SetText("Summon |cffff7f7fGreedy Scavenger|r after Vendoring")
        st:SetWidth(420)
        st:SetJustifyH("LEFT")
    end
    sumCB:SetScript("OnClick", function()
        DB.summonGreedy = sumCB:GetChecked() and true or false
        if not DB.summonGreedy and DB.autoLootCycle then
            DB.autoLootCycle = false
            if self.cycleCB then
                self.cycleCB:SetChecked(false)
            end
        end
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.sumCB = sumCB

    local combatOnlyCB = AddCheckbox(
        content,
        "EbonClearanceSummonOnlyOutOfCombatCB",
        sumCB,
        "Only summon |cffff7f7fGreedy Scavenger|r when out of combat",
        function()
            return DB.summonOnlyOutOfCombat
        end,
        function(v)
            DB.summonOnlyOutOfCombat = v
        end,
        -8
    )
    self.combatOnlyCB = combatOnlyCB

    local chatCB = AddCheckbox(
        content,
        "EbonClearanceHideGreedyChatCB",
        combatOnlyCB,
        "Hide |cffff7f7fGreedy Scavenger|r's chat messages",
        function()
            return DB.hideGreedyChat
        end,
        function(v)
            DB.hideGreedyChat = v
            ApplyGreedyChatFilter()
        end,
        -8
    )
    self.chatCB = chatCB

    local bubCB = AddCheckbox(
        content,
        "EbonClearanceHideGreedyBubblesCB",
        chatCB,
        "Hide |cffff7f7fGreedy Scavenger|r's chat bubbles",
        function()
            return DB.hideGreedyBubbles
        end,
        function(v)
            DB.hideGreedyBubbles = v
        end,
        -8
    )
    self.bubCB = bubCB

    local delaySlider = AddSlider(
        content,
        "EbonClearanceSummonDelaySlider",
        bubCB,
        "Summon delay",
        0.0,
        3.0,
        0.1,
        function()
            return DB.summonDelay or 1.6
        end,
        function(v)
            DB.summonDelay = v
        end,
        -16,
        "%.1fs"
    )
    self.delaySlider = delaySlider
    delaySlider:SetWidth(200)

    local cycleCB = AddCheckbox(
        content,
        "EbonClearanceAutoLootCycleCB",
        delaySlider,
        "Enable auto-loot cycle (loot, sell, repeat)",
        function()
            return DB.autoLootCycle
        end,
        function(v)
            DB.autoLootCycle = v
            if v then
                DB.summonGreedy = true
                if self.sumCB then
                    self.sumCB:SetChecked(true)
                end
            end
        end,
        -16
    )
    self.cycleCB = cycleCB

    local cycleNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    cycleNote:SetPoint("TOPLEFT", cycleCB, "BOTTOMLEFT", 26, -2)
    EC_compCache.setPanelWidth(cycleNote, 60)
    cycleNote:SetJustifyH("LEFT")
    cycleNote:SetText(
        "|cff888888At threshold: Greedy is dismissed and the Goblin Merchant is summoned. Right-click it to sell; Greedy re-summons automatically.|r"
    )

    local threshSlider = AddSlider(
        content,
        "EbonClearanceBagThresholdSlider",
        cycleNote,
        "Bag slots remaining before selling",
        0,
        10,
        1,
        function()
            return DB.bagFullThreshold or 2
        end,
        function(v)
            DB.bagFullThreshold = v
        end,
        -16,
        "%d"
    )
    self.threshSlider = threshSlider
    threshSlider:SetWidth(200)

    local autoOpenCB = AddCheckbox(
        content,
        "EbonClearanceAutoOpenCB",
        threshSlider,
        "Auto-open lootable containers from your bags",
        function()
            return DB.autoOpenContainers
        end,
        function(v)
            DB.autoOpenContainers = v
        end,
        -16
    )
    self.autoOpenCB = autoOpenCB

    local autoOpenNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    autoOpenNote:SetPoint("TOPLEFT", autoOpenCB, "BOTTOMLEFT", 26, -2)
    EC_compCache.setPanelWidth(autoOpenNote, 60)
    autoOpenNote:SetJustifyH("LEFT")
    if autoOpenNote.SetWordWrap then
        autoOpenNote:SetWordWrap(true)
    end
    autoOpenNote:SetText("|cff888888Lockboxes that need a key or lockpick are skipped. Combat-paused.|r")

    -- v2.10.0: the v2.9.0 editable companion-name input boxes were removed
    -- from this panel after in-game testing showed the click-to-focus path
    -- was unreliable on PE-ElvUI; users could see the inputs but typing did
    -- not update DB.scavengerName / DB.merchantName consistently. The
    -- underlying mechanism (DB fields, EC_compCache.refreshNames, the
    -- EnsureDB defaults, and the spellID 600126 cold-cache fallback in
    -- FindGoblinMerchantIndex) all stay - they are still the source of
    -- truth for companion lookup and a future re-enable can drop the UI
    -- back in without touching the runtime path. For now if a user needs
    -- to override either name they can edit DB.scavengerName /
    -- DB.merchantName directly via /run on a single character.

    -- Discoverability hint for the right-click context menu. Lives on this
    -- panel because both v2.3.0 bag-action features cluster here.
    local rightClickHint = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    rightClickHint:SetPoint("TOPLEFT", autoOpenNote, "BOTTOMLEFT", 0, -16)
    EC_compCache.setPanelWidth(rightClickHint, 60)
    rightClickHint:SetJustifyH("LEFT")
    if rightClickHint.SetWordWrap then
        rightClickHint:SetWordWrap(true)
    end
    rightClickHint:SetText(
        "|cffffb84dTip:|r |cff888888Alt+Right-Click any item in your bags for a quick-action menu (whitelist, blacklist, delete, sell now).|r"
    )

    -- Size the scroll content to fit the bottom-most widget so the scrollbar
    -- range matches actual content (no excess empty space at the bottom).
    EC_FitScrollContent(content, rightClickHint)
end)

local CharPanel = CreateFrame("Frame", "EbonClearanceOptionsCharacter", InterfaceOptionsFramePanelContainer)
CharPanel.name = "Character Settings"
CharPanel.parent = "EbonClearance"

local function CreateNameListUI(parent, titleText, setTableName, x, y)
    local w = EC_PANEL_WIDTH - x
    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", x, y)
    -- 280 matches CreateListUI's default; keeps the scroll arrows inside the
    -- InterfaceOptions sub-panel's visible area instead of clipping below it.
    box:SetSize(w, 280)

    local title = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(titleText)

    local input = CreateFrame("EditBox", "EbonClearanceIDInput_" .. setTableName, box, "InputBoxTemplate")
    input:SetAutoFocus(false)
    input:SetSize(180, 20)
    input:SetPoint("TOPLEFT", 0, -24)
    input:SetMaxLetters(24)
    input:SetText("")

    local addBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 20)
    addBtn:SetPoint("LEFT", input, "RIGHT", 8, 0)
    addBtn:SetText("Add")

    local meBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    meBtn:SetSize(90, 20)
    meBtn:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
    meBtn:SetText("Add Me")
    meBtn:SetScript("OnClick", function()
        input:SetText(EC_GetPlayerName())
        input:HighlightText()
    end)

    local scroll =
        CreateFrame("ScrollFrame", "EbonClearanceNameListScroll_" .. setTableName, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -54)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(w - 26, 1)
    scroll:SetScrollChild(content)
    -- Auto-hide the scroll bar (arrows + thumb) when content fits the visible
    -- area. Wired once here; OnScrollRangeChanged fires on every Refresh that
    -- changes content height, so visibility tracks the list automatically.
    EC_HookScrollbarAutoHide(scroll)

    -- v2.11.0: track box width on resize so the content (a ScrollChild)
    -- and its rows stretch with the panel. Mirror of CreateListUI.
    box:SetScript("OnSizeChanged", function(self, width)
        if not width or width <= 0 then
            return
        end
        if content and content.SetWidth then
            content:SetWidth(width - 26)
        end
    end)

    local rowPool = {}
    local activeRows = 0

    local function GetRow(index)
        if rowPool[index] then
            return rowPool[index]
        end
        local row = CreateFrame("Frame", nil, content)
        row:SetHeight(22)
        -- v2.11.0: row anchors set in Refresh below (TOPLEFT + TOPRIGHT
        -- relative to content) so the row stretches with content. Text
        -- inside spans LEFT-of-row to LEFT-of-Remove-button via anchors,
        -- no SetWidth snapshot.

        local rm = CreateFrame(
            "Button",
            "EbonClearanceNameRM_" .. setTableName .. "_" .. index,
            content,
            "UIPanelButtonTemplate"
        )
        rm:SetSize(72, 18)
        rm:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        rm:SetText("Remove")

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 2, 0)
        text:SetPoint("RIGHT", rm, "LEFT", -8, 0)
        text:SetJustifyH("LEFT")

        row.rm = rm
        row.text = text
        rowPool[index] = row
        return row
    end

    local function HideAllRows()
        for i = 1, activeRows do
            if rowPool[i] then
                rowPool[i]:Hide()
                rowPool[i].rm:Hide()
            end
        end
        activeRows = 0
    end

    local function SortedNames(t)
        local names = {}
        for k in pairs(t) do
            if type(k) == "string" and k ~= "" then
                names[#names + 1] = k
            end
        end
        table.sort(names)
        return names
    end

    local function Refresh()
        HideAllRows()

        local setTable = DB[setTableName]
        local keys = SortedNames(setTable)

        local shown = 0
        local rowY = -4
        for i = 1, #keys do
            local name = keys[i]
            shown = shown + 1
            local row = GetRow(shown)
            row:ClearAllPoints()
            -- v2.11.0: anchor TOPLEFT + TOPRIGHT so the row stretches.
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, rowY)
            row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, rowY)
            row.text:SetText("|cffb6ffb6" .. name .. "|r")
            row.rm:SetScript("OnClick", function()
                DB[setTableName][name] = nil
                Refresh()
            end)
            row:Show()
            row.rm:Show()
            rowY = rowY - 22
        end

        activeRows = shown
        content:SetHeight(math.max(1, (shown * 22) + 8))
        -- Scroll-bar visibility handled by the OnScrollRangeChanged hook.
    end

    addBtn:SetScript("OnClick", function()
        -- v2.13.1: permissive trim. Strips ASCII whitespace plus the two
        -- most common invisible characters that survive Discord/web copy-
        -- paste: non-breaking space (\194\160 = U+00A0) and zero-width
        -- joiner (\226\128\139 = U+200B). Without this, an entry that
        -- looks identical to the player's character name in the UI can
        -- still mismatch the EC_IsCharacterAllowed lookup.
        local v = (input:GetText() or "")
            :gsub("^[%s\194\160\226\128\139]+", "")
            :gsub("[%s\194\160\226\128\139]+$", "")
        if v == "" then
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        DB[setTableName][v] = true
        input:SetText("")
        Refresh()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    input:SetScript("OnEnterPressed", function()
        addBtn:Click()
        input:ClearFocus()
    end)

    box.Refresh = Refresh
    return box
end

CharPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.onlyCB then
            self.onlyCB:SetChecked(DB.enableOnlyListedChars)
        end
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Character Settings", -16)
    local charDesc = MakeLabel(
        self,
        "Prevents this addon from running on characters you didn't intend. If enabled, EbonClearance runs only on characters listed below.",
        16,
        -44
    )

    local cb =
        CreateFrame("CheckButton", "EbonClearanceEnableOnlyListedCharsCB", self, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", charDesc, "BOTTOMLEFT", 0, -8)
    cb:SetChecked(DB.enableOnlyListedChars)

    local t = _G[cb:GetName() .. "Text"]
    if t then
        t:SetText("Enable Only for Listed Characters")
        EC_compCache.setPanelWidth(t, 60)
        t:SetJustifyH("LEFT")
    end

    cb:SetScript("OnClick", function()
        DB.enableOnlyListedChars = cb:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.onlyCB = cb

    self.listUI = CreateNameListUI(self, "Allowed Characters", "allowedChars", 16, -130)
    -- v2.11.0: anchor BOTTOMRIGHT so the list stretches with the panel
    -- on resize - keeps each row's "Remove" button inside the panel
    -- boundary even after the user shrinks the Interface Options frame.
    self.listUI:ClearAllPoints()
    self.listUI:SetPoint("TOPLEFT", 16, -130)
    self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
    self.listUI:Refresh()
end)

-- ============================================================
-- Blacklist (Do Not Sell) Panel
-- ============================================================
local BlacklistPanel = CreateFrame("Frame", "EbonClearanceOptionsBlacklist", InterfaceOptionsFramePanelContainer)
BlacklistPanel.name = "Blacklist - Keep"
BlacklistPanel.parent = "EbonClearance"

BlacklistPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.autoEquipCB then
            self.autoEquipCB:SetChecked(DB.autoAddEquipped)
        end
        if self.autoUpgradeCB then
            self.autoUpgradeCB:SetChecked(DB.autoProtectUpgrades)
        end
        if self.autoSetCB then
            self.autoSetCB:SetChecked(DB.autoProtectEquipmentSets)
        end
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Blacklist (Do Not Sell)", -16)
    local blDesc = MakeLabel(
        self,
        "Specific items to permanently protect from auto-sell. Use this for valuable items you'd rather list at the auction house. |cffaaaaaaThe auto-protect toggles below extend this list automatically with items you equip and upgrades you loot.|r",
        16,
        -44
    )

    -- Anchored to blDesc so the hint stays below even when the description
    -- wraps to multiple lines (previous absolute y=-80 overlapped the wrap).
    local blHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    blHint:SetPoint("TOPLEFT", blDesc, "BOTTOMLEFT", 0, -8)
    EC_compCache.setPanelWidth(blHint, 16)
    blHint:SetJustifyH("LEFT")
    blHint:SetJustifyV("TOP")
    if blHint.SetWordWrap then
        blHint:SetWordWrap(true)
    end
    blHint:SetText("Add items by Shift-Clicking, dragging, or typing the Item ID below.")

    -- v2.10.0: auto-protect equipped gear. Toggling on runs a one-shot sync
    -- of every currently equipped slot into THIS list (Blacklist - Keep),
    -- then a reactive PLAYER_EQUIPMENT_CHANGED handler keeps the list in
    -- step with future gear swaps. The blacklist veto in EC_IsSellable
    -- prevents auto-rules from touching anything on this list, so a
    -- replaced upgrade sliding into bags is automatically protected. The
    -- tooltip annotation surfaces "(auto-protected: equipped)" so users
    -- who decide they want an auto-added item sold can see why it's being
    -- kept and Alt+Right-Click to remove it.
    local autoEquipCB = CreateFrame(
        "CheckButton",
        "EbonClearanceAutoProtectEquippedCB",
        self,
        "InterfaceOptionsCheckButtonTemplate"
    )
    autoEquipCB:SetPoint("TOPLEFT", blHint, "BOTTOMLEFT", 0, -10)
    autoEquipCB:SetChecked(DB.autoAddEquipped)
    local aeText = _G[autoEquipCB:GetName() .. "Text"]
    if aeText then
        aeText:SetText("Auto-protect equipped gear")
        EC_compCache.setPanelWidth(aeText, 60)
        aeText:SetJustifyH("LEFT")
    end
    autoEquipCB:SetScript("OnClick", function(cb)
        local on = cb:GetChecked() and true or false
        local wasOff = (DB.autoAddEquipped ~= true)
        DB.autoAddEquipped = on
        PlaySound("igMainMenuOptionCheckBoxOn")
        if on and wasOff then
            EC_compCache.syncEquipped()
            if self.listUI then
                self.listUI:Refresh()
            end
        end
    end)
    self.autoEquipCB = autoEquipCB

    local autoEquipNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    autoEquipNote:SetPoint("TOPLEFT", autoEquipCB, "BOTTOMLEFT", 26, -2)
    EC_compCache.setPanelWidth(autoEquipNote, 60)
    autoEquipNote:SetJustifyH("LEFT")
    if autoEquipNote.SetWordWrap then
        autoEquipNote:SetWordWrap(true)
    end
    autoEquipNote:SetText(
        "|cff888888Adds your currently equipped gear to this Keep list on toggle, then auto-adds anything you equip later so replaced upgrades sliding into bags are automatically protected from auto-sell rules. The bag tooltip explains why each item is kept; Alt+Right-Click an item to remove it if you want it sold.|r"
    )

    -- v2.11.0 auto-protect upgrades. The companion to v2.10.0's auto-
    -- protect-equipped: this one watches BAG_UPDATE for items whose iLvl
    -- exceeds the equipped item in any of their candidate slots (rings,
    -- trinkets, weapons compare against the lower of the two equipped
    -- slots so any genuine upgrade triggers). Looted upgrades sitting in
    -- bags are stamped on this Keep list before any iLvl-cap rule on
    -- Merchant Settings can sweep them up. Default off; opt-in.
    local autoUpgradeCB = CreateFrame(
        "CheckButton",
        "EbonClearanceAutoProtectUpgradesCB",
        self,
        "InterfaceOptionsCheckButtonTemplate"
    )
    autoUpgradeCB:SetPoint("TOPLEFT", autoEquipNote, "BOTTOMLEFT", -26, -10)
    autoUpgradeCB:SetChecked(DB.autoProtectUpgrades)
    local auText = _G[autoUpgradeCB:GetName() .. "Text"]
    if auText then
        auText:SetText("Auto-protect upgraded gear in bags")
        EC_compCache.setPanelWidth(auText, 60)
        auText:SetJustifyH("LEFT")
    end
    autoUpgradeCB:SetScript("OnClick", function(cb)
        DB.autoProtectUpgrades = cb:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
        if DB.autoProtectUpgrades then
            -- Re-check on toggle so existing bag contents are evaluated
            -- immediately rather than waiting for the next BAG_UPDATE.
            EC_compCache.checkBagsForUpgrades()
            if self.listUI then
                self.listUI:Refresh()
            end
        end
    end)
    self.autoUpgradeCB = autoUpgradeCB

    local autoUpgradeNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    autoUpgradeNote:SetPoint("TOPLEFT", autoUpgradeCB, "BOTTOMLEFT", 26, -2)
    EC_compCache.setPanelWidth(autoUpgradeNote, 60)
    autoUpgradeNote:SetJustifyH("LEFT")
    if autoUpgradeNote.SetWordWrap then
        autoUpgradeNote:SetWordWrap(true)
    end
    autoUpgradeNote:SetText(
        "|cff888888Watches new bag items and auto-adds any whose item level beats your currently equipped gear in the same slot. |r"
            .. "|cffaaaaaaRedundant when Merchant Settings uses |cffffff00Use equipped iLvl|r|cffaaaaaa "
            .. "(the dynamic cap already excludes upgrades from auto-sell). "
            .. "Useful when you switch a rarity to a fixed |cffffff00max iLvl|r|cffaaaaaa "
            .. "above your equipped iLvl - then an upgrade falling below that cap could "
            .. "vendor without this protection.|r"
    )

    -- v2.13.0 Equipment Manager protection. Catches the dual-spec /
    -- off-set gap: items assigned to your alternate Blizzard equipment
    -- set sit in bags between swaps and aren't protected by
    -- autoAddEquipped (which only catches currently-equipped slots).
    -- One-shot sync at toggle, then EQUIPMENT_SETS_CHANGED reactive.
    local autoSetCB = CreateFrame(
        "CheckButton",
        "EbonClearanceAutoProtectSetsCB",
        self,
        "InterfaceOptionsCheckButtonTemplate"
    )
    autoSetCB:SetPoint("TOPLEFT", autoUpgradeNote, "BOTTOMLEFT", -26, -10)
    autoSetCB:SetChecked(DB.autoProtectEquipmentSets)
    local asText = _G[autoSetCB:GetName() .. "Text"]
    if asText then
        asText:SetText("Auto-protect items in Blizzard equipment sets")
        EC_compCache.setPanelWidth(asText, 60)
        asText:SetJustifyH("LEFT")
    end
    autoSetCB:SetScript("OnClick", function(cb)
        local on = cb:GetChecked() and true or false
        local wasOff = (DB.autoProtectEquipmentSets ~= true)
        DB.autoProtectEquipmentSets = on
        PlaySound("igMainMenuOptionCheckBoxOn")
        if on and wasOff then
            EC_compCache.syncEquipmentSets(false)
            if self.listUI then
                self.listUI:Refresh()
            end
        end
    end)
    self.autoSetCB = autoSetCB

    local autoSetNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    autoSetNote:SetPoint("TOPLEFT", autoSetCB, "BOTTOMLEFT", 26, -2)
    EC_compCache.setPanelWidth(autoSetNote, 60)
    autoSetNote:SetJustifyH("LEFT")
    if autoSetNote.SetWordWrap then
        autoSetNote:SetWordWrap(true)
    end
    autoSetNote:SetText(
        "|cff888888Adds every item in your saved Blizzard equipment-manager sets to this Keep list, and re-syncs whenever you save or modify a set. "
            .. "Useful for hybrids and dual-spec players whose off-set gear sits in bags between swaps. "
            .. "Tooltip shows |cffffb84dAuto-Protected (Set)|r|cff888888 on items kept by this rule. Removing a set later does not auto-clean items it added; use Alt+Right-Click to drop unwanted entries.|r"
    )

    -- Cascade-anchor the list UI to the auto-set note's BOTTOMLEFT so
    -- the manual-add list always sits below the toggle stack regardless
    -- of how many lines the notes wrap to.
    self.listUI = CreateListUI(self, "Protected Items", "blacklist", 16, -200)
    self.listUI:ClearAllPoints()
    self.listUI:SetPoint("TOPLEFT", autoSetNote, "BOTTOMLEFT", -26, -16)
    self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
    self.listUI:Refresh()
end)

local AccountWhitelistPanel =
    CreateFrame("Frame", "EbonClearanceOptionsAccountWhitelist", InterfaceOptionsFramePanelContainer)
AccountWhitelistPanel.name = "Whitelist - Account"
AccountWhitelistPanel.parent = "EbonClearance"

AccountWhitelistPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Account Whitelist", -16)
    local descLabel = MakeLabel(
        self,
        "Specific items to always auto-sell on |cffffff00every|r character on this account. Useful for shared trash like reagents or seasonal items. |cffaaaaaaThis list is not part of profiles - it stays the same when you switch profiles.|r",
        16,
        -44
    )

    -- Cascade-anchor the scan row to the description's BOTTOMLEFT so it stays
    -- below the description regardless of how many lines it wraps to. Then the
    -- list UI cascades below the scan row. Mirrors WhitelistPanel.
    local scanRow = EC_AddScanByQualityRow(self, descLabel, "accountWhitelist", "the account whitelist", function()
        if self.listUI then
            self.listUI:Refresh()
        end
    end, 0, -10)

    self.listUI = CreateListUI(self, "Account-Wide Items", "accountWhitelist", 16, -118)
    self.listUI:ClearAllPoints()
    self.listUI:SetPoint("TOPLEFT", scanRow, "BOTTOMLEFT", 0, -16)
    -- Fill remaining vertical space rather than fixed-height; mirrors
    -- WhitelistPanel and avoids bottom-row clipping at narrow widths.
    self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
    self.listUI:Refresh()
end)

-- Register sub-panels in alphabetical order
InterfaceOptions_AddCategory(CharPanel)
InterfaceOptions_AddCategory(ScavengerPanel)
InterfaceOptions_AddCategory(MerchantPanel)
InterfaceOptions_AddCategory(ProfilesPanel)
InterfaceOptions_AddCategory(ImportExportPanel)
InterfaceOptions_AddCategory(DeletePanel)
InterfaceOptions_AddCategory(BlacklistPanel)
InterfaceOptions_AddCategory(WhitelistPanel)
InterfaceOptions_AddCategory(AccountWhitelistPanel)

-- v2.11.0 reactive panel layout. The Interface Options frame is user-
-- resizable in some UI mod packs (and the resize handle is exposed as a
-- draggable widget on PE-ElvUI). Pre-v2.11.0 the addon's panels stayed
-- clamped at their build-time width because every label, scroll-content,
-- and list-row width was a snapshot of EC_PANEL_WIDTH taken at first
-- OnShow. Hooking the container's OnSizeChanged once routes every
-- registered widget through EC_compCache.refreshLayouts on each resize -
-- labels re-wrap, scroll content re-fits, list frames already track via
-- BOTTOMRIGHT anchors (their visible drift was just label clutter on
-- top, fixed by the same width refresh).
if InterfaceOptionsFramePanelContainer and InterfaceOptionsFramePanelContainer.HookScript then
    InterfaceOptionsFramePanelContainer:HookScript("OnSizeChanged", function()
        EC_compCache.refreshLayouts()
    end)
end

-- Bug report diagnostic snapshot
local function EC_CopperToPlainText(copper)
    if not copper or copper <= 0 then
        return "0"
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100
    if gold > 0 then
        return string.format("%dg %ds %dc", gold, silver, cop)
    elseif silver > 0 then
        return string.format("%ds %dc", silver, cop)
    else
        return string.format("%dc", cop)
    end
end

local function EC_BuildBugReport()
    EnsureDB()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end

    local version = EC_GetVersion()
    local player = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    local dateStr = date("%Y-%m-%d %H:%M")
    local className = UnitClass and UnitClass("player") or "Unknown"
    local level = UnitLevel and UnitLevel("player") or 0
    local locale = GetLocale and GetLocale() or "Unknown"

    add("=== EbonClearance Bug Report ===")
    add("Version: " .. version)
    add("Character: " .. player .. " - " .. realm)
    add("Class / Level: " .. className .. " / " .. tostring(level))
    add("Locale: " .. tostring(locale))
    add("Date: " .. dateStr)
    add("")

    -- v2.13.1 Live State section. Captures the runtime context at the
    -- exact moment of report. Useful for diagnosing merchant-mode
    -- target-vs-npc mismatches, combat-deferral cases, and "addon not
    -- doing anything" reports where the cause is a live unit / frame
    -- state the static settings can't show.
    add("--- Live State ---")
    add("In Combat: " .. tostring(InCombatLockdown and InCombatLockdown() or false))
    add("Mounted: " .. tostring(IsMounted and IsMounted() or false))
    local targetExists = UnitExists and UnitExists("target")
    add("Target: " .. ((targetExists and UnitName("target")) or "(none)"))
    local npcExists = UnitExists and UnitExists("npc")
    add("NPC (interact): " .. ((npcExists and UnitName("npc")) or "(none)"))
    local merchantOpen = MerchantFrame and MerchantFrame:IsShown() or false
    add("Merchant Open: " .. tostring(merchantOpen))
    local totalBagSlots = 0
    for bag = 0, 4 do
        totalBagSlots = totalBagSlots + (GetContainerNumSlots(bag) or 0)
    end
    add("Free Bags: " .. tostring(EC_GetFreeBagSlots()) .. " / " .. tostring(totalBagSlots))
    add("")

    add("--- Settings ---")
    add("Enabled: " .. tostring(DB.enabled))
    add("Merchant Mode: " .. tostring(DB.merchantMode))
    add("Repair Gear: " .. tostring(DB.repairGear))
    add("Repair via Guild Bank: " .. tostring(DB.repairUseGuildBank))
    add("Keep Bags Open: " .. tostring(DB.keepBagsOpen))
    add("Enable Deletion: " .. tostring(DB.enableDeletion))
    add("Vendor Interval: " .. tostring(DB.vendorInterval))
    add("Max Items Per Run: " .. tostring(DB.maxItemsPerRun))
    add("Fast Mode: " .. tostring(DB.fastMode))
    -- v2.10.0 / v2.11.0 / v2.13.0 auto-protect family - omitting these
    -- left a blind spot in earlier reports for "why is X being kept?"
    -- diagnostics where the auto-protect path was the answer.
    add("Auto-Add Equipped: " .. tostring(DB.autoAddEquipped))
    add("Auto-Protect Upgrades: " .. tostring(DB.autoProtectUpgrades))
    add("Auto-Protect Equipment Sets: " .. tostring(DB.autoProtectEquipmentSets))
    add("Enable Only Listed Chars: " .. tostring(DB.enableOnlyListedChars))
    if DB.enableOnlyListedChars then
        local allowed = {}
        if type(DB.allowedChars) == "table" then
            for k, v in pairs(DB.allowedChars) do
                if v == true and type(k) == "string" then
                    allowed[#allowed + 1] = k
                end
            end
        end
        table.sort(allowed)
        add("Allowed Characters: " .. (#allowed > 0 and table.concat(allowed, ", ") or "(none)"))
    end
    add("")

    add("--- Scavenger ---")
    add("Summon Greedy: " .. tostring(DB.summonGreedy))
    add("Summon Delay: " .. tostring(DB.summonDelay))
    add("Summon Only Out Of Combat: " .. tostring(DB.summonOnlyOutOfCombat))
    add("Mute Greedy: " .. tostring(DB.muteGreedy))
    add("Hide Chat: " .. tostring(DB.hideGreedyChat))
    add("Hide Bubbles: " .. tostring(DB.hideGreedyBubbles))
    add("Auto-Loot Cycle: " .. tostring(DB.autoLootCycle))
    add("Bag Full Threshold: " .. tostring(DB.bagFullThreshold))
    add("Auto-Open Containers: " .. tostring(DB.autoOpenContainers))
    -- Companion-name overrides. Most users leave these as defaults; when a
    -- user has customised one and then reports a "addon doesn't recognise
    -- my Goblin Merchant" / "Scavenger isn't being detected" issue, the
    -- override is usually the cause.
    -- v2.13.3: dropped the DB.petName branch (field had no setter, copy-
    -- paste artifact of the v2.9.0 scavengerName rename); the real pet
    -- field is DB.scavengerName.
    -- v2.13.5: only show these lines when the value actually differs
    -- from the default that EnsureDB seeds. The previous "non-empty"
    -- check matched every install because EnsureDB always seeds these
    -- fields with default strings, so the "(override)" label was
    -- displayed even when no override was set. Also added the scavenger
    -- field which had a comment claiming it was "exposed elsewhere"
    -- but in fact wasn't surfaced in the report at all.
    if DB.merchantName and DB.merchantName ~= "" and DB.merchantName ~= "Goblin Merchant" then
        add("Merchant Name (override): " .. tostring(DB.merchantName))
    end
    if DB.scavengerName and DB.scavengerName ~= "" and DB.scavengerName ~= "Greedy scavenger" then
        add("Scavenger Name (override): " .. tostring(DB.scavengerName))
    end
    add("")

    -- v2.13.1 Runtime State section. Snapshots the in-flight loot-cycle
    -- and stuck-detection signals so a Discord report can pinpoint
    -- "why isn't the cycle progressing" cases without requiring a /reload
    -- or chat-log scrape.
    add("--- Runtime State ---")
    add("Loot Cycle State: " .. tostring(EC_lootCycleState or "?"))
    add("Scavenger Out: " .. tostring(EC_lastScavengerOut))
    add("Addon-Dismissed: " .. tostring(EC_addonDismissed))
    add("Scav Speech Heard This Session: " .. tostring(EC_compCache.scavSpeechEverHeard))
    if EC_compCache.bagFullSince and EC_compCache.bagFullSince > 0 then
        local elapsed = (GetTime and GetTime() or 0) - EC_compCache.bagFullSince
        add(string.format("Bag-Full Threshold Hit: %.1fs ago", elapsed))
    else
        add("Bag-Full Threshold Hit: -")
    end
    add("")

    add("--- Whitelist ---")
    add("Quality Rules:")
    for q = 1, 4 do
        local r = DB.qualityRules and DB.qualityRules[q] or {}
        local rarityName = (q == 1) and "White"
            or (q == 2) and "Green"
            or (q == 3) and "Blue"
            or "Epic"
        local capStr = (r.maxILvl and r.maxILvl > 0) and tostring(r.maxILvl) or "no cap"
        local bindStr = tostring(r.bindFilter or "any")
        add(string.format(
            "  %s: enabled=%s, max iLvl=%s, useEquipped=%s, bind=%s",
            rarityName,
            tostring(r.enabled),
            capStr,
            tostring(r.useEquippedILvl),
            bindStr
        ))
    end
    add("Active Profile: " .. tostring(DB.activeProfileName))
    add("Whitelist Items: " .. tostring(EC_CountItems(DB.whitelist)))
    add("Account Whitelist Items: " .. tostring(ADB and EC_CountItems(ADB.whitelist) or 0))
    add("Blacklist Items: " .. tostring(EC_CountItems(DB.blacklist)))
    add("Delete List Items: " .. tostring(EC_CountItems(DB.deleteList)))
    add("")

    -- v2.13.1 Auto-Protected Breakdown. Walks DB.blacklistAuto and groups
    -- entries by origin tag so a user reporting "my Keep list is huge,
    -- why?" can see at a glance which auto-protect path is responsible.
    -- Legacy entries (v2.10.0 / v2.11.0 stamped a boolean true rather
    -- than a string tag) bucket separately so they're visible for the
    -- /ec clean upgrades workflow.
    if type(DB.blacklistAuto) == "table" then
        local cWorn, cUpgrade, cSet, cLegacy = 0, 0, 0, 0
        for _, tag in pairs(DB.blacklistAuto) do
            if tag == "equipped" then
                cWorn = cWorn + 1
            elseif tag == "upgrade" then
                cUpgrade = cUpgrade + 1
            elseif tag == "set" then
                cSet = cSet + 1
            elseif tag == true then
                cLegacy = cLegacy + 1
            end
        end
        local total = cWorn + cUpgrade + cSet + cLegacy
        if total > 0 then
            add("--- Auto-Protected Breakdown ---")
            add("Equipped (Worn): " .. cWorn)
            add("Upgrade: " .. cUpgrade)
            add("Set: " .. cSet)
            if cLegacy > 0 then
                add("Legacy (untagged): " .. cLegacy)
            end
            add("Total auto-tagged: " .. total)
            add("")
        end
    end

    add("--- Profiles ---")
    local names = {}
    for name in pairs(DB.whitelistProfiles) do
        if type(name) == "string" then
            names[#names + 1] = name
        end
    end
    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)
    for i = 1, #names do
        local wlCount = EC_CountItems(DB.whitelistProfiles[names[i]])
        local blCount = DB.blacklistProfiles[names[i]] and EC_CountItems(DB.blacklistProfiles[names[i]]) or 0
        local tag = (names[i] == DB.activeProfileName) and " (active)" or ""
        add(names[i] .. " (" .. wlCount .. " whitelist, " .. blCount .. " blacklist)" .. tag)
    end
    add("")

    add("--- Stats ---")
    add("Total Money Made: " .. EC_CopperToPlainText(DB.totalCopper or 0))
    add("Total Items Sold: " .. tostring(DB.totalItemsSold or 0))
    add("Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0))
    add("Total Repairs: " .. tostring(DB.totalRepairs or 0))
    add("Total Repair Cost: " .. EC_CopperToPlainText(DB.totalRepairCopper or 0))
    add("")

    -- v2.13.1 UI mod detection. The PE addon ecosystem has a handful of
    -- bag/inventory mods that interact (or fail to interact) with EC's
    -- ContainerFrame hooks; capturing which the user runs disambiguates
    -- "ElvUI bag buttons not appearing" / "Bagnon hides EC tooltips" /
    -- "ArkInventory replaces my bag frame" reports without a follow-up.
    add("--- UI Mods Detected ---")
    add("ElvUI: " .. ((_G.ElvUI ~= nil) and "yes" or "no"))
    add("Bagnon: " .. ((_G.Bagnon ~= nil or _G.BagnonFrame ~= nil) and "yes" or "no"))
    add("ArkInventory: " .. ((_G.ArkInventory ~= nil) and "yes" or "no"))
    add("Auctionator: " .. ((_G.Atr_GetAuctionBuyout ~= nil or _G.Auctionator ~= nil) and "yes" or "no"))

    add("")
    add("--- Bags ---")
    add("Free Slots: " .. tostring(EC_GetFreeBagSlots()))

    return table.concat(lines, "\n")
end

local EC_bugReportFrame = nil

local function EC_ShowBugReport()
    if not EC_bugReportFrame then
        local f = CreateFrame("Frame", "EbonClearanceBugReportFrame", UIParent)
        f:SetSize(460, 360)
        f:SetPoint("CENTER")
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")
        tinsert(UISpecialFrames, "EbonClearanceBugReportFrame")

        local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        title:SetPoint("TOP", 0, -14)
        title:SetText("EbonClearance Bug Report")

        local hint = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        hint:SetPoint("TOP", title, "BOTTOM", 0, -4)
        hint:SetText("|cff888888Press Ctrl+A then Ctrl+C to copy this report.|r")

        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -4, -4)

        local scroll = CreateFrame("ScrollFrame", "EbonClearanceBugReportScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -50)
        scroll:SetPoint("BOTTOMRIGHT", -32, 16)

        local editBox = CreateFrame("EditBox", "EbonClearanceBugReportBox", scroll)
        editBox:SetAutoFocus(false)
        editBox:SetMultiLine(true)
        editBox:SetFontObject("GameFontHighlightSmall")
        editBox:SetWidth(400)
        editBox:SetText("")
        editBox:SetScript("OnEscapePressed", function(s)
            s:ClearFocus()
        end)
        scroll:SetScrollChild(editBox)

        f.editBox = editBox
        EC_bugReportFrame = f
    end

    local report = EC_BuildBugReport()
    EC_bugReportFrame.editBox:SetText(report)
    EC_bugReportFrame:Show()
    EC_bugReportFrame.editBox:HighlightText()
    EC_bugReportFrame.editBox:SetFocus()
    PrintNice("Bug report generated. Copy the text from the window.")
end

-- Keybinding registration. Populates the "EbonClearance" section of
-- ESC -> Key Bindings. Four bindings:
--   - "Target Goblin Merchant" - dispatched through the hidden
--     EbonClearanceTargetMerchantButton SecureActionButton so it works in
--     combat lockdown.
--   - Three operational bindings (open/close settings, toggle enabled,
--     force sell at current merchant) declared in Bindings.xml and wired
--     to the EbonClearance_* global handlers further down this file.
BINDING_HEADER_EBONCLEARANCE = "EbonClearance"
_G["BINDING_NAME_CLICK EbonClearanceTargetMerchantButton:LeftButton"] = "Target Goblin Merchant"
BINDING_NAME_EBONCLEARANCE_TOGGLE_SETTINGS = "Open/close settings"
BINDING_NAME_EBONCLEARANCE_TOGGLE_ENABLED = "Toggle enabled"
BINDING_NAME_EBONCLEARANCE_FORCE_SELL = "Force sell at current merchant"
-- Cross-list intent groups for the add-time conflict guard:
--   keep   = whitelist (per-character) + accountWhitelist (account-wide)
--   sell   = blacklist
--   delete = deleteList
-- Same-intent scopes are NOT in conflict (whitelist + accountWhitelist is
-- redundant, not contradictory). Cross-intent IS the conflict we refuse at
-- input time. The post-hoc EC_ApplyCleanResolution below remains as the
-- legacy-data safety net for DBs that pre-date this guard.
--
-- Returns the name of an already-occupying list with a different intent,
-- or nil when the add is safe. Forward-declared at the top of the file so
-- EC_AddItemToList can call it before this body is reached.
EC_FindAddConflict = function(itemID, targetListName)
    if not itemID or not targetListName then
        return nil
    end
    local function intentOf(n)
        if n == "whitelist" or n == "accountWhitelist" then
            return "keep"
        end
        if n == "blacklist" then
            return "sell"
        end
        if n == "deleteList" then
            return "delete"
        end
        return nil
    end
    local targetIntent = intentOf(targetListName)
    if not targetIntent then
        return nil
    end
    local checks = {
        { name = "blacklist", data = DB and DB.blacklist },
        { name = "deleteList", data = DB and DB.deleteList },
        { name = "whitelist", data = DB and DB.whitelist },
        { name = "accountWhitelist", data = ADB and ADB.whitelist },
    }
    for i = 1, #checks do
        local c = checks[i]
        if c.name ~= targetListName and c.data and c.data[itemID] and intentOf(c.name) ~= targetIntent then
            return c.name
        end
    end
    return nil
end

-- Conflict detection + resolution across whitelist/blacklist/deleteList.
-- Precedence when auto-resolving: blacklist > deleteList > whitelist.
local function EC_ScanListConflicts()
    local lists = {
        { name = "whitelist", data = DB.whitelist },
        { name = "blacklist", data = DB.blacklist },
        { name = "deleteList", data = DB.deleteList },
    }
    local where = {}
    for i = 1, #lists do
        local e = lists[i]
        if type(e.data) == "table" then
            for id in pairs(e.data) do
                if type(id) == "number" then
                    where[id] = where[id] or {}
                    where[id][#where[id] + 1] = e.name
                end
            end
        end
    end
    local conflicts = {}
    for id, names in pairs(where) do
        if #names >= 2 then
            conflicts[#conflicts + 1] = { id = id, lists = names }
        end
    end
    table.sort(conflicts, function(a, b)
        return a.id < b.id
    end)
    return conflicts
end

local function EC_PrintConflictReport(conflicts)
    if #conflicts == 0 then
        PrintNice("|cff00ff00No list conflicts found.|r")
        return
    end
    PrintNicef("Found |cffffff00%d|r item(s) present in multiple lists:", #conflicts)
    for i = 1, #conflicts do
        local c = conflicts[i]
        local name = GetItemInfo(c.id) or ("ItemID:" .. c.id)
        PrintNicef("  |cffb6ffb6%d|r  %s  [%s]", c.id, name, table.concat(c.lists, ", "))
    end
end

local function EC_ApplyCleanResolution(conflicts)
    local removed = 0
    for i = 1, #conflicts do
        local c = conflicts[i]
        local inBL, inDel, inWL = false, false, false
        for j = 1, #c.lists do
            local n = c.lists[j]
            if n == "blacklist" then
                inBL = true
            elseif n == "deleteList" then
                inDel = true
            elseif n == "whitelist" then
                inWL = true
            end
        end
        if inBL and inWL then
            DB.whitelist[c.id] = nil
            removed = removed + 1
        end
        if inBL and inDel then
            DB.deleteList[c.id] = nil
            removed = removed + 1
        end
        if inDel and inWL then
            DB.whitelist[c.id] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- v2.12.0 stale-upgrade scanner. Walks DB.blacklistAuto entries with the
-- "upgrade" tag and re-evaluates each against the player's currently-
-- equipped gear. Returns three lists:
--   stale    - entries that are no longer upgrades (iLvl <= lowest equipped)
--   deferred - entries we couldn't evaluate (GetItemInfo not loaded yet)
--   skipped  - entries we can't evaluate (no equipLoc / all candidate slots
--              empty / equipLoc not in INVTYPE_SLOTS); these stay put
-- Mirror of EC_compCache.checkBagsForUpgrades' eligibility logic, inverted.
-- Hung off EC_compCache to avoid burning two main-chunk local slots
-- (Lua 5.1 caps that at 200 and we sit near it).
function EC_compCache.buildStaleUpgradeReport()
    local stale, deferred, skipped = {}, {}, {}
    if not DB or type(DB.blacklistAuto) ~= "table" then
        return { stale = stale, deferred = deferred, skipped = skipped }
    end
    for id, tag in pairs(DB.blacklistAuto) do
        if tag == "upgrade" and DB.blacklist and DB.blacklist[id] then
            local name, _, _, iLvl, _, _, _, _, equipLoc = GetItemInfo(id)
            if not name or not iLvl then
                deferred[#deferred + 1] = id
            else
                local slots = equipLoc and equipLoc ~= "" and EC_compCache.INVTYPE_SLOTS[equipLoc]
                if not slots then
                    skipped[#skipped + 1] = { id = id, name = name }
                else
                    local lowestEquipped = nil
                    for _, sid in ipairs(slots) do
                        local eq = EC_compCache.getEquippedILvl(sid)
                        if eq > 0 and (lowestEquipped == nil or eq < lowestEquipped) then
                            lowestEquipped = eq
                        end
                    end
                    if not lowestEquipped then
                        skipped[#skipped + 1] = { id = id, name = name }
                    elseif iLvl <= lowestEquipped then
                        stale[#stale + 1] =
                            { id = id, name = name, iLvl = iLvl, lowestEquipped = lowestEquipped }
                    end
                end
            end
        end
    end
    return { stale = stale, deferred = deferred, skipped = skipped }
end

-- Removes the entries flagged as stale by buildStaleUpgradeReport.
-- Pulls them out of both DB.blacklist and DB.blacklistAuto so the tooltip
-- annotation and EC_IsSellable both stop treating them as protected.
-- Returns the count of removed entries.
function EC_compCache.applyStaleUpgradeCleanup(report)
    if not report or not report.stale then
        return 0
    end
    local removed = 0
    for i = 1, #report.stale do
        local id = report.stale[i].id
        if DB.blacklist and DB.blacklist[id] then
            DB.blacklist[id] = nil
        end
        if DB.blacklistAuto and DB.blacklistAuto[id] then
            DB.blacklistAuto[id] = nil
        end
        removed = removed + 1
    end
    return removed
end

-- Handlers for the three operational keybindings (declared in Bindings.xml,
-- labels above with the binding registration block).
function EbonClearance_ToggleSettings()
    if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then
        InterfaceOptionsFrame:Hide()
    else
        InterfaceOptionsFrame_OpenToCategory(MainOptions)
        InterfaceOptionsFrame_OpenToCategory(MainOptions)
    end
end

function EbonClearance_ToggleEnabled()
    EnsureDB()
    DB.enabled = not DB.enabled
    PrintNicef("EbonClearance is now %s.", DB.enabled and "|cff00ff00enabled|r" or "|cffff4444disabled|r")
    PlaySound(DB.enabled and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
end

function EbonClearance_ForceSell()
    EnsureDB()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        PrintNice("|cffff4444Force sell|r: open a merchant first.")
        return
    end
    StartRun()
end

SLASH_EBONCLEARANCE1 = "/ec"
SlashCmdList["EBONCLEARANCE"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then
        InterfaceOptionsFrame_OpenToCategory(MainOptions)
        InterfaceOptionsFrame_OpenToCategory(MainOptions)
        return
    end

    local cmd, rest = msg:match("^(%S+)%s*(.*)")
    cmd = (cmd or ""):lower()
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if cmd == "profile" or cmd == "profiles" then
        local sub, arg = rest:match("^(%S+)%s*(.*)")
        sub = (sub or ""):lower()
        arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")

        if sub == "save" and arg ~= "" then
            EnsureDB()
            -- Discard the boolean ok flag; PrintNice surfaces the failure
            -- message itself for the user. Renamed local from `msg` to
            -- `result` to avoid shadowing the outer slash-input `msg`.
            local _, result = EC_SaveProfile(arg)
            PrintNice(result)
        elseif sub == "load" and arg ~= "" then
            EnsureDB()
            local _, result = EC_LoadProfile(arg)
            PrintNice(result)
        elseif sub == "delete" and arg ~= "" then
            EnsureDB()
            local _, result = EC_DeleteProfile(arg)
            PrintNice(result)
        elseif sub == "list" or sub == "" then
            EnsureDB()
            PrintNice("Whitelist Profiles:")
            local names = {}
            for name in pairs(DB.whitelistProfiles) do
                if type(name) == "string" then
                    names[#names + 1] = name
                end
            end
            table.sort(names, function(a, b)
                return a:lower() < b:lower()
            end)
            for i = 1, #names do
                local wlCount = EC_CountItems(DB.whitelistProfiles[names[i]])
                local blCount = DB.blacklistProfiles[names[i]] and EC_CountItems(DB.blacklistProfiles[names[i]]) or 0
                local tag = (names[i] == DB.activeProfileName) and " |cff00ff00(active)|r" or ""
                PrintNicef("  |cffffff00%s|r - %d whitelist, %d blacklist%s", names[i], wlCount, blCount, tag)
            end
        else
            PrintNice("Usage: /ec profile save|load|delete|list <name>")
        end
        return
    end

    if cmd == "bugreport" then
        EC_ShowBugReport()
        return
    end

    if cmd == "help" or cmd == "?" then
        -- Full reference; the Main panel only shows a 4-line summary so it
        -- fits the default Interface Options sub-panel height. Chat has no
        -- height constraint, so the long list lives here instead.
        PrintNice("|cffffff00=== EbonClearance Slash Commands ===|r")
        PrintNice("|cffffff00/ec|r  Open settings")
        PrintNice("|cffffff00/ec profile list|r  Show all saved profiles")
        PrintNice("|cffffff00/ec profile save <name>|r  Save current whitelist as a profile")
        PrintNice("|cffffff00/ec profile load <name>|r  Load a saved profile")
        PrintNice("|cffffff00/ec profile delete <name>|r  Delete a profile")
        PrintNice("|cffffff00/ec clean|r  Report items present in more than one list")
        PrintNice("|cffffff00/ec clean apply|r  Auto-resolve conflicts (blacklist > deleteList > whitelist)")
        PrintNice("|cffffff00/ec clean upgrades|r  Report stale 'Upgrade'-tagged Blacklist entries no longer above equipped")
        PrintNice("|cffffff00/ec clean upgrades apply|r  Remove the stale 'Upgrade' entries (with confirmation)")
        PrintNice("|cffffff00/ec bugreport|r  Generate a diagnostic report for bug reports")
        PrintNice("|cffffff00/ecdebug|r  Show debug info and bag scan")
        return
    end

    if cmd == "clean" then
        EnsureDB()
        -- v2.12.0: subcommand fork. "/ec clean upgrades [apply]" walks the
        -- DB.blacklistAuto entries with tag "upgrade" and reports / removes
        -- ones that are no longer upgrades vs current gear (cleans up the
        -- spurious entries the v2.11.0 empty-slot bug left on user lists).
        -- Existing "/ec clean [apply]" cross-list conflict resolver is
        -- unchanged.
        if rest == "upgrades" or rest == "upgrades apply" then
            local report = EC_compCache.buildStaleUpgradeReport()
            local nStale = #report.stale
            local nDeferred = #report.deferred
            local nSkipped = #report.skipped
            if nStale == 0 and nDeferred == 0 and nSkipped == 0 then
                PrintNice("|cffaaaaaaNo 'Upgrade'-tagged entries on your Blacklist.|r")
                return
            end
            PrintNicef(
                "|cffffff00%d|r stale 'Upgrade' entr%s found (no longer above your equipped iLvl).",
                nStale,
                nStale == 1 and "y" or "ies"
            )
            if nStale > 0 then
                local cap = math.min(nStale, 10)
                for i = 1, cap do
                    local s = report.stale[i]
                    PrintNicef(
                        "  |cffaaaaaa[%d]|r %s |cffaaaaaa(iLvl %d, equipped %d)|r",
                        s.id,
                        s.name,
                        s.iLvl,
                        s.lowestEquipped
                    )
                end
                if nStale > cap then
                    PrintNicef("  |cffaaaaaa... and %d more.|r", nStale - cap)
                end
            end
            if nDeferred > 0 then
                PrintNicef(
                    "|cffaaaaaaDeferred %d entr%s (item info not loaded; rerun the command later).|r",
                    nDeferred,
                    nDeferred == 1 and "y" or "ies"
                )
            end
            if nSkipped > 0 then
                PrintNicef(
                    "|cffaaaaaaSkipped %d entr%s (no candidate slot populated to compare against).|r",
                    nSkipped,
                    nSkipped == 1 and "y" or "ies"
                )
            end
            if rest == "upgrades apply" and nStale > 0 then
                local dialog = StaticPopup_Show("EC_CONFIRM_CLEAN_UPGRADES", nStale)
                if dialog then
                    dialog.data = function()
                        local removed = EC_compCache.applyStaleUpgradeCleanup(report)
                        PrintNicef(
                            "Removed |cffffff00%d|r stale 'Upgrade' entr%s from the Blacklist.",
                            removed,
                            removed == 1 and "y" or "ies"
                        )
                        local bp = _G["EbonClearanceOptionsBlacklist"]
                        if bp and bp.listUI then
                            bp.listUI:Refresh()
                        end
                    end
                end
            elseif nStale > 0 then
                PrintNice("Run |cffffff00/ec clean upgrades apply|r to remove them.")
            end
            return
        end
        local conflicts = EC_ScanListConflicts()
        EC_PrintConflictReport(conflicts)
        if rest == "apply" and #conflicts > 0 then
            local removed = EC_ApplyCleanResolution(conflicts)
            PrintNicef(
                "Removed |cffffff00%d|r duplicate entr%s (precedence: blacklist > deleteList > whitelist).",
                removed,
                removed == 1 and "y" or "ies"
            )
            local wp = _G["EbonClearanceOptionsWhitelist"]
            if wp and wp.listUI then
                wp.listUI:Refresh()
            end
            local bp = _G["EbonClearanceOptionsBlacklist"]
            if bp and bp.listUI then
                bp.listUI:Refresh()
            end
        elseif #conflicts > 0 then
            PrintNice("Run |cffffff00/ec clean apply|r to auto-resolve (blacklist > deleteList > whitelist).")
        end
        return
    end

    -- Unknown subcommand - open options
    InterfaceOptionsFrame_OpenToCategory(MainOptions)
    InterfaceOptionsFrame_OpenToCategory(MainOptions)
end

SLASH_ECDEBUG1 = "/ecdebug"
SlashCmdList["ECDEBUG"] = function()
    if not DB then
        PrintNice("|cffff4444DB not loaded.|r")
        return
    end
    PrintNice("|cffffff00=== EbonClearance Debug ===|r")
    for q = 1, 4 do
        local r = DB.qualityRules and DB.qualityRules[q] or {}
        local rarityName = (q == 1) and "White"
            or (q == 2) and "Green"
            or (q == 3) and "Blue"
            or "Epic"
        local capStr = (r.maxILvl and r.maxILvl > 0) and tostring(r.maxILvl) or "no cap"
        PrintNicef("Quality[%s]: enabled=%s, max iLvl=%s", rarityName, tostring(r.enabled), capStr)
    end

    -- Print whitelist contents
    local wlCount = 0
    for k, v in pairs(DB.whitelist or {}) do
        local n = GetItemInfo(k) or ("ItemID:" .. tostring(k))
        PrintNicef("  Whitelist[%s] = %s  (%s)", tostring(k), tostring(v), n)
        wlCount = wlCount + 1
    end
    if wlCount == 0 then
        PrintNice("  (whitelist is empty)")
    end

    -- Scan bags and check which items would be sold. v2.13.4: routes
    -- through EC_IsSellable so the debug output reflects every check
    -- the live merchant cycle applies. The previous inline predicate
    -- was missing v2.10.0+ rules (bind filter, Use equipped iLvl,
    -- quest-item safety net, blacklist veto, IsEquippedItem veto)
    -- and silently produced wrong "would sell" answers for items
    -- those checks cover. The breakdown columns (junk/wp/qp) are now
    -- inferred from EC_IsSellable's authoritative outcome plus the
    -- two cheap stable predicates (isJunk and whitelistPass) computed
    -- locally.
    PrintNice("|cffffff00--- Bag scan ---|r")
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local sellable, _, _, _, _ = EC_IsSellable(bag, slot, false)
                if sellable then
                    local name, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
                    local junk = (quality ~= nil) and (quality == 0) and sellPrice and sellPrice > 0
                    local wp = IsInSet(DB.whitelist, itemID)
                        or (ADB and IsInSet(ADB.whitelist, itemID))
                    -- Quality-rule path is whatever's left when the
                    -- authoritative EC_IsSellable says yes but neither
                    -- of the explicit list/junk paths matched.
                    local qp = sellable and not junk and not wp
                    PrintNicef(
                        "|cff00ff00SELL|r bag=%d slot=%d id=%d q=%s junk=%s wp=%s qp=%s sp=%s name=%s",
                        bag,
                        slot,
                        itemID,
                        tostring(quality),
                        tostring(junk),
                        tostring(wp),
                        tostring(qp),
                        tostring(sellPrice),
                        tostring(name)
                    )
                end
            end
        end
    end
    PrintNice("|cffffff00=== End Debug ===|r")
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_CLOSED")
-- BAG_UPDATE drives auto-loot-cycle bag-full detection. Cheap handler;
-- early-returns unless STATE.LOOTING + cycle enabled. See EC_HandleBagFullForCycle.
f:RegisterEvent("BAG_UPDATE")
-- LOOT_CLOSED feeds the loot-silence stuck signal in EC_IsLootSilenceStuck.
-- Pushes one timestamp per corpse looted; pruned lazily on the 5 s pet tick.
-- Only accumulates while DB.autoLootCycle is on, so cycle-off users pay nothing.
f:RegisterEvent("LOOT_CLOSED")
-- UNIT_AURA fires per-unit. The player-only form is much cheaper in raids
-- than an unfiltered registration; fall back on clients that lack it.
if f.RegisterUnitEvent then
    f:RegisterUnitEvent("UNIT_AURA", "player")
else
    f:RegisterEvent("UNIT_AURA")
end
-- v2.9.2: track player-only profession-cast successes so the LOOT_CLOSED
-- handler can suppress the loot-silence ring push when the loot was
-- triggered by a craft / disenchant / mill / prospect / lockpick rather
-- than a corpse loot. RegisterUnitEvent("player") avoids firing for
-- party/raid casts (irrelevant traffic), with the unfiltered fallback
-- for clients that lack it.
if f.RegisterUnitEvent then
    f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
else
    f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end
-- v2.10.0: drives the auto-protect-equipped reactive path. Fires every time
-- the player swaps a gear slot; the handler routes through
-- EC_AutoProtectEquippedSlot which short-circuits when the toggle is off,
-- so users not opted in pay one early-return per swap.
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
-- v2.13.0: drives the Equipment Manager protection re-sync when the user
-- adds, modifies, or deletes a saved equipment set via the Blizzard
-- Equipment Manager. Handler is gated on DB.autoProtectEquipmentSets so
-- users without the toggle on pay one early-return per set save.
f:RegisterEvent("EQUIPMENT_SETS_CHANGED")
-- Wakes the auto-open-containers driver when combat ends. Without this the
-- combat-deferred queue could sit indefinitely if no further BAG_UPDATE
-- arrives. Handler self-gates on DB.autoOpenContainers, so users with the
-- toggle off pay one early-return per combat exit.
f:RegisterEvent("PLAYER_REGEN_ENABLED")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            EnsureDB()
            -- Scrub orphans from the v2.2.0 scoping bug where these names
            -- briefly leaked into _G. Harmless if absent. See v2.2.1 fix.
            _G.EC_summonGoblinPending = nil
            _G.EC_summonGoblinTimer = nil
            HookDeletePopupOnce()
            if ApplyGreedyChatFilter then
                ApplyGreedyChatFilter()
            end
            EC_CreateMinimapButton()
            EC_InstallTooltipHookOnce()
            EC_CreateLDBLauncher()
            EC_CreateTargetMerchantButton()
            EC_InstallBagContextHookOnce()
            EC_manualSell.installHookOnce()
        end
    elseif event == "PLAYER_LOGOUT" then
        if DB then
            EbonClearanceDB = DB
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        EnsureDB()
        if EC_InstallGreedyMuteOnce then
            EC_InstallGreedyMuteOnce()
        end
        -- One-time companion-state bootstrap so the OnUpdate movement
        -- accumulator can start counting immediately if the Scavenger was
        -- already out at /reload (otherwise we wait for the first 5 s tick
        -- to observe the state and lose that much accumulation).
        if not EC_scavStateBootstrapped then
            local _, scavOut = EC_FindGreedyScavenger()
            if scavOut then
                EC_lastScavengerOut = true
            end
            EC_scavStateBootstrapped = true
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended: clear the deferred-announce gate and re-fire the
        -- open driver. If the toggle is off or the queue is empty the
        -- driver early-returns; cost on combat exit for opted-out users is
        -- one branch.
        EC_compCache.combatDeferredAnnounced = false
        EC_HandleAutoOpenContainers()
    elseif event == "EQUIPMENT_SETS_CHANGED" then
        -- v2.13.0: live re-sync of Blizzard equipment-manager sets onto
        -- the Keep list. Silent variant suppresses the chat summary so
        -- save-edit-save cycles in the Equipment Manager UI don't spam.
        if DB and DB.autoProtectEquipmentSets then
            EC_compCache.syncEquipmentSets(true)
            local bp = _G["EbonClearanceOptionsBlacklist"]
            if bp and bp.listUI then
                bp.listUI:Refresh()
            end
        end
    elseif event == "BAG_UPDATE" then
        -- Bag-full handler runs first; the open driver yields via the `running`
        -- guard if the vendor cycle is already active.
        EC_HandleBagFullForCycle()
        EC_HandleAutoOpenContainers()
        -- v2.11.0 auto-protect-upgrades. No-op unless DB.autoProtectUpgrades
        -- is on. Per-itemID dedupe via EC_compCache.upgradeProcessed keeps
        -- the steady-state cost to one GetItemInfo lookup per never-seen
        -- bag item.
        EC_compCache.checkBagsForUpgrades()
    elseif event == "LOOT_CLOSED" then
        -- One push per corpse looted. EC_IsLootSilenceStuck prunes the ring
        -- inside its body (called from the 5 s pet tick), so growth is bounded.
        --
        -- v2.9.2 false-positive guards: LOOT_CLOSED also fires for fishing,
        -- disenchanting, milling, prospecting, lockpicking, and opening
        -- engineered containers. The Scavenger doesn't react to any of those,
        -- so counting them as "loot the pet should have answered" produced
        -- false-positive stuck-and-resummon loops for players crafting in
        -- town. Fishing is excluded via IsFishingLoot(); the profession
        -- spells are excluded by the timestamp window populated from
        -- UNIT_SPELLCAST_SUCCEEDED below.
        if DB and DB.autoLootCycle then
            local skip = false
            if IsFishingLoot and IsFishingLoot() then
                skip = true
            elseif (GetTime() - EC_compCache.lastProfLootCastAt) < EC_compCache.PROF_LOOT_WINDOW_S then
                skip = true
            end
            if not skip then
                EC_recentLootTimes[#EC_recentLootTimes + 1] = GetTime()
            end
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg1 is the unit (always "player" thanks to RegisterUnitEvent),
        -- arg2 is the spell name. Two timestamps get updated here:
        --
        --   * lastProfLootCastAt - only on loot-generating profession
        --     spells. Drives the loot-silence false-positive guard so
        --     the Scavenger isn't accused of going quiet because the
        --     player was disenchanting / milling / prospecting.
        --
        --   * lastPlayerCastAt - on EVERY successful player cast.
        --     Drives the v2.11.0 GCD-aware busy gate so the goblin
        --     summon retry budget isn't burned on CallCompanion calls
        --     the server silently drops during instant-cast rotations.
        local _, spellName = ...
        if spellName and EC_compCache.PROF_LOOT_SPELLS[spellName] then
            EC_compCache.lastProfLootCastAt = GetTime()
        end
        EC_compCache.lastPlayerCastAt = GetTime()
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        -- v2.10.0: auto-protect equipped gear. arg1 is the slot id (1-19);
        -- empty slots fire too (the player just un-equipped). The helper
        -- gates on DB.autoAddEquipped, skips shirt/tabard, and bails when
        -- the slot is empty. On a successful add it prints one targeted
        -- chat line and stamps DB.blacklistAuto so the tooltip annotation
        -- can label the entry as "(auto-protected: equipped)".
        if not (DB and DB.autoAddEquipped) then
            return
        end
        local slot = ...
        if EC_compCache.protectEquipSlot(slot) then
            local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
            local id = link and tonumber(link:match("item:(%d+)"))
            local itemName = (id and GetItemInfo(id)) or "item"
            PrintNicef("Auto-protected |cffb6ffb6%s|r (added to Keep list).", itemName)
            local bp = _G["EbonClearanceOptionsBlacklist"]
            if bp and bp.listUI then
                bp.listUI:Refresh()
            end
        end
    elseif event == "MERCHANT_SHOW" then
        EnsureDB()
        EC_merchantReminderPending = false
        EC_batchTotalSold = 0
        EC_batchTotalGold = 0
        EC_keepBagsFlag = true
        -- v2.9.0: snapshot bag contents BEFORE StartRun fires its first sell.
        -- The hooksecurefunc on UseContainerItem reads this map to attribute
        -- right-click sells (which empty the slot before the hook callback
        -- runs); the worker path is excluded by EC_manualSell.inSelfSell. Captured even
        -- when the addon is disabled for this character so manual sells at a
        -- merchant the user opened by hand are still tracked.
        EC_manualSell.snapshotBags()
        if DB and DB.autoLootCycle then
            EC_lootCycleState = STATE.SELLING
        end
        if not EC_IsAddonEnabledForChar() then
            return
        end
        EC_InstallGreedyMuteOnce()
        StartRun()
    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" and DB and DB.summonGreedy and EC_IsAddonEnabledForChar() then
            local mounted = IsMounted()
            if mounted and not EC_wasMounted then
                -- Only dismiss if the Scavenger is actually out. A bare
                -- DismissGreedyScavenger() on a non-event would set
                -- EC_addonDismissed=true and trick the unmount branch into
                -- "restoring" something the user actively dismissed.
                local _, scavOut = EC_FindGreedyScavenger()
                if scavOut then
                    DismissGreedyScavenger()
                    EC_mountDismissTime = GetTime()
                end
            elseif not mounted and EC_wasMounted then
                -- Restore only if the addon dismissed for the mount. A
                -- manual portrait dismiss before mount-up never set
                -- EC_addonDismissed=true (the mount-up branch above gates
                -- on `if scavOut` first), so this naturally honours it.
                if EC_addonDismissed then
                    EC_SummonGreedyWithDelay()
                end
            end
            EC_wasMounted = mounted
        end
    elseif event == "MERCHANT_CLOSED" then
        running = false
        worker:Hide()
        pendingDelete = nil
        -- Reset cycle state so the stuck detection can re-summon the Scavenger
        if EC_lootCycleState == STATE.SELLING then
            EC_lootCycleState = STATE.IDLE
        end
        -- Reopen bags after merchant closes
        if DB and DB.keepBagsOpen and EC_keepBagsFlag then
            EC_Delay(0.8, EC_OpenAllBags)
        end
        EC_keepBagsFlag = false
    end

    if event == "PLAYER_LOGIN" then
        EC_Delay(1, function()
            -- v2.12.0: branch on first-run state. Fresh installs see the
            -- expanded welcome explaining defaults + a setup popup.
            -- Existing characters keep the unchanged single-line welcome.
            if DB and DB._needsWelcome then
                DB._needsWelcome = nil
                PrintNice("|cffffff00Welcome to EbonClearance!|r Out of the box:")
                PrintNice("  |cffaaaaaa-|r Greys auto-sell at any merchant.")
                PrintNice(
                    "  |cffaaaaaa-|r Whites and greens with iLvl below your equipped gear "
                        .. "auto-sell on next merchant visit."
                )
                PrintNice(
                    "  |cffaaaaaa-|r Equipped gear and looted upgrades are auto-added to "
                        .. "your Keep list (never sold)."
                )
                PrintNice(
                    "Type |cff00ff00/ec|r to customise, or pick a setup mode in the popup."
                )
                EC_Delay(0.5, function()
                    StaticPopup_Show("EC_WELCOME")
                end)
            else
                PrintNice("Enabled. Use |cff00ff00/ec|r to configure.")
            end
            -- Fresh-install one-shot equipped sync. Set in EnsureDB only
            -- when the SavedVariable was nil at first ADDON_LOADED, so
            -- existing characters never trigger this. The 2 s extra
            -- defer (on top of the 1 s welcome delay) gives inventory
            -- APIs time to settle before walking the slots.
            if EC_compCache.pendingFreshInstallSync then
                EC_compCache.pendingFreshInstallSync = nil
                EC_Delay(2, function()
                    if EC_compCache.syncEquipped then
                        EC_compCache.syncEquipped()
                    end
                end)
            end
            -- v2.13.0 ElvUI bag buttons. ElvUI's container frame is
            -- constructed lazily during its own load sequence; the 2 s
            -- defer (on top of the 1 s PLAYER_LOGIN delay) is borrowed
            -- from AutoDelete's matching feature and is enough on every
            -- realm we've seen. Self-gates on _G.ElvUI_ContainerFrame at
            -- call time, so non-ElvUI users pay one nil-check per login.
            EC_Delay(2, function()
                if EC_compCache.buildElvUIBagButtons then
                    EC_compCache.buildElvUIBagButtons()
                end
            end)
        end)
    end
end)
