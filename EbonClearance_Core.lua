-- EbonClearance_Core - provenance, fingerprint, and shared junk-drawer state.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 2 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. This file owns the chunks that have no dependencies on anything
-- else in the addon AND that EbonClearance.lua used to define at the top
-- of its own main chunk:
--
--   * Provenance globals (EBONCLEARANCE_* and __EbonClearance_* writes
--     required by LICENSE §2(d)).
--   * The EC_Fingerprint salted djb2 helper. Exposed as NS.Fingerprint.
--   * The EC_compCache junk-drawer table. Exposed as NS.compCache.
--
-- Things that did NOT move in this stage:
--   * ADDON_VERSION - CI's release workflow `sed` rule targets the
--     `local ADDON_VERSION = "..."` line in EbonClearance.lua by name.
--     Moving it would require updating .github/workflows; deferred to
--     a later split stage.
--   * The watermark global write (depends on ADDON_VERSION).
--   * EC_GetVersion (depends on ADDON_VERSION).
--   * STATE / EC_lootCycleState and the API cached upvalues - those are
--     still in EbonClearance.lua and will move in a later stage.
--
-- This file loads BEFORE EbonClearance.lua per the .toc, so anything
-- it puts on NS is reachable to EbonClearance.lua's main chunk at load.

local NS = select(2, ...)

-- Provenance. Mirrored into globals so the origin/author are visible to any
-- /run introspection, addon-management tool, or crash trace. LICENSE section
-- 2(d) requires these globals to be preserved in any derivative. The
-- double-underscore-prefix-with-addon-name form follows a convention shared
-- elsewhere in the 3.3.5a addon ecosystem; see NOTICE.md for the prior-art
-- acknowledgement. EBONCLEARANCE_IDENT is set inline (no local) because the
-- display-name string only appears in this one assignment; ADDON_AUTHOR and
-- ADDON_URL stay as locals because the settings byline (still in
-- EbonClearance.lua, reached via NS.ADDON_AUTHOR / NS.ADDON_URL) reads them
-- too.
local ADDON_AUTHOR = "Serv"
local ADDON_URL = "https://github.com/powerfulqa/EbonClearance"
_G["EBONCLEARANCE_IDENT"] = "EbonClearance"
_G["EBONCLEARANCE_AUTHOR"] = ADDON_AUTHOR
_G["EBONCLEARANCE_ORIGIN"] = ADDON_URL
_G["__EbonClearance_origin"] = ADDON_URL
_G["__EbonClearance_author"] = ADDON_AUTHOR
NS.ADDON_AUTHOR = ADDON_AUTHOR
NS.ADDON_URL = ADDON_URL

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
NS.Fingerprint = EC_Fingerprint

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
    -- v2.20.0 Chance-on-hit cache. Same per-itemID caching pattern as
    -- bindCache: chance-on-hit is a stable property (same itemID
    -- always either has or doesn't have the proc line), so we cache
    -- the boolean result keyed by itemID and skip the tooltip scan on
    -- subsequent lookups. Cache resets naturally on /reload because
    -- this table lives in the module-local EC_compCache and isn't
    -- persisted. Filled lazily by EC_compCache.itemHasChanceOnHit.
    chanceOnHitCache = {},
    -- v2.22.0 Process-mode cache. Maps itemID to one of
    -- "Disenchant" | "Mill" | "Prospect" | "none", or nil if not yet
    -- scanned. Stable property per itemID. Filled lazily by the
    -- can* helpers below.
    processCache = {},
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
    -- v2.7.0 / v2.8.0 loot-silence stuck signal: timestamp of the most
    -- recent observed Scavenger chat speech (set by EC_GreedyEventFilter
    -- via author + body matches). Read by EC_IsLootSilenceStuck on every
    -- pet-tick to compare against the LOOT_CLOSED ring; if the last loot
    -- close postdates the last speech AND the silent-realm guard
    -- (scavSpeechEverHeard) is true, the signal trips and the pet gets
    -- a stuck-resummon. Lives on EC_compCache (instead of as a file-
    -- scope local) so Companion code in EbonClearance_Companion.lua and
    -- EC_IsLootSilenceStuck in EbonClearance.lua can both update / read
    -- it via the same shared cache table after the Stage 3 file split.
    lastScavSpokeAt = 0,
    -- Vendor cycle gate. Set to true while the worker frame is processing
    -- the sell/delete queue, false otherwise. Multiple cross-cutting
    -- paths read it as a "skip while a vendor cycle is mid-flight"
    -- guard (BAG_UPDATE handlers, mount cycle, scav-recovery summon,
    -- auto-open driver). Lives on EC_compCache so EbonClearance_Vendor.lua
    -- can write it from inside the worker and EbonClearance.lua's
    -- non-vendor handlers can read it via the same shared cache table
    -- after the Stage 5 file split.
    vendorRunning = false,
    -- Deletion-confirmation popup state. Set by DoNextAction when a
    -- deletion needs the user to confirm via the StaticPopupDialog, read
    -- by the HookDeletePopupOnce OnUpdate. Cleared at MERCHANT_CLOSED so
    -- a vendor cycle that exits mid-deletion doesn't leave the popup
    -- armed. Lives on EC_compCache for the same reason as vendorRunning
    -- above - cross-file access between Vendor and the event hub.
    pendingDelete = nil,
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
-- Mirror the junk-drawer table onto the addon namespace. Same table; both
-- names alias the same memory. EbonClearance.lua re-binds this as its own
-- module-local `EC_compCache` upvalue so existing call sites keep working
-- without churn. Stage 1 of the file split established this alias; Stage 2
-- moved the declaration into Core.
NS.compCache = EC_compCache
