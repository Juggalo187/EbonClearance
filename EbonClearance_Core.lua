-- EbonClearance_Core - provenance, fingerprint, and shared junk-drawer state.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Owns the chunks that have no dependencies on anything else in the addon:
--
--   * Provenance globals (EBONCLEARANCE_* and __EbonClearance_* writes
--     required by LICENSE §2(d)).
--   * The EC_Fingerprint salted djb2 helper. Exposed as NS.Fingerprint.
--   * The EC_compCache junk-drawer table. Exposed as NS.compCache.
--
-- ADDON_VERSION, EC_GetVersion, the watermark write, STATE / EC_lootCycleState,
-- and the API cached upvalues live in EbonClearance_Events.lua because the
-- release workflow's sed rule targets that file by name.
--
-- This file loads FIRST per the .toc, so anything it puts on NS is reachable
-- to every other split file's main chunk at load.

local NS = select(2, ...)

-- Provenance. Mirrored into globals so the origin/author are visible to any
-- /run introspection, addon-management tool, or crash trace. LICENSE section
-- 2(d) requires these globals to be preserved in any derivative. The
-- double-underscore-prefix-with-addon-name form follows a convention shared
-- elsewhere in the 3.3.5a addon ecosystem; see NOTICE.md for the prior-art
-- acknowledgement. EBONCLEARANCE_IDENT is set inline (no local) because the
-- display-name string only appears in this one assignment; ADDON_AUTHOR and
-- ADDON_URL stay as locals because the settings byline in
-- EbonClearance_Events.lua reads them via NS.ADDON_AUTHOR / NS.ADDON_URL.
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

-- Set-membership helper. Single canonical definition for the addon; the
-- consuming files (Vendor, Process, Tooltip, BagContextMenu, BagDisplay,
-- Events) bind it as `local IsInSet = NS.IsInSet` at file head so the
-- per-call cost is one local read, identical to the previous file-local
-- function pattern. Centralising the definition fixes the Stage 7
-- regression where one of the split files silently dropped its local
-- copy: `tests/test_perf_guardrails.lua` Test 65 still enforces the
-- per-file invariant via the `local IsInSet = ...` import line.
--
-- Strict semantics: only `true` or `1` count as membership. The pre-
-- unification BagDisplay and Vendor copies used a more permissive
-- `~= nil` check, but DB / ADB only ever stores `true` (verified by
-- audit), so the strict version is a no-op semantic narrowing on
-- current data and a safety improvement against hand-edited
-- SavedVariables.
function NS.IsInSet(setTable, itemID)
    if not itemID or not setTable then
        return false
    end
    local v = setTable[itemID]
    return (v == true) or (v == 1)
