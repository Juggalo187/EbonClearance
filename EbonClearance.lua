-- EbonClearance - bag manager for Project Ebonhold (3.3.5a): vendoring,
-- deletion, looting, protection rules, profession processing.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.

-- Shared namespace for the addon. WoW passes (addonName, namespaceTable) as
-- the varargs to every .lua file in an addon; the same table is shared
-- across files. NS exists from the first stage of the multi-release file
-- split planned in docs/CODE_REVIEW.md item 4 ("File split"). Stage 1
-- (this commit) bootstraps the namespace without moving any code -
-- existing file-scope locals stay as upvalue captures, and module-level
-- helpers that need to be reachable from future split files get mirrored
-- onto NS as the split progresses. Reading or writing NS.foo from any
-- future EbonClearance_*.lua file picks up the same table this assignment
-- creates. `select(2, ...)` is used instead of `local addonName, NS = ...`
-- because the main chunk is already at Lua 5.1's 200-locals cap; capturing
-- only the namespace (and not the addon name string, which we don't use)
-- spends one slot instead of two.
local NS = select(2, ...)

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

-- Provenance globals (EBONCLEARANCE_* and __EbonClearance_*) plus the
-- EC_Fingerprint helper now live in EbonClearance_Core.lua per the file
-- split (Stage 2, see docs/CODE_REVIEW.md item 4). Core writes those
-- globals on load and exposes the helper as NS.Fingerprint; we re-bind
-- the byline strings here from the namespace because the settings panel
-- byline (still defined in this file) reads them as upvalues.
local ADDON_AUTHOR = NS.ADDON_AUTHOR
local ADDON_URL = NS.ADDON_URL

-- Build-time version. The release workflow's sed rule rewrites the
-- `local ADDON_VERSION = "vX.Y.Z"` line on each tag push (anchored
-- pattern fixed in v2.13.2), so the in-game UI surfaces (settings
-- panel header, bug-report builder, anything routed through EC_GetVersion)
-- always match the .toc on a release build. Dev checkouts keep
-- whatever real version the last release shipped; EC_GetVersion's
-- match check accepts any `^v%d+%.%d+%.%d+` value and short-circuits
-- to it. The fallback to GetAddOnMetadata exists for the legacy
-- placeholder case but is no longer reached on the current workflow.
-- Carrying the version here means a stale .toc cache (WoW only re-reads
-- .toc files on full client restart, not /reload) cannot make the displayed
-- version lie on a release build. The CI test in
-- tests/test_layout_reactivity.lua asserts this constant matches the
-- .toc Version field so any future drift fails CI before shipping.
-- DO NOT move this constant out of EbonClearance.lua without first
-- updating the CI workflow's sed rule that targets this file by name.
local ADDON_VERSION = "v2.30.0"
local function EC_GetVersion()
    if ADDON_VERSION:match("^v%d+%.%d+%.%d+") then
        return ADDON_VERSION
    end
    return GetAddOnMetadata("EbonClearance", "Version") or "unknown"
end

-- Build watermark: a precomputed fingerprint of "EbonClearance@<version>".
-- Exposed as a global so /run inspection and external auditors can read it.
-- If this exact 6-char hex value (computed for our version) ever appears in
-- another addon's source, that addon is a verbatim copy of EbonClearance.
-- Lives in this file (not Core) because it reads ADDON_VERSION, which
-- has to stay here for CI sed-rule compatibility.
_G["__EbonClearance_watermark"] = NS.Fingerprint("EbonClearance@" .. ADDON_VERSION)

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
-- Cached companion creature IDs and v2.9.0 dismiss-vs-leash classifier state.
-- The actual table literal lives in EbonClearance_Core.lua (Stage 2 of the
-- file split, see docs/CODE_REVIEW.md item 4) and is exposed on the addon
-- namespace as NS.compCache. We re-bind it to the file-scope upvalue here
-- so every existing `EC_compCache.foo` reference downstream resolves
-- correctly without per-site changes. Same table; both names alias the
-- same memory. Comments documenting individual fields (scav, lastSummonAt,
-- bindCache, etc.) live next to the declaration in Core.
local EC_compCache = NS.compCache

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
-- on the chat-event path. Lives on EC_compCache (declared in
-- EbonClearance_Core.lua) so EbonClearance_Companion.lua's chat filter and
-- EbonClearance.lua's EC_IsLootSilenceStuck can both access it via the
-- shared cache table after the file split. See docs/CODE_REVIEW.md item 4.
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
-- vendorRunning state was promoted from `local running = false` to
-- EC_compCache.vendorRunning (initialised in EbonClearance_Core.lua's
-- table literal) so EbonClearance_Vendor.lua can write it and the
-- non-vendor handlers in this file can read it via the shared cache
-- table after the Stage 5 file split.

-- The Greedy Scavenger chat filter, the speech-bubble killer, and
-- the secondary ApplyGreedyChatFilter live in EbonClearance_Companion.lua
-- (Stage 3 of the file split, see docs/CODE_REVIEW.md item 4). Companion
-- exposes NS.InstallGreedyMuteOnce and NS.ApplyGreedyChatFilter, which
-- the event hub + ADDON_LOADED branch + DB toggles further down this
-- file call by name.

-- Forward-declared so EC_AddItemToList (defined below) can call it before the
-- helper body is reached further down the file. Returns the name of a list
-- that already holds the item with a different intent (keep / sell / delete),
-- or nil when the add is safe. Same-intent scopes (character whitelist plus
-- account whitelist) do not conflict.
local EC_FindAddConflict

-- Forward-declared on NS so the Character Settings panel's toggle +
-- colour-picker closures can call it before the bag-display hooks (which
-- own the body) install. Stub-assigned to a no-op here so settings flips
-- work even before the hooks register. The real body is assigned by
-- EbonClearance_BagDisplay.lua (Stage 6 of the file split, see
-- docs/CODE_REVIEW.md item 4). Lives on NS rather than as a file-scope
-- local because the body assignment is in a different file post-Stage-6;
-- a `local` here would mean BagDisplay's assignment creates a global
-- instead of replacing the stub. Callers reach it as NS.RefreshSellBorders.
NS.RefreshSellBorders = function() end

local PET_NAME_LC = PET_NAME:lower()
-- Initial namespace exposure (before EnsureDB runs). EnsureDB and
-- EC_compCache.refreshNames rewrite these once the saved DB names are
-- known. Split files (Companion) read NS.PET_NAME_LC inline at call time
-- so they always see the current value.
NS.PET_NAME = PET_NAME
NS.TARGET_NAME = TARGET_NAME
NS.PET_NAME_LC = PET_NAME_LC

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
    -- Mirror the live ADB binding onto the namespace so split files (post-
    -- Stage 3) can read NS.ADB inline at call time. Same table; both
    -- names alias the same memory. See docs/CODE_REVIEW.md item 4.
    NS.ADB = ADB
    if type(ADB.whitelist) ~= "table" then
        ADB.whitelist = {}
    end
    EC_ExtraListTables["accountWhitelist"] = ADB.whitelist
    -- v2.26.0 / v2.27.0: account-wide override list for the v2.20.0
    -- chance-on-hit protection AND the v2.23.0 random-affix
    -- protection. Marking an itemID releases the safety net so
    -- future drops auto-sell via the normal quality rules and
    -- become eligible for Process Bags. Account-wide because both
    -- PE's affix / proc extractions are themselves account-wide and
    -- whether to keep / sell a protected item is an item-property
    -- decision, not a per-character one.
    --
    -- Migrated from the v2.26.0 `allowedProcs` field. New name
    -- (`allowedItems`) reflects that the list now covers both
    -- protection mechanisms; the old name was misleading for
    -- affixed items. One-shot migration: contents move across,
    -- the old field clears.
    if type(ADB.allowedItems) ~= "table" then
        ADB.allowedItems = {}
    end
    -- v2.27.0: affix-keyed allow list. Random-affix items carry their
    -- identity in the affix description (per-instance roll), so a
    -- per-itemID mark is too coarse - it'd let every base-itemID drop
    -- through regardless of which affix rolled. This list is keyed by
    -- the normalised affix description (same key the v2.23.0
    -- knownAffixDescriptions set uses), so marking one drop allows
    -- every future drop rolling the same affix even across different
    -- base items.
    if type(ADB.allowedAffixes) ~= "table" then
        ADB.allowedAffixes = {}
    end
    -- One-shot migration: case-fold existing keys to match the post-fix
    -- normaliser. Prior to this version the normaliser preserved source
    -- casing, so entries stored from a description that began with a
    -- capital letter would no longer match a lookup that now produces
    -- a lowercase key. Walk the table, lowercase any key that isn't
    -- already pure-lower, and carry the value across. Idempotent on
    -- subsequent loads (lowercased keys equal their own lowered form).
    do
        local migrated, remapped = false, {}
        for k, v in pairs(ADB.allowedAffixes) do
            if type(k) == "string" then
                local lk = k:lower()
                if lk ~= k then
                    remapped[lk] = v
                    ADB.allowedAffixes[k] = nil
                    migrated = true
                end
            end
        end
        if migrated then
            for k, v in pairs(remapped) do
                ADB.allowedAffixes[k] = v
            end
        end
    end
    -- v2.27.0: side meta marking which Sell/Keep/Delete list entries
    -- came in via an affixed-item menu add. Lets the list panels
    -- render an "(affix-gated)" tag on those rows so the user knows
    -- the entry doesn't blanket-sell every drop of that itemID -
    -- the affix protection still filters per-drop. Account-scoped
    -- because the affix-ness of an itemID is an item property
    -- (random-suffix DBC field), not a per-character thing.
    if type(ADB.affixedListedItems) ~= "table" then
        ADB.affixedListedItems = {}
    end
    -- One-shot migration from the v2.26.0 field `allowedProcs`.
    -- rawget avoids the EnsureDefaults pattern's auto-create when
    -- the legacy field has already been migrated away.
    local legacy = rawget(ADB, "allowedProcs")
    if type(legacy) == "table" then
        for k, v in pairs(legacy) do
            ADB.allowedItems[k] = v
        end
        ADB.allowedProcs = nil
    end
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
    -- Mirror the live DB binding onto the namespace so split files can
    -- read NS.DB inline at call time. Same table; both names alias the
    -- same memory. EnsureAccountDB() below does the same for ADB. See
    -- docs/CODE_REVIEW.md item 4.
    NS.DB = DB
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
    -- v2.19.0: Project Ebonhold's roguelite system randomly applies
    -- "affix" suffixes to dropped items (e.g. `Thorbia's Gauntlets of
    -- Fortified by Pain IV` is the same itemID as the base
    -- `Thorbia's Gauntlets` but has a random suffix and an attached
    -- proc effect). A user with the base itemID on their Sell List or
    -- Delete List would inadvertently dump the affixed version, which
    -- is meaningfully different gear. This toggle gates the affix-
    -- check that skips affixed Rare/Epic instances at sell/delete
    -- decision time. Default ON because it's a safety net; users who
    -- want pre-v2.19.0 behaviour toggle it off. See
    -- EC_compCache.bagSlotHasAffix / liveTooltipHasAffix for the
    -- two-layer detection (link suffix-DBC field, then tooltip-title
    -- name-compare fallback for any custom PE mechanism).
    if type(DB.protectAffixedRareItems) ~= "boolean" then
        DB.protectAffixedRareItems = true
    end
    -- v2.23.0: Exact-rank duplicate gate on the affix protection.
    -- When ON, an affixed bag item that matches the player's already-
    -- known (affixName, rank) pair via PE's PerkService is allowed to
    -- fall through to the normal sell / DE rules. Different ranks of
    -- the same affix stay protected so the player can still collect
    -- all four. Defaults OFF so v2.22.0 upgraders see no behaviour
    -- change. Inert when Project Ebonhold isn't loaded (the per-rank
    -- known-set is empty so nothing matches).
    if type(DB.affixAllowExactDupes) ~= "boolean" then
        DB.affixAllowExactDupes = false
    end
    -- v2.20.0: Chance-on-hit protection. PE lets players EXTRACT proc
    -- spells from weapons (the green `Chance on hit:` tooltip line)
    -- and apply them to other items, so an item with a Chance-on-hit
    -- proc is meaningfully different from the base itemID even when
    -- the user lists the base for selling. Default ON; users who
    -- don't use the extraction system can toggle it off. No quality
    -- filter (the proc text is the signal, not the rarity).
    if type(DB.protectChanceOnHitItems) ~= "boolean" then
        DB.protectChanceOnHitItems = true
    end
    -- v2.22.0: Process Bags panel. Lets the player batch-cast their
    -- profession spells (Disenchant / Mill / Prospect) on eligible
    -- bag items via a secure-button macro. Soulbound DE is opt-in
    -- (default OFF) because it's irreversible; DE quality cap
    -- defaults to Epic (max permissive). Ignored items are
    -- per-character (DB, not ADB) since profession alts vary.
    if type(DB.processIncludeSoulbound) ~= "boolean" then
        DB.processIncludeSoulbound = false
    end
    if type(DB.processMaxDEQuality) ~= "number" or DB.processMaxDEQuality < 2 or DB.processMaxDEQuality > 4 then
        DB.processMaxDEQuality = 4
    end
    if type(DB.processIgnored) ~= "table" then
        DB.processIgnored = {}
    end
    -- v2.25.0: Lockpick mode in Process Bags. Adds a fourth mode (DE /
    -- Mill / Prospect / Lockpick) for rogues, listing locked containers
    -- in bags and driving Pick Lock via the existing SecureActionButton
    -- workflow. Inert on non-rogues (IsSpellKnown(1804) is false).
    -- Enabled by default since the entry point is the panel itself.
    if type(DB.lockpickEnabled) ~= "boolean" then
        DB.lockpickEnabled = true
    end
    -- Optional combat-exit chat hint: "N lockbox(es) available. Click
    -- Process Next to open." Default off (one extra line on every
    -- combat exit gets noisy for opted-in users with many lockboxes).
    if type(DB.lockpickNotifyOnCombatExit) ~= "boolean" then
        DB.lockpickNotifyOnCombatExit = false
    end
    -- v2.25.0: per-mode collapsed state for the Process Bags panel.
    -- Each key (Disenchant / Mill / Prospect / Lockpick) maps to true
    -- when the player has collapsed that section. Persisted so the
    -- preference survives /reload and login. Default empty (all
    -- expanded). Cursor logic in rearmProcessButton skips entries
    -- whose mode is in this set.
    if type(DB.processCollapsedModes) ~= "table" then
        DB.processCollapsedModes = {}
    end
    -- v2.16.0: Fast Loot. When on AND Blizzard's auto-loot CVar is
    -- effectively enabled, EC_HandleLootReady queues every slot in the
    -- loot window for draining, so the loot frame flashes briefly or
    -- skips entirely. Pairs with the auto-loot cycle: faster per-kill
    -- looting = bag-full threshold trips sooner = vendor cycle turns
    -- over faster. Default off so existing users keep the standard
    -- loot-window behaviour and BoP-bind safety prompts. Pattern
    -- borrowed from FasterLoot (others/FasterLoot/FasterLoot.lua).
    --
    -- v2.21.0 retrofit: drain is now queue-based with a ~110 ms
    -- throttle per slot (was: tight loop over GetNumLootItems in one
    -- frame), reducing disconnect risk on busy private servers. The
    -- toggle, schema, and BoP-bind auto-confirm are unchanged from
    -- v2.16.0; only the internal draining is refactored.
    if type(DB.fastLoot) ~= "boolean" then
        DB.fastLoot = false
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
    -- Opt-in slot-frame border tint that highlights bag items the current
    -- rule chain would sell at the next vendor visit. Texture sits on a
    -- frame-overlay sublevel ABOVE the slot's quality-border but does not
    -- draw on the icon itself, so the icon canvas stays untouched.
    -- Off by default; users opt in via the Character Settings panel and
    -- pick their own colour through the standard colour-picker dialog.
    if type(DB.sellBorderEnabled) ~= "boolean" then
        DB.sellBorderEnabled = false
    end
    if type(DB.sellBorderColor) ~= "table" then
        DB.sellBorderColor = { r = 1.0, g = 0.82, b = 0.0, a = 0.9 }
    else
        -- Repair partially-corrupted saves so a missing component never
        -- blanks the border. Each channel falls back to the default if it
        -- isn't a number in [0, 1].
        local c = DB.sellBorderColor
        local function clamp01(v, fallback)
            if type(v) ~= "number" or v ~= v then
                return fallback
            end
            if v < 0 then
                return 0
            end
            if v > 1 then
                return 1
            end
            return v
        end
        c.r = clamp01(c.r, 1.0)
        c.g = clamp01(c.g, 0.82)
        c.b = clamp01(c.b, 0.0)
        c.a = clamp01(c.a, 0.9)
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
    -- Mirror onto NS so split files (the chat filter in
    -- EbonClearance_Companion.lua, post-Stage-3) can read the live names
    -- without each owning its own upvalue rebind hook. Refreshed everywhere
    -- the file-scope names get rebound (EnsureDB here and refreshNames below).
    NS.PET_NAME = PET_NAME
    NS.TARGET_NAME = TARGET_NAME
    NS.PET_NAME_LC = PET_NAME_LC
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
-- Expose to split files. Process Bags (Stage 7+) gates its operations
-- on this; any future per-character feature can read it via NS.
NS.IsAddonEnabledForChar = EC_IsAddonEnabledForChar

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
    return true, string.format('Saved profile "|cffffff00%s|r" (%d sell, %d keep).', name, wlCount, blCount)
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
    return true, string.format('Loaded profile "|cffffff00%s|r" (%d sell, %d keep).', name, wlCount, blCount)
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