end

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
    -- v2.44.0: Resilience-detection cache. PvP gear on most servers
    -- has Resilience as a stat line and `sellPrice = 0` (unsellable
    -- at vendors). Murlocked asked for an option to auto-mark such
    -- items for deletion. Like the chance-on-hit cache, the property
    -- is stable per itemID (an item either has the stat or doesn't),
    -- so we cache lazily and never need to invalidate. Filled by
    -- EC_compCache.itemHasResilience.
    resilienceCache = {},
    -- Tome caches. Two tables because the two properties decay at
    -- different rates:
    --   * tomeCache - is-a-tome boolean. Stable per itemID (an item
    --     that teaches a spell ALWAYS teaches that spell), so the
    --     entry never needs invalidation. Filled lazily by
    --     EC_compCache.itemIsTome.
    --   * tomeIsKnownCache - has-player-learned-the-spell boolean.
    --     Character-state-sensitive: flips false -> true the moment
    --     the player right-clicks a recipe or trains a spell. The
    --     LEARNED_SPELL_IN_TAB / SPELLS_CHANGED handler wipes this
    --     table so the next lookup re-scans the tooltip for the
    --     "Already known" line (ITEM_SPELL_KNOWN). Filled lazily by
    --     EC_compCache.playerKnowsTomeSpell.
    tomeCache = {},
    tomeIsKnownCache = {},
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
    -- EC_IsLootSilenceStuck in EbonClearance_Events.lua can both update / read
    -- it via the same shared cache table after the Stage 3 file split.
    lastScavSpokeAt = 0,
    -- Vendor cycle gate. Set to true while the worker frame is processing
    -- the sell/delete queue, false otherwise. Multiple cross-cutting
    -- paths read it as a "skip while a vendor cycle is mid-flight"
    -- guard (BAG_UPDATE handlers, mount cycle, scav-recovery summon,
    -- auto-open driver). Lives on EC_compCache so EbonClearance_Vendor.lua
    -- can write it from inside the worker and EbonClearance_Events.lua's
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
    -- Auto-loot cycle state machine. Promoted from file-scope `local
    -- EC_lootCycleState = STATE.IDLE` in EbonClearance_Events.lua so split files
    -- (the bug-report builder in Stage 8, and potentially future cycle
    -- code) can read it as a snapshot. The string values match the STATE
    -- constants table also declared in EbonClearance_Events.lua's main chunk
    -- (STATE = { IDLE = "idle", LOOTING = "looting", WAITING_MERCHANT =
    -- "waiting_merchant", SELLING = "selling" }).
    lootCycleState = "idle",
    -- Last-tick value of "is the Scavenger summoned?". Promoted from
    -- `local EC_lastScavengerOut = false`. Read by the pet-tick OnUpdate's
    -- movement accumulator and by the bug-report snapshot.
    lastScavengerOut = false,
    -- "WE just dismissed the Scavenger and a resummon is pending"
    -- flag. Promoted from `local EC_addonDismissed = false`. Set by the
    -- mount handler and various recovery paths; cleared by the pet-tick
    -- when the Scavenger comes back out.
    addonDismissed = false,
    -- Baseline-protected itemIDs: profession tools the player needs to
    -- keep around to perform their profession (fishing poles, mining
    -- picks, the engineering Arclight Spanner, skinning knife, blacksmith
    -- hammer). Reported by user Monrad after EC auto-sold their tools
    -- through a White-rule sweep. Mirrors the v2.13.x quest-item narrowing
    -- design: this safety net vetoes qualityPass (auto-rule sweeps) but
    -- NOT whitelistPass (explicit Sell List entries) - the user's lists
    -- are authoritative. ADB.allowedItems[itemID] also bypasses the
    -- safety net for the per-item Allow Sell override case.
    --
    -- Item IDs are WoW WotLK 3.3.5a standard. Project Ebonhold custom
    -- profession tools (if any) need to be added by the user via Keep
    -- List or Allow Sell override.
    baselineProtectedIDs = {
        -- Fishing poles (all are itemSubType "Fishing Poles" weapons
        -- equipped in main hand for fishing).
        [6256]  = true, -- Fishing Pole
        [6365]  = true, -- Strong Fishing Pole
        [6366]  = true, -- Darkwood Fishing Pole
        [6367]  = true, -- Big Iron Fishing Pole
        [12225] = true, -- Blump Family Fishing Pole
        [19022] = true, -- Nat Pagle's Extreme Angler FC-5000
        [19970] = true, -- Arcanite Fishing Pole
        [25979] = true, -- Seth's Graphite Fishing Pole
        [44050] = true, -- Mastercraft Kalu'ak Fishing Pole
        [45858] = true, -- Bone Fishing Pole
        [46337] = true, -- Staats' Fishing Pole
        -- Mining picks (required to mine nodes; the basic Mining Pick
        -- 2901 is the trigger Monrad reported).
        [2901]  = true, -- Mining Pick
        [20723] = true, -- Brann's Trusty Pick
        [40772] = true, -- Hammer Pick
        [40892] = true, -- Mammoth Mining Pick
        -- Engineering tool (required to use some Engineering devices;
        -- Monrad reported the Arclight Spanner specifically).
        [6219]  = true, -- Arclight Spanner
        -- Skinning Knife (required to skin corpses).
        [7005]  = true, -- Skinning Knife
        -- Blacksmith Hammer (required for some Blacksmithing recipes).
        [5956]  = true, -- Blacksmith Hammer
    },
    -- v2.11.0 bag-full hysteresis. Without this, a single transient
    -- BAG_UPDATE that crosses DB.bagFullThreshold (a vendor opening up,
    -- an item splitting, an inventory shuffle) immediately fires the
    -- dismiss-Scav / summon-Goblin cycle even if the next tick puts the
    -- count back over the threshold. A similar same-niche addon ships
    -- a 1.5 s confirm window for the same reason. bagFullSince is timestamped at
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
-- names alias the same memory. EbonClearance_Events.lua re-binds this as its own
-- module-local `EC_compCache` upvalue so existing call sites keep working
-- without churn. Stage 1 of the file split established this alias; Stage 2
-- moved the declaration into Core.
NS.compCache = EC_compCache