-- Expose to split files (Stage 6+ uses NS.PrintNice / NS.PrintNicef from
-- EbonClearance_BagDisplay.lua's sellinfo trace output). EbonClearance.lua's
-- own call sites keep using the file-scope upvalues.
NS.PrintNice = PrintNice
NS.PrintNicef = PrintNicef

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
    -- Mirror the live names onto NS for split files (see EnsureDB above
    -- for the same writes; refreshNames is the lightweight UI-handler
    -- variant and must keep the namespace in lockstep).
    NS.PET_NAME = PET_NAME
    NS.TARGET_NAME = TARGET_NAME
    NS.PET_NAME_LC = PET_NAME_LC
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
        -- v2.13.8: print the recovery acknowledgement line on this happy
        -- path too, not just in EC_TryResummonScavenger's busy-gate-
        -- recovery branch. Historically the line was firing only when
        -- the cycle was slow enough that SummonGreedyScavenger got
        -- busy-gated and the pet-tick had to take over via
        -- EC_TryResummonScavenger; on the happy path
        -- (CallCompanion succeeds directly) the pet-tick observed the
        -- false->true transition and silently cleared pendingAnnounce
        -- without printing. The user expected the line as a close-out
        -- on every bag-full cycle. Print it here so the close-out fires
        -- regardless of which path actually completed the summon.
        if EC_compCache.pendingAnnounce then
            PrintNice("|cff00ff00Greedy Scavenger resummoned.|r")
            EC_compCache.pendingAnnounce = false
        end
        -- v2.11.0: do NOT clear EC_addonDismissed here. A combat
        -- keypress that lands in the same client tick as CallCompanion
        -- can take the cast slot and silently reject the summon; if
        -- we'd already cleared EC_addonDismissed the pet-tick retry
        -- path (the only thing that would catch the rejection) is
        -- disarmed and the Scavenger stays gone for the rest of the
        -- session. The pet-tick at the EC_PetCheckTick transition
        -- handler is the canonical "summon confirmed" signal and
        -- clears EC_addonDismissed after observing scavengerOut=true.
        -- Same model v2.6.1 applied to EC_TryResummonScavenger. The
        -- pendingAnnounce flag IS cleared above because the print
        -- has already fired; the retry path's silent-on-retry
        -- behaviour is preserved by the cleared flag.
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
-- Expose EC_Delay to split files via NS. Used by post-Stage-7
-- EbonClearance_Process.lua and any future split file that needs to
-- schedule a delayed callback. The forward-declared `EC_delayFrame`
-- and `EC_timers` stay local to this file; only the scheduling helper
-- is part of the namespace surface.
NS.Delay = EC_Delay

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

-- v2.21.0: Fast Loot queue state hung off EC_compCache to stay under
-- Lua 5.1's 200-locals-per-main-chunk cap (CLAUDE.md discipline). The
-- queue replaces v2.16.0's tight-loop drain with a slot-index queue
-- that drains via OnUpdate throttle, reducing per-frame LootSlot
-- pressure to mitigate disconnect risk on busy 3.3.5a private
-- servers. EC_compCache.lootQueue is initialised here so the OnUpdate
-- driver (built lazily in EC_HandleLootReady) can reach it via
-- EC_compCache. Resets naturally on /reload and on every LOOT_READY
-- (re-population wipes + refills).
EC_compCache.lootQueue = {
    slots = {},
    isProcessing = false,
    lastLootAt = 0,
    delay = 0.11, -- 110 ms; matches the reference implementation's default
    frame = nil, -- built lazily in EC_HandleLootReady on first call
}

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
    if EC_compCache.vendorRunning then
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
-- Hidden tooltip used to scan bag items for the "Right Click to Open" line,
-- bind type detection, PE affix + chance-on-hit detection, and Process Bags
-- mode detection. Anchored offscreen via SetOwner(UIParent, "ANCHOR_NONE")
-- so it never flashes on the user's screen during scans.
--
-- Lives in this file (not EbonClearance_Protection.lua) because callers
-- exist in both Protection and non-protection code (auto-open driver,
-- Process Bags helpers, bug-report builder). Exposed on the namespace so
-- EbonClearance_Protection.lua can dereference it lazily at call time
-- (Protection loads BEFORE this file, so an upvalue capture at Protection's
-- load would store nil).
local EC_scanTooltip = CreateFrame("GameTooltip", "EbonClearanceScanTooltip", UIParent, "GameTooltipTemplate")
EC_scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
NS.scanTooltip = EC_scanTooltip

-- Forward declaration so the debounce frame's OnUpdate closure below
-- can resolve the name. Without this, Lua's lexical scoping resolves
-- the reference to the (nil) global at closure-creation time and the
-- auto-open driver never fires from the debounce path. v2.24.0 perf
-- regression discovered post-v2.25.0 when locked boxes that the user
-- opened via Process Bags weren't being auto-opened by the debounce.
-- Function body still lives at its original spot below.
local EC_HandleAutoOpenContainers

-- v2.24.0: BAG_UPDATE coalescing frame. The Greedy Scavenger looting
-- 5 items in <100 ms fires 5 BAG_UPDATE events; running the full
-- deferred-work chain (auto-open containers, upgrade scan, Process
-- Bags rearm, panel refresh) per-event caused 1.5 s freezes in
-- v2.22.0+v2.23.0. This frame's OnUpdate watches a "burst settled"
-- accumulator and fires the work once after the configured idle
-- window. EC_HandleBagFullForCycle stays synchronous (kept inline in
-- the OnEvent branch) so the bag-full cycle's responsiveness is
-- unchanged. State on EC_compCache to stay under Lua 5.1's 200-
-- locals cap.
EC_compCache.bagUpdatePending = false
EC_compCache.bagUpdateAccum = 0
EC_compCache.BAG_UPDATE_DEBOUNCE_S = 0.12 -- 120 ms idle window
EC_compCache.bagUpdateFrame = CreateFrame("Frame")
EC_compCache.bagUpdateFrame:Hide()
EC_compCache.bagUpdateFrame:SetScript("OnUpdate", function(self, elapsed)
    EC_compCache.bagUpdateAccum = EC_compCache.bagUpdateAccum + elapsed
    if EC_compCache.bagUpdateAccum < EC_compCache.BAG_UPDATE_DEBOUNCE_S then
        return
    end
    self:Hide()
    EC_compCache.bagUpdatePending = false
    -- Burst settled. Fire the deferred work once.
    if EC_HandleAutoOpenContainers then
        EC_HandleAutoOpenContainers()
    end
    if EC_compCache.checkBagsForUpgrades then
        EC_compCache.checkBagsForUpgrades()
    end
    if EC_compCache.rearmProcessButton then
        EC_compCache.rearmProcessButton()
    end
    -- v2.26.0: cheap dirty-check rebuild of the known-affix /
    -- known-proc description map. Skips the rebuild when the player's
    -- learned-record count hasn't changed since the last fire. Picks
    -- up post-extraction state from the Enchanted Anvil without
    -- needing a /reload.
    if EC_compCache.refreshExtractionIfDirty then
        EC_compCache.refreshExtractionIfDirty()
    end
    local pbp = _G["EbonClearanceOptionsProcessBags"]
    if pbp and pbp:IsShown() and EC_compCache.refreshProcessPanel then
        EC_compCache.refreshProcessPanel()
    end
end)

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

-- Auto-open driver. Walks bags, opens the first openable item, and recurses
-- via EC_Delay if more remain. EC_autoOpenInFlight coalesces BAG_UPDATE
-- bursts so we never stack `UseContainerItem` calls within the inter-item
-- delay. Reassigns the forward-declared `EC_HandleAutoOpenContainers` local
-- (declared above near the v2.24.0 BAG_UPDATE debounce frame, so the
-- frame's OnUpdate closure can capture this name). Body lives in this file
-- because it references file-scope locals EC_IsOpenable + EC_autoOpenInFlight.
function EC_HandleAutoOpenContainers()
    if not DB or not DB.autoOpenContainers then
        return
    end
    if EC_compCache.vendorRunning then
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

-- The PE random-affix detection cluster (linkHasAffix, romanToInt,
-- parseAffixFromTitle, scanTooltipForAffixDesc, normaliseAffixDesc,
-- bagSlotAffixData and siblings), the chance-on-hit detection cluster
-- (lineLooksLikeChanceProc, itemHasChanceOnHit, liveTooltipHasChanceOnHit),
-- the PE engraving-spell catalog integration (refreshKnownAffixes,
-- refreshExtractionIfDirty, playerHasAffixDescription,
-- knownAffixDescriptions / procIdToDescription tables), and the
-- v2.26.0 Anvil bridge (findLearnedAffixForItem, itemAffixLookupCache)
-- all live in EbonClearance_Protection.lua (Stage 4 of the file split,
-- see docs/CODE_REVIEW.md item 4). Every helper is attached to
-- EC_compCache, so call sites elsewhere in this file already resolve
-- through the shared upvalue and need no changes.

-- v2.21.0: pre-flight bag-space check used by the Fast Loot queue
-- before each LootSlot call. Returns true if the item can fit (free
-- slot in a compatible bag, OR room in an existing stack). False
-- means bags are too full - the queue defers, and the loot window
-- stays open for the player to deal with manually. Money and items
-- with no link (currency drops) always return true since they don't
-- consume bag space.
function EC_compCache.canLootItem(link)
    if not link then
        return true
    end
    local itemFamily = GetItemFamily and GetItemFamily(link) or 0
    local totalFree = 0
    for i = 0, NUM_BAG_SLOTS do
        local free, bagFamily = GetContainerNumFreeSlots(i)
        bagFamily = bagFamily or 0
        -- bagFamily 0 = generic bag, accepts anything. Non-zero =
        -- specialty bag (quiver, soul shard pouch, etc.) - only
        -- accepts items whose family bit matches.
        if free and (bagFamily == 0 or (itemFamily and bit.band(itemFamily, bagFamily) > 0)) then
            totalFree = totalFree + free
        end
    end
    if totalFree > 0 then
        return true
    end
    -- Bags full but check if the item can stack into an existing
    -- partial stack of the same item.
    local have = GetItemCount and GetItemCount(link) or 0
    if have > 0 then
        local _, _, _, _, _, _, _, stackSize = GetItemInfo(link)
        if stackSize and stackSize > 1 then
            local remainder = have % stackSize
            if remainder > 0 then
                return true
            end
        end
    end
    return false
end

-- The Process Bags engine (Disenchant / Mill / Prospect / Lockpick
-- eligibility predicates + spell IDs + buildProcessSummary bag walk)
-- lives in EbonClearance_Process.lua after Stage 7 of the file split.
-- The Process Bags PANEL (rearmProcessButton, refreshProcessPanel,
-- updateProcessSelection, skipProcessTarget + the SecureActionButton
-- UI) stays in this file for Stage 8 because it pulls in a dense web
-- of UI-building helpers. See docs/CODE_REVIEW.md item 4.


-- v2.21.0: Fast Loot driver. Replaces v2.16.0's tight-loop drain
-- (which fired N LootSlot calls in one frame and risked anti-flood
-- disconnect on busy 3.3.5a private servers) with a queue + OnUpdate
-- throttle: on LOOT_READY, the slot indices are pushed into
-- EC_lootQueue.slots and the OnUpdate driver below drains one slot
-- every EC_LOOT_QUEUE_DELAY seconds. Each pop re-validates the slot
-- and pre-checks bag space before calling LootSlot. The 0.3 s
-- LOOT_READY debounce from v2.16.0 is gone - re-populating the queue
-- on a fresh LOOT_READY is idempotent (wipe + refill).
--
-- The "auto-loot is effectively on right now?" check is unchanged
-- from v2.16.0: autoLootDefault is the CVar setting, AUTOLOOTTOGGLE
-- is the modifier key (typically Shift) that inverts auto-loot for
-- one interaction. When the CVar's value matches whether the
-- modifier is held, auto-loot is OFF for this loot (user is
-- explicitly opting OUT - or didn't opt IN); when they differ,
-- auto-loot is ON. Skip when off so the user keeps the standard
-- loot window for selective looting.
--
-- BoP-bind auto-confirm (also v2.16.0) is unchanged: the
-- hooksecurefunc on LootSlot fires whether the call comes from the
-- old tight loop or the new queue. Fast Loot users still don't see
-- the bind popup.
local function EC_HandleLootReady()
    if not DB or not DB.fastLoot then
        return
    end
    if GetCVarBool("autoLootDefault") == IsModifiedClick("AUTOLOOTTOGGLE") then
        return
    end
    local n = GetNumLootItems()
    if n == 0 then
        return
    end
    local q = EC_compCache.lootQueue
    -- Lazy-build the OnUpdate driver frame on first LOOT_READY. Lives
    -- for the rest of the session; cheap when DB.fastLoot is off
    -- because the OnUpdate body bails on isProcessing == false.
    if not q.frame then
        q.frame = CreateFrame("Frame")
        q.frame:SetScript("OnUpdate", function(self, elapsed)
            local qs = EC_compCache.lootQueue
            if not qs.isProcessing then
                return
            end
            -- Cap elapsed so a long pause (Alt-Tab, /reload) doesn't
            -- void the next throttle window and drain in a burst.
            if elapsed > 0.1 then
                elapsed = 0.1
            end
            if (GetTime() - qs.lastLootAt) < qs.delay then
                return
            end
            if #qs.slots == 0 then
                qs.isProcessing = false
                return
            end
            local slotIdx = qs.slots[1]
            table.remove(qs.slots, 1)
            -- Per-slot revalidation: server-side loot state can
            -- desync from the snapshot at LOOT_READY (a slot can
            -- become invalid before we reach it).
            local _, _, _, _, locked = GetLootSlotInfo(slotIdx)
            if locked then
                -- BoP / roll item: leave for player. The existing
                -- BoP-bind auto-confirm hook only fires AFTER a
                -- successful LootSlot, so skipping here leaves the
                -- loot window open for manual handling.
                return
            end
            -- Bag-space pre-check: avoids ERR_INV_FULL spam in the
            -- chat frame when bags are full.
            local link = GetLootSlotLink(slotIdx)
            if link and not EC_compCache.canLootItem(link) then
                return
            end
            qs.lastLootAt = GetTime()
            LootSlot(slotIdx)
        end)
    end
    wipe(q.slots)
    for i = n, 1, -1 do
        q.slots[#q.slots + 1] = i
    end
    q.isProcessing = true
    q.lastLootAt = 0
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
    -- Any list mutation can change a bag slot's would-sell verdict, so
    -- repaint the slot-border tints across already-decorated buttons. The
    -- helper is a no-op when the toggle is off or no buttons are tracked.
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    return true
end

-- v2.13.0 ElvUI bag buttons: cursor-drop helper. Called by the bag-frame
-- buttons' OnReceiveDrag handler. Reads the cursor item via GetCursorInfo
-- (returns "item", itemID, itemLink for items), clears the cursor, and
-- routes through EC_AddItemToList so cross-list conflict guards and
-- duplicate checks apply. The label is the human-readable list name used
-- in the chat reply ("Sell List", "Keep List", "Delete List").
-- Hung off EC_compCache (rather than a file-scope local) to stay under
-- Lua 5.1's 200-locals-per-main-chunk cap.
function EC_compCache.handleItemDrop(setName, label)
    local cursorType, cursorID, cursorLink = GetCursorInfo()
    if cursorType ~= "item" then
        ClearCursor()
        return
    end
    local id = (type(cursorID) == "number") and cursorID or (cursorLink and tonumber(cursorLink:match("item:(%d+)")))
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
    local sellBtn =
        makeButton("EbonClearance_ElvUISellBtn", bagFrame, "Interface\\Icons\\INV_Misc_Coin_01", 0.71, 1.0, 0.71)
    sellBtn:SetPoint("TOPRIGHT", bagFrame, "TOPRIGHT", -98, -4)
    sellBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("|cff66ccff[EC]|r |cffb6ffb6Sell|r", 0.71, 1, 0.71)
        GameTooltip:AddLine("Drop item to add to Sell List.", 1, 1, 1)
        GameTooltip:AddLine("Click at a vendor to start selling now.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click to open the Sell List panel.", 0.7, 0.7, 0.7)
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
        EC_compCache.handleItemDrop("whitelist", "Sell List")
    end)
    sellBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            EC_compCache.openPanelToList("whitelist")
        elseif CursorHasItem() then
            EC_compCache.handleItemDrop("whitelist", "Sell List")
        elseif EbonClearance_ForceSell then
            EbonClearance_ForceSell()
        end
    end)

    -- Keep button (blacklist) - middle. Shield icon (semantically clearer
    -- than AutoDelete's chocolate box for "protected"). Drag adds to
    -- Blacklist (Keep); right-click opens the Blacklist panel.
    local keepBtn =
        makeButton("EbonClearance_ElvUIKeepBtn", bagFrame, "Interface\\Icons\\INV_Shield_06", 1.0, 0.78, 0.30)
    keepBtn:SetPoint("LEFT", sellBtn, "RIGHT", 4, 0)
    keepBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("|cff66ccff[EC]|r |cffffb84dKeep|r", 1, 0.78, 0.30)
        GameTooltip:AddLine("Drop item to add to Keep List.", 1, 1, 1)
        GameTooltip:AddLine("Items here are never auto-sold or auto-deleted.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click to open the Keep List panel.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
        self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        self._icon:SetVertexColor(self._hoverR, self._hoverG, self._hoverB)
    end)
    keepBtn:RegisterForDrag("LeftButton")
    keepBtn:RegisterForClicks("AnyUp")
    keepBtn:SetScript("OnReceiveDrag", function()
        EC_compCache.handleItemDrop("blacklist", "Keep List")
    end)
    keepBtn:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            EC_compCache.openPanelToList("blacklist")
        elseif CursorHasItem() then
            EC_compCache.handleItemDrop("blacklist", "Keep List")
        end
    end)

    -- Delete button - rightmost. Red X icon (Blizzard's loot-pass texture,
    -- no icon-inset crop needed). Drag adds to delete list; right-click
    -- opens the Delete List panel.
    local delBtn = makeButton(
        "EbonClearance_ElvUIDeleteBtn",
        bagFrame,
        "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
        1.0,
        0.30,
        0.30
    )
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
    -- Any list mutation can change a bag slot's would-sell verdict, so
    -- repaint the slot-border tints across already-decorated buttons. The
    -- helper is a no-op when the toggle is off or no buttons are tracked.
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
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
    if EC_AddItemToList("blacklist", id, "Keep List", true) then
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
    if EC_AddItemToList("blacklist", itemID, "Keep List", true) then
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
            PrintNice(
                "|cffaaaaaaNo equipment sets saved. Use the Blizzard Equipment Manager to create one, then re-tick this option.|r"
            )
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
            PrintNicef(
                "|cffb6ffb6Auto-protected %d item%s from %d equipment set%s.|r",
                added,
                added == 1 and "" or "s",
                sets,
                sets == 1 and "" or "s"
            )
        else
            PrintNicef(
                "|cffaaaaaaScanned %d equipment set%s; all items already on the keep list.|r",
                sets,
                sets == 1 and "" or "s"
            )
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
    if EC_compCache.vendorRunning then
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
                            if EC_AddItemToList("blacklist", itemID, "Keep List", true) then
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

-- Row metadata for the popup. Each "list" row toggles between "Add to ..."
-- (white) and "Remove from ..." (orange) based on the item's live list
-- membership at show time. Special rows ("sellNow", "cancel") get plain text
-- and fixed handlers. EC_ShowItemContextMenu sets per-row text + OnClick on
-- every show; the buttons created in EC_BuildCtxFrame are empty placeholders.
local EC_CTX_ROWS = {
    { kind = "list", setName = "whitelist", label = "Sell List (Character)" },
    { kind = "list", setName = "accountWhitelist", label = "Sell List (Account)" },
    { kind = "list", setName = "blacklist", label = "Keep List (Do Not Sell)" },
    { kind = "list", setName = "deleteList", label = "Delete List" },
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

    -- v2.26.0 / v2.27.0: protected items (chance-on-hit OR
    -- random-affix) show a single "Allow Sell" option in place of
    -- Sell Now while unmarked. Picking it releases the v2.20.0 /
    -- v2.23.0 safety net - future drops auto-sell via the normal
    -- quality rules and the item becomes available to Process Bags.
    -- While unmarked, the Sell List / Keep List / Delete List rows
    -- are hidden so the user must consciously acknowledge the
    -- protection before adding it to a sell rule. Once marked, the
    -- full menu opens up and the sellNow row shows "Remove from
    -- Allow List" as the toggle.
    local hasProc = EC_compCache.itemHasChanceOnHit(bag, slot, itemID)
    -- For random-affix items the identity-bearing field is the affix
    -- description, NOT the base itemID. Capture both the protection
    -- flag and the normalised description so the Allow Sell row can
    -- mark by affix when relevant.
    local affixData
    if DB.protectAffixedRareItems then
        local _, _, q = GetItemInfo(itemID)
        if q and q >= 3 and EC_compCache.bagSlotAffixData then
            affixData = EC_compCache.bagSlotAffixData(bag, slot)
        end
    end
    local hasAffix = affixData ~= nil
    local affixKey = affixData
        and affixData.description
        and EC_compCache.normaliseAffixDesc
        and EC_compCache.normaliseAffixDesc(affixData.description)
    local hasProtection = hasProc or hasAffix
    -- Allowance has three sources:
    --   1. Manual itemID mark for chance-on-hit (allowedItems).
    --   2. Manual affix-description mark for random affix
    --      (allowedAffixes).
    --   3. Auto-dupe gate for random affix: when
    --      DB.affixAllowExactDupes is ON, an affix the player has
    --      already extracted is implicitly allowed - no manual mark
    --      needed. This is the "if exact-rank dupes is enabled then
    --      Allow Sell isn't required" rule from the user spec.
    local procAllowed = hasProc and ADB.allowedItems and ADB.allowedItems[itemID] == true
    local affixManualAllowed = hasAffix and affixKey and ADB.allowedAffixes and ADB.allowedAffixes[affixKey] == true
    local affixAutoAllowed = hasAffix
        and affixData
        and affixData.description
        and DB.affixAllowExactDupes
        and EC_compCache.playerHasAffixDescription
        and EC_compCache.playerHasAffixDescription(affixData.description)
    local affixAllowed = affixManualAllowed or affixAutoAllowed
    local itemAllowed = procAllowed or affixAllowed
    local procProtected = hasProtection and not itemAllowed

    local merchantOpen = MerchantFrame and MerchantFrame:IsShown()
    local visibleSlot = 0
    for i, row in ipairs(EC_CTX_ROWS) do
        local btn = frame.buttons[i]
        local rowHidden = false
        if row.kind == "list" and procProtected then
            -- v2.26.0: hide all list rows while protected. User must
            -- click "Allow Sell" first to unlock the normal
            -- Sell/Keep/Delete actions on this item.
            rowHidden = true
        elseif row.kind == "list" then
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
                -- items the auto-rules can't act on anyway. The Delete
                -- List row stays visible because that's the actually-
                -- useful action.
                rowHidden = true
            else
                -- v2.26.0: dropped the "Add to" prefix on add rows -
                -- the label alone is self-evident and orange
                -- "Remove from" rows provide the contrast.
                local conflictName = EC_FindAddConflict(itemID, row.setName)
                if conflictName then
                    btn:SetText(row.label)
                    btn:SetScript("OnClick", function() end)
                    btn:Disable()
                else
                    btn:SetText(row.label)
                    btn:SetScript("OnClick", function()
                        EC_AddItemToList(row.setName, itemID, row.label)
                        -- v2.27.0: stamp the affix-meta flag so the
                        -- list panel renders "(affix-gated)" on this
                        -- entry. Reminds the user that the affix
                        -- protection still filters per-drop even
                        -- though the base itemID is on the list.
                        if hasAffix then
                            ADB.affixedListedItems = ADB.affixedListedItems or {}
                            ADB.affixedListedItems[itemID] = true
                        end
                        frame:Hide()
                    end)
                    btn:Enable()
                end
            end
        elseif row.kind == "sellNow" then
            -- v2.26.0 / v2.27.0: unified "Allow Sell" toggle for any
            -- protected item (chance-on-hit or random affix). Marks
            -- the right list automatically: itemID for chance-on-hit
            -- (proc carried by the item), affix description for
            -- random affix (so all future drops with the same affix
            -- pass, not just the same base item).
            --
            -- When the affix auto-dupe gate is allowing the item
            -- (DB.affixAllowExactDupes is ON and the affix is one the
            -- player has extracted), there's no manual mark to
            -- toggle - hide the row. The full list menu is already
            -- visible because itemAllowed is true.
            local hasManualMark = procAllowed or affixManualAllowed
            if hasManualMark then
                btn:SetText("|cffff8000Remove from Allow List|r")
                btn:SetScript("OnClick", function()
                    if procAllowed and ADB.allowedItems then
                        ADB.allowedItems[itemID] = nil
                    end
                    if affixManualAllowed and affixKey and ADB.allowedAffixes then
                        ADB.allowedAffixes[affixKey] = nil
                    end
                    frame:Hide()
                    PrintNicef("Removed %s from Allow List.", itemName)
                    -- The Allow List feeds into EC_IsSellable's chance-on-hit
                    -- and random-affix branches, so its mutation can flip a
                    -- slot's would-sell verdict. Repaint the border tints
                    -- across already-decorated buttons so the ring tracks
                    -- the new state without waiting for the next bag event.
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end)
                btn:Enable()
            elseif itemAllowed then
                -- Auto-allowed (affix dupe gate); no manual state.
                rowHidden = true
            elseif hasProtection then
                btn:SetText("Allow Sell")
                btn:SetScript("OnClick", function()
                    if hasAffix and affixKey then
                        ADB.allowedAffixes = ADB.allowedAffixes or {}
                        ADB.allowedAffixes[affixKey] = true
                        PrintNicef(
                            "Marked affix %s as allowed. Future drops with this affix will auto-sell.",
                            tostring(affixData.name or affixKey)
                        )
                    elseif hasProc then
                        ADB.allowedItems = ADB.allowedItems or {}
                        ADB.allowedItems[itemID] = true
                        PrintNicef("Marked %s as allowed. Future drops will auto-sell.", itemName)
                    end
                    frame:Hide()
                    -- Same reasoning as the remove-from-allow path: this
                    -- mutation can flip a slot from "protected" to "will
                    -- sell" so the border should track immediately.
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end)
                btn:Enable()
            else
                rowHidden = true
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
        -- Alt+Shift+Right-Click on a bag item: print the per-predicate
        -- sellability trace for that slot. Lower-priority than the Alt-only
        -- branch above; falls through to the original handler when the
        -- click can't be resolved to a (bag, slot) pair.
        if button == "RightButton" and IsAltKeyDown() and IsShiftKeyDown() and not IsControlKeyDown() then
            if EC_compCache.bagSlotFromButton and EC_compCache.printSellabilityTrace then
                local bag, slot = EC_compCache.bagSlotFromButton(self)
                if bag and slot then
                    EC_compCache.printSellabilityTrace(bag, slot)
                    return
                end
            end
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
    -- synthetic refresh of EC_compCache.lastScavSpokeAt resets the silence clock
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
    return EC_compCache.lastScavSpokeAt < kept[1]
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
    if EC_compCache.vendorRunning then
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
            EC_compCache.lastScavSpokeAt = GetTime()
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

-- pendingDelete state was promoted from a file-scope local to
-- EC_compCache.pendingDelete (initialised in EbonClearance_Core.lua's
-- table literal) for the same Stage 5 reason as vendorRunning above.
-- The HookDeletePopupOnce body that consumes pendingDelete moved to
-- EbonClearance_Vendor.lua (Stage 5 of the file split, exposed as
-- NS.HookDeletePopupOnce). The deletePopupHooked install-once gate
-- moved with it.

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
    -- Baseline profession-tool safety net. Same narrowing as the quest-item
    -- gate above: explicit Sell List entries override (whitelistPass is
    -- unchanged); only auto-rule sweeps are vetoed. ADB.allowedItems[itemID]
    -- also bypasses (per-item Allow Sell override, mirrors the chance-on-hit
    -- + affix pattern). Hardcoded list in EC_compCache.baselineProtectedIDs;
    -- see the table for the rationale.
    if
        qualityPass
        and EC_compCache.baselineProtectedIDs
        and EC_compCache.baselineProtectedIDs[itemID]
        and not (ADB and ADB.allowedItems and ADB.allowedItems[itemID])
    then
        qualityPass = false
    end
    local blacklisted = IsInSet(DB.blacklist, itemID)
    if not (isJunk or qualityPass or whitelistPass) then
        return false
    end
    if IsEquippedItem(itemID) or blacklisted then
        return false
    end
    -- v2.19.0: PE roguelite affix protection. Skip Rare (3) / Epic (4)
    -- items that have a random affix even when their itemID is on the
    -- Sell List or the auto-rule sweep matched them. The base itemID
    -- and the affixed itemID are the same; only the per-link suffix /
    -- tooltip-title differs. Default ON; users can opt out via the
    -- Protection Settings panel. White/Green items are NOT covered
    -- (per user scope), so per-rarity sweep rules still vendor them.
    -- v2.20.0: narrowed detection requires rank-suffix in name to
    -- avoid misfiring on standard ItemRandomSuffix.dbc entries.
    -- v2.23.0: exact-rank duplicate gate. When the player already
    -- has the SAME (affixName, rank) pair via PE's PerkService,
    -- DB.affixAllowExactDupes ON lets the item fall through to the
    -- existing sell / delete rules. Different ranks of the same
    -- affix stay protected so the player can still collect all four.
    if (whitelistPass or qualityPass) and DB.protectAffixedRareItems and quality and quality >= 3 then
        local affix = EC_compCache.bagSlotAffixData(bag, slot)
        if affix then
            -- v2.27.0: affix-keyed Allow Sell. Marking via Alt+Right-
            -- Click stores the affix description (not the itemID) so
            -- every future drop rolling that affix passes through the
            -- gate, regardless of base item.
            local affixKey = affix.description and EC_compCache.normaliseAffixDesc(affix.description)
            local manualAllow = affixKey and ADB.allowedAffixes and ADB.allowedAffixes[affixKey]
            local autoDupe = DB.affixAllowExactDupes and EC_compCache.playerHasAffixDescription(affix.description)
            if not (manualAllow or autoDupe) then
                return false
            end
        end
    end
    -- v2.20.0: PE Chance-on-hit protection. Skip items with a "Chance
    -- on hit:" proc line in their tooltip - on Project Ebonhold these
    -- spells can be extracted and applied to other items.
    -- v2.20.1: narrowed to auto-rule sweep only. Mirrors the v2.13.x
    -- quest-item safety-net design above: when the user explicitly
    -- lists a chance-on-hit itemID on Sell List, they typically have
    -- already extracted the proc spell and want to dump the now-
    -- worthless base. Explicit user intent overrides the safety net;
    -- only the auto-rule sweep (qualityPass) is gated.
    if qualityPass and DB.protectChanceOnHitItems and EC_compCache.itemHasChanceOnHit(bag, slot, itemID) then
        -- v2.26.0: chance-on-hit allow list. Items the user has
        -- marked via Alt+Right-Click -> "Allow Sell" fall through to
        -- the normal sell / DE rules. Unmarked items stay protected.
        -- Account-wide because extraction state is account-wide.
        if not (ADB.allowedItems and ADB.allowedItems[itemID]) then
            qualityPass = false
        end
    end
    -- After the chance-on-hit downgrade, if no positive sell signal
    -- remains (isJunk / qualityPass / whitelistPass), the item is no
    -- longer sellable. Recheck the predicate the main guard uses.
    if not (isJunk or qualityPass or whitelistPass) then
        return false
    end
    return true, link, itemID, sellPrice, itemCount
end
NS.IsSellable = EC_IsSellable

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
                -- v2.13.8: dropped the IsEquippedItem(id) guard from
                -- this path. The original intent was "don't auto-
                -- destroy items currently worn," but IsEquippedItem
                -- checks by item ID, not by slot - so for any item
                -- where the user has one copy equipped AND has
                -- duplicates in bags (e.g. tabards, off-spec armor,
                -- BoE accessories with multiple copies), all the bag
                -- duplicates were silently kept. The iteration only
                -- visits bag slots; equipped items live in inventory
                -- slots 1-19 by definition, so a bag-slot copy is by
                -- definition NOT the worn instance. The check was
                -- never actually protecting the right thing - it was
                -- conflating "this item ID is worn" with "this
                -- specific bag copy is the worn instance." Following
                -- the same principle as v2.13.x's quest-item safety-
                -- net narrowing: explicit user lists override safety
                -- nets. Delete-list entries are explicit user intent;
                -- respect them.
                if id and IsInSet(DB.deleteList, id) then
                    local _, count, locked = GetContainerItemInfo(bag, slot)
                    if count and count > 0 and not locked then
                        -- v2.19.0: PE roguelite affix protection on
                        -- the Delete List path. Same gate as
                        -- EC_IsSellable's sell-time check: a user
                        -- with the base itemID on Delete must not
                        -- accidentally destroy a randomly-affixed
                        -- Rare/Epic copy. The toggle's default ON.
                        -- v2.20.1: chance-on-hit protection NO LONGER
                        -- applies on the delete path. Delete List
                        -- entries are always explicit user intent
                        -- (added via Alt+Right-Click, manual entry,
                        -- or the Delete List panel) - the user has
                        -- said "destroy items with this ID". Don't
                        -- override explicit destruction. Affix
                        -- protection KEEPS protecting the delete path
                        -- because affixed-instance detection is per-
                        -- link and the user can't anticipate which
                        -- specific bag copy will roll an affix.
                        -- v2.23.0: same exact-rank dupe gate as the
                        -- sell path. When the user opted in AND owns
                        -- the same (affix, rank) pair, the affix
                        -- protection releases the item to be deleted.
                        local _, _, quality = GetItemInfo(id)
                        local affixProtected = false
                        if DB.protectAffixedRareItems and quality and quality >= 3 then
                            local affix = EC_compCache.bagSlotAffixData(bag, slot)
                            if affix then
                                local isDupe = DB.affixAllowExactDupes
                                    and EC_compCache.playerHasAffixDescription(affix.description)
                                affixProtected = not isDupe
                            end
                        end
                        if not affixProtected then
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
    EC_compCache.vendorRunning = false
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
                EC_compCache.vendorRunning = true
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
                -- v2.14.0: arm the resummon-print debounce on every
                -- merchant-cycle close-out, not just bag-full-triggered
                -- cycles. SummonGreedyScavenger's already-out branch
                -- clears the flag silently if the Scavenger was never
                -- dismissed (e.g. user sold only greys at a normal
                -- vendor without the Goblin cycle), so this can't
                -- spuriously print. The previous behaviour only set
                -- the flag in EC_HandleBagFullForCycle, so manual
                -- merchant visits silently summoned the Scavenger
                -- without the chat acknowledgement.
                EC_compCache.pendingAnnounce = true
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
    -- v2.14.0: see comment at the corresponding call above.
    EC_compCache.pendingAnnounce = true
    EC_SummonGreedyWithDelay()
end

local function DoNextAction()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        EC_compCache.vendorRunning = false
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
            EC_compCache.pendingDelete = { bag = action.bag, slot = action.slot, itemID = action.itemID }
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
            EC_compCache.pendingDelete = nil
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

-- The Release-1 bag-display layer (sell-border tint helpers, the
-- NS.RefreshSellBorders body, the sellability-trace inspector that
-- drives /ec sellinfo and Alt+Shift+Right-Click, plus the
-- bagSlotFromButton helper) all live in EbonClearance_BagDisplay.lua
-- after Stage 6 of the file split. Every helper is attached to
-- EC_compCache (= NS.compCache, declared in Core), so call sites in
-- this file already resolve via the shared cache table and need no
-- changes. NS.RefreshSellBorders is forward-declared as a no-op stub
-- near the top of THIS file (so the Character Settings panel toggle
-- can call it before BagDisplay loads its real body).


local function StartRun()
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if EC_compCache.vendorRunning then
        return
    end

    local merchantAllowed = EC_IsMerchantAllowed()

    NS.HookDeletePopupOnce()

    EC_compCache.vendorRunning = true

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
        EC_compCache.vendorRunning = false
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
            statusLine = "|cff66ccff[EC]|r |cffffb84dProtected|r"
        end
    elseif IsInSet(DB.deleteList, id) and DB.enableDeletion then
        statusLine = "|cff66ccff[EC]|r |cffff4444Will Delete|r"
    elseif IsInSet(DB.whitelist, id) or (ADB and IsInSet(ADB.whitelist, id)) then
        -- Honesty: EC_IsSellable also requires sellPrice > 0 and not currently
        -- equipped. Without these checks the tooltip used to claim "Will Sell"
        -- on items that the merchant cycle correctly refuses (custom items
        -- with no vendor price, or items the player has equipped). Surface
        -- both reasons in warning-yellow so the user sees them at the point
        -- of decision instead of wondering why the cycle skipped them.
        local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
        if IsEquippedItem(id) then
            statusLine = "|cff66ccff[EC]|r |cffffb84dWon't Sell - Currently Equipped|r"
        elseif not (sellPrice and sellPrice > 0) then
            statusLine = "|cff66ccff[EC]|r |cffffb84dWon't Sell - No Vendor Price|r"
        else
            statusLine = "|cff66ccff[EC]|r |cffb6ffb6Will Sell|r"
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
                elseif
                    matchesILvl
                    and EC_compCache.baselineProtectedIDs
                    and EC_compCache.baselineProtectedIDs[id]
                    and not (ADB and ADB.allowedItems and ADB.allowedItems[id])
                then
                    -- Baseline profession-tool safety net (Monrad's report).
                    -- Same honesty as the quest-item case: the auto-rule
                    -- sweep would have caught the tool but EC_IsSellable
                    -- vetoes; the tooltip should say so. Allow Sell
                    -- override unsets this annotation (the item flows to
                    -- the normal sell path).
                    statusLine = "|cff66ccff[EC]|r |cffffb84dProtected - Profession tool|r"
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
                        statusLine =
                            string.format("|cff66ccff[EC]|r |cffb6ffb6Will Sell - %s (no iLvl cap)|r", rarityName)
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
                        statusLine =
                            string.format("|cff66ccff[EC]|r |cffffb84dProtected - %s has no iLvl|r", rarityName)
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

    -- v2.19.0: PE roguelite affix protection - tooltip honesty pass.
    -- If the if/elseif chain above resolved to a would-sell or would-
    -- delete verdict but DB.protectAffixedRareItems is on AND the item
    -- is Rare/Epic AND has an affix, override the label to make it
    -- clear that the merchant cycle won't actually act on this
    -- specific bag instance.
    -- v2.20.0: liveTooltipHasAffix now requires the rank-suffix
    -- pattern in the title, narrowing the check so standard
    -- ItemRandomSuffix.dbc entries (`of the Bear`, `of the Sorcerer`)
    -- don't get protected as PE roguelite affixes.
    -- v2.23.0: when the exact-dupe gate releases an affixed item back
    -- to the sell / delete chain, the status line shows "Allowed -
    -- affix already known" instead of "Protected - Random affix". The
    -- match is by description text scraped from the item's @affix@
    -- line vs the descriptions on engraving spells in the player's
    -- spellbook (see EC_compCache.refreshKnownAffixes).
    -- v2.27.0: always surface the affix state when the item has one
    -- (not only when the would-vendor chain produced a label). Mirrors
    -- the v2.26.0 chance-on-hit tooltip pass so Epic items with
    -- affixes also show their state.
    if DB.protectAffixedRareItems then
        local _, _, quality = GetItemInfo(id)
        if quality and quality >= 3 then
            local affix = EC_compCache.liveTooltipAffixData(tooltip, id)
            if affix then
                -- v2.27.0: backfill the affix-meta flag for itemIDs
                -- already on a list. Pre-v2.27 entries didn't get
                -- stamped at add time; hovering the item now after
                -- /reload fills in the flag so the panel renders the
                -- (affix-gated) tag.
                local onAnyList = IsInSet(DB.whitelist, id)
                    or (ADB and IsInSet(ADB.whitelist, id))
                    or IsInSet(DB.blacklist, id)
                    or IsInSet(DB.deleteList, id)
                if onAnyList and ADB then
                    ADB.affixedListedItems = ADB.affixedListedItems or {}
                    ADB.affixedListedItems[id] = true
                end
                local affixKey = affix.description and EC_compCache.normaliseAffixDesc(affix.description)
                local manualAllow = affixKey and ADB.allowedAffixes and ADB.allowedAffixes[affixKey]
                local autoDupe = DB.affixAllowExactDupes and EC_compCache.playerHasAffixDescription(affix.description)
                if manualAllow or autoDupe then
                    -- v2.27.0: list-destination label wins over the
                    -- auto-dupe info text. The destination tells the
                    -- user what's going to happen with this item; the
                    -- auto-dupe info only fills in when no list has
                    -- claimed it.
                    if IsInSet(DB.blacklist, id) then
                        -- Keep wins; leave the Protected / Auto-
                        -- Protected label alone.
                    elseif IsInSet(DB.deleteList, id) and DB.enableDeletion then
                        statusLine = "|cff66ccff[EC]|r |cffff4444Allowed - Delete|r"
                    elseif ADB and ADB.whitelist and IsInSet(ADB.whitelist, id) then
                        statusLine = "|cff66ccff[EC]|r |cffb6ffb6Allowed - Account Sell|r"
                    elseif IsInSet(DB.whitelist, id) then
                        statusLine = "|cff66ccff[EC]|r |cffb6ffb6Allowed - Character Sell|r"
                    elseif manualAllow then
                        statusLine = "|cff66ccff[EC]|r |cffffea80Allowed - Choose List|r"
                    else
                        -- autoDupe only, not on any list - keep the
                        -- v2.23.0 informational label.
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6Allowed - %s %s already known|r",
                            affix.name or "affix",
                            (affix.rank and ("rank " .. affix.rank)) or ""
                        )
                    end
                else
                    statusLine = "|cff66ccff[EC]|r |cffffb84dProtected - Random affix|r"
                end
            end
        end
    end

    -- v2.20.0: Chance-on-hit protection - tooltip honesty pass.
    -- v2.20.1: narrowed to "Will Sell - <rarity>" verdicts (the
    -- quality-rule sweep labels). Plain "Will Sell" (whitelist match)
    -- and "Will Delete" (Delete List match) stay as-is because they
    -- represent explicit user intent; chance-on-hit protection no
    -- longer overrides those (the user has typically already
    -- extracted the proc and is dumping the base item).
    --
    -- Discriminator: quality-rule labels always have " - " separator
    -- after "Will Sell" (e.g. "Will Sell - Green iLvl 25 (cap 35)").
    -- The plain whitelist label is just "Will Sell" with no separator.
    -- Lua pattern "Will Sell %- " (escaped dash) matches only the
    -- quality-rule variant.
    -- v2.26.0: chance-on-hit state is always surfaced when the item
    -- has the proc, regardless of whether the auto-rule sweep would
    -- fire. Epic items (default quality rule off) still show the
    -- protection state.
    --
    -- Unmarked items always show "Protected - Chance on hit" (the
    -- protection overrides any other status).
    --
    -- Marked items show the actual destination so the user can see
    -- where the item will go: explicit list membership (Account Sell,
    -- Character Sell, Delete) takes the specific label; otherwise
    -- the item will fall through to the quality-rule sweep and the
    -- label is plain "Allowed - Sell". Keep List membership wins
    -- everything else; we don't override the Kept label.
    if DB.protectChanceOnHitItems and EC_compCache.liveTooltipHasChanceOnHit(tooltip, id) then
        if ADB.allowedItems and ADB.allowedItems[id] then
            if IsInSet(DB.blacklist, id) then
                -- Kept wins; leave the earlier Protected / Auto-
                -- Protected label alone.
            elseif IsInSet(DB.deleteList, id) and DB.enableDeletion then
                statusLine = "|cff66ccff[EC]|r |cffff4444Allowed - Delete|r"
            elseif ADB and ADB.whitelist and IsInSet(ADB.whitelist, id) then
                statusLine = "|cff66ccff[EC]|r |cffb6ffb6Allowed - Account Sell|r"
            elseif IsInSet(DB.whitelist, id) then
                statusLine = "|cff66ccff[EC]|r |cffb6ffb6Allowed - Character Sell|r"
            else
                -- Marked allowed but no specific list chosen. "Allowed
                -- - Sell" reads as "this will be auto-sold" which is
                -- misleading - releasing the protection just opens
                -- the item up to the user's decision. The label is a
                -- call to action: pick a list.
                statusLine = "|cff66ccff[EC]|r |cffffea80Allowed - Choose List|r"
            end
        else
            statusLine = "|cff66ccff[EC]|r |cffffb84dProtected - Chance on hit|r"
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

-- v2.16.0: Fast Loot BoP-bind auto-dismiss. When Fast Loot is on and the
-- user loots a Bind-on-Pickup item, Blizzard normally shows a LOOT_BIND
-- popup asking "are you sure?". That popup blocks the rest of the loot
-- queue draining and defeats the point of Fast Loot. This hook auto-
-- confirms each LootSlot call and force-hides the popup. Self-gates on
-- DB.fastLoot at call time so non-Fast-Loot users keep the Blizzard
-- safety prompt. Idempotent: the hookedOnce guard makes a second call
-- cheap if anything ever calls this twice. Pattern borrowed from
-- LootClicker (others/LootClicker-master/core.lua:158-161).
local EC_fastLootHooked = false
local function EC_InstallFastLootHookOnce()
    if EC_fastLootHooked then
        return
    end
    EC_fastLootHooked = true
    hooksecurefunc("LootSlot", function(slot)
        if not DB or not DB.fastLoot then
            return
        end
        ConfirmLootSlot(slot)
        StaticPopup_Hide("LOOT_BIND")
    end)
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

-- v2.17.0: panel OnShow preamble extractor. Replaces the boilerplate
-- (EnsureDB / EC_UpdatePanelWidth / inited guard / refresh-or-build
-- branch / optional scroll-wrap) at the top of every Interface Options
-- panel's OnShow handler. `refresh` is called every OnShow AFTER the
-- first; `build` is called once under the inited guard. `wrapScroll`
-- toggles the EC_WrapPanelInScrollFrame call; when true, `build`
-- receives the scroll-wrap's content frame as its second arg, otherwise
-- it receives the panel `self`. Either callback may be nil. Hung off
-- EC_compCache rather than as a file-scope local to stay under Lua
-- 5.1's 200-locals-per-main-chunk cap (the file is already dense; see
-- CLAUDE.md and ADDON_GUIDE.md for the discipline). Consolidates the
-- duplicated preamble across 11 panels (CODE_REVIEW.md item 4) so
-- future preamble changes - e.g. a UI_SCALE_CHANGED recompute - land
-- in one place instead of 11.
function EC_compCache.initPanel(self, refresh, build, wrapScroll)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if refresh then
            refresh(self)
        end
        return
    end
    self.inited = true
    local content = self
    if wrapScroll then
        content = EC_WrapPanelInScrollFrame(self)
    end
    if build then
        build(self, content)
    end
end

-- StyleInputBox: applied to every InputBoxTemplate EditBox we use. v2.18.0
-- moved this up from its old position below CreateListUI so the new
-- EC_compCache.buildListHeaderRow / buildListSearchAndSortRow /
-- buildListMatchRow helpers (which call it during their pure-layout build)
-- can see it as an upvalue. Forward-reference discipline: Lua file-scope
-- locals are only visible to code AFTER their declaration; the v2.18.0
-- split inadvertently placed the helpers BEFORE StyleInputBox, which
-- worked at parse time but exploded at first OnShow with
-- "attempt to call global 'StyleInputBox' (a nil value)".
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

-- v2.18.0: CreateListUI scroll-area extraction. Builds the scroll frame +
-- ScrollChild content + the auto-hide scrollbar hook + the OnSizeChanged
-- reactive-width hook that keeps the ScrollChild's width in step with the
-- box on Interface Options frame resize. Returns (scroll, content). Hung
-- off EC_compCache rather than as a file-scope local to stay under Lua
-- 5.1's 200-locals-per-main-chunk cap (CLAUDE.md discipline). Part of the
-- CODE_REVIEW.md item 2 split of CreateListUI.
-- v2.18.0: CreateListUI row-factory extraction. Encapsulates the row
-- pool (`rowPool`) and the active-row count (`activeRows`) that the
-- list widget uses to display its rows. Returns a small table with
-- three methods: `getRow(index)` mints or returns a pooled row frame
-- with a Remove button + label FontString, `hideAllRows()` hides every
-- currently active row and resets the count, `setActiveRows(n)` lets
-- the caller (Refresh) report how many rows are now displayed so the
-- next hideAllRows knows the upper bound.
--
-- Why expose setActiveRows: in the inline-CreateListUI version the
-- Refresh closure mutated `activeRows` directly as an upvalue. After
-- extraction the state lives inside the factory's closure, so Refresh
-- needs an explicit setter. Same data flow, just routed through a
-- method call.
--
-- Row layout: 22 px tall, full width via TOPLEFT/TOPRIGHT anchors set
-- by Refresh on each placement. Remove button is right-anchored, label
-- text fills the gap between row's left edge and the button.
function EC_compCache.makeListRowFactory(content, setTableName)
    local rowPool = {}
    local activeRows = 0

    local function getRow(index)
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

    local function hideAllRows()
        for i = 1, activeRows do
            if rowPool[i] then
                rowPool[i]:Hide()
                rowPool[i].rm:Hide()
            end
        end
        activeRows = 0
    end

    local function setActiveRows(n)
        activeRows = n
    end

    return {
        getRow = getRow,
        hideAllRows = hideAllRows,
        setActiveRows = setActiveRows,
    }
end

-- v2.18.0: CreateListUI header-row extraction. Builds the title
-- FontString + ID-input EditBox + Add Button + Clear All Button.
-- Also wires the input's focus-tracking handlers (EC_activeIDBox is the
-- shift-click-to-add target) and the drag-to-receive handler that
-- populates the input with an itemID when a bag item is dropped onto
-- it - these are pure layout (don't depend on Refresh), so they live
-- here. Add and Clear All button OnClick handlers stay in CreateListUI
-- because they call Refresh. Returns (input, addBtn, clearAllBtn).
function EC_compCache.buildListHeaderRow(box, titleText, setTableName)
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
    -- confirmation popup. OnClick wired by caller (needs Refresh).
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

    return input, addBtn, clearAllBtn
end

-- v2.18.0: CreateListUI search-and-sort-row extraction. Builds the
-- "Search:" label + search input + sort-by-ID button + sort-by-Name button,
-- all on one line at y=-52 within the box. Pure layout - no OnClick
-- wiring; caller attaches handlers after Refresh exists. Returns
-- (search, sortIDBtn, sortNameBtn). The sort buttons use right-pointing
-- triangle glyphs ("\226\150\178") by default; the OnClick handlers in
-- CreateListUI swap to down-pointing ("\226\150\188") to indicate
-- descending order.
function EC_compCache.buildListSearchAndSortRow(box, setTableName)
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

    return search, sortIDBtn, sortNameBtn
end

-- v2.18.0: CreateListUI match-row extraction. Builds the
-- "Add matching in bags:" label + match-input EditBox + Add Match button
-- (anchored at y=-76 within the box, with the input filling the gap
-- between label and button). Pure layout - no OnClick wiring; caller
-- attaches handlers after Refresh exists. Returns (matchInput, matchBtn).
function EC_compCache.buildListMatchRow(box, setTableName)
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

    return matchInput, matchBtn
end

function EC_compCache.buildListScrollArea(box, w, setTableName)
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

    return scroll, content
end

-- ---------------------------------------------------------------------------
-- Panel-text principle (v2.20.2)
-- ---------------------------------------------------------------------------
-- Panel descriptions (yellow MakeLabel) and grey checkbox notes
-- (|cff888888...|r) should answer one of three questions for the
-- player:
--   1. What does this do?
--   2. When does it apply?
--   3. How do I override it?
-- If a sentence explains WHY a feature exists, cites version history,
-- or names an internal mechanism, cut it. The player doesn't care; we
-- have CLAUDE.md and source comments for that. Same lens applies when
-- adding a new toggle or panel description.

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

local function CreateListUI(parent, titleText, setTableName, x, y)
    local w = EC_PANEL_WIDTH - x
    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", x, y)
    -- Height chosen to keep the whole box inside a standard InterfaceOptions
    -- sub-panel. Callers may override via listUI:SetHeight(n) if they need more
    -- or less room (e.g. WhitelistPanel has extra controls above it).
    box:SetSize(w, 280)

    local input, addBtn, clearAllBtn = EC_compCache.buildListHeaderRow(box, titleText, setTableName)

    local sortMode = "id_asc" -- default: sort by ID ascending

    -- Search row: Search box then ID, Name sort buttons all on one line
    local search, sortIDBtn, sortNameBtn = EC_compCache.buildListSearchAndSortRow(box, setTableName)

    -- Bag-scan "Add matching" row: scan bags for items whose name contains the
    -- typed substring and add each match to this list.
    local matchInput, matchBtn = EC_compCache.buildListMatchRow(box, setTableName)

    local scroll, content = EC_compCache.buildListScrollArea(box, w, setTableName)

    local rowFactory = EC_compCache.makeListRowFactory(content, setTableName)

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
        rowFactory.hideAllRows()

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
        -- v2.28.0: name-sort comparator previously called GetItemInfo
        -- per pair-compare = ~20k lookups for a 1000-item sort. Build
        -- a one-pass {id -> lowercase name} map first; comparator
        -- becomes an O(1) table read.
        if sortMode == "id_desc" then
            table.sort(keys, function(a, b)
                return a > b
            end)
        elseif sortMode == "name_asc" or sortMode == "name_desc" then
            local nameByID = {}
            for i = 1, #keys do
                nameByID[keys[i]] = (GetItemInfo(keys[i]) or ""):lower()
            end
            if sortMode == "name_asc" then
                table.sort(keys, function(a, b)
                    return nameByID[a] < nameByID[b]
                end)
            else
                table.sort(keys, function(a, b)
                    return nameByID[a] > nameByID[b]
                end)
            end
        else
            table.sort(keys) -- id_asc (default)
        end

        -- v2.28.0: hoist the affix-set reference once per Refresh
        -- instead of dereferencing ADB.affixedListedItems three times
        -- per visible row.
        local affixSet = (ADB and ADB.affixedListedItems) or nil

        -- Tooltip-prime helper. SetHyperlink for an uncached item
        -- queues an async server request; the response populates the
        -- item cache and the existing pendingRetry chain re-paints
        -- once names are available. SetOwner is called once outside
        -- the loop body since the same owner serves every prime.
        local primeFrame = GameTooltip
        local canPrime = primeFrame and primeFrame.SetHyperlink
        if canPrime then
            primeFrame:SetOwner(UIParent, "ANCHOR_NONE")
        end

        local shown = 0
        local rowY = -4
        local hasUncached = false
        for i = 1, #keys do
            local id = keys[i]
            local name = GetItemInfo(id)
            if not name then
                hasUncached = true
                if canPrime then
                    primeFrame:SetHyperlink("item:" .. id .. ":0:0:0:0:0:0:0")
                end
                name = "ItemID: " .. id
            end

            if MatchesSearch(id, name, searchText) then
                shown = shown + 1
                local row = rowFactory.getRow(shown)
                row:ClearAllPoints()
                -- v2.11.0: anchor both TOPLEFT and TOPRIGHT so the row
                -- stretches with the (resizable) content frame.
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, rowY)
                row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, rowY)
                -- v2.27.0: append "(affix-gated)" tag when the entry
                -- was added because the item carries a random affix.
                local affixTag = (affixSet and affixSet[id]) and " |cffaaaaaa(affix-gated)|r" or ""
                row.text:SetText(string.format("|cffb6ffb6%d|r  %s%s", id, name, affixTag))
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

        -- One Hide() after the prime loop instead of one per uncached
        -- item. SetOwner(ANCHOR_NONE) keeps the tooltip offscreen
        -- while we prime, then we hide it once at the end.
        if canPrime then
            primeFrame:Hide()
        end

        rowFactory.setActiveRows(shown)
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

    -- v2.28.0: debounce search refreshes. Each keystroke previously
    -- fired a full O(N) Refresh which on a 1000-item list walked the
    -- table, called GetItemInfo per entry, and rebuilt the visible
    -- rows. Typing "bloodpike" = 9 of those passes. Coalesce via a
    -- per-CreateListUI OnUpdate frame; first keystroke arms a 250 ms
    -- countdown, subsequent keystrokes reset it, idle window fires
    -- one Refresh.
    local searchDebounce = CreateFrame("Frame")
    searchDebounce:Hide()
    searchDebounce.elapsed = 0
    searchDebounce:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed >= 0.25 then
            self:Hide()
            Refresh()
        end
    end)
    search:SetScript("OnTextChanged", function()
        searchDebounce.elapsed = 0
        searchDebounce:Show()
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
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
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
            -- Combat lockdown blocks the InterfaceOptions panel-swap path;
            -- queue the open so it fires the moment combat ends. The user
            -- gets a one-line note so silent no-op doesn't look broken.
            if InCombatLockdown and InCombatLockdown() then
                EC_compCache.pendingOpenAfterCombat = "main"
                PrintNice("|cffffb84dSettings will open when combat ends.|r")
                return
            end
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
        elseif button == "MiddleButton" then
            local pbp = _G["EbonClearanceOptionsProcessBags"]
            if pbp and InterfaceOptionsFrame_OpenToCategory then
                if InCombatLockdown and InCombatLockdown() then
                    EC_compCache.pendingOpenAfterCombat = "process"
                    PrintNice("|cffffb84dProcess Bags will open when combat ends.|r")
                    return
                end
                -- Double-call is the 3.3.5a workaround for the first
                -- OpenToCategory landing on the parent's main panel
                -- instead of the requested sub-panel.
                InterfaceOptionsFrame_OpenToCategory(pbp)
                InterfaceOptionsFrame_OpenToCategory(pbp)
            end
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
        GameTooltip:AddLine("Left: Options  |  Middle: Process Bags  |  Right: Toggle Addon", 1, 1, 1)
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
    text = "Reset |cffb6ffb6EbonClearance|r lifetime stats?\n|cffaaaaaaThis clears money earned, items sold, items deleted, and repair totals. Session stats are not affected.|r",
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
    text = "Remove |cffffff00%d|r stale 'Upgrade'-tagged entries from your Keep List?\n"
        .. "|cffaaaaaaThese items were auto-tagged as upgrades but are no longer above your "
        .. "currently-equipped iLvl. Manual Keep List entries (no auto-tag) and 'Worn'-tagged "
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
        "Welcome to |cffb6ffb6EbonClearance|r! Bag management for Project Ebonhold: vendoring, deletion, looting, protection rules, and profession processing.",
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
        "Greys auto-sell. Whites and greens below your equipped iLvl auto-sell too, and looted upgrades are auto-protected.\n\n"
            .. "Use |cffb6ffb6Sell List|r (per-character or account-wide) to mark specific items for sale, "
            .. "|cffb6ffb6Keep List|r to permanently protect items, "
            .. "|cffb6ffb6Merchant Settings|r to tune the auto-sell rules per rarity, "
            .. "and |cffb6ffb6Process Bags|r to disenchant, mill, prospect, or pick lock from one button."
    )
    -- Tip on its own line, in grey, so it reads as a hint rather than
    -- another sentence in the main description block.
    local mainTip = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    mainTip:SetPoint("TOPLEFT", descLabel2, "BOTTOMLEFT", 0, -10)
    EC_compCache.setPanelWidth(mainTip, 16)
    mainTip:SetJustifyH("LEFT")
    mainTip:SetJustifyV("TOP")
    if mainTip.SetWordWrap then
        mainTip:SetWordWrap(true)
    end
    mainTip:SetText("|cff888888Tip: Alt+Right-Click any bag item for a quick-action menu.|r")

    -- Stats fontstrings. Stacked vertically; each attaches its ref to `panel`
    -- so RefreshStats can find them across subsequent OnShow calls.
    local money = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    money:SetPoint("TOPLEFT", mainTip, "BOTTOMLEFT", 0, -16)
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
            .. "|cffffff00/ec clean upgrades [apply]|r  Clean stale 'Upgrade'-tagged Keep List entries\n"
            .. "|cffffff00/ec sellinfo [bag slot]|r  Trace why a bag item will/won't sell |cffaaaaaa(or Alt+Shift+Right-Click)|r\n"
            .. "|cffffff00/ec bugreport|r  Generate a diagnostic report\n"
            .. "|cffffff00/ec help|r  Print full slash-command reference in chat\n"
            .. "|cffffff00/ecdebug|r  Show debug info and bag scan"
    )

    -- v2.12.0: size the scroll content to fit the bottom-most widget so
    -- the scroll bar engages when the Interface Options frame is too
    -- short to show everything (matches the Scavenger / Merchant /
    -- Profiles / Import-Export panels' pattern).
    EC_FitScrollContent(content, cmdText)
end

MainOptions:SetScript("OnShow", function(self)
    -- Stats helpers stay inside OnShow because RefreshStats captures `self`
    -- via closure and gets passed in two slots (the EC_compCache.initPanel
    -- refresh callback, and as the refresh fn handed to BuildMainPanel so
    -- the stat fields update after the merchant cycle). Re-declaring on
    -- each OnShow is cheap; the closures are reclaimed once initPanel
    -- returns.
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

    EC_compCache.initPanel(self, RefreshStats, function(self, content)
        -- v2.12.0: scroll-wrap the Main panel so the Slash Commands block
        -- at the bottom doesn't overlap the OK/Cancel button strip when
        -- the Interface Options frame is shorter than the panel content.
        -- Scavenger and Merchant Settings are wrapped the same way.
        BuildMainPanel(self, content, RefreshStats)
        RefreshStats()
    end, true)
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
    EC_compCache.initPanel(self, function(self)
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
    end, function(self, content)
        MakeHeader(content, "Merchant Settings", -16)
        -- Panel-specific intro only. Generic "grey junk auto-sells" cross-cut
        -- removed; it's covered on the Main panel.
        MakeLabel(content, "Tune which items auto-sell and at which merchants.", 16, -44)

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
            rt:SetText("Repair gear while vendoring")
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
        local guildRepairCB =
            CreateFrame("CheckButton", "EbonClearanceRepairGuildBankCB", content, "InterfaceOptionsCheckButtonTemplate")
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
            "Auto-sell rules per rarity. Each rarity has its own toggle, an optional cap, and a bind-type filter. Tick |cffffff00Use equipped iLvl|r for a dynamic cap that follows your equipped iLvl in the same slot (recommended; default ON for whites/greens on fresh installs). Untick for a fixed |cffffff00max iLvl|r - 0 = sell every item of that rarity. |cffaaaaaaSell List always sells; Keep List always protects.|r"
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
            local cb = AddCheckbox(
                content,
                "EbonClearanceQualityRow" .. qualityIdx .. "CB",
                anchor,
                labelText,
                function()
                    return DB.qualityRules[qualityIdx].enabled
                end,
                function(v)
                    DB.qualityRules[qualityIdx].enabled = v
                end,
                yOff
            )

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

            -- Re-anchor the rarity-row checkbox's auto-label so its right edge
            -- is bounded by the "Use equipped iLvl" text's left edge. The
            -- shared AddCheckbox helper applies a fixed 420 px label width
            -- which fits the wider Main / Protection Settings panels but
            -- overruns the right-anchored max-iLvl input on this row at
            -- narrow panel widths. Anchoring instead of fixed-width lets the
            -- rarity name truncate cleanly rather than visually colliding
            -- with the iLvl controls.
            local rowLabel = _G[cb:GetName() .. "Text"]
            if rowLabel then
                rowLabel:ClearAllPoints()
                rowLabel:SetPoint("LEFT", cb, "RIGHT", 4, 1)
                rowLabel:SetPoint("RIGHT", useEqText, "LEFT", -8, 0)
                rowLabel:SetJustifyH("LEFT")
                if rowLabel.SetWordWrap then
                    rowLabel:SetWordWrap(false)
                end
                if rowLabel.SetNonSpaceWrap then
                    rowLabel:SetNonSpaceWrap(false)
                end
            end

            useEqCB.tooltipText = "Use equipped iLvl"
            useEqCB.tooltipRequirement = "When checked, the cap for this rarity is your currently-equipped iLvl in the same slot. "
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
        local row1CB, row1Input, row1DD, row1UseEq =
            MakeQualityRow(thresholdDesc, 1, EC_WHITELIST_QUALITIES[1].text, -10)
        local row2CB, row2Input, row2DD, row2UseEq =
            MakeQualityRow(thresholdDesc, 2, EC_WHITELIST_QUALITIES[2].text, -88)
        local row3CB, row3Input, row3DD, row3UseEq =
            MakeQualityRow(thresholdDesc, 3, EC_WHITELIST_QUALITIES[3].text, -166)
        local row4CB, row4Input, row4DD, row4UseEq =
            MakeQualityRow(thresholdDesc, 4, EC_WHITELIST_QUALITIES[4].text, -244)

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
    end, true)
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
WhitelistPanel.name = "Sell List"
WhitelistPanel.parent = "EbonClearance"

WhitelistPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        MakeHeader(self, "Sell List", -16)

        -- Panel-specific description only. Cross-cutting info (grey junk
        -- auto-sell, quality threshold) lives on the Main panel to avoid
        -- repeating the same explanation on every list page.
        local descLabel = MakeLabel(
            self,
            "Specific items to always auto-sell on this character, regardless of rarity rules. Use the |cffb6ffb6Add from bags|r buttons below to bulk-add by colour, or shift-click an item to add it manually.",
            16,
            -44
        )

        -- Grey side-note on its own line.
        local descNote = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        descNote:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -6)
        EC_compCache.setPanelWidth(descNote, 16)
        descNote:SetJustifyH("LEFT")
        descNote:SetJustifyV("TOP")
        if descNote.SetWordWrap then
            descNote:SetWordWrap(true)
        end
        descNote:SetText(
            "|cffaaaaaaProfiles let you swap between different sell lists. For items you want sold on every alt, use |r|cffb6ffb6Account Sell List|r|cffaaaaaa instead.|r"
        )

        -- Cascade-anchor the scan row to the grey note's BOTTOMLEFT so it stays
        -- below regardless of how many lines the description / note wrap to.
        local scanRow = EC_AddScanByQualityRow(self, descNote, "whitelist", "the Sell List", function()
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
end)

-- ============================================================
-- Whitelist Profiles Panel
-- ============================================================
local ProfilesPanel = CreateFrame("Frame", "EbonClearanceOptionsProfiles", InterfaceOptionsFramePanelContainer)
ProfilesPanel.name = "Profiles"
ProfilesPanel.parent = "EbonClearance"

ProfilesPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(self)
        if self.RefreshProfileList then
            self:RefreshProfileList()
        end
    end, function(self)
        MakeHeader(self, "Profiles", -16)
        local descLabel = MakeLabel(
            self,
            "Profiles save and restore your |cffb6ffb6Sell List|r and |cffb6ffb6Keep List|r as a named pair. Switching profiles overwrites the live character lists with the saved snapshot. Handy for swapping between farming spots.",
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
            "|cffaaaaaaProfiles do NOT touch the |cffb6ffb6Account Sell List|r|cffaaaaaa (which is shared across every alt and never replaced). The |cffb6ffb6Default|r|cffaaaaaa profile is permanently empty - give your profile a real name before saving.|r"
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

            local clearBtn =
                CreateFrame("Button", "EbonClearanceProfileClear_" .. index, content, "UIPanelButtonTemplate")
            clearBtn:SetSize(52, 18)
            clearBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
            clearBtn:SetText("Clear")

            local loadBtn =
                CreateFrame("Button", "EbonClearanceProfileLoad_" .. index, content, "UIPanelButtonTemplate")
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
    -- Fingerprint suffix flags this export as EbonClearance-produced.
    -- Helper lives in EbonClearance_Core.lua, exposed as NS.Fingerprint.
    return payload .. ";fp=" .. NS.Fingerprint(payload)
end

-- Full settings pack: serialises qualityRules + Sell / Keep / Delete lists +
-- account Sell List into one shareable string. Extends the existing single-
-- list export model so a user can paste a friend's complete config in one
-- go. Format kept human-readable (line per record, comma-separated IDs);
-- the prefix below is checked first so the importer can route the right
-- parser. Pack strings are fingerprinted using the same helper the
-- single-list export uses, so a recipient can verify provenance the same
-- way.
EC_compCache.PACK_PREFIX = "EC_PACK_V1"

function EC_compCache.exportFullPack()
    -- Inner locals don't count against the main-chunk locals cap, so keep
    -- the formatting helpers inside the function body.
    local function formatRule(q)
        local r = DB and DB.qualityRules and DB.qualityRules[q]
        if not r then
            return string.format("QR:%d:0:0:any:0", q)
        end
        local en = r.enabled and 1 or 0
        local ilvl = tonumber(r.maxILvl) or 0
        local bf = r.bindFilter or "any"
        if bf ~= "boe" and bf ~= "bop" then
            bf = "any"
        end
        local eq = r.useEquippedILvl and 1 or 0
        return string.format("QR:%d:%d:%d:%s:%d", q, en, ilvl, bf, eq)
    end

    local function formatIDs(prefix, t)
        local ids = {}
        if t then
            for k, v in pairs(t) do
                if type(k) == "number" and (v == true or v == 1) then
                    ids[#ids + 1] = k
                end
            end
        end
        table.sort(ids)
        return prefix .. ":" .. table.concat(ids, ",")
    end

    local lines = { EC_compCache.PACK_PREFIX }
    for q = 1, 4 do
        lines[#lines + 1] = formatRule(q)
    end
    lines[#lines + 1] = formatIDs("SL", DB and DB.whitelist)
    lines[#lines + 1] = formatIDs("SLA", ADB and ADB.whitelist)
    lines[#lines + 1] = formatIDs("KL", DB and DB.blacklist)
    lines[#lines + 1] = formatIDs("DL", DB and DB.deleteList)
    local payload = table.concat(lines, "\n")
    return payload .. "\n;fp=" .. NS.Fingerprint(payload)
end

function EC_compCache.importFullPack(str, mode)
    if type(str) ~= "string" or str == "" then
        return false, "Empty string."
    end
    -- Normalise line endings + strip trailing fingerprint and whitespace.
    str = (str:gsub("\r\n", "\n"))
    str = (str:gsub(";fp=[0-9a-f]+%s*$", ""))
    str = (str:gsub("%s+$", ""))

    local lines = {}
    for line in str:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    if #lines == 0 or lines[1]:sub(1, #EC_compCache.PACK_PREFIX) ~= EC_compCache.PACK_PREFIX then
        return false, "Not a full settings pack. Use the single-list importer below."
    end

    -- Parse-then-apply: build the full snapshot first so a single malformed
    -- line doesn't half-apply the import.
    local sell, sellAcct, keep, del = {}, {}, {}, {}
    local rules = {}

    for i = 2, #lines do
        local line = lines[i]
        if line:sub(1, 3) == "QR:" then
            local q, en, ilvl, bf, eq = line:match("^QR:(%d+):(%d+):(%d+):(%w+):(%d+)$")
            q = tonumber(q)
            if q and q >= 1 and q <= 4 then
                rules[q] = {
                    enabled = (en == "1"),
                    maxILvl = tonumber(ilvl) or 0,
                    bindFilter = (bf == "boe" or bf == "bop") and bf or "any",
                    useEquippedILvl = (eq == "1"),
                }
            end
        else
            local prefix, payload = line:match("^([A-Z]+):(.*)$")
            local target
            if prefix == "SL" then
                target = sell
            elseif prefix == "SLA" then
                target = sellAcct
            elseif prefix == "KL" then
                target = keep
            elseif prefix == "DL" then
                target = del
            end
            if target and payload and payload ~= "" then
                for token in payload:gmatch("[^,]+") do
                    local n = tonumber(token:match("^%s*(%d+)%s*$"))
                    if n and n > 0 then
                        target[n] = true
                    end
                end
            end
        end
    end

    local function applyList(dst, parsed)
        if not dst then
            return
        end
        if mode == "replace" then
            wipe(dst)
        end
        for id in pairs(parsed) do
            dst[id] = true
        end
    end

    local sellAdded, keepAdded, delAdded, acctAdded = 0, 0, 0, 0
    local function countNew(dst, parsed)
        if not dst then
            return 0
        end
        local n = 0
        for id in pairs(parsed) do
            if not dst[id] then
                n = n + 1
            end
        end
        return n
    end

    if DB then
        sellAdded = countNew(DB.whitelist, sell)
        keepAdded = countNew(DB.blacklist, keep)
        delAdded = countNew(DB.deleteList, del)
        applyList(DB.whitelist, sell)
        applyList(DB.blacklist, keep)
        applyList(DB.deleteList, del)
        DB.qualityRules = DB.qualityRules or {}
        for q = 1, 4 do
            if rules[q] then
                DB.qualityRules[q] = DB.qualityRules[q] or {}
                local t = DB.qualityRules[q]
                t.enabled = rules[q].enabled
                t.maxILvl = rules[q].maxILvl
                t.bindFilter = rules[q].bindFilter
                t.useEquippedILvl = rules[q].useEquippedILvl
            end
        end
    end
    if ADB and ADB.whitelist then
        acctAdded = countNew(ADB.whitelist, sellAcct)
        applyList(ADB.whitelist, sellAcct)
    end

    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end

    -- Refresh any open list panels so the new contents render immediately.
    for _, panelName in ipairs({
        "EbonClearanceOptionsWhitelist",
        "EbonClearanceOptionsAccountWhitelist",
        "EbonClearanceOptionsBlacklist",
        "EbonClearanceOptionsDeletion",
        "EbonClearanceOptionsMerchant",
    }) do
        local p = _G[panelName]
        if p and p.listUI then
            p.listUI:Refresh()
        end
    end

    local modeLabel = (mode == "replace") and "replaced" or "merged"
    return true,
        string.format(
            "Imported settings pack (%s). Quality rules updated; Sell +%d, Keep +%d, Delete +%d, Account Sell +%d.",
            modeLabel,
            sellAdded,
            keepAdded,
            delAdded,
            acctAdded
        )
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
    EC_compCache.initPanel(self, nil, function(self)
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

        local exportCharCB =
            CreateFrame("CheckButton", "EbonClearanceExportSourceCharCB", self, "UIRadioButtonTemplate")
        exportCharCB:SetPoint("LEFT", exportScopeLabel, "RIGHT", 8, 0)
        exportCharCB:SetChecked(true)
        local exportCharLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        exportCharLbl:SetPoint("LEFT", exportCharCB, "RIGHT", 2, 1)
        exportCharLbl:SetText("Character")

        local exportAcctCB =
            CreateFrame("CheckButton", "EbonClearanceExportSourceAcctCB", self, "UIRadioButtonTemplate")
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
        exportNameBox:SetText("My Sell List")
        StyleInputBox(exportNameBox)

        local exportBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        exportBtn:SetSize(80, 22)
        exportBtn:SetPoint("LEFT", exportNameBox, "RIGHT", 8, 0)
        exportBtn:SetText("Export")

        -- Optional checkbox: when ticked, the Export button emits a full
        -- settings pack instead of the current single-list payload. Toggling
        -- it greys out the scope and name inputs since the pack covers every
        -- list and carries no name field. Off by default; existing exports
        -- remain unchanged.
        --
        -- Lives on its OWN row below the name input so the export controls
        -- never overflow on a narrow panel; the previous side-by-side layout
        -- pushed the checkbox off the right edge on smaller widths.
        local fullPackCB = CreateFrame("CheckButton", "EbonClearanceExportFullPackCB", self, "UICheckButtonTemplate")
        fullPackCB:SetPoint("TOPLEFT", exportNameLabel, "BOTTOMLEFT", 0, -8)
        fullPackCB:SetSize(22, 22)
        local fullPackLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fullPackLbl:SetPoint("LEFT", fullPackCB, "RIGHT", 2, 1)
        fullPackLbl:SetText("Full settings pack (rules + Sell / Keep / Delete + Account Sell)")
        fullPackCB:SetChecked(false)

        local function refreshExportInputsForPackMode(packMode)
            -- EditBox on 3.3.5a doesn't expose Enable/Disable like Button does;
            -- toggle mouse + keyboard interaction and drop focus instead. The
            -- alpha shift makes the disabled state visually obvious.
            if packMode then
                exportNameBox:ClearFocus()
                exportNameBox:EnableMouse(false)
                exportNameBox:EnableKeyboard(false)
                exportNameBox:SetTextColor(0.5, 0.5, 0.5)
            else
                exportNameBox:EnableMouse(true)
                exportNameBox:EnableKeyboard(true)
                exportNameBox:SetTextColor(1, 1, 1)
            end
            -- CheckButton derives from Button so Enable/Disable do exist here,
            -- but for symmetry with the EditBox path we drive both via alpha
            -- plus EnableMouse so the visual state stays consistent.
            for _, cb in ipairs({ exportCharCB, exportAcctCB }) do
                cb:EnableMouse(not packMode)
                cb:SetAlpha(packMode and 0.5 or 1)
            end
            exportNameLabel:SetAlpha(packMode and 0.5 or 1)
            exportScopeLabel:SetAlpha(packMode and 0.5 or 1)
            exportCharLbl:SetAlpha(packMode and 0.5 or 1)
            exportAcctLbl:SetAlpha(packMode and 0.5 or 1)
        end

        fullPackCB:SetScript("OnClick", function(self_)
            refreshExportInputsForPackMode(self_:GetChecked())
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        fullPackCB:SetScript("OnEnter", function(self_)
            GameTooltip:SetOwner(self_, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Full settings pack")
            GameTooltip:AddLine(
                "When ticked, Export produces one string covering quality rules, the Sell List, the Keep List, the Delete List, and the Account Sell List together. Off by default.",
                1,
                1,
                1,
                true
            )
            GameTooltip:Show()
        end)
        fullPackCB:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        -- Wrap the scroll frame in a thin backdrop frame so the input area is
        -- visually distinct. The raw ScrollFrame template doesn't carry any
        -- backdrop, so an empty box renders as a transparent void with no
        -- visual cue for where to click. The wrapper supplies the chrome;
        -- the scroll frame inside still owns scrolling behaviour.
        local exportBoxBg = CreateFrame("Frame", nil, self)
        exportBoxBg:SetPoint("TOPLEFT", fullPackCB, "BOTTOMLEFT", 0, -8)
        exportBoxBg:SetSize(EC_PANEL_WIDTH - 36, 50)
        exportBoxBg:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        exportBoxBg:SetBackdropColor(0, 0, 0, 0.6)
        exportBoxBg:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)
        -- Track the wrapper's width on panel resize so the input area follows
        -- the Interface Options frame resize handle.
        EC_compCache.registerWidth(exportBoxBg, 36)

        local exportScroll =
            CreateFrame("ScrollFrame", "EbonClearanceExportScroll", exportBoxBg, "UIPanelScrollFrameTemplate")
        exportScroll:SetPoint("TOPLEFT", 6, -6)
        exportScroll:SetPoint("BOTTOMRIGHT", -28, 6)

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
        -- Clicking anywhere in the backdrop area focuses the EditBox so the
        -- user doesn't have to land precisely on the (often empty) text
        -- glyphs to start typing or to highlight an existing export.
        exportBoxBg:EnableMouse(true)
        exportBoxBg:SetScript("OnMouseDown", function()
            exportBox:SetFocus()
        end)

        exportBtn:SetScript("OnClick", function()
            local str
            if fullPackCB:GetChecked() and EC_compCache.exportFullPack then
                str = EC_compCache.exportFullPack()
                exportBox:SetText(str)
                exportBox:HighlightText()
                exportBox:SetFocus()
                PlaySound("igMainMenuOptionCheckBoxOn")
                PrintNice(
                    "Exported full settings pack (rules + Sell / Keep / Delete + Account Sell). Copy the text above."
                )
            else
                str = EC_ExportWhitelist(exportNameBox:GetText(), exportScope)
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
            end
        end)

        -- === IMPORT SECTION ===
        MakeLabel(self, "Paste a Sell List string and pick which list it imports into.", 16, -228)

        local importScope = "character"

        local importScopeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        importScopeLabel:SetPoint("TOPLEFT", 16, -256)
        importScopeLabel:SetText("Target list:")

        local importCharCB =
            CreateFrame("CheckButton", "EbonClearanceImportTargetCharCB", self, "UIRadioButtonTemplate")
        importCharCB:SetPoint("LEFT", importScopeLabel, "RIGHT", 8, 0)
        importCharCB:SetChecked(true)
        local importCharLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        importCharLbl:SetPoint("LEFT", importCharCB, "RIGHT", 2, 1)
        importCharLbl:SetText("Character")

        local importAcctCB =
            CreateFrame("CheckButton", "EbonClearanceImportTargetAcctCB", self, "UIRadioButtonTemplate")
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

        -- Wrap in a backdrop frame for the same reason as the export box:
        -- the raw ScrollFrame is transparent until typed into, leaving the
        -- user with no visual target for paste. Wrapper supplies chrome;
        -- ScrollFrame inside owns scrolling.
        local importBoxBg = CreateFrame("Frame", nil, self)
        importBoxBg:SetPoint("TOPLEFT", 16, -284)
        importBoxBg:SetSize(EC_PANEL_WIDTH - 36, 50)
        importBoxBg:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        importBoxBg:SetBackdropColor(0, 0, 0, 0.6)
        importBoxBg:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)
        EC_compCache.registerWidth(importBoxBg, 36)

        local importScroll =
            CreateFrame("ScrollFrame", "EbonClearanceImportScroll", importBoxBg, "UIPanelScrollFrameTemplate")
        importScroll:SetPoint("TOPLEFT", 6, -6)
        importScroll:SetPoint("BOTTOMRIGHT", -28, 6)

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
        -- Clicking anywhere in the wrapper focuses the EditBox so users can
        -- paste without having to land on the (empty) glyph row inside the
        -- scroll frame.
        importBoxBg:EnableMouse(true)
        importBoxBg:SetScript("OnMouseDown", function()
            importBox:SetFocus()
        end)

        local importMergeBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        importMergeBtn:SetSize(120, 22)
        importMergeBtn:SetPoint("TOPLEFT", 16, -342)
        importMergeBtn:SetText("Import (Merge)")

        local importReplaceBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        importReplaceBtn:SetSize(120, 22)
        importReplaceBtn:SetPoint("LEFT", importMergeBtn, "RIGHT", 8, 0)
        importReplaceBtn:SetText("Import (Replace)")

        local statusFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        statusFS:SetPoint("TOPLEFT", 16, -370)
        EC_compCache.setPanelWidth(statusFS, 16)
        statusFS:SetJustifyH("LEFT")
        statusFS:SetText("")

        local function runImport(mode)
            local raw = importBox:GetText() or ""
            -- Auto-detect: full settings packs start with the EC_PACK_V1 marker
            -- on their first line. Anything else falls through to the existing
            -- single-list import, which honours the Target scope radio above.
            local firstLine = raw:match("^%s*([^\r\n]+)")
            local isPack = firstLine and firstLine:sub(1, #EC_compCache.PACK_PREFIX) == EC_compCache.PACK_PREFIX
            local ok, msg
            if isPack and EC_compCache.importFullPack then
                ok, msg = EC_compCache.importFullPack(raw, mode)
            else
                ok, msg = EC_ImportWhitelist(raw, mode, importScope)
            end
            statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
            if ok then
                PlaySound("igMainMenuOptionCheckBoxOn")
                PrintNice(msg)
                if isPack then
                -- The pack importer already refreshed every relevant panel,
                -- so nothing extra to do here.
                else
                    local panelName = (importScope == "account") and "EbonClearanceOptionsAccountWhitelist"
                        or "EbonClearanceOptionsWhitelist"
                    local wp = _G[panelName]
                    if wp and wp.listUI then
                        wp.listUI:Refresh()
                    end
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
end)

local DeletePanel = CreateFrame("Frame", "EbonClearanceOptionsDeletion", InterfaceOptionsFramePanelContainer)
DeletePanel.name = "Delete List"
DeletePanel.parent = "EbonClearance"

DeletePanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        MakeHeader(self, "Deletion Settings", -16)
        local delDesc = MakeLabel(
            self,
            "Items on this list are destroyed automatically on the next bag scan. This cannot be undone.",
            16,
            -44
        )
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

        local delCB =
            CreateFrame("CheckButton", "EbonClearanceEnableDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
        delCB:SetPoint("TOPLEFT", delHint, "BOTTOMLEFT", 0, -6)
        delCB:SetChecked(DB.enableDeletion)
        local dt = _G[delCB:GetName() .. "Text"]
        if dt then
            dt:SetText("Enable item deletion")
            dt:SetWidth(420)
            dt:SetJustifyH("LEFT")
        end
        delCB:SetScript("OnClick", function()
            DB.enableDeletion = delCB:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)

        self.listUI = CreateListUI(self, "Delete List", "deleteList", 16, -130)
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
end)

local ScavengerPanel = CreateFrame("Frame", "EbonClearanceOptionsScavenger", InterfaceOptionsFramePanelContainer)

ScavengerPanel.name = "Scavenger Settings"
ScavengerPanel.parent = "EbonClearance"

ScavengerPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(self)
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
        if self.fastLootCB then
            self.fastLootCB:SetChecked(DB.fastLoot)
        end
    end, function(self, content)
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
            st:SetText("Summon |cffff7f7fGreedy Scavenger|r after vendoring")
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
                NS.ApplyGreedyChatFilter()
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

        -- v2.16.0: Fast Loot. When on AND Blizzard's auto-loot CVar is
        -- effectively enabled (autoLootDefault XOR'd with the
        -- AUTOLOOTTOGGLE modifier), EC drains every slot in the loot
        -- window the moment LOOT_READY fires - the loot frame flashes
        -- briefly or skips entirely, and BoP-bind popups are auto-
        -- confirmed for items that would otherwise interrupt the drain.
        -- Pairs well with the auto-loot cycle for fast farming.
        local fastLootCB = AddCheckbox(
            content,
            "EbonClearanceFastLootCB",
            autoOpenNote,
            "Fast Loot (instant corpse looting)",
            function()
                return DB.fastLoot
            end,
            function(v)
                DB.fastLoot = v
            end,
            -10
        )
        -- AddCheckbox anchors at (0, yOff) from its anchor's BOTTOMLEFT, and
        -- our anchor (autoOpenNote) is itself indented +26 to align with the
        -- auto-open checkbox label. Back-shift the x by -26 to put fastLootCB
        -- on the panel's left margin, level with autoOpenCB above. Same trick
        -- the Protection Settings panel uses to keep its toggle stack
        -- left-aligned beneath each toggle's wrapped explanatory note.
        fastLootCB:ClearAllPoints()
        fastLootCB:SetPoint("TOPLEFT", autoOpenNote, "BOTTOMLEFT", -26, -10)
        self.fastLootCB = fastLootCB

        local fastLootNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fastLootNote:SetPoint("TOPLEFT", fastLootCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(fastLootNote, 60)
        fastLootNote:SetJustifyH("LEFT")
        if fastLootNote.SetWordWrap then
            fastLootNote:SetWordWrap(true)
        end
        fastLootNote:SetText(
            "|cff888888Speeds up manual looting (corpses, fishing, gift bags, dungeon/raid loot, mailbox). Honours Blizzard's |cffffff00Auto Loot|r|cff888888 setting. |cffff7f7fGreedy Scavenger|r|cff888888 looting is already instant and isn't affected.|r"
        )

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
        rightClickHint:SetPoint("TOPLEFT", fastLootNote, "BOTTOMLEFT", 0, -16)
        EC_compCache.setPanelWidth(rightClickHint, 60)
        rightClickHint:SetJustifyH("LEFT")
        if rightClickHint.SetWordWrap then
            rightClickHint:SetWordWrap(true)
        end
        rightClickHint:SetText(
            "|cffffb84dTip:|r |cff888888Alt+Right-Click any item in your bags for a quick-action menu (Sell, Keep, Delete, Sell Now).|r"
        )

        -- Size the scroll content to fit the bottom-most widget so the scrollbar
        -- range matches actual content (no excess empty space at the bottom).
        EC_FitScrollContent(content, rightClickHint)
    end, true)
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
        local v = (input:GetText() or ""):gsub("^[%s\194\160\226\128\139]+", ""):gsub("[%s\194\160\226\128\139]+$", "")
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
    EC_compCache.initPanel(self, function(self)
        if self.onlyCB then
            self.onlyCB:SetChecked(DB.enableOnlyListedChars)
        end
        if self.sellBorderCB then
            self.sellBorderCB:SetChecked(DB.sellBorderEnabled)
        end
        if self.RefreshSellBorderSwatch then
            self:RefreshSellBorderSwatch()
        end
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        MakeHeader(self, "Character Settings", -16)
        local charDesc = MakeLabel(
            self,
            "Prevents this addon from EC_compCache.vendorRunning on characters you didn't intend. If enabled, EbonClearance runs only on characters listed below.",
            16,
            -44
        )

        local cb = CreateFrame(
            "CheckButton",
            "EbonClearanceEnableOnlyListedCharsCB",
            self,
            "InterfaceOptionsCheckButtonTemplate"
        )
        cb:SetPoint("TOPLEFT", charDesc, "BOTTOMLEFT", 0, -8)
        cb:SetChecked(DB.enableOnlyListedChars)

        local t = _G[cb:GetName() .. "Text"]
        if t then
            t:SetText("Enable only for listed characters")
            EC_compCache.setPanelWidth(t, 60)
            t:SetJustifyH("LEFT")
        end

        cb:SetScript("OnClick", function()
            DB.enableOnlyListedChars = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        self.onlyCB = cb

        -- Bag display: opt-in coloured ring around bag slot frames whose items
        -- the current rule chain would sell at the next vendor visit. The ring
        -- texture sits on a frame-overlay sublevel and is anchored OUTSIDE the
        -- icon bounds; the icon itself stays untouched. Disabled by default
        -- so existing users see no visual change after upgrading.
        local bagHeader = self:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        bagHeader:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", -2, -18)
        bagHeader:SetText("Bag display")

        local bagDesc = MakeLabel(
            self,
            "Highlight bag items that would sell at the next vendor visit with a coloured border around the slot frame. The icon itself is never modified.",
            16,
            0
        )
        bagDesc:ClearAllPoints()
        bagDesc:SetPoint("TOPLEFT", bagHeader, "BOTTOMLEFT", 0, -6)

        local sbCB =
            CreateFrame("CheckButton", "EbonClearanceSellBorderCB", self, "InterfaceOptionsCheckButtonTemplate")
        sbCB:SetPoint("TOPLEFT", bagDesc, "BOTTOMLEFT", 0, -8)
        sbCB:SetChecked(DB.sellBorderEnabled)

        -- Text auto-sizes to its content (no width snapshot) so the colour
        -- button can dock immediately to the text's right edge without
        -- overlapping. The standard checkbox-template text anchors LEFT of
        -- the checkbox icon already; only the wrap width was the problem.
        local sbText = _G[sbCB:GetName() .. "Text"]
        if sbText then
            sbText:SetText("Show sell-border tint")
            sbText:SetJustifyH("LEFT")
        end

        sbCB:SetScript("OnClick", function()
            DB.sellBorderEnabled = sbCB:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)
        self.sellBorderCB = sbCB

        -- Colour button: opens the standard colour picker via the
        -- OpenColorPicker global. The global handles frame-strata elevation
        -- so the picker sits above the Interface Options frame instead of
        -- being occluded by it, which a direct ColorPickerFrame manipulation
        -- fails to do on this client. Picker writes channel-by-channel to
        -- DB.sellBorderColor and re-invokes the refresh helper so visible bag
        -- frames recolour instantly without waiting for the next bag event.
        local colourBtn = CreateFrame("Button", "EbonClearanceSellBorderColorBtn", self, "UIPanelButtonTemplate")
        colourBtn:SetSize(120, 22)
        -- Anchor to the checkbox text's right edge with a small gap. Falls
        -- back to the checkbox itself if the text font-string isn't exposed
        -- (template variant safety).
        if sbText then
            colourBtn:SetPoint("LEFT", sbText, "RIGHT", 12, 0)
        else
            colourBtn:SetPoint("LEFT", sbCB, "RIGHT", 140, 0)
        end
        colourBtn:SetText("Change colour")

        -- Swatch sits OUTSIDE the button frame, to its right, so it never
        -- overlaps the centred button text. Parented to the panel (not the
        -- button) so it isn't clipped by the button's content rect.
        local swatch = self:CreateTexture(nil, "OVERLAY")
        swatch:SetSize(16, 16)
        swatch:SetPoint("LEFT", colourBtn, "RIGHT", 6, 0)
        swatch:SetTexture("Interface\\Buttons\\WHITE8X8")

        local function updateSwatch()
            local c = DB.sellBorderColor or { r = 1, g = 0.82, b = 0, a = 0.9 }
            swatch:SetVertexColor(c.r, c.g, c.b, 1)
        end
        updateSwatch()
        self.RefreshSellBorderSwatch = function(panel)
            updateSwatch()
        end

        colourBtn:SetScript("OnClick", function()
            local c = DB.sellBorderColor

            local function commit(r, g, b, a)
                c.r, c.g, c.b, c.a = r, g, b, a
                updateSwatch()
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end

            local pickerInfo = {
                r = c.r,
                g = c.g,
                b = c.b,
                -- 3.3.5a opacity convention: 0 = fully opaque, 1 = fully
                -- transparent. Our stored alpha is the inverse; flip on the
                -- way in, flip back on the way out.
                opacity = 1 - (c.a or 0.9),
                hasOpacity = true,
                swatchFunc = function()
                    local r, g, b = ColorPickerFrame:GetColorRGB()
                    local a = 1 - (OpacitySliderFrame:GetValue() or 0)
                    commit(r, g, b, a)
                end,
                opacityFunc = function()
                    local r, g, b = ColorPickerFrame:GetColorRGB()
                    local a = 1 - (OpacitySliderFrame:GetValue() or 0)
                    commit(r, g, b, a)
                end,
                cancelFunc = function(prev)
                    if not prev then
                        return
                    end
                    commit(prev.r, prev.g, prev.b, 1 - (prev.opacity or 0))
                end,
            }
            OpenColorPicker(pickerInfo)
            -- 3.3.5a quirk: the InterfaceOptions container can sit at the
            -- same frame-strata as the colour picker, so the picker renders
            -- behind it on some clients. Force the picker to the top
            -- AFTER OpenColorPicker has reset the frame state.
            if ColorPickerFrame then
                ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
                if ColorPickerFrame.Raise then
                    ColorPickerFrame:Raise()
                end
            end
        end)

        self.listUI = CreateNameListUI(self, "Allowed Characters", "allowedChars", 16, -230)
        -- v2.11.0: anchor BOTTOMRIGHT so the list stretches with the panel
        -- on resize - keeps each row's "Remove" button inside the panel
        -- boundary even after the user shrinks the Interface Options frame.
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", 16, -230)
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)

-- ============================================================
-- Blacklist (Do Not Sell) Panel
-- ============================================================
local BlacklistPanel = CreateFrame("Frame", "EbonClearanceOptionsBlacklist", InterfaceOptionsFramePanelContainer)
BlacklistPanel.name = "Keep List"
BlacklistPanel.parent = "EbonClearance"

BlacklistPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        -- v2.15.0: the auto-protect toggles (autoAddEquipped, autoProtectUpgrades,
        -- autoProtectEquipmentSets) plus their explanatory notes used to live on
        -- this panel and dominated it visually - 3 checkboxes + 3 multi-line notes
        -- stacked above the actual list. They moved to the new `Protection Settings`
        -- sub-panel so this panel matches the Sell List / Delete List / Account
        -- Sell List rhythm (header + description + hint + list). DB field names
        -- unchanged so all event handlers, tooltip annotations, and slash commands
        -- continue to work without modification.
        MakeHeader(self, "Keep List (Do Not Sell)", -16)
        local blDesc = MakeLabel(
            self,
            "Specific items to permanently protect from auto-sell. Use this for valuable items you'd rather list at the auction house.",
            16,
            -44
        )

        -- Grey side-note on its own line so it doesn't blend into the
        -- white action text above.
        local blNote = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        blNote:SetPoint("TOPLEFT", blDesc, "BOTTOMLEFT", 0, -6)
        EC_compCache.setPanelWidth(blNote, 16)
        blNote:SetJustifyH("LEFT")
        blNote:SetJustifyV("TOP")
        if blNote.SetWordWrap then
            blNote:SetWordWrap(true)
        end
        blNote:SetText(
            "|cffaaaaaaFor automatic protection rules (equipped gear, looted upgrades, equipment sets, affixes, chance-on-hit), see the |r|cffffb84dProtection Settings|r|cffaaaaaa panel.|r"
        )

        -- Anchored to blNote so the hint stays below even when the
        -- description wraps to multiple lines.
        local blHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        blHint:SetPoint("TOPLEFT", blNote, "BOTTOMLEFT", 0, -8)
        EC_compCache.setPanelWidth(blHint, 16)
        blHint:SetJustifyH("LEFT")
        blHint:SetJustifyV("TOP")
        if blHint.SetWordWrap then
            blHint:SetWordWrap(true)
        end
        blHint:SetText("Add items by Shift-Clicking, dragging, or typing the Item ID below.")

        self.listUI = CreateListUI(self, "Protected Items", "blacklist", 16, -130)
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", blHint, "BOTTOMLEFT", 0, -16)
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)

-- ============================================================
-- v2.15.0 Protection Settings sub-panel (renamed from "Keep List Settings"
-- in v2.20.0 when the panel grew to cover affix + chance-on-hit protection
-- alongside the original Keep-List auto-protect toggles).
-- ============================================================
-- Holds the auto-protect toggles + explanatory notes that previously
-- cluttered the Keep List panel. Schema and behaviour are identical to the
-- pre-v2.15.0 surfacing; this is purely a visual split for consistency with
-- the other list panels' rhythm. The toggles still write to the same DB
-- fields (DB.autoAddEquipped, DB.autoProtectUpgrades, DB.autoProtectEquipmentSets)
-- and still call the same sync helpers (EC_compCache.syncEquipped /
-- checkBagsForUpgrades / syncEquipmentSets), so the PLAYER_EQUIPMENT_CHANGED
-- and EQUIPMENT_SETS_CHANGED reactive paths in the event hub continue to
-- drive the same protection without any wiring changes.
local BlacklistSettingsPanel =
    CreateFrame("Frame", "EbonClearanceOptionsBlacklistSettings", InterfaceOptionsFramePanelContainer)
BlacklistSettingsPanel.name = "Protection Settings"
BlacklistSettingsPanel.parent = "EbonClearance"

BlacklistSettingsPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(self)
        if self.autoEquipCB then
            self.autoEquipCB:SetChecked(DB.autoAddEquipped)
        end
        if self.autoUpgradeCB then
            self.autoUpgradeCB:SetChecked(DB.autoProtectUpgrades)
        end
        if self.autoSetCB then
            self.autoSetCB:SetChecked(DB.autoProtectEquipmentSets)
        end
        if self.autoAffixCB then
            self.autoAffixCB:SetChecked(DB.protectAffixedRareItems)
        end
        if self.dupeAffixCB then
            self.dupeAffixCB:SetChecked(DB.affixAllowExactDupes)
        end
        if self.UpdateDupeAffixEnabled then
            self:UpdateDupeAffixEnabled()
        end
        if self.procCB then
            self.procCB:SetChecked(DB.protectChanceOnHitItems)
        end
    end, function(self, content)
        -- Auto-protect handlers used to refresh `self.listUI` directly because
        -- the list lived on the same frame. Now the list lives on the Keep List
        -- panel, so toggles refresh that panel's list if it's been initialized.
        local function refreshKeepListUI()
            local blPanel = _G["EbonClearanceOptionsBlacklist"]
            if blPanel and blPanel.listUI then
                blPanel.listUI:Refresh()
            end
        end

        MakeHeader(content, "Protection Settings", -16)
        local desc = MakeLabel(
            content,
            "Automatic protection rules. Items matched by any rule below are added to your Keep List automatically and excluded from auto-sell.",
            16,
            -44
        )

        -- v2.10.0: auto-protect equipped gear. Toggling on runs a one-shot sync
        -- of every currently equipped slot into the Keep List, then a reactive
        -- PLAYER_EQUIPMENT_CHANGED handler keeps the list in step with future
        -- gear swaps. The blacklist veto in EC_IsSellable prevents auto-rules
        -- from touching anything on this list, so a replaced upgrade sliding
        -- into bags is automatically protected. Tooltip annotation surfaces
        -- "(auto-protected: equipped)" so users who decide they want an
        -- auto-added item sold can see why it's being kept.
        local autoEquipCB = CreateFrame(
            "CheckButton",
            "EbonClearanceAutoProtectEquippedCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        autoEquipCB:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
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
                refreshKeepListUI()
            end
        end)
        self.autoEquipCB = autoEquipCB

        local autoEquipNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        autoEquipNote:SetPoint("TOPLEFT", autoEquipCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(autoEquipNote, 60)
        autoEquipNote:SetJustifyH("LEFT")
        if autoEquipNote.SetWordWrap then
            autoEquipNote:SetWordWrap(true)
        end
        autoEquipNote:SetText(
            "|cff888888Adds your equipped gear to the Keep List, and anything you equip later. Alt+Right-Click an item to remove it.|r"
        )

        -- v2.11.0 auto-protect upgrades. The companion to v2.10.0's auto-
        -- protect-equipped: this one watches BAG_UPDATE for items whose iLvl
        -- exceeds the equipped item in any of their candidate slots (rings,
        -- trinkets, weapons compare against the lower of the two equipped
        -- slots so any genuine upgrade triggers). Looted upgrades sitting in
        -- bags are stamped on the Keep list before any iLvl-cap rule on
        -- Merchant Settings can sweep them up. Default off; opt-in.
        local autoUpgradeCB = CreateFrame(
            "CheckButton",
            "EbonClearanceAutoProtectUpgradesCB",
            content,
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
                refreshKeepListUI()
            end
        end)
        self.autoUpgradeCB = autoUpgradeCB

        local autoUpgradeNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        autoUpgradeNote:SetPoint("TOPLEFT", autoUpgradeCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(autoUpgradeNote, 60)
        autoUpgradeNote:SetJustifyH("LEFT")
        if autoUpgradeNote.SetWordWrap then
            autoUpgradeNote:SetWordWrap(true)
        end
        autoUpgradeNote:SetText(
            "|cff888888Auto-Keeps bag items with a higher iLvl than your current gear in the same slot.|r"
        )

        -- v2.13.0 Equipment Manager protection. Catches the dual-spec /
        -- off-set gap: items assigned to your alternate Blizzard equipment
        -- set sit in bags between swaps and aren't protected by
        -- autoAddEquipped (which only catches currently-equipped slots).
        -- One-shot sync at toggle, then EQUIPMENT_SETS_CHANGED reactive.
        local autoSetCB =
            CreateFrame("CheckButton", "EbonClearanceAutoProtectSetsCB", content, "InterfaceOptionsCheckButtonTemplate")
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
                refreshKeepListUI()
            end
        end)
        self.autoSetCB = autoSetCB

        local autoSetNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        autoSetNote:SetPoint("TOPLEFT", autoSetCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(autoSetNote, 60)
        autoSetNote:SetJustifyH("LEFT")
        if autoSetNote.SetWordWrap then
            autoSetNote:SetWordWrap(true)
        end
        autoSetNote:SetText(
            "|cff888888Auto-Keeps every item in your saved equipment-manager sets. Removing a set doesn't drop its items from the Keep List - Alt+Right-Click to remove them.|r"
        )

        -- v2.19.0 PE roguelite affix protection. The base itemID of an
        -- affixed item (e.g. "Thorbia's Gauntlets of Fortified by Pain IV")
        -- is identical to the base, plain version. A user with the base
        -- itemID on their Sell List or Delete List would inadvertently
        -- dump the random-affix version, which is meaningfully different
        -- gear. This toggle is a per-decision gate (no one-shot sync;
        -- protection runs at sell/delete time only). No Keep List
        -- entries are stamped - if the user wants the protected items
        -- on the Keep List explicitly, they Alt+Right-Click to add.
        local autoAffixCB = CreateFrame(
            "CheckButton",
            "EbonClearanceProtectAffixedRareCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        autoAffixCB:SetPoint("TOPLEFT", autoSetNote, "BOTTOMLEFT", -26, -10)
        autoAffixCB:SetChecked(DB.protectAffixedRareItems)
        local aaText = _G[autoAffixCB:GetName() .. "Text"]
        if aaText then
            aaText:SetText("Protect rare/epic items with random affixes")
            EC_compCache.setPanelWidth(aaText, 60)
            aaText:SetJustifyH("LEFT")
        end
        autoAffixCB:SetScript("OnClick", function(cb)
            DB.protectAffixedRareItems = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        self.autoAffixCB = autoAffixCB

        local autoAffixNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        autoAffixNote:SetPoint("TOPLEFT", autoAffixCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(autoAffixNote, 60)
        autoAffixNote:SetJustifyH("LEFT")
        if autoAffixNote.SetWordWrap then
            autoAffixNote:SetWordWrap(true)
        end
        autoAffixNote:SetText(
            "|cff888888Blue/Purple items with a random affix (e.g. |cffffb84d'of Fortified by Pain IV'|r|cff888888) are never sold or deleted, even when their itemID is listed.|r"
        )

        -- v2.23.0 child toggle: exact-rank duplicate gate on the affix
        -- protection. Reads PE's PerkService.GetGrantedPerks /
        -- GetLockedPerks (`_G.ProjectEbonhold`) to know which
        -- (affixName, rank) pairs the player owns. When ON AND a bag
        -- item's affix matches exact rank, the protection releases the
        -- item to the normal sell / DE rules. Inert without PE.
        local dupeAffixCB = CreateFrame(
            "CheckButton",
            "EbonClearanceAffixAllowExactDupesCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        -- Indent further right than the parent toggle: anchor under the
        -- parent's note (which already has +26 indent) with no horizontal
        -- offset, so the child sits a column to the right.
        dupeAffixCB:SetPoint("TOPLEFT", autoAffixNote, "BOTTOMLEFT", 0, -8)
        dupeAffixCB:SetChecked(DB.affixAllowExactDupes)
        local daText = _G[dupeAffixCB:GetName() .. "Text"]
        if daText then
            daText:SetText("Allow exact-rank duplicates to be sold / disenchanted")
            EC_compCache.setPanelWidth(daText, 86)
            daText:SetJustifyH("LEFT")
        end
        dupeAffixCB:SetScript("OnClick", function(cb)
            DB.affixAllowExactDupes = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        self.dupeAffixCB = dupeAffixCB

        local dupeAffixNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        dupeAffixNote:SetPoint("TOPLEFT", dupeAffixCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(dupeAffixNote, 86)
        dupeAffixNote:SetJustifyH("LEFT")
        if dupeAffixNote.SetWordWrap then
            dupeAffixNote:SetWordWrap(true)
        end
        self.dupeAffixNote = dupeAffixNote

        -- Greys-out the child CB when the parent toggle is off OR when PE
        -- isn't detected, and swaps the explanatory note for a "PE not
        -- detected" status line in that case. Called on init, on the
        -- parent CB's OnClick, and on every refresh-callback fire.
        local function UpdateDupeAffixEnabled()
            local peOn = EC_compCache.peDetected and EC_compCache.peDetected()
            local parentOn = DB.protectAffixedRareItems == true
            if peOn and parentOn then
                dupeAffixCB:Enable()
                if daText then
                    daText:SetTextColor(1, 1, 1)
                end
                dupeAffixNote:SetText(
                    "|cff888888Drops you already have at the same rank fall through to your sell rules. Different ranks of the same affix stay protected so you can still collect them all.|r"
                )
            else
                dupeAffixCB:Disable()
                if daText then
                    daText:SetTextColor(0.5, 0.5, 0.5)
                end
                if not peOn then
                    dupeAffixNote:SetText(
                        "|cff888888Project Ebonhold addon not detected. This feature needs PE's perk service to know which affixes you have.|r"
                    )
                else
                    dupeAffixNote:SetText("|cff888888Enable the affix protection above to use this option.|r")
                end
            end
        end
        self.UpdateDupeAffixEnabled = UpdateDupeAffixEnabled
        UpdateDupeAffixEnabled()

        -- Wire parent CB's OnClick to keep the child's enabled state in
        -- sync. (Replaces the simpler OnClick the parent had above.)
        autoAffixCB:SetScript("OnClick", function(cb)
            DB.protectAffixedRareItems = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            UpdateDupeAffixEnabled()
        end)

        -- v2.20.0 Chance-on-hit protection. Sibling toggle to the affix
        -- check above: Project Ebonhold lets players extract a weapon's
        -- "Chance on hit:" proc spell and apply it to another item, so an
        -- item with that proc text is meaningfully different from the
        -- base itemID. Same gate-at-decision-time design as the affix
        -- toggle. No quality filter because chance-on-hit is a stable
        -- per-itemID property and extraction works regardless of rarity.
        local procCB = CreateFrame(
            "CheckButton",
            "EbonClearanceProtectChanceOnHitCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        -- v2.23.0: anchor moved from autoAffixNote to dupeAffixNote so the
        -- new child toggle sits between the affix toggle and the chance-
        -- on-hit toggle visually.
        -- v2.26.0: x-offset corrected to -52 so procCB returns to the
        -- parent toggle's indent column (dupeAffixNote sits at +52 from
        -- the parent toggle column: +26 for the dupeAffixCB indent, +26
        -- for the note's indent under that). -26 only un-did one of those.
        procCB:SetPoint("TOPLEFT", dupeAffixNote, "BOTTOMLEFT", -52, -10)
        procCB:SetChecked(DB.protectChanceOnHitItems)
        local pcText = _G[procCB:GetName() .. "Text"]
        if pcText then
            pcText:SetText("Protect items with Chance on hit: effects")
            EC_compCache.setPanelWidth(pcText, 60)
            pcText:SetJustifyH("LEFT")
        end
        self.procCB = procCB

        local procNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        procNote:SetPoint("TOPLEFT", procCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(procNote, 60)
        procNote:SetJustifyH("LEFT")
        if procNote.SetWordWrap then
            procNote:SetWordWrap(true)
        end
        procNote:SetText(
            "|cff888888Items with a |cffffb84d'Chance on hit:'|r|cff888888 proc are skipped by the quality-threshold sweep. Explicitly listing them on the Sell or Delete List still works.|r"
        )

        -- v2.26.0 child toggle: exact-proc duplicate gate on the chance-
        -- on-hit protection. When ON AND a bag item's proc description
        -- matches an engraving spell the player has already extracted (via
        -- PE's Extraction Service / spellbook), the protection releases
        -- the item to the normal sell / DE rules. Inert without any
        -- learned procs.
        procCB:SetScript("OnClick", function(cb)
            DB.protectChanceOnHitItems = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)

        EC_FitScrollContent(content, procNote)
    end, true)
end)

local AccountWhitelistPanel =
    CreateFrame("Frame", "EbonClearanceOptionsAccountWhitelist", InterfaceOptionsFramePanelContainer)
AccountWhitelistPanel.name = "Account Sell List"
AccountWhitelistPanel.parent = "EbonClearance"

AccountWhitelistPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        MakeHeader(self, "Account Sell List", -16)
        local descLabel = MakeLabel(
            self,
            "Specific items to always auto-sell on |cffffff00every|r character on this account. Useful for shared trash like reagents or seasonal items.",
            16,
            -44
        )

        -- Grey side-note on its own line so the action text and the
        -- side info stay visually separate.
        local descNote = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        descNote:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -6)
        EC_compCache.setPanelWidth(descNote, 16)
        descNote:SetJustifyH("LEFT")
        descNote:SetJustifyV("TOP")
        if descNote.SetWordWrap then
            descNote:SetWordWrap(true)
        end
        descNote:SetText("|cffaaaaaaThis list is not part of profiles - it stays the same when you switch profiles.|r")

        -- Cascade-anchor the scan row to the grey note's BOTTOMLEFT so it stays
        -- below regardless of how many lines the description / note wrap to.
        local scanRow = EC_AddScanByQualityRow(self, descNote, "accountWhitelist", "the Account Sell List", function()
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
end)

-- ============================================================
-- v2.22.0 Process Bags panel
-- ============================================================
-- Lets the player batch-cast Disenchant / Milling / Prospecting on
-- eligible bag items via a SecureActionButton macro. The button's
-- macrotext is rewritten between casts to point at the next queued
-- item; the user clicks (hardware event) to fire each cast. Re-arm
-- happens on BAG_UPDATE so the queue follows the actual bag state
-- after each successful cast.
local ProcessBagsPanel = CreateFrame("Frame", "EbonClearanceOptionsProcessBags", InterfaceOptionsFramePanelContainer)
ProcessBagsPanel.name = "Process Bags"
ProcessBagsPanel.parent = "EbonClearance"

-- Re-arms the SecureActionButton's macrotext with the next eligible
-- queue entry. No-op during combat lockdown (SetAttribute is
-- protected). Hung off EC_compCache so the BAG_UPDATE / panel /
-- registration code paths can all reach it.
function EC_compCache.rearmProcessButton()
    local panel = _G["EbonClearanceOptionsProcessBags"]
    if not panel or not panel.castBtn then
        return
    end
    -- v2.24.0 perf: skip the full bag walk + tooltip scans when the
    -- user isn't actively using the Process Bags workflow. Two cases
    -- where we still need to arm:
    --   1. Panel is shown - user is interacting with the list, so
    --      the cast button's macrotext must point at the current
    --      next-item.
    --   2. Cast button has a keybind - user might press it from
    --      anywhere (e.g. hold-key-to-drain a herb stack mid-farm).
    -- If neither, the macrotext won't be observed, so skipping saves
    -- ~100 slot checks + per-Rare/Epic tooltip scans per BAG_UPDATE.
    -- This was the dominant cost during pet AOE looting (1.5 s freezes
    -- reported by the user during v2.22.0+v2.23.0 testing).
    local hasBinding = GetBindingKey and GetBindingKey("CLICK EbonClearanceProcessCastBtn:LeftButton") ~= nil
    if not panel:IsShown() and not hasBinding then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        -- PLAYER_REGEN_ENABLED handler retries when combat exits.
        return
    end
    -- Cursor priority on each rearm:
    --   1. (armedBag, armedSlot): the exact bag slot the user picked.
    --      Unique even when two stacks of the same item exist (itemID
    --      and itemString are identical for e.g. two Copper Ore
    --      stacks). Survives transient bag-slot locks during cast
    --      resolution because we include locked slots in the list.
    --   2. armedMode: sticky preference set by the skip button. Used
    --      when the original slot is empty (DE consumed, mill/prospect
    --      stack drained below 5) - hunts for the next entry of the
    --      same mode.
    --   3. armedIndex (clamped): fallback for fresh-open / no prior
    --      cursor state.
    local list = EC_compCache.buildProcessSummary()
    local entry
    -- v2.25.0: cursor must skip entries in collapsed sections. A
    -- collapsed section's items aren't visible, so the user can't
    -- audit before clicking; auto-arming on one would be a footgun.
    -- The header above the section stays visible so the player can
    -- re-expand and continue.
    local collapsed = DB.processCollapsedModes or {}
    local function isCollapsed(e)
        return e and collapsed[e.mode] == true
    end
    if #list > 0 then
        local idx
        -- Step 1: exact (bag, slot) match - but skip if the matched
        -- entry's section is collapsed. The user's prior arm pointed
        -- at this row, but they've since hidden the section, so
        -- treat as "no specific cursor" and fall through.
        if EC_compCache.armedBag and EC_compCache.armedSlot then
            for i = 1, #list do
                if list[i].bag == EC_compCache.armedBag and list[i].slot == EC_compCache.armedSlot then
                    if not isCollapsed(list[i]) then
                        idx = i
                    end
                    break
                end
            end
        end
        -- Step 2: armedMode sticky preference - only if the mode
        -- itself isn't collapsed.
        if not idx and EC_compCache.armedMode and not (collapsed[EC_compCache.armedMode] == true) then
            for i = 1, #list do
                if list[i].mode == EC_compCache.armedMode and not isCollapsed(list[i]) then
                    idx = i
                    break
                end
            end
            if not idx then
                EC_compCache.armedMode = nil
            end
        end
        -- Step 3: armedIndex fallback, walking forward to the first
        -- non-collapsed entry. If everything is collapsed, idx stays
        -- nil and entry stays nil (button shows "Nothing eligible").
        if not idx then
            local start = EC_compCache.armedIndex or 1
            if start < 1 or start > #list then
                start = 1
            end
            for i = start, #list do
                if not isCollapsed(list[i]) then
                    idx = i
                    break
                end
            end
            -- Wrap to the start if forward walk found nothing.
            if not idx then
                for i = 1, start - 1 do
                    if not isCollapsed(list[i]) then
                        idx = i
                        break
                    end
                end
            end
        end
        if idx then
            entry = list[idx]
            EC_compCache.armedIndex = idx
            EC_compCache.armedBag = entry.bag
            EC_compCache.armedSlot = entry.slot
        end
    end
    if entry then
        panel.castBtn:SetAttribute(
            "macrotext",
            string.format("/cast %s\n/use %d %d", entry.spellName, entry.bag, entry.slot)
        )
        panel.castBtn:Enable()
        if panel.castBtnLabel then
            -- Mode label only; the dynamic item name lives on the
            -- separate label below the button so a long item name
            -- can't overflow the fixed button width.
            panel.castBtnLabel:SetText(string.format("Process Next (%s)", entry.mode))
        end
        if panel.nextItemLabel then
            local short = (GetItemInfo(entry.itemID)) or "item"
            panel.nextItemLabel:SetText(string.format("|cffaaaaaaNext:|r %s", short))
        end
    else
        panel.castBtn:SetAttribute("macrotext", "")
        panel.castBtn:Disable()
        if panel.castBtnLabel then
            panel.castBtnLabel:SetText("Process Next")
        end
        if panel.nextItemLabel then
            panel.nextItemLabel:SetText("|cffaaaaaaNothing eligible.|r")
        end
    end
    EC_compCache.updateProcessSelection()
end

-- Repaints the persistent "armed" highlight on the row whose entryIndex
-- matches EC_compCache.armedIndex. Called from rearm so any cursor
-- change (skip arrow, left-click on a row, BAG_UPDATE re-arm) reflects
-- in the list immediately. Cheap loop; rows table is small.
function EC_compCache.updateProcessSelection()
    local panel = _G["EbonClearanceOptionsProcessBags"]
    if not panel or not panel.rows then
        return
    end
    local armed = EC_compCache.armedIndex
    for i = 1, #panel.rows do
        local row = panel.rows[i]
        if row and row.sel then
            if row:IsShown() and row.entryIndex == armed then
                row.sel:SetAlpha(0.45)
            else
                row.sel:SetAlpha(0)
            end
        end
    end
end

-- Advance the armed-cast target by one entry in the current list and
-- remember the chosen mode so the BAG_UPDATE re-arm stays on that mode
-- after the next successful cast (until no more entries of that mode
-- remain).
function EC_compCache.skipProcessTarget()
    local list = EC_compCache.buildProcessSummary()
    if #list == 0 then
        return
    end
    -- v2.25.0: cycle past collapsed-section entries. Try forward from
    -- current+1, wrap to start. If every entry is collapsed, no-op
    -- (the cast button is already disabled by rearmProcessButton in
    -- that case).
    local collapsed = DB.processCollapsedModes or {}
    local start = (EC_compCache.armedIndex or 1) + 1
    if start > #list then
        start = 1
    end
    local idx
    for i = start, #list do
        if not (collapsed[list[i].mode] == true) then
            idx = i
            break
        end
    end
    if not idx then
        for i = 1, start - 1 do
            if not (collapsed[list[i].mode] == true) then
                idx = i
                break
            end
        end
    end
    if not idx then
        return -- everything collapsed, leave cursor as-is
    end
    EC_compCache.armedIndex = idx
    EC_compCache.armedMode = list[idx].mode
    EC_compCache.armedBag = list[idx].bag
    EC_compCache.armedSlot = list[idx].slot
    EC_compCache.rearmProcessButton()
end

-- Refreshes the scrolling item list AND re-arms the cast button.
-- Called from OnShow, the Refresh button, and BAG_UPDATE.
function EC_compCache.refreshProcessPanel()
    local panel = _G["EbonClearanceOptionsProcessBags"]
    if not panel or not panel.rows then
        return
    end
    -- Update the Clear Ignored button (visible/labelled with current count).
    if panel.clearIgnoredBtn then
        local n = 0
        for _ in pairs(DB.processIgnored or {}) do
            n = n + 1
        end
        if n > 0 then
            panel.clearIgnoredBtn:SetText(string.format("Clear Ignored (%d)", n))
            panel.clearIgnoredBtn:Show()
        else
            panel.clearIgnoredBtn:Hide()
        end
    end
    -- Hide all existing rows
    for i = 1, #panel.rows do
        panel.rows[i]:Hide()
    end
    for i = 1, #(panel.headers or {}) do
        panel.headers[i]:Hide()
    end
    local list = EC_compCache.buildProcessSummary()
    if #list == 0 then
        if panel.emptyState then
            panel.emptyState:Show()
        end
        EC_compCache.rearmProcessButton()
        return
    end
    if panel.emptyState then
        panel.emptyState:Hide()
    end
    -- Group rows by mode with a section header above each group.
    -- rowAnchor is positioned in the build callback just below the
    -- dropdown so rows/headers don't overlap the panel's top controls.
    local anchor = panel.rowAnchor or panel.content
    local rowY = 0
    local rowIdx = 0
    local headerIdx = 0
    local lastMode = nil
    local modeCounts = {}
    for i = 1, #list do
        modeCounts[list[i].mode] = (modeCounts[list[i].mode] or 0) + 1
    end
    local collapsedModes = DB.processCollapsedModes or {}
    for i = 1, #list do
        local entry = list[i]
        if entry.mode ~= lastMode then
            headerIdx = headerIdx + 1
            local header = panel.headers and panel.headers[headerIdx]
            if not header then
                -- v2.25.0: section headers are Buttons (not bare
                -- FontStrings) so the player can click to collapse /
                -- expand. The button spans the panel width; the
                -- FontString child holds the text + ▼/▶ indicator.
                header = CreateFrame("Button", nil, panel.content)
                header:SetHeight(16)
                header:EnableMouse(true)
                header:RegisterForClicks("LeftButtonUp")
                local txt = header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
                txt:SetPoint("LEFT", header, "LEFT", 0, 0)
                txt:SetPoint("RIGHT", header, "RIGHT", 0, 0)
                txt:SetJustifyH("LEFT")
                header.text = txt
                header:SetScript("OnClick", function(self)
                    if not self.mode then
                        return
                    end
                    DB.processCollapsedModes = DB.processCollapsedModes or {}
                    DB.processCollapsedModes[self.mode] = not (DB.processCollapsedModes[self.mode] == true)
                    PlaySound("igMainMenuOptionCheckBoxOn")
                    EC_compCache.refreshProcessPanel()
                end)
                panel.headers = panel.headers or {}
                panel.headers[headerIdx] = header
            end
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, rowY)
            header:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, rowY)
            header.mode = entry.mode
            local isCollapsed = collapsedModes[entry.mode] == true
            local indicator = isCollapsed and "|cffaaaaaa>|r" or "|cffaaaaaav|r"
            header.text:SetText(
                string.format(
                    "%s |cffffb84d%s|r |cffaaaaaa(%d)|r",
                    indicator,
                    entry.mode:upper(),
                    modeCounts[entry.mode]
                )
            )
            header:Show()
            rowY = rowY - 18
            lastMode = entry.mode
        end
        -- v2.25.0: skip rendering rows in collapsed sections. The
        -- section header above is still shown so the player can
        -- click to expand. rowY stays where the header left it, so
        -- the next section's header anchors directly below the
        -- collapsed-section header.
        if not (collapsedModes[entry.mode] == true) then
            rowIdx = rowIdx + 1
            local row = panel.rows[rowIdx]
            if not row then
                row = CreateFrame("Button", nil, panel.content)
                row:SetHeight(20)
                row:EnableMouse(true)
                row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                local txt = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                txt:SetPoint("LEFT", row, "LEFT", 16, 0)
                txt:SetPoint("RIGHT", row, "RIGHT", -16, 0)
                txt:SetJustifyH("LEFT")
                row.text = txt
                -- sel: persistent "armed" highlight. Yellow tint via the
                -- ADD blend so it doesn't fight the hover texture above.
                local sel = row:CreateTexture(nil, "BACKGROUND")
                sel:SetAllPoints(row)
                sel:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                sel:SetBlendMode("ADD")
                sel:SetVertexColor(1.0, 0.85, 0.3)
                sel:SetAlpha(0)
                row.sel = sel
                local hl = row:CreateTexture(nil, "ARTWORK")
                hl:SetAllPoints(row)
                hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                hl:SetBlendMode("ADD")
                hl:SetAlpha(0)
                row:SetScript("OnEnter", function(self)
                    hl:SetAlpha(0.3)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if self.bag and self.slot then
                        GameTooltip:SetBagItem(self.bag, self.slot)
                    elseif self.itemLink then
                        GameTooltip:SetHyperlink(self.itemLink)
                    end
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function()
                    hl:SetAlpha(0)
                    GameTooltip:Hide()
                end)
                row:SetScript("OnClick", function(self, button)
                    if button == "RightButton" and self.itemString then
                        DB.processIgnored = DB.processIgnored or {}
                        DB.processIgnored[self.itemString] = true
                        PrintNicef(
                            "Ignored |cffb6ffb6%s|r in Process Bags. Click |cffffb84dClear Ignored|r on the panel to restore.",
                            (GetItemInfo(self.itemID)) or "item"
                        )
                        EC_compCache.refreshProcessPanel()
                        PlaySound("igMainMenuOptionCheckBoxOn")
                    elseif button == "LeftButton" and self.entryIndex and self.entryMode then
                        -- Pick this row as the armed target directly.
                        EC_compCache.armedIndex = self.entryIndex
                        EC_compCache.armedMode = self.entryMode
                        EC_compCache.armedBag = self.bag
                        EC_compCache.armedSlot = self.slot
                        EC_compCache.rearmProcessButton()
                        PlaySound("igMainMenuOptionCheckBoxOn")
                    end
                end)
                panel.rows[rowIdx] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", anchor, "TOPLEFT", 16, rowY)
            row:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -16, rowY)
            row.bag = entry.bag
            row.slot = entry.slot
            row.itemID = entry.itemID
            row.itemString = entry.itemString
            row.itemLink = entry.link
            -- v2.25.0: entryIndex tracks the list[] position (which spans
            -- both visible and collapsed entries), not the visible-row
            -- counter. armedIndex is also a list[] index, so this keeps
            -- the selection-paint comparison correct after some sections
            -- are collapsed.
            row.entryIndex = i
            row.entryMode = entry.mode
            if entry.perCast and entry.perCast > 1 then
                row.text:SetText(
                    string.format(
                        "%s  |cffaaaaaax%d -> %d cast%s|r",
                        entry.link,
                        entry.count,
                        entry.casts,
                        entry.casts == 1 and "" or "s"
                    )
                )
            else
                row.text:SetText(string.format("%s  |cffaaaaaax%d|r", entry.link, entry.count))
            end
            row:Show()
            rowY = rowY - 20
        end -- end "if not collapsed" wrap (v2.25.0)
    end
    -- Grow content so rows fit below rowAnchor. The cast/refresh
    -- buttons live on the panel itself (outside the scroll), so the
    -- content only needs to cover the top controls + list.
    if panel.content and panel.content.SetHeight and panel.rowAnchorOffset then
        local listH = math.abs(rowY) + 8
        panel.content:SetHeight(panel.rowAnchorOffset + listH + 16)
    end
    EC_compCache.rearmProcessButton()
end

ProcessBagsPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(self)
        if self.includeSoulboundCB then
            self.includeSoulboundCB:SetChecked(DB.processIncludeSoulbound)
        end
        if self.UpdateDEDropdownText then
            self:UpdateDEDropdownText()
        end
        -- Reset the armed cursor so re-opening the panel starts fresh
        -- rather than honouring a stale skip from a previous session.
        EC_compCache.armedIndex = 1
        EC_compCache.armedMode = nil
        EC_compCache.armedBag = nil
        EC_compCache.armedSlot = nil
        EC_compCache.refreshProcessPanel()
    end, function(self, content)
        MakeHeader(content, "Process Bags", -16)
        local desc = MakeLabel(
            content,
            "Disenchant, mill, prospect, or pick lock bag items. |cffffd870Left-click|r a row to select it. |cffffd870Right-click|r a row to hide it (use |cffffb84dClear Ignored|r to bring hidden items back). The |cffffb84d>|r arrow moves to the next item. Click |cffffb84dProcess Next|r to cast on the selected row.",
            16,
            -44
        )

        local tip = MakeLabel(
            content,
            "|cff888888Tip: bind a key to Process Next under Key Bindings, then hold it to drain a stack hands-free.|r",
            16,
            -44
        )
        tip:ClearAllPoints()
        tip:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -8)

        local sbCB = CreateFrame(
            "CheckButton",
            "EbonClearanceProcessIncludeSoulboundCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        sbCB:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", 0, -10)
        sbCB:SetChecked(DB.processIncludeSoulbound)
        local sbText = _G[sbCB:GetName() .. "Text"]
        if sbText then
            sbText:SetText("Include Soulbound items (Disenchant only)")
            EC_compCache.setPanelWidth(sbText, 60)
            sbText:SetJustifyH("LEFT")
        end
        sbCB:SetScript("OnClick", function(cb)
            DB.processIncludeSoulbound = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            EC_compCache.refreshProcessPanel()
        end)
        self.includeSoulboundCB = sbCB

        -- DE quality cap dropdown
        local ddLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        ddLabel:SetPoint("TOPLEFT", sbCB, "BOTTOMLEFT", 0, -10)
        ddLabel:SetText("Disenchant up to:")

        local dd = CreateFrame("Frame", "EbonClearanceProcessDEQualityDD", content, "UIDropDownMenuTemplate")
        dd:SetPoint("LEFT", ddLabel, "RIGHT", -8, -2)
        local qualityNames = { [2] = "Green", [3] = "Blue", [4] = "Epic" }
        UIDropDownMenu_SetWidth(dd, 100)
        local function ddSet(q)
            DB.processMaxDEQuality = q
            UIDropDownMenu_SetText(dd, qualityNames[q] or "Epic")
            CloseDropDownMenus()
            EC_compCache.refreshProcessPanel()
        end
        UIDropDownMenu_Initialize(dd, function()
            for _, q in ipairs({ 2, 3, 4 }) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = qualityNames[q]
                info.value = q
                info.checked = (DB.processMaxDEQuality == q)
                info.func = function()
                    ddSet(q)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetText(dd, qualityNames[DB.processMaxDEQuality or 4] or "Epic")
        function self:UpdateDEDropdownText()
            UIDropDownMenu_SetText(dd, qualityNames[DB.processMaxDEQuality or 4] or "Epic")
        end

        -- Clear-ignored button. Sits to the right of the DE dropdown.
        -- Hidden when there's nothing to clear so the panel doesn't
        -- carry chrome for a never-used state.
        local clearBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        clearBtn:SetSize(150, 20)
        clearBtn:SetPoint("LEFT", dd, "RIGHT", 8, 2)
        clearBtn:SetText("Clear Ignored (0)")
        clearBtn:Hide()
        clearBtn:SetScript("OnClick", function()
            DB.processIgnored = {}
            PrintNice("Process Bags ignored list cleared.")
            EC_compCache.refreshProcessPanel()
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        clearBtn:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText("Clear ignored list")
            GameTooltip:AddLine(
                "|cffaaaaaaRestores every item you've right-clicked to hide. Per-character.|r",
                1,
                1,
                1,
                true
            )
            GameTooltip:Show()
        end)
        clearBtn:SetScript("OnLeave", GameTooltip_Hide)
        self.clearIgnoredBtn = clearBtn

        -- rowAnchor frame: a zero-height anchor parked below the
        -- dropdown so the dynamic rows / section headers stack from a
        -- known Y without overlapping the static controls above.
        local rowAnchor = CreateFrame("Frame", nil, content)
        rowAnchor:SetPoint("TOPLEFT", ddLabel, "BOTTOMLEFT", 0, -20)
        rowAnchor:SetPoint("TOPRIGHT", content, "TOPRIGHT", -16, 0)
        rowAnchor:SetHeight(1)
        self.rowAnchor = rowAnchor
        -- Approximate vertical space reserved above rowAnchor (header +
        -- desc + tip + checkbox + dropdown + paddings). Used by
        -- SetHeight in refresh so the scroll content grows from the
        -- proper origin.
        self.rowAnchorOffset = 200

        -- Empty state pinned to rowAnchor so it sits where the list
        -- would begin.
        local empty = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        empty:SetPoint("TOPLEFT", rowAnchor, "TOPLEFT", 0, -4)
        EC_compCache.setPanelWidth(empty, 16)
        empty:SetJustifyH("LEFT")
        if empty.SetWordWrap then
            empty:SetWordWrap(true)
        end
        empty:SetText(
            "|cff888888No eligible items. Learn Disenchant, Milling, Prospecting, or Pick Lock and pick up some loot to fill this list.|r"
        )
        empty:Hide()
        self.emptyState = empty

        self.content = content
        self.rows = {}
        self.headers = {}

        -- Cast/refresh buttons live on the panel itself (not the scroll
        -- content) so they don't slide around as the list collapses
        -- under them. The scroll frame is re-anchored below to reserve
        -- a fixed 56 px strip at the panel's bottom for the buttons.
        local castBtn = CreateFrame(
            "Button",
            "EbonClearanceProcessCastBtn",
            self,
            "SecureActionButtonTemplate,UIPanelButtonTemplate"
        )
        castBtn:SetSize(200, 24)
        castBtn:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 16, 16)
        castBtn:SetAttribute("type", "macro")
        castBtn:SetAttribute("macrotext", "")
        castBtn:RegisterForClicks("AnyUp")
        castBtn:SetText("Process Next")
        self.castBtn = castBtn
        self.castBtnLabel = castBtn:GetFontString()

        -- Skip arrow: advances the armed cast target to the next list
        -- entry. Lets the user reach Mill / Prospect without first
        -- processing every Disenchant row. Sticky on mode (see
        -- EC_compCache.skipProcessTarget) so the next BAG_UPDATE
        -- re-arm stays on the picked mode until it runs out.
        local skipBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        skipBtn:SetSize(28, 22)
        skipBtn:SetPoint("LEFT", castBtn, "RIGHT", 4, 1)
        skipBtn:SetText(">")
        skipBtn:SetScript("OnClick", function()
            EC_compCache.skipProcessTarget()
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        skipBtn:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText("Skip to next item")
            GameTooltip:AddLine(
                "|cffaaaaaaCycle through the queue without casting. Sticks to the picked mode until it's empty.|r",
                1,
                1,
                1,
                true
            )
            GameTooltip:Show()
        end)
        skipBtn:SetScript("OnLeave", GameTooltip_Hide)

        local refreshBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        refreshBtn:SetSize(100, 22)
        refreshBtn:SetPoint("LEFT", skipBtn, "RIGHT", 8, 0)
        refreshBtn:SetText("Refresh")
        refreshBtn:SetScript("OnClick", function()
            -- Refresh resets the armed cursor + mode preference: the
            -- user is asking for a fresh start.
            EC_compCache.armedIndex = 1
            EC_compCache.armedMode = nil
            EC_compCache.armedBag = nil
            EC_compCache.armedSlot = nil
            EC_compCache.refreshProcessPanel()
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)

        -- Dynamic "Next: ..." label above the cast button. The item
        -- name lives here (not in the button label) so a long item
        -- name can't overlap the button chrome.
        local nextLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        nextLbl:SetPoint("BOTTOMLEFT", castBtn, "TOPLEFT", 0, 4)
        nextLbl:SetPoint("BOTTOMRIGHT", refreshBtn, "TOPRIGHT", 0, 4)
        nextLbl:SetJustifyH("LEFT")
        nextLbl:SetText("")
        self.nextItemLabel = nextLbl

        -- Shrink the scroll frame from the bottom so it doesn't run
        -- under the button strip. EC_WrapPanelInScrollFrame anchored it
        -- to BOTTOMRIGHT(-26, 6); reserve 56 px for the button row +
        -- "Next:" label + padding.
        local scroll = _G[self:GetName() .. "Scroll"]
        if scroll then
            scroll:ClearAllPoints()
            scroll:SetPoint("TOPLEFT", 0, 0)
            scroll:SetPoint("BOTTOMRIGHT", -26, 62)
        end

        EC_compCache.refreshProcessPanel()
    end, true)
end)

-- Register sub-panels in alphabetical order
InterfaceOptions_AddCategory(CharPanel)
InterfaceOptions_AddCategory(ScavengerPanel)
InterfaceOptions_AddCategory(MerchantPanel)
InterfaceOptions_AddCategory(ProfilesPanel)
InterfaceOptions_AddCategory(ImportExportPanel)
InterfaceOptions_AddCategory(DeletePanel)
InterfaceOptions_AddCategory(BlacklistPanel)
InterfaceOptions_AddCategory(BlacklistSettingsPanel)
InterfaceOptions_AddCategory(ProcessBagsPanel)
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
    add("Protect Affixed Rare Items: " .. tostring(DB.protectAffixedRareItems))
    add("Protect Chance-on-Hit Items: " .. tostring(DB.protectChanceOnHitItems))
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
    add("Fast Loot: " .. tostring(DB.fastLoot))
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

    add("--- Sell Rules ---")
    add("Quality Rules:")
    for q = 1, 4 do
        local r = DB.qualityRules and DB.qualityRules[q] or {}
        local rarityName = (q == 1) and "White" or (q == 2) and "Green" or (q == 3) and "Blue" or "Epic"
        local capStr = (r.maxILvl and r.maxILvl > 0) and tostring(r.maxILvl) or "no cap"
        local bindStr = tostring(r.bindFilter or "any")
        add(
            string.format(
                "  %s: enabled=%s, max iLvl=%s, useEquipped=%s, bind=%s",
                rarityName,
                tostring(r.enabled),
                capStr,
                tostring(r.useEquippedILvl),
                bindStr
            )
        )
    end
    add("Active Profile: " .. tostring(DB.activeProfileName))
    add("Sell List Items: " .. tostring(EC_CountItems(DB.whitelist)))
    add("Account Sell List Items: " .. tostring(ADB and EC_CountItems(ADB.whitelist) or 0))
    add("Keep List Items: " .. tostring(EC_CountItems(DB.blacklist)))
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
        add(names[i] .. " (" .. wlCount .. " sell, " .. blCount .. " keep)" .. tag)
    end
    add("")

    add("--- Stats ---")
    add("Total Money Made: " .. EC_CopperToPlainText(DB.totalCopper or 0))
    add("Total Items Sold: " .. tostring(DB.totalItemsSold or 0))
    add("Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0))
    add("Total Repairs: " .. tostring(DB.totalRepairs or 0))
    add("Total Repair Cost: " .. EC_CopperToPlainText(DB.totalRepairCopper or 0))
    add("")

    -- Capability flags. The bag-rendering layer and auction-pricing source
    -- can interact (or fail to interact) with EC's hooks and integrations;
    -- capturing which capabilities are present disambiguates "bag
    -- decoration missing" / "tooltip overlaps" reports without a
    -- follow-up. Generic flags so the report doesn't depend on specific
    -- third-party addon names.
    add("--- Environment Capabilities ---")
    local hostBagUI = (_G.Bagnon ~= nil) or (_G.BagnonFrame ~= nil) or (_G.ArkInventory ~= nil) or (_G.ElvUI ~= nil)
    add("Host bag UI detected: " .. (hostBagUI and "yes" or "no"))
    add(
        "Host bag-UI category API: "
            .. ((_G.LibStub and pcall(_G.LibStub, "AceAddon-3.0", true)) and "available" or "absent")
    )
    add("LibItemSearch: " .. (_G.LibStub and _G.LibStub("LibItemSearch-1.0", true) and "yes" or "no"))
    add(
        "Auction pricing source: "
            .. ((_G.Atr_GetAuctionBuyout ~= nil or _G.Auctionator ~= nil) and "detected" or "absent")
    )
    add(
        "Project Ebonhold extraction catalog: "
            .. ((_G.ExtractionService and _G.ExtractionService.learnedAffixes) and "exposed" or "absent")
    )

    add("")
    add("--- Bag Display ---")
    add("Sell-border tint enabled: " .. (DB.sellBorderEnabled and "yes" or "no"))
    if DB.sellBorderColor then
        local c = DB.sellBorderColor
        add(
            string.format(
                "Sell-border colour (r,g,b,a): %.2f, %.2f, %.2f, %.2f",
                c.r or 0,
                c.g or 0,
                c.b or 0,
                c.a or 0
            )
        )
    end
    local decoratedCount = 0
    if EC_compCache.sellBorderButtons then
        for _ in pairs(EC_compCache.sellBorderButtons) do
            decoratedCount = decoratedCount + 1
        end
    end
    add("Decorated slot buttons (this session): " .. tostring(decoratedCount))
    add("Host bag-UI border hook installed: " .. (EC_compCache._hostBagBorderHookInstalled and "yes" or "no"))

    add("")
    add("--- Allow Lists ---")
    local allowedItemCount = 0
    if ADB and ADB.allowedItems then
        for _ in pairs(ADB.allowedItems) do
            allowedItemCount = allowedItemCount + 1
        end
    end
    local allowedAffixCount = 0
    if ADB and ADB.allowedAffixes then
        for _ in pairs(ADB.allowedAffixes) do
            allowedAffixCount = allowedAffixCount + 1
        end
    end
    local knownAffixCount = 0
    if EC_compCache.knownAffixDescriptions then
        for _ in pairs(EC_compCache.knownAffixDescriptions) do
            knownAffixCount = knownAffixCount + 1
        end
    end
    add("Chance-on-hit allow list (per-itemID): " .. tostring(allowedItemCount))
    add("Random-affix allow list (per-description): " .. tostring(allowedAffixCount))
    add("Known affix descriptions in session set: " .. tostring(knownAffixCount))
    add("Allow exact-rank duplicates: " .. (DB.affixAllowExactDupes and "yes" or "no"))

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
                        stale[#stale + 1] = { id = id, name = name, iLvl = iLvl, lowestEquipped = lowestEquipped }
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

    if cmd == "affixfind" then
        local needle = rest:lower()
        if needle == "" then
            PrintNice("usage: /ec affixfind <text>")
            return
        end
        local set = EC_compCache.knownAffixDescriptions or {}
        local hits = 0
        for k in pairs(set) do
            if k:lower():find(needle, 1, true) then
                hits = hits + 1
                PrintNicef("  [%s]", k)
            end
        end
        PrintNicef("affixfind: %d match(es)", hits)
        return
    elseif cmd == "affixdump" then
        -- v2.23.0 debug: re-runs the known-affix spellbook scan, then
        -- prints diagnostic info for tracking down dupe-gate misfires.
        -- Intended as a one-shot inspector; safe to leave in but not
        -- documented in /ec help.
        if EC_compCache.refreshKnownAffixes then
            EC_compCache.refreshKnownAffixes()
        end
        local set = EC_compCache.knownAffixDescriptions or {}
        local count = 0
        local sample = {}
        for k in pairs(set) do
            count = count + 1
            if #sample < 5 then
                sample[#sample + 1] = k
            end
        end
        PrintNicef("affixdump: %d known descriptions in set", count)
        for _, s in ipairs(sample) do
            PrintNicef("  - [%s]", s)
        end
        -- Scan bags for the first affixed item and dump its data.
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link then
                    local affix = EC_compCache.bagSlotAffixData(bag, slot)
                    if affix then
                        PrintNicef(
                            "bag (%d,%d) %s: name=[%s] rank=[%s] desc=[%s]",
                            bag,
                            slot,
                            link,
                            tostring(affix.name),
                            tostring(affix.rank),
                            tostring(affix.description)
                        )
                        local norm = EC_compCache.normaliseAffixDesc(affix.description)
                        PrintNicef("  norm=[%s]", tostring(norm))
                        PrintNicef("  match? %s", tostring(EC_compCache.playerHasAffixDescription(affix.description)))
                        return
                    end
                end
            end
        end
        PrintNice("affixdump: no affixed bag items found")
        return
    elseif cmd == "procdump" then
        -- v2.26.0 debug: dump the per-link affix lookup for the first
        -- Chance-on-hit bag item, plus the HasRandomProperty gate
        -- result and a hyperlink-tooltip-line dump so we can see what
        -- SetHyperlink(link) renders. Use this when the chance-on-hit
        -- dupe gate misfires (item stays "Protected" when the player
        -- expects "Allowed").
        local svc = _G.ExtractionService
        local catalogSize = (svc and type(svc.learnedAffixes) == "table") and #svc.learnedAffixes or 0
        PrintNicef("procdump: ExtractionService.learnedAffixes has %d records", catalogSize)
        local learnedProcs = 0
        if svc and type(svc.learnedAffixes) == "table" then
            for _, r in ipairs(svc.learnedAffixes) do
                if r and r.learned and r.weaponOnly then
                    learnedProcs = learnedProcs + 1
                end
            end
        end
        PrintNicef("procdump: %d learned weaponOnly procs in catalog", learnedProcs)
        local allowedCount = 0
        for _ in pairs(ADB and ADB.allowedItems or {}) do
            allowedCount = allowedCount + 1
        end
        PrintNicef("procdump: %d Allowed Proc itemIDs (account-wide)", allowedCount)
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag) or 0
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                local itemID = GetContainerItemID(bag, slot)
                if link and itemID and EC_compCache.itemHasChanceOnHit(bag, slot, itemID) then
                    PrintNicef("procdump: scanning (%d,%d) %s", bag, slot, link)
                    local hrp = HasRandomProperty and HasRandomProperty(link)
                    PrintNicef("  HasRandomProperty=%s", tostring(hrp))
                    local rec = EC_compCache.findLearnedAffixForItem and EC_compCache.findLearnedAffixForItem(link)
                    if rec then
                        PrintNicef(
                            "  match: name=[%s] id=%s learned=%s weaponOnly=%s",
                            tostring(rec.name),
                            tostring(rec.id),
                            tostring(rec.learned),
                            tostring(rec.weaponOnly)
                        )
                    else
                        PrintNice("  match: nil (no learnedAffixes name matched the tooltip)")
                    end
                    -- Dump the SetHyperlink tooltip lines so we can see
                    -- what text was searched.
                    EC_scanTooltip:ClearLines()
                    EC_scanTooltip:SetHyperlink(link)
                    for i = 1, EC_scanTooltip:NumLines() do
                        local fs = _G["EbonClearanceScanTooltipTextLeft" .. i]
                        if fs and fs.GetText then
                            local txt = fs:GetText()
                            if txt then
                                PrintNicef("  L%d: %s", i, txt)
                            end
                        end
                    end
                    return
                end
            end
        end
        PrintNice("procdump: no Chance-on-hit bag items found")
        return
    elseif cmd == "profile" or cmd == "profiles" then
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
            PrintNice("Sell List Profiles:")
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

    if cmd == "sellinfo" then
        EnsureDB()
        -- Optional positional args: bag, slot. Defaults to the first
        -- non-empty bag slot when omitted.
        local bagArg, slotArg = rest:match("^%s*(%S+)%s+(%S+)%s*$")
        local bag = tonumber(bagArg)
        local slot = tonumber(slotArg)
        if EC_compCache.printSellabilityTrace then
            EC_compCache.printSellabilityTrace(bag, slot)
        end
        return
    end

    if cmd == "help" or cmd == "?" then
        -- Full reference; the Main panel only shows a 4-line summary so it
        -- fits the default Interface Options sub-panel height. Chat has no
        -- height constraint, so the long list lives here instead.
        PrintNice("|cffffff00=== EbonClearance Slash Commands ===|r")
        PrintNice("|cffffff00/ec|r  Open settings")
        PrintNice("|cffffff00/ec profile list|r  Show all saved profiles")
        PrintNice("|cffffff00/ec profile save <name>|r  Save current Sell List as a profile")
        PrintNice("|cffffff00/ec profile load <name>|r  Load a saved profile")
        PrintNice("|cffffff00/ec profile delete <name>|r  Delete a profile")
        PrintNice("|cffffff00/ec clean|r  Report items present in more than one list")
        PrintNice("|cffffff00/ec clean apply|r  Auto-resolve conflicts (Keep List > Delete List > Sell List)")
        PrintNice(
            "|cffffff00/ec clean upgrades|r  Report stale 'Upgrade'-tagged Keep List entries no longer above equipped"
        )
        PrintNice("|cffffff00/ec clean upgrades apply|r  Remove the stale 'Upgrade' entries (with confirmation)")
        PrintNice("|cffffff00/ec bugreport|r  Generate a diagnostic report for bug reports")
        PrintNice(
            "|cffffff00/ec sellinfo [bag slot]|r  Trace why a bag item will/won't sell (defaults to first non-empty slot)"
        )
        PrintNice("|cffaaaaaaTip: Alt+Shift+Right-Click a bag item for the same trace.|r")
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
                PrintNice("|cffaaaaaaNo 'Upgrade'-tagged entries on your Keep List.|r")
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
                            "Removed |cffffff00%d|r stale 'Upgrade' entr%s from the Keep List.",
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
        local rarityName = (q == 1) and "White" or (q == 2) and "Green" or (q == 3) and "Blue" or "Epic"
        local capStr = (r.maxILvl and r.maxILvl > 0) and tostring(r.maxILvl) or "no cap"
        PrintNicef("Quality[%s]: enabled=%s, max iLvl=%s", rarityName, tostring(r.enabled), capStr)
    end

    -- Print whitelist contents
    local wlCount = 0
    for k, v in pairs(DB.whitelist or {}) do
        local n = GetItemInfo(k) or ("ItemID:" .. tostring(k))
        PrintNicef("  Sell List[%s] = %s  (%s)", tostring(k), tostring(v), n)
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
                    local wp = IsInSet(DB.whitelist, itemID) or (ADB and IsInSet(ADB.whitelist, itemID))
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
-- v2.25.0: ITEM_LOCK_CHANGED fires when a bag slot's `locked` flag
-- transitions - either a transient mid-pickup lock or a Pick Lock /
-- key-use unlock. BAG_UPDATE does NOT fire for lock-state changes
-- because the slot's contents haven't changed, so Pick Lock leaves
-- the Process Bags panel showing a stale row + the auto-open driver
-- unaware that the box is now openable. Routing this event through
-- the same debounce frame as BAG_UPDATE refreshes the panel, fires
-- the auto-open driver, and re-arms the cast button.
f:RegisterEvent("ITEM_LOCK_CHANGED")
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
-- v2.23.0: drives the known-affix refresh for the exact-dupe gate.
-- LEARNED_SPELL_IN_TAB fires when a new spell is added to the
-- spellbook (covers PE affix extraction). SPELLS_CHANGED fires after
-- the spellbook is fully populated post-login and on bulk updates.
-- Both handlers re-scan and rebuild the description map.
f:RegisterEvent("LEARNED_SPELL_IN_TAB")
f:RegisterEvent("SPELLS_CHANGED")
-- Wakes the auto-open-containers driver when combat ends. Without this the
-- combat-deferred queue could sit indefinitely if no further BAG_UPDATE
-- arrives. Handler self-gates on DB.autoOpenContainers, so users with the
-- toggle off pay one early-return per combat exit.
f:RegisterEvent("PLAYER_REGEN_ENABLED")
-- v2.16.0: drives the Fast Loot driver. Handler self-gates on
-- DB.fastLoot and on Blizzard's autoLootDefault CVar, so users without
-- the toggle on pay one early-return per loot interaction.
f:RegisterEvent("LOOT_READY")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            EnsureDB()
            -- Scrub orphans from the v2.2.0 scoping bug where these names
            -- briefly leaked into _G. Harmless if absent. See v2.2.1 fix.
            _G.EC_summonGoblinPending = nil
            _G.EC_summonGoblinTimer = nil
            NS.HookDeletePopupOnce()
            EC_InstallFastLootHookOnce()
            if NS.ApplyGreedyChatFilter then
                NS.ApplyGreedyChatFilter()
            end
            EC_CreateMinimapButton()
            EC_InstallTooltipHookOnce()
            EC_CreateLDBLauncher()
            EC_CreateTargetMerchantButton()
            EC_InstallBagContextHookOnce()
            EC_manualSell.installHookOnce()
        elseif addonName == "Bagnon" then
            -- The host bag UI's slot class was registered during its load
            -- pass; install the sell-border hook now so the first paint
            -- after bags open already runs through our refresh path. The
            -- PLAYER_LOGIN-deferred fallback further down is idempotent so
            -- double-firing is harmless.
            if EC_compCache.installHostBagBorderHook then
                EC_compCache.installHostBagBorderHook()
            end
        end
    elseif event == "PLAYER_LOGOUT" then
        if DB then
            EbonClearanceDB = DB
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        EnsureDB()
        if NS.InstallGreedyMuteOnce then
            NS.InstallGreedyMuteOnce()
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
        -- Drain any settings-panel open that was queued while combat was
        -- active. Same double-call workaround as the original click paths.
        local pendingOpen = EC_compCache.pendingOpenAfterCombat
        if pendingOpen then
            EC_compCache.pendingOpenAfterCombat = nil
            if pendingOpen == "main" and MainOptions and InterfaceOptionsFrame_OpenToCategory then
                InterfaceOptionsFrame_OpenToCategory(MainOptions)
                InterfaceOptionsFrame_OpenToCategory(MainOptions)
            elseif pendingOpen == "process" and InterfaceOptionsFrame_OpenToCategory then
                local pbp = _G["EbonClearanceOptionsProcessBags"]
                if pbp then
                    InterfaceOptionsFrame_OpenToCategory(pbp)
                    InterfaceOptionsFrame_OpenToCategory(pbp)
                end
            end
        end
        -- v2.22.0: Process Bags cast-button re-arm. SetAttribute is blocked
        -- during combat, so any re-arm attempts from BAG_UPDATE bail and
        -- this combat-exit catch-up restores a current macrotext.
        EC_compCache.rearmProcessButton()
        -- v2.26.0: cheap dirty-check refresh of the known-extraction
        -- description map. PE's ExtractionService updates in-place
        -- after the player extracts at the Anvil; this catches the
        -- state at combat exit without needing a /reload.
        if EC_compCache.refreshExtractionIfDirty then
            EC_compCache.refreshExtractionIfDirty()
        end
        -- v2.25.0: optional one-line nudge when combat ends with
        -- lockable containers in bags. Off by default (one extra line
        -- per combat exit is noisy for rogues farming heavy zones).
        -- Only counts containers, not casts available; the user picks
        -- which one to open via the panel / hold-key-to-drain.
        if
            DB.lockpickEnabled
            and DB.lockpickNotifyOnCombatExit
            and IsSpellKnown
            and IsSpellKnown(EC_compCache.SPELL_PICK_LOCK)
        then
            local n = 0
            for bag = 0, 4 do
                local slots = GetContainerNumSlots(bag) or 0
                for slot = 1, slots do
                    if EC_compCache.canPickLock(bag, slot) then
                        n = n + 1
                    end
                end
            end
            if n > 0 then
                PrintNicef(
                    "|cffaaaaaa%d lockbox(es) available.|r Click |cffffb84dProcess Next|r in Process Bags to open.",
                    n
                )
            end
        end
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
    elseif event == "LEARNED_SPELL_IN_TAB" or event == "SPELLS_CHANGED" then
        -- v2.30.0 perf: debounced. Soul ash tree and login can fire
        -- dozens of spell events in rapid succession; a synchronous
        -- spellbook scan on each one caused 30+ second freezes. Reset
        -- the accumulator on every event so we wait for 0.5 s of quiet
        -- before doing a single rebuild. The actual rebuild is driven
        -- by EC_compCache.spellUpdateFrame's OnUpdate in
        -- EbonClearance_Protection.lua; calling refreshKnownAffixes
        -- directly here would defeat the debounce.
        EC_compCache.spellUpdatePending = true
        EC_compCache.spellUpdateAccum = 0
        EC_compCache.spellUpdateFrame:Show()
    elseif event == "BAG_UPDATE" or event == "ITEM_LOCK_CHANGED" then
        -- v2.24.0 perf: bag-full handler stays synchronous so the
        -- cycle's responsiveness across the free-slot threshold is
        -- unchanged (its internal 1.5 s hysteresis already debounces
        -- transient bag fluctuations). Everything else goes through
        -- EC_compCache.bagUpdateFrame's 120 ms debounce - pet AOE
        -- looting fires one BAG_UPDATE per slot filled, and doing the
        -- full deferred-work chain per-event caused 1.5 s freezes.
        -- v2.25.0: ITEM_LOCK_CHANGED routes through the same debounce
        -- so a Pick Lock completion refreshes the panel + fires the
        -- auto-open driver (which picks up the now-`Right Click to
        -- Open` box). The bag-full handler skips for lock-state
        -- changes (no slot count change so it'd be a no-op anyway).
        if event == "BAG_UPDATE" then
            EC_HandleBagFullForCycle()
        end
        EC_compCache.bagUpdatePending = true
        EC_compCache.bagUpdateAccum = 0
        EC_compCache.bagUpdateFrame:Show()
    elseif event == "LOOT_READY" then
        -- v2.16.0: Fast Loot driver. Self-gates on DB.fastLoot and on
        -- Blizzard's autoLootDefault CVar so non-Fast-Loot users pay
        -- one early-return per loot interaction.
        EC_HandleLootReady()
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
        -- v2.25.0: Pick Lock completion - BAG_UPDATE doesn't fire for a
        -- lockbox's lock-state change (slot contents unchanged), and
        -- ITEM_LOCK_CHANGED doesn't reliably fire either. UNIT_SPELLCAST_SUCCEEDED
        -- with the Pick Lock spell name is the most reliable trigger.
        -- Route through the same debounce frame as BAG_UPDATE so the
        -- panel refreshes (drops the now-unlocked row) and the auto-
        -- open driver fires (opens the now-`Right Click to Open` box).
        if spellName and EC_compCache.PICK_LOCK_NAME and spellName == EC_compCache.PICK_LOCK_NAME then
            EC_compCache.bagUpdatePending = true
            EC_compCache.bagUpdateAccum = 0
            EC_compCache.bagUpdateFrame:Show()
        end
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
        NS.InstallGreedyMuteOnce()
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
        EC_compCache.vendorRunning = false
        worker:Hide()
        EC_compCache.pendingDelete = nil
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
                PrintNice("Type |cff00ff00/ec|r to customise, or pick a setup mode in the popup.")
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
            -- Sell-border tint: install the host bag-UI adapter once the
            -- host has had a chance to build its slot class. Same 2 s
            -- defer rationale as the ElvUI bind above; the call self-gates
            -- on LibStub + AceAddon presence so non-host users pay one
            -- nil-check per login.
            EC_Delay(2, function()
                if EC_compCache.installHostBagBorderHook then
                    EC_compCache.installHostBagBorderHook()
                end
            end)
            -- v2.23.0: initial spellbook scan for known affixes. The
            -- 2 s defer (same logic as the ElvUI bind above) gives the
            -- spellbook time to fully populate after login. Subsequent
            -- updates are driven by the LEARNED_SPELL_IN_TAB and
            -- SPELLS_CHANGED events registered below.
            EC_Delay(2, function()
                if EC_compCache.refreshKnownAffixes then
                    EC_compCache.refreshKnownAffixes()
                end
            end)
        end)
    end
end)
