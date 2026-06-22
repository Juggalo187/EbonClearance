#!/usr/bin/env lua
-- Perf-guardrail regression tests for EbonClearance.
--
-- Run from repo root:    lua tests/test_perf_guardrails.lua
--
-- v2.22.0 (Process Bags) and v2.23.0 (affix dupe gate) introduced
-- a heavyweight `buildProcessSummary` call into the BAG_UPDATE event
-- handler. Each call walks all 5 bags, scans tooltip text per
-- Rare/Epic item, and re-sorts the result. The Greedy Scavenger
-- picking up 5 items fires 5 BAG_UPDATE events in <100 ms, so the
-- cost compounded into 1.5 s game freezes during AOE farming.
--
-- v2.24.0 fixed it by:
--   1. Gating `rearmProcessButton` on panel visibility / keybind.
--   2. Routing BAG_UPDATE deferred work through a 120 ms debounce
--      frame so bursts coalesce.
--   3. Caching `bagSlotAffixData` per itemString.
--
-- v2.25.0 added Lockpick mode (rogue Pick Lock via Process Bags) +
-- collapsible Process Bags sections. v2.25.1 fixed an auto-open
-- regression where the debounce frame's OnUpdate closure couldn't
-- resolve `EC_HandleAutoOpenContainers` because it was declared as
-- `local function` AFTER the closure (Lua's lexical scoping captures
-- locals at closure-creation time, not at call time). Tests below
-- cover both the original perf invariants and the wiring invariants
-- that drove v2.25.1.
--
-- These tests are static-pattern checks against the source. They do
-- NOT measure runtime - the WoW API is not mockable - but they catch
-- the structural mistakes that caused these regressions so the same
-- patterns can't sneak back in without setting off CI.
--
-- Add new tests below as new invariants emerge. Keep them pattern-
-- matching only - this file must run under stock lua5.1 with no
-- external dependencies so it works in CI without a luarocks step.

-- Post-split: concat every shipped .lua source file. The file-split refactor
-- tracked in docs/CODE_REVIEW.md item 4 moves chunks out of EbonClearance_Events.lua
-- into per-feature files (Core first, more to follow). Every static-pattern
-- check below runs against the whole concatenated source, so invariants
-- expressed as `src:find(...)` continue to hold across the split boundary.
-- Add new source files to the SOURCE_PATHS list in the order they appear in
-- the .toc (matches load order).
local SOURCE_PATHS = {
    "EbonClearance_Core.lua",
    "EbonClearance_Companion.lua",
    "EbonClearance_Protection.lua",
    "EbonClearance_Vendor.lua",
    "EbonClearance_Process.lua",
    "EbonClearance_ProcessBagsPanel.lua",
    "EbonClearance_MerchantPanel.lua",
    "EbonClearance_ScavengerPanel.lua",
    "EbonClearance_SellListPanels.lua",
    "EbonClearance_KeepDeletePanels.lua",
    "EbonClearance_ProtectionPanel.lua",
    "EbonClearance_ItemHighlightingPanel.lua",
    "EbonClearance_ProfilesPanel.lua",
    "EbonClearance_MainPanel.lua",
    "EbonClearance_StatsPanel.lua",
    "EbonClearance_GuildPanel.lua",
    "EbonClearance_PanelInfra.lua",
    "EbonClearance_PanelWidgets.lua",
    "EbonClearance_ListWidget.lua",
    "EbonClearance_QuickstartPanel.lua",
    "EbonClearance_Events.lua",
    "EbonClearance_Comms.lua",
    "EbonClearance_GuildShare.lua",
    "EbonClearance_BagDisplay.lua",
    "EbonClearance_BugReport.lua",
    "EbonClearance_Minimap.lua",
    "EbonClearance_Tooltip.lua",
    "EbonClearance_BagContextMenu.lua",
    "EbonClearance_HelpPanel.lua",
}

local pieces = {}
for _, path in ipairs(SOURCE_PATHS) do
    local f, err = io.open(path, "r")
    if not f then
        io.stderr:write("FAIL: cannot open " .. path .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end
    pieces[#pieces + 1] = f:read("*a")
    f:close()
end
local src = table.concat(pieces, "\n")

local fails = 0

local function check(name, ok, message)
    if ok then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name)
        if message then
            print("      " .. message)
        end
        fails = fails + 1
    end
end

-- ---------------------------------------------------------------------------
-- Helper: extract the body of the BAG_UPDATE branch in the OnEvent
-- dispatcher. Returns the text between `event == "BAG_UPDATE"` and the
-- next `elseif event ==` or `end` at a similar indent level. Used by
-- multiple tests below.
-- ---------------------------------------------------------------------------
local function extract_bag_update_branch()
    -- Lazy scan: find the BAG_UPDATE elseif, then read until the next
    -- elseif/end at the same level. Not a real Lua parser, but
    -- sufficient for our static-pattern checks.
    local startIdx = src:find('event == "BAG_UPDATE"', 1, true)
    if not startIdx then return nil end
    local tailStart = startIdx
    -- Find the next "elseif event ==" or terminating end-of-handler.
    local endIdx = src:find('elseif event ==', tailStart + 1, true)
    if not endIdx then
        -- Should always find one - the handler has many branches.
        return src:sub(startIdx)
    end
    return src:sub(startIdx, endIdx - 1)
end

-- ---------------------------------------------------------------------------
-- Test 1: BAG_UPDATE branch must NOT directly call heavy bag-walking
-- functions. Those go through the debounce frame.
-- ---------------------------------------------------------------------------
-- Background: Pet AOE loot fires one BAG_UPDATE per slot filled. A
-- 5-item drop = 5 BAG_UPDATEs in <100 ms. Calling buildProcessSummary
-- (via rearmProcessButton) or scanning all bags (via
-- checkBagsForUpgrades / HandleAutoOpenContainers / refreshProcessPanel)
-- per-event multiplies the cost by 5. They MUST route through the
-- debounce frame so the burst is coalesced.
--
-- Exception: EC_HandleBagFullForCycle stays synchronous because its
-- internal 1.5 s hysteresis already debounces, and the bag-full cycle
-- wants the FIRST trip across the threshold without extra delay.
do
    local body = extract_bag_update_branch()
    local violators = {}
    if body then
        local forbidden = {
            "EC_compCache%.rearmProcessButton%(%)",
            "EC_compCache%.checkBagsForUpgrades%(%)",
            "EC_HandleAutoOpenContainers%(%)",
            "EC_compCache%.refreshProcessPanel%(%)",
        }
        for _, pat in ipairs(forbidden) do
            for line in body:gmatch("[^\n]+") do
                local stripped = line:gsub("^%s+", "")
                local isComment = stripped:find("^%-%-")
                if not isComment and line:find(pat) then
                    violators[#violators + 1] = stripped
                end
            end
        end
    end
    local detail
    if #violators > 0 then
        local list = {}
        for i = 1, #violators do
            list[i] = "    " .. violators[i]
        end
        detail = "BAG_UPDATE branch directly invokes a heavy function. Route through EC_compCache.bagUpdateFrame instead:\n" ..
                 table.concat(list, "\n")
    end
    check("BAG_UPDATE branch routes heavy work through debounce frame",
          body ~= nil and #violators == 0,
          detail or (body == nil and "could not locate BAG_UPDATE branch in source"))
end

-- ---------------------------------------------------------------------------
-- Test 2: The BAG_UPDATE debounce frame must exist and be wired to
-- BAG_UPDATE.
-- ---------------------------------------------------------------------------
do
    local hasFrame = src:find("EC_compCache%.bagUpdateFrame%s*=%s*CreateFrame")
    local hasOnUpdate = src:find('EC_compCache%.bagUpdateFrame:SetScript%("OnUpdate"')
    local body = extract_bag_update_branch()
    local triggersFrame = body and body:find("EC_compCache%.bagUpdateFrame:Show%(%)") ~= nil

    check("BAG_UPDATE debounce frame is declared (EC_compCache.bagUpdateFrame)",
          hasFrame ~= nil)
    check("BAG_UPDATE debounce frame has an OnUpdate handler",
          hasOnUpdate ~= nil)
    check("BAG_UPDATE branch triggers the debounce frame via :Show()",
          triggersFrame == true)
end

-- ---------------------------------------------------------------------------
-- Test 3: rearmProcessButton must early-return when the user isn't
-- using Process Bags (panel hidden AND no keybind set).
-- ---------------------------------------------------------------------------
-- Background: rearmProcessButton calls buildProcessSummary, which is
-- O(bags + Rare/Epic tooltip scans). When the user has never opened
-- the panel AND has no keybind, the macrotext won't be observed, so
-- the work is entirely wasted. Gate at the top.
do
    -- Pull the rearmProcessButton body (function-start to next `end`
    -- at column 0, which is the function close).
    local fnStart = src:find("function EC_compCache%.rearmProcessButton%(%)")
    if not fnStart then
        check("rearmProcessButton is gated on panel visibility / keybind",
              false, "rearmProcessButton not found in source")
    else
        -- Find the function close: the next `\nend` after fnStart.
        local fnEnd = src:find("\nend", fnStart)
        local body = fnEnd and src:sub(fnStart, fnEnd) or src:sub(fnStart, fnStart + 2000)
        local hasIsShown = body:find("panel:IsShown%(%)") ~= nil
        local hasBindingCheck = body:find("GetBindingKey") ~= nil
        check("rearmProcessButton gates on panel:IsShown()",
              hasIsShown,
              "expected the function to check panel:IsShown() before the bag walk")
        check("rearmProcessButton gates on GetBindingKey for the cast button",
              hasBindingCheck,
              "expected GetBindingKey check so hold-key-to-drain still works without the panel open")
    end
end

-- ---------------------------------------------------------------------------
-- Test 4: bagSlotAffixData must cache per itemString.
-- ---------------------------------------------------------------------------
-- Background: bagSlotAffixData does a SetBagItem + 30-line tooltip
-- parse. Without a cache, repeat calls within the same BAG_UPDATE
-- storm (or across the rearm + tooltip-annotation + IsSellable paths)
-- pay full cost every time. Cache key is itemString since the affix
-- is per-instance.
do
    local fnStart = src:find("function EC_compCache%.bagSlotAffixData%(")
    if not fnStart then
        check("bagSlotAffixData caches via affixDataCache",
              false, "bagSlotAffixData not found in source")
    else
        local fnEnd = src:find("\nend", fnStart)
        local body = fnEnd and src:sub(fnStart, fnEnd) or src:sub(fnStart, fnStart + 2000)
        local reads = body:find("EC_compCache%.affixDataCache%[") ~= nil
        check("bagSlotAffixData reads / writes EC_compCache.affixDataCache",
              reads,
              "expected the function to short-circuit on a cached itemString lookup")
    end
end

-- ---------------------------------------------------------------------------
-- Test 5: affixDataCache table is declared.
-- ---------------------------------------------------------------------------
do
    local declared = src:find("EC_compCache%.affixDataCache%s*=%s*{}") ~= nil
    check("EC_compCache.affixDataCache is declared as an empty table",
          declared)
end

-- ---------------------------------------------------------------------------
-- Test 6 (v2.25.1 regression): EC_HandleAutoOpenContainers must be
-- forward-declared at file scope BEFORE the bagUpdateFrame OnUpdate
-- closure captures the name. Otherwise Lua's lexical scoping resolves
-- the reference to the (nil) global and auto-open silently never
-- fires from the debounce path.
--
-- Detection: the function definition uses bare `function EC_Handle...`
-- (NOT `local function`), meaning the local was forward-declared
-- separately. The forward declaration itself appears earlier as a
-- standalone `local EC_HandleAutoOpenContainers` line.
-- ---------------------------------------------------------------------------
do
    -- Definition style: bare `function X` (no `local`) is the
    -- correct shape when X was forward-declared at file scope.
    local hasBareDefinition = src:find("\nfunction EC_HandleAutoOpenContainers%(%)") ~= nil
    local hasLocalDefinition = src:find("\nlocal function EC_HandleAutoOpenContainers%(%)") ~= nil
    -- Forward declaration: a `local EC_HandleAutoOpenContainers` line
    -- NOT immediately followed by `function`.
    local hasForwardDecl = src:find("\nlocal EC_HandleAutoOpenContainers[%s\n]") ~= nil
        or src:find("\nlocal EC_HandleAutoOpenContainers$") ~= nil
    check("EC_HandleAutoOpenContainers is forward-declared (not `local function`)",
          hasBareDefinition and not hasLocalDefinition and hasForwardDecl,
          "expected `local EC_HandleAutoOpenContainers` forward decl + bare `function EC_HandleAutoOpenContainers()` definition; without the forward decl the v2.24.0 debounce frame closure resolves the name to the nil global and auto-open never fires")
end

-- ---------------------------------------------------------------------------
-- Test 7 (v2.25.1): bagUpdateFrame OnUpdate must reference
-- EC_HandleAutoOpenContainers so the auto-open driver fires from the
-- debounce path. If a refactor accidentally drops the call, unlocked
-- containers stop being processed.
-- ---------------------------------------------------------------------------
do
    -- Extract the OnUpdate closure body. The closure starts at the
    -- SetScript("OnUpdate", function(...) and ends at the matching
    -- `end)`. Crude bracket match good enough for the static check.
    local startIdx = src:find('bagUpdateFrame:SetScript%("OnUpdate"', 1)
    local body
    if startIdx then
        local endIdx = src:find("end%)", startIdx)
        body = endIdx and src:sub(startIdx, endIdx) or src:sub(startIdx, startIdx + 4000)
    end
    local refs = body and body:find("EC_HandleAutoOpenContainers%(%)") ~= nil
    check("bagUpdateFrame OnUpdate calls EC_HandleAutoOpenContainers",
          refs == true,
          "the debounce frame must call EC_HandleAutoOpenContainers() inside its OnUpdate body so the auto-open driver fires after each burst settles")
end

-- ---------------------------------------------------------------------------
-- Test 8 (v2.25.0): Pick Lock spell-cast trigger is wired into
-- UNIT_SPELLCAST_SUCCEEDED. BAG_UPDATE doesn't fire for a lockbox's
-- locked->openable transition, so the UNIT_SPELLCAST_SUCCEEDED match
-- against PICK_LOCK_NAME is the only reliable trigger to refresh the
-- Process Bags panel and run the auto-open driver post-cast.
-- ---------------------------------------------------------------------------
do
    local startIdx = src:find('event == "UNIT_SPELLCAST_SUCCEEDED"', 1, true)
    local body
    if startIdx then
        local endIdx = src:find('elseif event ==', startIdx + 1, true)
        body = endIdx and src:sub(startIdx, endIdx - 1) or src:sub(startIdx, startIdx + 3000)
    end
    local hasPickLockHook = body and body:find("PICK_LOCK_NAME") ~= nil
    local triggersDebounce = body and body:find("bagUpdateFrame:Show%(%)") ~= nil
    check("UNIT_SPELLCAST_SUCCEEDED handles PICK_LOCK_NAME completion",
          hasPickLockHook == true and triggersDebounce == true,
          "expected the UNIT_SPELLCAST_SUCCEEDED branch to compare spellName against EC_compCache.PICK_LOCK_NAME and trigger the bagUpdateFrame debounce")
end

-- ---------------------------------------------------------------------------
-- Test 9 (v2.25.0): Lockpick spell constants + helpers exist.
-- ---------------------------------------------------------------------------
do
    local hasSpellConst = src:find("EC_compCache%.SPELL_PICK_LOCK%s*=%s*1804") ~= nil
    local hasNameConst = src:find("EC_compCache%.PICK_LOCK_NAME") ~= nil
    local hasHelper = src:find("function EC_compCache%.canPickLock%(") ~= nil
    check("EC_compCache.SPELL_PICK_LOCK = 1804 constant is declared",
          hasSpellConst)
    check("EC_compCache.PICK_LOCK_NAME is cached at file scope",
          hasNameConst)
    check("EC_compCache.canPickLock helper is defined",
          hasHelper)
end

-- ---------------------------------------------------------------------------
-- Test 10 (v2.25.0): Lockpick + collapsible-section schema is
-- defaulted in EnsureDB. Without these defaulters the per-session
-- code path reads `nil` and the toggles silently do nothing.
-- ---------------------------------------------------------------------------
do
    local hasLockpickEnabled = src:find("DB%.lockpickEnabled%s*=%s*true") ~= nil
    local hasNotifyDefault = src:find("DB%.lockpickNotifyOnCombatExit%s*=%s*false") ~= nil
    local hasCollapsedDefault = src:find("DB%.processCollapsedModes%s*=%s*{}") ~= nil
    check("EnsureDB defaults DB.lockpickEnabled to true",
          hasLockpickEnabled)
    check("EnsureDB defaults DB.lockpickNotifyOnCombatExit to false",
          hasNotifyDefault)
    check("EnsureDB defaults DB.processCollapsedModes to an empty table",
          hasCollapsedDefault)
end

-- ---------------------------------------------------------------------------
-- Test 11 (v2.25.0): Lockpick mode is wired into buildProcessSummary.
-- ---------------------------------------------------------------------------
do
    local hasLockpickBranch = src:find('mode%s*=%s*"Lockpick"') ~= nil
    local hasModeOrder = src:find("Lockpick%s*=%s*4") ~= nil
    check("buildProcessSummary emits a Lockpick mode entry",
          hasLockpickBranch,
          "expected `mode = \"Lockpick\"` assignment in the canPickLock branch")
    check("modeOrder ranks Lockpick = 4",
          hasModeOrder,
          "the sort order must include Lockpick or its rows won't sort consistently with DE/Mill/Prospect")
end

-- ---------------------------------------------------------------------------
-- Test 12 (v2.26.0): chance-on-hit "Allow Sell" override list.
-- ---------------------------------------------------------------------------
-- Background: v2.26.0 replaces the chance-on-hit protection's auto-
-- dupe-gate ambition (which failed because engraving descriptions
-- don't match bag-tooltip effect text) with a single account-wide
-- manual override list. The user marks itemIDs via the Alt+Right-
-- Click menu's "Allow Sell" row. Marked items release the v2.20.0
-- protection so future drops auto-sell via the quality rules and
-- become available to Process Bags. Account-wide because PE's
-- extraction state itself is account-wide.
do
    local hasDefault = src:find("ADB%.allowedItems%s*=%s*{}") ~= nil
    check("EnsureAccountDB defaults ADB.allowedItems to an empty table",
          hasDefault,
          "the account-wide allow list is the load-bearing v2.26+ schema field for both chance-on-hit AND random-affix overrides")

    -- buildProcessSummary must gate on allowedItems for both
    -- chance-on-hit and random-affix branches.
    local pbStart = src:find("function EC_compCache%.buildProcessSummary%(", 1)
    local pbEnd = pbStart and src:find("\nend", pbStart) or nil
    local pbBody = pbStart and pbEnd and src:sub(pbStart, pbEnd) or ""
    local processGate = pbBody:find("allowedItems") ~= nil
    check("buildProcessSummary gates protected items on ADB.allowedItems",
          processGate,
          "Process Bags must hide protected items until the user marks them via Allow Sell")

    -- Migration: an older field name was `allowedProcs`. New code
    -- must still migrate that data forward so v2.26.x users don't
    -- lose their decisions.
    local hasMigration = src:find('rawget%(ADB,%s*"allowedProcs"%)') ~= nil
        or src:find("ADB%.allowedProcs") ~= nil
    check("ADB.allowedProcs -> allowedItems migration is in EnsureAccountDB",
          hasMigration,
          "renaming the schema field requires a one-shot copy so existing decisions survive upgrade")
end

-- ---------------------------------------------------------------------------
-- Test 13 (v2.26.0): ExtractionService merge + dirty-check refresh.
-- ---------------------------------------------------------------------------
-- Background: PE's _G.ExtractionService.learnedAffixes is the
-- authoritative catalog of (id, name, learned, weaponOnly) records.
-- The refresh path must read from that table (not just walk the
-- spellbook), and the dirty-check function must be wired into both
-- the BAG_UPDATE debounce frame and the PLAYER_REGEN_ENABLED handler
-- so the player's post-extraction state propagates without /reload.
do
    local readsExtraction = src:find("_G%.ExtractionService") ~= nil
        or src:find("svc%.learnedAffixes") ~= nil
    local hasDirtyFn = src:find("function EC_compCache%.refreshExtractionIfDirty%(") ~= nil
    local hasVersionCounter = src:find("EC_compCache%.knownExtractionVersion") ~= nil
    check("refreshKnownAffixes reads from _G.ExtractionService.learnedAffixes",
          readsExtraction,
          "expected the affix-refresh path to merge entries from PE's ExtractionService catalog")
    check("EC_compCache.refreshExtractionIfDirty exists",
          hasDirtyFn,
          "expected a cheap dirty-check helper that skips the rebuild when learnedCount is unchanged")
    check("EC_compCache.knownExtractionVersion counter is declared",
          hasVersionCounter,
          "expected a learnedCount counter used by refreshExtractionIfDirty for the dirty check")

    -- The PLAYER_REGEN_ENABLED handler must call refreshExtractionIfDirty
    -- so combat exit picks up freshly-extracted procs.
    local startIdx = src:find('event == "PLAYER_REGEN_ENABLED"', 1, true)
    local body
    if startIdx then
        local endIdx = src:find('elseif event ==', startIdx + 1, true)
        body = endIdx and src:sub(startIdx, endIdx - 1) or src:sub(startIdx, startIdx + 3000)
    end
    local wiredCombat = body and body:find("refreshExtractionIfDirty") ~= nil
    check("PLAYER_REGEN_ENABLED branch calls refreshExtractionIfDirty",
          wiredCombat == true,
          "combat exit is the cheap, periodic dirty-check tick for post-extraction state")

    -- The 120 ms BAG_UPDATE debounce frame must also call it.
    local frameStart = src:find('bagUpdateFrame:SetScript%("OnUpdate"', 1)
    local frameBody
    if frameStart then
        local endIdx = src:find("end%)", frameStart)
        frameBody = endIdx and src:sub(frameStart, endIdx) or src:sub(frameStart, frameStart + 4000)
    end
    local wiredFrame = frameBody and frameBody:find("refreshExtractionIfDirty") ~= nil
    check("bagUpdateFrame OnUpdate calls refreshExtractionIfDirty",
          wiredFrame == true,
          "the debounce frame is the post-anvil-close tick when bags update after extraction")
end

-- ---------------------------------------------------------------------------
-- Test 14 (v2.26.0): two-phrasing chance-on-hit detector.
-- ---------------------------------------------------------------------------
-- Background: items with chance-on-hit procs use two tooltip
-- phrasings - the classic `Chance on hit: <text>` (Bloodpike) and the
-- older PPM-style `Equip: Chance to <verb>... <text>` (Quillshooter).
-- v2.26.0 routes both through the same protection. If the detector
-- regresses to one phrasing, the other style slips past the v2.20.0
-- auto-rule gate and ends up in the Will Sell sweep.
do
    local hasHelper = src:find("function EC_compCache%.lineLooksLikeChanceProc%(") ~= nil
    -- Must scan for ITEM_SPELL_TRIGGER_ONPROC (or its enUS fallback) AND
    -- the Equip-Chance pattern.
    local hasClassicNeedle = src:find("ITEM_SPELL_TRIGGER_ONPROC") ~= nil
    local hasEquipPattern = src:find('"%^Equip:%%s%*Chance to') ~= nil
    check("EC_compCache.lineLooksLikeChanceProc helper is defined",
          hasHelper,
          "the shared chance-proc line detector must exist so both bag- and live-tooltip scans use the same rules")
    check("detector still matches the classic Chance on hit needle",
          hasClassicNeedle,
          "ITEM_SPELL_TRIGGER_ONPROC is the locale-safe constant for Chance on hit:")
    check("detector also matches the Equip: Chance to <verb> pattern",
          hasEquipPattern,
          "v2.26.0: Quillshooter-style PPM procs use Equip: Chance to <verb>; without this pattern they slip past protection")
end

-- ---------------------------------------------------------------------------
-- Test 15 (v2.26.0): EC_IsSellable chance-on-hit branch gates on
-- ADB.allowedItems.
-- ---------------------------------------------------------------------------
-- Background: the central sell-decision gate must consult the
-- allow list before letting a chance-on-hit item through the
-- quality-rule sweep. Without this branch the v2.26.0 schema field
-- exists but no code reads it, and items stay protected forever.
do
    local fnStart = src:find("local function EC_IsSellable%(", 1)
    if not fnStart then
        check("EC_IsSellable references ADB.allowedItems in the chance-on-hit branch",
              false, "EC_IsSellable not found")
    else
        local fnEnd = src:find("\nend", fnStart) or fnStart + 8000
        local body = src:sub(fnStart, fnEnd)
        local gateOK = body:find("allowedItems") ~= nil
            and body:find("itemHasChanceOnHit") ~= nil
        check("EC_IsSellable chance-on-hit branch consults ADB.allowedItems",
              gateOK,
              "the chance-on-hit gate must release qualityPass when the itemID is in the allow list")
    end
end

-- ---------------------------------------------------------------------------
-- Test 16 (v2.26.0): tooltip annotation has Protected and Allowed
-- states, replaces the v2.25.x single-state label.
-- ---------------------------------------------------------------------------
do
    -- v2.32.x label simplification: protection labels now read "Keep
    -- (reason)" instead of "Protected - reason"; override-active
    -- labels surface the actual destination as "Will Sell (...)" or
    -- "Will Delete" instead of "Allowed - ...".
    local hasProtectedLabel = src:find("Keep %(chance%-on%-hit proc%)") ~= nil
    local hasSellLabel = src:find("Override on") ~= nil
    local hasAccountSellLabel = src:find("Will Sell %(your Account List%)") ~= nil
    local hasCharSellLabel = src:find("Will Sell %(your Character List%)") ~= nil
    -- "Allowed - Delete" collapses to plain "Will Delete" because the
    -- destination doesn't need an "Allowed" qualifier - the verdict
    -- is what the player needs to see.
    -- v2.43.0: verdict labels are localized (wrapped in L[...]), so the
    -- displayed string is no longer a single literal. Match the wrapped key.
    local hasDeleteLabel = src:find('L%["Will Delete"%]') ~= nil
    check("tooltip annotation emits 'Keep (chance-on-hit proc)' for unmarked items",
          hasProtectedLabel)
    check("tooltip annotation emits 'Override on ...' when no list chosen",
          hasSellLabel,
          "marked items with no list membership get a call-to-action label, not a misleading 'will sell'")
    check("tooltip annotation emits 'Will Sell (your Account List)' when on Account Sell List",
          hasAccountSellLabel,
          "marked + on ADB.whitelist - label must reflect the actual destination")
    check("tooltip annotation emits 'Will Sell (your Character List)' when on Character Sell List",
          hasCharSellLabel,
          "marked + on DB.whitelist - label must reflect the actual destination")
    check("tooltip annotation emits 'Will Delete' when on Delete List (with or without override)",
          hasDeleteLabel,
          "marked + on DB.deleteList - delete verdict is the destination, no 'Allowed' qualifier needed")
end

-- ---------------------------------------------------------------------------
-- Test 17 (v2.26.0): context menu invariants.
-- ---------------------------------------------------------------------------
-- The menu MUST:
--   1. Hide list rows while a chance-on-hit item is unmarked.
--   2. Show "Allow Sell" / "Remove from Allowed Procs" in the
--      sellNow row slot for chance-on-hit items.
--   3. NOT show "Sell Now" anywhere any more (dropped in v2.26.0).
--   4. NOT carry "Add to" prefix on list row labels.
do
    local hasProtectedGate = src:find("rowHidden = true") ~= nil
        and src:find("procProtected") ~= nil
    local hasAllowText = src:find('btn:SetText%(L%["Allow Sell"%]%)') ~= nil
    local hasRemoveText = src:find("Remove from Allow List") ~= nil
    local sellNowGone = src:find('btn:SetText%("Sell Now"%)') == nil
    local addToPrefixGone = src:find('btn:SetText%("Add to "') == nil
    check("menu hides list rows while chance-on-hit item is unmarked",
          hasProtectedGate,
          "the procProtected gate is what forces the user to acknowledge the proc before list options open up")
    check("menu shows 'Allow Sell' for unmarked chance-on-hit items",
          hasAllowText)
    check("menu shows 'Remove from Allow List' for marked items",
          hasRemoveText)
    check("'Sell Now' is no longer in the menu",
          sellNowGone,
          "v2.26.0 removed the one-shot Sell Now path; explicit sells go through the Sell List")
    check("'Add to' prefix is no longer on list row labels",
          addToPrefixGone,
          "v2.26.0 dropped the prefix; the labels are self-evident and orange 'Remove from' rows provide the contrast")
end

-- ---------------------------------------------------------------------------
-- Test 18 (v2.26.0): EC_CTX_ROWS no longer contains the abandoned
-- forceSell row kind, and the legacy sellNow kind survived (now
-- repurposed as the Allow toggle slot).
-- ---------------------------------------------------------------------------
do
    -- forceSell was an interim design that got collapsed into a single
    -- Allow toggle. If it sneaks back in we'll see a duplicate menu
    -- row alongside the Allow Sell entry.
    local hasForceSell = src:find('kind = "forceSell"') ~= nil
    local hasSellNow = src:find('kind = "sellNow"') ~= nil
    check("EC_CTX_ROWS does NOT contain the abandoned forceSell row kind",
          not hasForceSell,
          "forceSell was collapsed into the single Allow toggle in v2.26.0; if it re-appears the menu shows two redundant rows")
    check("EC_CTX_ROWS still contains the sellNow row kind (used as Allow toggle slot)",
          hasSellNow,
          "the Allow Sell toggle reuses the legacy sellNow row position; removing the kind would drop the toggle entirely")
end

-- ---------------------------------------------------------------------------
-- Test 19a (v2.27.0): random-affix protection uses the same Allow Sell
-- gate as chance-on-hit.
-- ---------------------------------------------------------------------------
-- Background: v2.26.0 introduced the Allow Sell context-menu workflow
-- (hide list rows -> show "Allow Sell" -> after marking, full menu
-- opens up) but only for chance-on-hit items. v2.27.0 extends the
-- same gate to v2.23.0 random-affix protected items so the user
-- workflow is consistent across both protection mechanisms.
do
    -- The menu-gate detection must consider BOTH protections. Look
    -- for a hasAffix branch alongside hasProc in the context menu.
    local fnStart = src:find("local function EC_ShowItemContextMenu%(", 1)
    local fnEnd = fnStart and src:find("\nend", fnStart + 100) or nil
    local body = fnStart and fnEnd and src:sub(fnStart, fnEnd) or ""
    local readsHasAffix = body:find("hasAffix") ~= nil
        and body:find("bagSlotAffixData") ~= nil
    local unifiedFlag = body:find("hasProtection") ~= nil
    check("context menu detects random-affix protection via bagSlotAffixData",
          readsHasAffix,
          "without this branch, protected affix items show the full Sell/Keep/Delete menu instead of the Allow Sell gate")
    check("context menu uses a unified hasProtection flag",
          unifiedFlag,
          "the unified flag is what lets the sellNow row and the list-row hiding share the same gate")

    -- EC_IsSellable affix branch must read allowedAffixes (the
    -- affix-keyed list, NOT allowedItems) as a manual override path
    -- alongside the v2.23.0 affixAllowExactDupes auto-detect.
    local sellStart = src:find("local function EC_IsSellable%(", 1)
    local sellEnd = sellStart and src:find("\nend", sellStart + 100) or nil
    local sellBody = sellStart and sellEnd and src:sub(sellStart, sellEnd) or ""
    local affixBranchReadsAllow = sellBody:find("protectAffixedRareItems") ~= nil
        and sellBody:find("allowedAffixes") ~= nil
    check("EC_IsSellable affix branch consults ADB.allowedAffixes (affix-keyed)",
          affixBranchReadsAllow,
          "marking by affix description (not base itemID) is what lets every drop with the same affix pass")
end

-- ---------------------------------------------------------------------------
-- Test 19b (v2.27.0): affix-keyed allow list schema + marking path.
-- ---------------------------------------------------------------------------
-- Background: random-affix items carry their identity in the affix
-- description (per-instance roll). A per-itemID mark would let every
-- base-itemID drop through regardless of which affix rolled - too
-- coarse. The affix-keyed list is what gives the user "I have this
-- affix extracted; pass any drop rolling it" semantics.
do
    local hasDefault = src:find("ADB%.allowedAffixes%s*=%s*{}") ~= nil
    check("EnsureAccountDB defaults ADB.allowedAffixes to an empty table",
          hasDefault,
          "the affix-keyed allow list is what gives per-affix granularity for v2.23.0 random-affix items")

    -- The Allow Sell click path for an affixed item must write to
    -- ADB.allowedAffixes keyed by the normalised description, not to
    -- ADB.allowedItems keyed by itemID.
    local fnStart = src:find("local function EC_ShowItemContextMenu%(", 1)
    local fnEnd = fnStart and src:find("\nend", fnStart + 100) or nil
    local body = fnStart and fnEnd and src:sub(fnStart, fnEnd) or ""
    local marksByDescription = body:find("allowedAffixes%[affixKey%]") ~= nil
    check("Allow Sell click writes the affix description to allowedAffixes",
          marksByDescription,
          "marking by itemID would be too coarse - rolling a different affix on the same base would also pass")

end

-- ---------------------------------------------------------------------------
-- Test 19c (v2.27.0): affix-sourced Sell List entries get an
-- "(affix-gated)" tag in the panel.
-- ---------------------------------------------------------------------------
-- Background: adding an affixed-item-instance to the Sell List adds
-- the BASE itemID, which is coarser than the per-drop filtering the
-- affix protection actually applies. The (affix-gated) tag makes
-- this honest in the panel so the user doesn't read "Orb of
-- Mistmantle" on the list and assume every drop of that itemID
-- will sell.
do
    local hasDefault = src:find("ADB%.affixedListedItems%s*=%s*{}") ~= nil
    local hasStamp = src:find("ADB%.affixedListedItems%[itemID%]%s*=%s*true") ~= nil
    local hasTag = src:find('%(affix%-gated%)') ~= nil
    check("EnsureAccountDB defaults ADB.affixedListedItems to an empty table",
          hasDefault,
          "the side meta table lets the list panel mark affix-sourced entries without changing the core list shape")
    check("menu stamps ADB.affixedListedItems[itemID] when adding an affixed item",
          hasStamp,
          "without the stamp at add time, the panel can't tell which entries came in via an affixed drop")
    check("list panel row text appends an '(affix-gated)' tag",
          hasTag,
          "the tag is what makes the list honest - 'Will Sell every drop of this itemID' isn't actually what happens for affix items")
end

-- ---------------------------------------------------------------------------
-- Test 19 (post-v2.26.1 cleanup): processTooltipHasLine writes the
-- "none" negative-cache sentinel on scan miss.
-- ---------------------------------------------------------------------------
-- Background: canMill and canProspect both early-return on
-- `processCache[itemID] == "none"`. Without the negative-write,
-- every non-millable / non-prospectable item gets a fresh 30-line
-- tooltip scan on each BAG_UPDATE-driven rearm (the panel/keybind-
-- gated rearm path that fires after the 120 ms debounce). Bag-heavy
-- characters paid this on every burst. Lock the sentinel write so
-- the regression doesn't sneak back in.
do
    local fnStart = src:find("function EC_compCache%.processTooltipHasLine%(")
    if not fnStart then
        check("processTooltipHasLine writes the 'none' negative-cache sentinel",
              false, "processTooltipHasLine not found in source")
    else
        local fnEnd = src:find("\nend", fnStart)
        local body = fnEnd and src:sub(fnStart, fnEnd) or src:sub(fnStart, fnStart + 2000)
        -- v2.36.x: the negative-cache sentinel is still written, but the
        -- write goes through a `result` local that defaults to "none" and
        -- is set to "Mill" or "Prospect" on a hit. So accept either the
        -- legacy direct-write form OR the new local-default form.
        local legacyDirectWrite = body:find('processCache%[itemID%]%s*=%s*"none"') ~= nil
        local newDefaultThenAssign = body:find('local result = "none"') ~= nil
            and body:find('processCache%[itemID%]%s*=%s*result') ~= nil
        local writesNone = legacyDirectWrite or newDefaultThenAssign
        check("processTooltipHasLine writes the 'none' negative-cache sentinel",
              writesNone,
              "without this, canMill/canProspect rescan every non-eligible item on each BAG_UPDATE-driven rearm")
    end
end

-- ---------------------------------------------------------------------------
-- Test 20 (v2.28.0): CreateListUI name-sort pre-computes a name map.
-- ---------------------------------------------------------------------------
-- Background: the previous name-sort comparator called GetItemInfo
-- twice per pair-compare, producing ~20k cache hits + 20k :lower()
-- allocations to sort a 1000-item list. Pre-computing a {id -> name}
-- map once before sort drops it to ~1k lookups + an O(1) comparator.
-- Same fix landed in buildProcessSummary in v2.27.0 (Test 6 covers
-- the comparator side there).
do
    local fnStart = src:find("local function CreateListUI%(")
    if not fnStart then
        check("CreateListUI name-sort pre-computes a nameByID map",
              false, "CreateListUI not found")
    else
        -- Refresh() lives inside CreateListUI. Capture the bigger
        -- enclosing range and look for the pre-compute pattern.
        -- Slice to the function's real end marker rather than a fixed byte
        -- window, so the body covers all of CreateListUI even as it grows.
        local fnEnd = src:find("\nNS%.CreateListUI = CreateListUI", fnStart) or (fnStart + 14000)
        local body = src:sub(fnStart, fnEnd)
        local hasMap = body:find("local nameByID = {}") ~= nil
        local mapDrivenSort = body:find("nameByID%[a%]") ~= nil
            and body:find("nameByID%[b%]") ~= nil
        check("CreateListUI builds a nameByID lookup before name-sort",
              hasMap,
              "without this pre-compute, the comparator runs ~2N log N GetItemInfo calls")
        check("CreateListUI name-sort comparator reads nameByID, not GetItemInfo",
              mapDrivenSort,
              "comparator must use the pre-computed map for O(1) compares")
    end
end

-- ---------------------------------------------------------------------------
-- Test 21 (v2.28.0): list search input debounced.
-- ---------------------------------------------------------------------------
-- Background: typing in the search box previously fired a full
-- Refresh() per keystroke. Coalesce via an OnUpdate-driven debounce
-- so multi-character searches only re-render once after the user
-- stops typing.
do
    local fnStart = src:find("local function CreateListUI%(")
    if not fnStart then
        check("CreateListUI search input is debounced",
              false, "CreateListUI not found")
    else
        -- Slice to the function's real end marker rather than a fixed byte
        -- window, so the body covers all of CreateListUI even as it grows.
        local fnEnd = src:find("\nNS%.CreateListUI = CreateListUI", fnStart) or (fnStart + 14000)
        local body = src:sub(fnStart, fnEnd)
        -- The search OnTextChanged handler must NOT call Refresh()
        -- directly. It should poke a debounce frame instead.
        local handler = body:match('search:SetScript%("OnTextChanged",%s*function%(%)(.-)end%)')
        local directRefresh = handler and handler:find("Refresh%(%)") ~= nil
        local hasDebounce = body:find("searchDebounce") ~= nil
        check("search OnTextChanged does NOT call Refresh() directly",
              not directRefresh,
              "calling Refresh() per keystroke causes the >1000-item slowdown the user reported")
        check("CreateListUI defines a searchDebounce frame",
              hasDebounce,
              "expected an OnUpdate-driven debounce frame guarding the search Refresh")
    end
end

-- ---------------------------------------------------------------------------
-- Test 22 (v2.28.0): tooltip-prime SetOwner hoisted outside the
-- per-row loop.
-- ---------------------------------------------------------------------------
-- Background: the previous loop called GameTooltip:SetOwner per
-- uncached row alongside SetHyperlink. SetOwner is a UI-frame state
-- change; calling it once per uncached item is wasteful when one
-- owner serves the whole pass. Lift it (and the matching Hide) out
-- of the per-row body.
do
    local fnStart = src:find("local function CreateListUI%(")
    if not fnStart then
        check("CreateListUI hoists tooltip-prime SetOwner out of the loop",
              false, "CreateListUI not found")
    else
        -- Slice to the function's real end marker rather than a fixed byte
        -- window, so the body covers all of CreateListUI even as it grows.
        local fnEnd = src:find("\nNS%.CreateListUI = CreateListUI", fnStart) or (fnStart + 14000)
        local body = src:sub(fnStart, fnEnd)
        -- Look for the prime-frame setup pattern outside the
        -- per-row loop.
        local hasPrimeHoist = body:find("local primeFrame = GameTooltip") ~= nil
            and body:find("local canPrime") ~= nil
        check("CreateListUI hoists GameTooltip prime setup outside the row loop",
              hasPrimeHoist,
              "SetOwner per uncached row was wasteful; one owner serves the whole pass")
    end
end

-- ---------------------------------------------------------------------------
-- Test 23 (v2.28.0): dead EC_SellNowAt removed.
-- ---------------------------------------------------------------------------
-- v2.27.0 removed the Sell Now context-menu row. EC_SellNowAt was the
-- handler behind that row; zero call sites remained. Regression-lock
-- the removal so a future "let's re-add Sell Now" attempt has to
-- update this test too.
do
    local stillDefined = src:find("local function EC_SellNowAt%(") ~= nil
    check("EC_SellNowAt is no longer defined",
          not stillDefined,
          "the function was orphaned after v2.27.0 dropped the Sell Now menu row; re-adding it should come with a re-introduced call site")
end

-- ---------------------------------------------------------------------------
-- Test 24 (v2.29.0): normaliseAffixDesc case-folds at the end.
-- ---------------------------------------------------------------------------
-- The affix dupe gate fails (and Allow Sell entries become orphaned)
-- if the normaliser stops case-folding while the EnsureAccountDB
-- migration still lowercases existing keys. The two are a load-bearing
-- pair: both must case-fold or neither.
do
    local hasLower = src:find("function EC_compCache%.normaliseAffixDesc%([^)]*%).-:lower%(%)%s*\n%s*end") ~= nil
    check("normaliseAffixDesc case-folds via :lower()",
          hasLower,
          "the function must return a lowercased string so source-side casing differences (rank-I lowercase vs rank-II capital) compare equal; see docs/ADDON_GUIDE.md Affix description normalisation case-folds")
end

-- ---------------------------------------------------------------------------
-- Test 25 (v2.29.0): EnsureAccountDB migrates allowedAffixes keys to lowercase.
-- ---------------------------------------------------------------------------
-- The one-shot migration in EnsureAccountDB lowercases pre-existing
-- ADB.allowedAffixes keys so Allow Sell entries set under the old
-- (mixed-case) normaliser keep matching. Pair-locked with test 24.
do
    local startIdx = src:find("local function EnsureAccountDB%(")
    local endIdx = startIdx and src:find("\nlocal function ", startIdx + 1) or nil
    local body = startIdx and src:sub(startIdx, endIdx or (startIdx + 6000)) or ""
    local hasLowercasePass = body:find("ADB%.allowedAffixes") and body:find("k:lower%(%)") ~= nil
    check("EnsureAccountDB lowercases ADB.allowedAffixes keys",
          hasLowercasePass,
          "the one-shot migration must lowercase existing keys; removing it without also removing the normaliser's :lower() orphans pre-fix Allow Sell entries")
end

-- ---------------------------------------------------------------------------
-- Test 26 (v2.29.0): list-mutation sites call the sell-border refresh helper.
-- ---------------------------------------------------------------------------
-- Any DB.whitelist / DB.blacklist / DB.deleteList / ADB.allowed* mutation
-- must be followed by the refresh helper so the slot-border ring
-- doesn't go stale. Verifies the documented contract in
-- docs/ADDON_GUIDE.md "List-mutation must call the sell-border refresh".
-- The helper name changed from EC_RefreshSellBorders to NS.RefreshSellBorders
-- in Stage 6 of the file split (the body moved to BagDisplay; the stub on
-- NS lives in EbonClearance_Events.lua so cross-file callers reach it).
local SB_REFRESH_PATTERN = "NS%.RefreshSellBorders%(%)"
local SB_REFRESH_CONTEXT_PATTERN = "NS%.RefreshSellBorders"
do
    local function bodyHasRefresh(funcSig)
        local startIdx = src:find(funcSig)
        if not startIdx then
            return nil
        end
        local nextLocal = src:find("\nlocal function ", startIdx + 1) or #src
        local nextTbl = src:find("\nfunction [A-Za-z_]+%.", startIdx + 1) or #src
        local endIdx = math.min(nextLocal, nextTbl)
        local body = src:sub(startIdx, endIdx)
        return body:find(SB_REFRESH_PATTERN) ~= nil
    end

    local addOk = bodyHasRefresh("local function EC_AddItemToList%(")
    check("EC_AddItemToList calls NS.RefreshSellBorders",
          addOk,
          "list adds must refresh slot-border tints so rings draw on newly-added items immediately")

    local removeOk = bodyHasRefresh("local function EC_RemoveItemFromList%(")
    check("EC_RemoveItemFromList calls NS.RefreshSellBorders",
          removeOk,
          "list removes must refresh slot-border tints so rings clear on freshly-removed items immediately")

    -- Allow Sell click handlers live inline in the context-menu builder;
    -- look for the "Allow Sell" / "Remove from Allow List" string literals
    -- followed (within a reasonable window) by an NS.RefreshSellBorders call.
    local allowSellRegion = src:match('Allow Sell".-' .. SB_REFRESH_CONTEXT_PATTERN)
    local removeAllowRegion = src:match("Remove from Allow List|r.-" .. SB_REFRESH_CONTEXT_PATTERN)
    check("Allow Sell click handler calls NS.RefreshSellBorders",
          allowSellRegion ~= nil,
          "marking an item as Allow Sell can flip its sellability verdict; the slot border must repaint")
    check("Remove from Allow List click handler calls NS.RefreshSellBorders",
          removeAllowRegion ~= nil,
          "removing an Allow Sell mark restores chance-on-hit / affix protection; the slot border must repaint")
end

-- ---------------------------------------------------------------------------
-- Test 27 (v2.29.0): sell-border helpers live on EC_compCache, not module-level.
-- ---------------------------------------------------------------------------
-- Adding these as module-level `local function` would trip Lua 5.1's
-- 200-locals cap in the main chunk. Keep them on EC_compCache so the
-- main chunk stays under the limit.
do
    local helpers = {
        "applySellBorder",
        "bagSlotWillSell",
        "updateSellBordersForBagFrame",
        "installHostBagBorderHook",
        "sellBorderButtons",
        "describeSellability",
        "printSellabilityTrace",
        "bagSlotFromButton",
        "exportFullPack",
        "importFullPack",
        "qualityNames",
        "PACK_PREFIX",
    }
    for _, name in ipairs(helpers) do
        -- Pinned check: plain-mode find for the literal "EC_compCache.<name>"
        -- string. Using plain mode so the dot is literal, not a pattern char.
        local pinned = src:find("EC_compCache." .. name, 1, true) ~= nil
        -- Leaked check: pattern-mode find for module-level local definitions.
        -- `local function NAME(` or `\nlocal NAME =` at file scope - both
        -- patterns escape literal parens / equals via Lua's pattern syntax.
        local leakedFn = src:find("local function " .. name .. "%(") ~= nil
        local leakedAssign = src:find("\nlocal " .. name .. "%s*=") ~= nil
        check(
            name .. " is namespaced under EC_compCache",
            pinned and not (leakedFn or leakedAssign),
            "the v2.29.0 helpers must live on EC_compCache (Lua 5.1 200-locals cap); if moved to a module local the main chunk overflows"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 28 (Stage 1+2): namespace bootstrap + EC_compCache split-safe.
-- ---------------------------------------------------------------------------
-- The multi-stage file split tracked in docs/CODE_REVIEW.md item 4 depends
-- on `local NS = select(2, ...)` at the top of every shipped source file
-- AND on EC_compCache being declared exactly ONCE as a table literal
-- (in EbonClearance_Core.lua after Stage 2) plus exactly ONCE as a
-- namespace re-alias (in EbonClearance_Events.lua). The concat-source pattern
-- the tests use means both of those declarations appear in `src`;
-- the invariants below count them separately so a shadowing redeclaration
-- still fails.
do
    -- Every shipped .lua file must declare `local NS = select(2, ...)`
    -- near its top - that's how each file captures the shared namespace
    -- table WoW passes as the second file-load vararg. After Stage 2
    -- both EbonClearance_Core.lua and EbonClearance_Events.lua have one each,
    -- so the concat source contains AT LEAST 2 occurrences.
    --
    -- Plain-mode find: pass true as the 3rd arg so `()` are literal
    -- parens and `...` is a literal ellipsis (no pattern escaping).
    local bootstrapCount = 0
    local searchStart = 1
    while true do
        local s, e = src:find("local NS = select(2, ...)", searchStart, true)
        if not s then break end
        bootstrapCount = bootstrapCount + 1
        searchStart = e + 1
    end
    check(
        "namespace varargs bootstrap present in every source file",
        bootstrapCount >= #SOURCE_PATHS,
        string.format(
            "expected at least %d `local NS = select(2, ...)` occurrences " ..
            "(one per source file in SOURCE_PATHS); found %d",
            #SOURCE_PATHS, bootstrapCount
        )
    )

    -- EC_compCache mirrored onto NS.compCache (Stage 1 invariant). Both
    -- names point at the same table; existing call sites use the
    -- EC_compCache upvalue, future split files reach the table via
    -- NS.compCache. Lives in Core after Stage 2.
    local mirror = src:find("NS%.compCache = EC_compCache") ~= nil
    check(
        "EC_compCache mirrored onto NS.compCache",
        mirror,
        "after the EC_compCache table literal closes (in Core post-Stage-2), `NS.compCache = EC_compCache` must alias the table onto the namespace"
    )

    -- Defence-in-depth: exactly ONE table-literal declaration of
    -- EC_compCache. A second literal would silently desync from
    -- NS.compCache (the alias would still point at the first table).
    -- The re-alias pattern `local EC_compCache = NS.compCache` is
    -- expected (in EbonClearance_Events.lua) and intentionally NOT counted here.
    local literalCount = 0
    for _ in src:gmatch("\nlocal EC_compCache%s*=%s*{") do
        literalCount = literalCount + 1
    end
    if src:find("^local EC_compCache%s*=%s*{") then
        literalCount = literalCount + 1
    end
    check(
        "EC_compCache declared as a table literal exactly once",
        literalCount == 1,
        "EC_compCache must have exactly one table-literal declaration (`local EC_compCache = { ... }`) across all shipped sources. A second one would silently desync the NS.compCache alias. Found " .. tostring(literalCount)
    )

    -- Companion invariant: AT LEAST ONE re-alias `local EC_compCache = NS.compCache`.
    -- Every split file that uses the `EC_compCache.foo` upvalue idiom adds
    -- its own re-alias near the top so call sites resolve through the
    -- file-scope local. EbonClearance_Events.lua has one; EbonClearance_Companion.lua
    -- has one; later stages will add more. If the count drops to zero,
    -- every `EC_compCache.foo` reference would resolve to global nil.
    local aliasCount = 0
    for _ in src:gmatch("\nlocal EC_compCache%s*=%s*NS%.compCache") do
        aliasCount = aliasCount + 1
    end
    check(
        "EC_compCache re-alias from NS.compCache present at least once per consumer file",
        aliasCount >= 1,
        "expected at least one `local EC_compCache = NS.compCache` re-alias across the shipped sources. Found " .. tostring(aliasCount)
    )
end

-- ---------------------------------------------------------------------------
-- Test 29 (Stage 3): Companion module cross-file API surface.
-- ---------------------------------------------------------------------------
-- After Stage 3 the chat-filter / bubble-killer cluster lives in
-- EbonClearance_Companion.lua. The event hub in EbonClearance_Events.lua calls
-- two entry points by name; both must be exposed on NS by Companion AND
-- called via NS by EbonClearance_Events.lua. If anyone re-introduces an
-- unqualified `EC_InstallGreedyMuteOnce()` / `ApplyGreedyChatFilter()`
-- call (which would resolve to nil), CI catches it here.
do
    -- Companion exposes both helpers on NS at file load.
    check(
        "NS.InstallGreedyMuteOnce exposed",
        src:find("NS%.InstallGreedyMuteOnce%s*=%s*EC_InstallGreedyMuteOnce") ~= nil,
        "Companion must publish `NS.InstallGreedyMuteOnce = EC_InstallGreedyMuteOnce`"
    )
    check(
        "NS.ApplyGreedyChatFilter exposed",
        src:find("NS%.ApplyGreedyChatFilter%s*=%s*ApplyGreedyChatFilter") ~= nil,
        "Companion must publish `NS.ApplyGreedyChatFilter = ApplyGreedyChatFilter`"
    )

    -- No bare-identifier call sites for either helper. After the move,
    -- every call site MUST be NS-qualified - a bare call would resolve
    -- to nil because the file-scope local is gone from EbonClearance_Events.lua.
    -- The function-definition lines in Companion ALSO match `<name>(` so
    -- we mask them out before scanning. Comment lines are skipped.
    local function hasBareCall(s, name)
        -- Mask definition sites so they don't false-positive.
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end

    local bareInstall = hasBareCall(src, "EC_InstallGreedyMuteOnce")
    local bareApply = hasBareCall(src, "ApplyGreedyChatFilter")
    check(
        "no bare EC_InstallGreedyMuteOnce() call sites (must be NS.InstallGreedyMuteOnce)",
        bareInstall == nil,
        "found bare call: " .. tostring(bareInstall)
    )
    check(
        "no bare ApplyGreedyChatFilter() call sites (must be NS.ApplyGreedyChatFilter)",
        bareApply == nil,
        "found bare call: " .. tostring(bareApply)
    )

    -- Companion captures `NS.DB` and `NS.PET_NAME_LC` inline at call time.
    -- The mirror sites in EbonClearance_Events.lua MUST keep writing those, so a
    -- future refactor that drops the NS exposure surfaces here.
    check(
        "EnsureDB exposes NS.DB",
        src:find("NS%.DB%s*=%s*DB", 1) ~= nil,
        "EnsureDB must write `NS.DB = DB` so split files reading NS.DB see the live binding"
    )
    check(
        "Name refresh exposes NS.PET_NAME_LC",
        src:find("NS%.PET_NAME_LC%s*=%s*PET_NAME_LC", 1) ~= nil,
        "Every site that rebinds PET_NAME_LC must mirror onto NS.PET_NAME_LC for the chat filter to see the live value"
    )
end

-- ---------------------------------------------------------------------------
-- Test 30 (Stage 4): Protection helpers stay namespaced under EC_compCache.
-- ---------------------------------------------------------------------------
-- After Stage 4 the affix + chance-on-hit detection cluster lives in
-- EbonClearance_Protection.lua. Every helper is attached to EC_compCache,
-- which is the same table EbonClearance_Events.lua's call sites already resolve
-- through via their re-aliased upvalue. If a future refactor moves any
-- of these helpers off EC_compCache (e.g. as a module-level local in
-- Protection), call sites in EbonClearance_Events.lua would resolve to nil.
do
    local helpers = {
        "linkHasAffix",
        "romanToInt",
        "parseAffixFromTitle",
        "scanTooltipForAffixDesc",
        "normaliseAffixDesc",
        "bagSlotAffixData",
        "bagSlotHasAffix",
        "liveTooltipAffixData",
        "liveTooltipHasAffix",
        "peDetected",
        "refreshKnownAffixes",
        "refreshExtractionIfDirty",
        "playerHasAffixDescription",
        "lineLooksLikeChanceProc",
        "itemHasChanceOnHit",
        "liveTooltipHasChanceOnHit",
        "findLearnedAffixForItem",
    }
    for _, name in ipairs(helpers) do
        local pinned = src:find("EC_compCache." .. name, 1, true) ~= nil
        local leakedFn = src:find("local function " .. name .. "%(") ~= nil
        check(
            name .. " is namespaced under EC_compCache",
            pinned and not leakedFn,
            name .. " must stay on EC_compCache so call sites in EbonClearance_Events.lua resolve through the shared upvalue"
        )
    end

    -- NS.scanTooltip exposure. EbonClearance_Events.lua creates the named
    -- GameTooltip frame and writes it onto NS so Protection's bodies
    -- can dereference NS.scanTooltip lazily at call time (Protection
    -- loads before EbonClearance_Events.lua's main chunk so an upvalue capture
    -- at Protection's load would store nil).
    check(
        "NS.scanTooltip exposed by EbonClearance_Events.lua frame creation",
        src:find("NS%.scanTooltip%s*=%s*EC_scanTooltip") ~= nil,
        "EbonClearance_Events.lua must write `NS.scanTooltip = EC_scanTooltip` immediately after creating the frame, so Protection's lazy dereference works"
    )
end

-- ---------------------------------------------------------------------------
-- Test 31 (Stage 5): vendor-cycle state promoted to EC_compCache;
-- HookDeletePopupOnce moved to EbonClearance_Vendor.lua.
-- ---------------------------------------------------------------------------
-- Stage 5 is narrowly scoped: only the deletion-popup hook moves to
-- EbonClearance_Vendor.lua. The vendor cycle itself (EC_IsSellable,
-- BuildQueue, worker, StartRun, EC_manualSell) stays in EbonClearance_Events.lua
-- for future stages because its cross-file dependency surface is wide.
--
-- Two vendor-cycle scalars WERE promoted in Stage 5 prep:
--   * running -> EC_compCache.vendorRunning
--   * pendingDelete -> EC_compCache.pendingDelete
-- Both initialise in Core's table literal. If a future refactor reintroduces
-- file-scope `local running` or `local pendingDelete` in EbonClearance_Events.lua,
-- it would silently desync from the cache table; the count check below
-- catches that.
do
    -- Vendor.lua publishes NS.HookDeletePopupOnce at file load.
    check(
        "NS.HookDeletePopupOnce exposed",
        src:find("NS%.HookDeletePopupOnce%s*=%s*HookDeletePopupOnce") ~= nil,
        "EbonClearance_Vendor.lua must publish `NS.HookDeletePopupOnce = HookDeletePopupOnce`"
    )

    -- No bare-identifier call sites for HookDeletePopupOnce. Definition
    -- in Vendor is masked from the scan.
    local function hasBareCall(s, name)
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    local bareHook = hasBareCall(src, "HookDeletePopupOnce")
    check(
        "no bare HookDeletePopupOnce() call sites (must be NS.HookDeletePopupOnce)",
        bareHook == nil,
        "found bare call: " .. tostring(bareHook)
    )

    -- vendorRunning + pendingDelete fields initialised in Core's
    -- EC_compCache table literal.
    check(
        "EC_compCache.vendorRunning initialised in Core",
        src:find("vendorRunning%s*=%s*false") ~= nil,
        "Core's EC_compCache table literal must initialise `vendorRunning = false` (promoted Stage 5 prep)"
    )
    check(
        "EC_compCache.pendingDelete initialised in Core",
        src:find("pendingDelete%s*=%s*nil") ~= nil,
        "Core's EC_compCache table literal must initialise `pendingDelete = nil` (promoted Stage 5 prep)"
    )

    -- No file-scope `local running` or `local pendingDelete` lurking in
    -- the shipped sources. Either would silently desync from the cache
    -- table. Comment lines mentioning these names are allowed.
    local lines_iter = {}
    for ln in src:gmatch("[^\n]+") do
        table.insert(lines_iter, ln)
    end
    local function noBareLocalDecl(name)
        for _, ln in ipairs(lines_iter) do
            local stripped = ln:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                -- Look for `local NAME =` or `local NAME\b` at start of code
                if code:match("^local%s+" .. name .. "%s*=") or
                   code:match("^local%s+" .. name .. "%s*$") then
                    return ln
                end
            end
        end
        return nil
    end
    local lurkingRunning = noBareLocalDecl("running")
    local lurkingPending = noBareLocalDecl("pendingDelete")
    check(
        "no file-scope `local running` (post Stage 5 promotion)",
        lurkingRunning == nil,
        "found: " .. tostring(lurkingRunning)
    )
    check(
        "no file-scope `local pendingDelete` (post Stage 5 promotion)",
        lurkingPending == nil,
        "found: " .. tostring(lurkingPending)
    )
end

-- ---------------------------------------------------------------------------
-- Test 32 (PR #2): affix-scan freeze fix - debounce + cache + chunked scan.
-- ---------------------------------------------------------------------------
-- Sanavesa's PR #2 fixed a ~30 s freeze on login / soul-ash-tree apply by
-- coalescing rapid SPELLS_CHANGED bursts and amortising tooltip scans
-- across frames. Three pieces, each must stay in place:
--
--   1. Per-spellID cache (EC_compCache.spellbookAffixCache) so each
--      spell's tooltip is scanned at most once per session. Same
--      `false` sentinel convention as procIdToDescription.
--   2. 0.5 s debounce frame (EC_compCache.spellUpdateFrame) so a burst
--      of LEARNED_SPELL_IN_TAB / SPELLS_CHANGED events coalesces into
--      one rebuild after the burst settles.
--   3. Chunked OnUpdate scan (EC_compCache.SPELLS_PER_CHUNK spells per
--      frame) so even the first cold-cache scan doesn't freeze the UI.
--
-- If any of these regresses - e.g. someone reverts to a synchronous
-- refreshKnownAffixes(), or removes the cache, or hard-codes the
-- chunk size as a magic literal - CI catches it here.
do
    -- 1. Cache table declared at module scope.
    check(
        "EC_compCache.spellbookAffixCache declared",
        src:find("EC_compCache%.spellbookAffixCache%s*=%s*{}") ~= nil,
        "PR #2 added a per-spellID tooltip cache. Removing it would re-scan every spell on every rebuild."
    )

    -- 2. Debounce frame + accumulator + named window constant.
    check(
        "EC_compCache.spellUpdateFrame declared as a CreateFrame",
        src:find("EC_compCache%.spellUpdateFrame%s*=%s*CreateFrame") ~= nil,
        "PR #2 added a debounce frame so spell-event bursts coalesce. It must remain on EC_compCache."
    )
    check(
        "EC_compCache.spellUpdateFrame has an OnUpdate handler",
        src:find('EC_compCache%.spellUpdateFrame:SetScript%("OnUpdate"') ~= nil,
        "the debounce frame must drive a coalescing OnUpdate; without it events would fire synchronously again"
    )
    check(
        "EC_compCache.SPELL_UPDATE_DEBOUNCE_S is a named constant",
        src:find("EC_compCache%.SPELL_UPDATE_DEBOUNCE_S%s*=") ~= nil,
        "the 0.5 s window must be a named constant for future tuning, not a magic literal scattered through the code"
    )

    -- 3. Chunked-scan budget constant.
    check(
        "EC_compCache.SPELLS_PER_CHUNK is a named constant",
        src:find("EC_compCache%.SPELLS_PER_CHUNK%s*=") ~= nil,
        "the per-frame scan budget must be a named constant; tuning would otherwise require scanning the source for a bare 30"
    )

    -- 4. Event branch triggers the debounce frame and does NOT call
    --    refreshKnownAffixes directly. The branch lives in EbonClearance_Events.lua's
    --    event-hub dispatcher; we extract it, strip comments, and assert
    --    against the resulting code (comments that mention the function
    --    name by way of explanation are fine).
    local startIdx = src:find('event == "LEARNED_SPELL_IN_TAB"', 1, true)
    local branchBody
    if startIdx then
        local nextIdx = src:find("elseif event ==", startIdx + 1, true)
        branchBody = nextIdx and src:sub(startIdx, nextIdx - 1) or src:sub(startIdx)
    end
    local branchCodeOnly
    if branchBody then
        local codeLines = {}
        for line in branchBody:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                codeLines[#codeLines + 1] = code
            end
        end
        branchCodeOnly = table.concat(codeLines, "\n")
    end
    check(
        "LEARNED_SPELL_IN_TAB / SPELLS_CHANGED branch triggers spellUpdateFrame:Show()",
        branchCodeOnly and branchCodeOnly:find("EC_compCache%.spellUpdateFrame:Show%(%)") ~= nil,
        "the event branch must :Show() the debounce frame instead of calling refreshKnownAffixes() synchronously"
    )
    check(
        "LEARNED_SPELL_IN_TAB / SPELLS_CHANGED branch does NOT call refreshKnownAffixes() synchronously",
        branchCodeOnly and branchCodeOnly:find("refreshKnownAffixes") == nil,
        "the event handler must route through the debounce frame; a direct call would defeat the whole fix (comments mentioning the function are fine; this check is code-only)"
    )
end

-- ---------------------------------------------------------------------------
-- Test 33 (Stage 6): BagDisplay extraction + NS.RefreshSellBorders pattern.
-- ---------------------------------------------------------------------------
-- Stage 6 moves the Release-1 bag-display layer to EbonClearance_BagDisplay.lua.
-- The forward-declared `EC_RefreshSellBorders` local was promoted to
-- NS.RefreshSellBorders so the stub (in EbonClearance_Events.lua) and the real
-- body (in BagDisplay) can live in different files. Load order in the
-- .toc puts BagDisplay AFTER EbonClearance_Events.lua so BagDisplay's body
-- assignment OVERWRITES the stub, not the other way around.
do
    -- The stub on NS (no-op). Lives in EbonClearance_Events.lua's forward-decl
    -- block so the Character Settings panel toggle can call it before
    -- BagDisplay loads its real body.
    check(
        "NS.RefreshSellBorders stub declared",
        src:find("NS%.RefreshSellBorders%s*=%s*function%(%)%s*end") ~= nil,
        "EbonClearance_Events.lua must forward-declare `NS.RefreshSellBorders = function() end` as a no-op stub"
    )

    -- The real body in BagDisplay. Pattern matches both
    -- `NS.RefreshSellBorders = function()` and `function NS.RefreshSellBorders()`.
    local hasBody =
        src:find("NS%.RefreshSellBorders%s*=%s*function%(%s*%)%s*\n") ~= nil
        or src:find("function%s+NS%.RefreshSellBorders%(%s*%)") ~= nil
    -- The stub itself matches the first pattern with no body lines, so
    -- "hasBody" is satisfied by either the stub OR a real reassignment.
    -- To distinguish: look for `NS.RefreshSellBorders = function()` followed
    -- by something other than `end` (the stub) OR a long body. Simplest
    -- check: BagDisplay's file content directly.
    local function read_file(path)
        local f = io.open(path, "r")
        if not f then
            return nil
        end
        local s = f:read("*a")
        f:close()
        return s
    end
    local bagDisplay = read_file("EbonClearance_BagDisplay.lua")
    check(
        "EbonClearance_BagDisplay.lua exists",
        bagDisplay ~= nil,
        "Stage 6 must create EbonClearance_BagDisplay.lua"
    )
    if bagDisplay then
        check(
            "BagDisplay reassigns NS.RefreshSellBorders body",
            bagDisplay:find("NS%.RefreshSellBorders%s*=%s*function%(%)") ~= nil,
            "EbonClearance_BagDisplay.lua must reassign `NS.RefreshSellBorders = function()` with the real body (replaces the no-op stub from EbonClearance_Events.lua)"
        )
        -- BagDisplay's helpers stay on EC_compCache.
        local helpers = {
            "sellBorderButtons",
            "applySellBorder",
            "bagSlotWillSell",
            "updateSellBordersForBagFrame",
            "installHostBagBorderHook",
            "qualityNames",
            "describeSellability",
            "printSellabilityTrace",
            "bagSlotFromButton",
        }
        for _, name in ipairs(helpers) do
            check(
                name .. " present in BagDisplay on EC_compCache",
                bagDisplay:find("EC_compCache." .. name, 1, true) ~= nil,
                name .. " must be attached to EC_compCache in BagDisplay so call sites elsewhere resolve via the shared cache"
            )
        end
    end

    -- The .toc loads BagDisplay AFTER EbonClearance_Events.lua. Verifies
    -- via the SOURCE_PATHS ordering this test file already uses
    -- (BagDisplay last in the list). If a future contributor accidentally
    -- swaps the order, the stub from EbonClearance_Events.lua would
    -- clobber the real body and the sell-border refresh would silently
    -- become a no-op. (File was named EbonClearance_Events.lua before Stage 9
    -- of the file split.)
    local toc = read_file("EbonClearance.toc")
    if toc then
        local ebonIdx = toc:find("\nEbonClearance_Events%.lua\n", 1)
        local bagIdx = toc:find("\nEbonClearance_BagDisplay%.lua", 1)
        check(
            ".toc loads EbonClearance_BagDisplay.lua AFTER EbonClearance_Events.lua",
            ebonIdx and bagIdx and ebonIdx < bagIdx,
            "BagDisplay's NS.RefreshSellBorders body reassignment must run AFTER EbonClearance_Events.lua's stub assignment; reversing the .toc order would clobber the real body"
        )
    end

    -- No bare-identifier call sites for EC_RefreshSellBorders. Definition
    -- in BagDisplay was rewritten to NS.RefreshSellBorders; every caller
    -- must use the NS-qualified form.
    local function hasBareCall(s, name)
        for line in s:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    local bareCall = hasBareCall(src, "EC_RefreshSellBorders")
    check(
        "no bare EC_RefreshSellBorders() call sites (must be NS.RefreshSellBorders)",
        bareCall == nil,
        "found bare call: " .. tostring(bareCall)
    )
end

-- ---------------------------------------------------------------------------
-- Test 34: baselineProtectedIDs profession-tool safety net.
-- ---------------------------------------------------------------------------
-- User Monrad reported that the basic Fishing Pole (6256), Mining Pick
-- (2901), and Arclight Spanner (6219) were being auto-sold by a White-
-- rule sweep. We added a hardcoded itemID safety net mirroring the
-- v2.13.x quest-item narrowing: explicit Sell List entries still
-- override, only auto-rule sweeps are gated. ADB.allowedItems[itemID]
-- also bypasses (Allow Sell per-item override).
do
    -- Core's table literal declares baselineProtectedIDs.
    check(
        "EC_compCache.baselineProtectedIDs declared",
        src:find("baselineProtectedIDs%s*=%s*{") ~= nil,
        "Core's EC_compCache table literal must initialise baselineProtectedIDs as a map"
    )

    -- The three Monrad-reported itemIDs are in the set.
    for _, id in ipairs({ 6256, 2901, 6219 }) do
        check(
            "baselineProtectedIDs contains itemID " .. id .. " (Monrad's report)",
            src:find("%[" .. id .. "%]%s*=%s*true") ~= nil,
            "the three items Monrad reported must remain in the safety-net list"
        )
    end

    -- EC_IsSellable consults baselineProtectedIDs after the qualityPass
    -- calculation, using the same narrowing pattern as isQuestItem.
    check(
        "EC_IsSellable consults baselineProtectedIDs",
        src:find("baselineProtectedIDs%[itemID%]") ~= nil,
        "EC_IsSellable must gate qualityPass on the baselineProtectedIDs map (mirrors the v2.13.x quest-item safety net)"
    )

    -- Allow Sell override bypasses the safety net (ADB.allowedItems check
    -- must appear next to the baselineProtectedIDs check).
    check(
        "Allow Sell override bypasses baseline protection",
        src:find("baselineProtectedIDs%[itemID%].-allowedItems") ~= nil
            or src:find("allowedItems.-baselineProtectedIDs%[itemID%]") ~= nil,
        "ADB.allowedItems[itemID] must short-circuit the baseline safety net so per-item Allow Sell still works"
    )

    -- Tooltip annotation emits "Keep (profession tool)" for matched items.
    check(
        "tooltip annotation emits 'Keep (profession tool)'",
        src:find("Keep %(profession tool%)") ~= nil,
        "EC_AnnotateTooltip must emit a Profession-tool annotation so users see why the item isn't selling"
    )

    -- Sellinfo trace step exists.
    check(
        "/ec sellinfo trace includes the professionToolSafetyNet step",
        src:find('"professionToolSafetyNet"') ~= nil,
        "describeSellability must surface the safety-net gate so /ec sellinfo and Alt+Shift+Right-Click trace it"
    )
end

-- ---------------------------------------------------------------------------
-- Test 35 (Stage 7): Process Bags engine extracted; eligibility predicates
-- stay on EC_compCache.
-- ---------------------------------------------------------------------------
-- Stage 7 moves the Process Bags ENGINE (spell IDs + eligibility
-- predicates + buildProcessSummary) to EbonClearance_Process.lua. The
-- Process Bags PANEL (UI helpers + rearmProcessButton +
-- refreshProcessPanel + updateProcessSelection + skipProcessTarget)
-- stays in EbonClearance_Events.lua for Stage 8.
do
    local helpers = {
        "canDisenchant",
        "canMill",
        "canProspect",
        "canPickLock",
        "processTooltipHasLine",
        "processIsSoulbound",
        "buildProcessSummary",
    }
    for _, name in ipairs(helpers) do
        local pinned = src:find("EC_compCache." .. name, 1, true) ~= nil
        local leakedFn = src:find("local function " .. name .. "%(") ~= nil
        check(
            name .. " is namespaced under EC_compCache",
            pinned and not leakedFn,
            name .. " must stay on EC_compCache so call sites elsewhere resolve through the shared upvalue"
        )
    end

    -- Spell ID constants stay on EC_compCache.
    local spellConstants = {
        { "SPELL_DISENCHANT", "13262" },
        { "SPELL_MILLING", "51005" },
        { "SPELL_PROSPECTING", "31252" },
        { "SPELL_PICK_LOCK", "1804" },
    }
    for _, pair in ipairs(spellConstants) do
        local name, value = pair[1], pair[2]
        check(
            "EC_compCache." .. name .. " = " .. value,
            src:find("EC_compCache%." .. name .. "%s*=%s*" .. value) ~= nil,
            "the spell ID constant must remain on EC_compCache so the Process panel + UNIT_SPELLCAST_SUCCEEDED handler can read it"
        )
    end

    -- NS exposures Process depends on:
    check(
        "NS.Delay exposed by EbonClearance_Events.lua",
        src:find("NS%.Delay%s*=%s*EC_Delay") ~= nil,
        "Process schedules deferred callbacks via NS.Delay; EbonClearance_Events.lua must publish the EC_Delay helper on NS"
    )
    check(
        "NS.IsAddonEnabledForChar exposed by EbonClearance_Events.lua",
        src:find("NS%.IsAddonEnabledForChar%s*=%s*EC_IsAddonEnabledForChar") ~= nil,
        "Process gates on per-character enable via NS.IsAddonEnabledForChar; EbonClearance_Events.lua must publish the helper"
    )
end

-- ---------------------------------------------------------------------------
-- Test 36 (Stage 8): bug-report extraction + cycle-state promotions.
-- ---------------------------------------------------------------------------
-- Stage 8 moves the bug-report builder (EC_CopperToPlainText,
-- EC_BuildBugReport, EC_ShowBugReport) to EbonClearance_BugReport.lua,
-- exposed as NS.ShowBugReport. The .toc must load it AFTER
-- EbonClearance_Events.lua because the slash command in EbonClearance_Events.lua
-- calls NS.ShowBugReport(), and that name must be populated by the
-- time the command runs (file-load order guarantees that).
--
-- Stage 8 also promoted three mutable file-scope cycle-state locals
-- to EC_compCache fields (matching the Stage 3 lastScavSpokeAt +
-- Stage 5 vendorRunning / pendingDelete promotions):
--   * EC_lootCycleState  -> EC_compCache.lootCycleState
--   * EC_lastScavengerOut -> EC_compCache.lastScavengerOut
--   * EC_addonDismissed   -> EC_compCache.addonDismissed
-- Plus four cross-file helpers exposed on NS so the bug-report builder
-- can read live values from EbonClearance_Events.lua:
--   * NS.GetVersion / NS.GetFreeBagSlots / NS.CopperToColoredText / NS.EnsureDB
do
    check(
        "NS.ShowBugReport exposed",
        src:find("NS%.ShowBugReport%s*=%s*EC_ShowBugReport") ~= nil,
        "EbonClearance_BugReport.lua must publish NS.ShowBugReport"
    )

    -- No bare EC_ShowBugReport() call sites. Definition in BugReport is
    -- masked from the scan.
    local function hasBareCall(s, name)
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    local bareCall = hasBareCall(src, "EC_ShowBugReport")
    check(
        "no bare EC_ShowBugReport() call sites (must be NS.ShowBugReport)",
        bareCall == nil,
        "found bare call: " .. tostring(bareCall)
    )

    -- Three Stage-8-prep state promotions. Core's table literal must
    -- initialise each one; EbonClearance_Events.lua must not retain its
    -- file-scope `local EC_xxx = ...` declarations (would silently
    -- shadow the cache field).
    for _, sym in ipairs({ "lootCycleState", "lastScavengerOut", "addonDismissed" }) do
        check(
            "EC_compCache." .. sym .. " initialised in Core",
            src:find(sym .. "%s*=%s*[%w%.%-_\"]") ~= nil,
            "Core's EC_compCache table literal must initialise " .. sym
        )
    end
    local function noBareLocalDecl(name)
        for line in src:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:match("^local%s+EC_" .. name .. "%s*=") then
                    return line
                end
            end
        end
        return nil
    end
    local lurkLoot = noBareLocalDecl("lootCycleState")
    local lurkScav = noBareLocalDecl("lastScavengerOut")
    local lurkDis = noBareLocalDecl("addonDismissed")
    check(
        "no file-scope `local EC_lootCycleState`",
        lurkLoot == nil,
        "found: " .. tostring(lurkLoot)
    )
    check(
        "no file-scope `local EC_lastScavengerOut`",
        lurkScav == nil,
        "found: " .. tostring(lurkScav)
    )
    check(
        "no file-scope `local EC_addonDismissed`",
        lurkDis == nil,
        "found: " .. tostring(lurkDis)
    )

    -- NS exposures the bug-report builder relies on.
    for _, exposure in ipairs({
        { "NS.GetVersion", "NS%.GetVersion%s*=%s*EC_GetVersion" },
        { "NS.GetFreeBagSlots", "NS%.GetFreeBagSlots%s*=%s*EC_GetFreeBagSlots" },
        { "NS.CopperToColoredText", "NS%.CopperToColoredText%s*=%s*CopperToColoredText" },
        { "NS.EnsureDB", "NS%.EnsureDB%s*=%s*EnsureDB" },
    }) do
        local name, pattern = exposure[1], exposure[2]
        check(
            name .. " exposed by EbonClearance_Events.lua",
            src:find(pattern) ~= nil,
            name .. " must be published so BugReport can read the live value"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 37 (Stage 8b): minimap + LDB + combat-vendor button extracted.
-- ---------------------------------------------------------------------------
-- Stage 8b moves the minimap button, LDB launcher, and the SecureActionButton
-- combat-vendor button to EbonClearance_Minimap.lua. Four entry points get
-- published on NS for the ADDON_LOADED branch in EbonClearance_Events.lua to call:
do
    for _, name in ipairs({
        "UpdateMinimapPos",
        "CreateMinimapButton",
        "CreateTargetMerchantButton",
        "CreateLDBLauncher",
    }) do
        check(
            "NS." .. name .. " exposed by Minimap",
            src:find("NS%." .. name .. "%s*=%s*EC_" .. name) ~= nil,
            "EbonClearance_Minimap.lua must publish NS." .. name
        )
    end

    -- No bare EC_Create*Button() / EC_CreateLDBLauncher() call sites in
    -- the shipped source. Definition lines in Minimap are masked.
    local function hasBareCall(s, name)
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    for _, name in ipairs({
        "EC_CreateMinimapButton",
        "EC_CreateTargetMerchantButton",
        "EC_CreateLDBLauncher",
    }) do
        local bare = hasBareCall(src, name)
        check(
            "no bare " .. name .. "() call sites (must be NS." .. name:gsub("^EC_", "") .. ")",
            bare == nil,
            "found bare call: " .. tostring(bare)
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 38 (Stage 8c): tooltip annotation extracted.
-- ---------------------------------------------------------------------------
-- Stage 8c moves the per-bag-item tooltip annotation system
-- (EC_AnnotateTooltip + EC_ClearTooltipFlag + EC_InstallTooltipHookOnce)
-- to EbonClearance_Tooltip.lua. The install entry point is exposed
-- on NS for the ADDON_LOADED branch in EbonClearance_Events.lua to call.
do
    check(
        "NS.InstallTooltipHookOnce exposed by Tooltip",
        src:find("NS%.InstallTooltipHookOnce%s*=%s*EC_InstallTooltipHookOnce") ~= nil,
        "EbonClearance_Tooltip.lua must publish NS.InstallTooltipHookOnce"
    )

    -- No bare EC_InstallTooltipHookOnce() call sites anywhere.
    local function hasBareCall(s, name)
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    local bare = hasBareCall(src, "EC_InstallTooltipHookOnce")
    check(
        "no bare EC_InstallTooltipHookOnce() call sites (must be NS.InstallTooltipHookOnce)",
        bare == nil,
        "found bare call: " .. tostring(bare)
    )
end

-- ---------------------------------------------------------------------------
-- Test 39 (Stage 8d): bag context menu extracted; list-mutation helpers
-- exposed on NS.
-- ---------------------------------------------------------------------------
-- Stage 8d moves the Alt+Right-Click bag context menu to
-- EbonClearance_BagContextMenu.lua. The hook installer is exposed on NS
-- for the ADDON_LOADED branch. Three list-mutation helpers
-- (AddItemToList, RemoveItemFromList, FindAddConflict) needed NS
-- exposure to support the move - row-click handlers in the menu call
-- them.
do
    check(
        "NS.InstallBagContextHookOnce exposed by BagContextMenu",
        src:find("NS%.InstallBagContextHookOnce%s*=%s*EC_InstallBagContextHookOnce") ~= nil,
        "EbonClearance_BagContextMenu.lua must publish NS.InstallBagContextHookOnce"
    )
    check(
        "NS.AddItemToList exposed",
        src:find("NS%.AddItemToList%s*=%s*EC_AddItemToList") ~= nil,
        "EbonClearance_Events.lua must publish NS.AddItemToList for the context menu's row-click handlers"
    )
    check(
        "NS.RemoveItemFromList exposed",
        src:find("NS%.RemoveItemFromList%s*=%s*EC_RemoveItemFromList") ~= nil,
        "EbonClearance_Events.lua must publish NS.RemoveItemFromList for the context menu's row-click handlers"
    )
    check(
        "NS.FindAddConflict exposed",
        src:find("NS%.FindAddConflict%s*=%s*EC_FindAddConflict") ~= nil,
        "EbonClearance_Events.lua must publish NS.FindAddConflict for the context menu's add-time conflict guard"
    )
    check(
        "NS.GetListTable exposed",
        src:find("NS%.GetListTable%s*=%s*EC_GetListTable") ~= nil,
        "EbonClearance_Events.lua must publish NS.GetListTable for the context menu's list-membership check"
    )

    -- No bare EC_InstallBagContextHookOnce() or EC_GetListTable() call sites
    -- inside EbonClearance_BagContextMenu.lua. (Other files may still call
    -- EC_GetListTable directly as a file-scope local.)
    local function hasBareCall(s, name)
        local cleaned = s:gsub("local function " .. name .. "%(", "local function _def_" .. name .. "(")
        for line in cleaned:gmatch("[^\n]+") do
            local stripped = line:gsub("^%s+", "")
            if stripped:sub(1, 2) ~= "--" then
                local commentAt = stripped:find("%-%-", 1, true)
                local code = commentAt and stripped:sub(1, commentAt - 1) or stripped
                if code:find("[^.%w_]" .. name .. "%s*%(") then
                    return stripped
                end
                if code:sub(1, #name + 1) == name .. "(" then
                    return stripped
                end
            end
        end
        return nil
    end
    local bare = hasBareCall(src, "EC_InstallBagContextHookOnce")
    check(
        "no bare EC_InstallBagContextHookOnce() call sites (must be NS.InstallBagContextHookOnce)",
        bare == nil,
        "found bare call: " .. tostring(bare)
    )

    -- Read BagContextMenu file directly for a focused bare-EC_GetListTable check;
    -- the global src concat includes EbonClearance_Events.lua where the local is fine.
    local ctxFile = io.open("EbonClearance_BagContextMenu.lua", "rb")
    if ctxFile then
        local ctxSrc = ctxFile:read("*a") or ""
        ctxFile:close()
        local bareList = hasBareCall(ctxSrc, "EC_GetListTable")
        check(
            "no bare EC_GetListTable() call sites in EbonClearance_BagContextMenu.lua (must be NS.GetListTable)",
            bareList == nil,
            "found bare call: " .. tostring(bareList)
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 40 (Stage 8e-i): Process Bags panel extracted; UI primitives
-- exposed on NS.
-- ---------------------------------------------------------------------------
-- Stage 8e-i moves the v2.22.0 Process Bags Interface Options panel
-- (frame creation + the four EC_compCache helpers + OnShow body) into
-- EbonClearance_ProcessBagsPanel.lua. Two cross-file UI primitives
-- (MakeHeader, MakeLabel) needed NS exposure to support the move - the
-- OnShow build body calls them. Registration in EbonClearance_Events.lua uses
-- a _G lookup because the local ProcessBagsPanel binding no longer
-- exists in that file.
do
    check(
        "NS.MakeHeader exposed",
        src:find("NS%.MakeHeader%s*=%s*MakeHeader") ~= nil,
        "EbonClearance_Events.lua must publish NS.MakeHeader for the Process Bags panel's OnShow body"
    )
    check(
        "NS.MakeLabel exposed",
        src:find("NS%.MakeLabel%s*=%s*MakeLabel") ~= nil,
        "EbonClearance_Events.lua must publish NS.MakeLabel for the Process Bags panel's OnShow body"
    )

    -- Read the new file to confirm the four EC_compCache helpers live
    -- there (not in EbonClearance_Events.lua) AND that the file references
    -- NS.MakeHeader / NS.MakeLabel rather than the bare locals which
    -- only exist in EbonClearance_Events.lua's scope.
    local pbFile = io.open("EbonClearance_ProcessBagsPanel.lua", "rb")
    if pbFile then
        local pbSrc = pbFile:read("*a") or ""
        pbFile:close()
        check(
            "rearmProcessButton defined in EbonClearance_ProcessBagsPanel.lua",
            pbSrc:find("function EC_compCache%.rearmProcessButton%(%)") ~= nil,
            "rearmProcessButton must live in EbonClearance_ProcessBagsPanel.lua (Stage 8e-i)"
        )
        check(
            "refreshProcessPanel defined in EbonClearance_ProcessBagsPanel.lua",
            pbSrc:find("function EC_compCache%.refreshProcessPanel%(%)") ~= nil,
            "refreshProcessPanel must live in EbonClearance_ProcessBagsPanel.lua (Stage 8e-i)"
        )
        check(
            "updateProcessSelection defined in EbonClearance_ProcessBagsPanel.lua",
            pbSrc:find("function EC_compCache%.updateProcessSelection%(%)") ~= nil,
            "updateProcessSelection must live in EbonClearance_ProcessBagsPanel.lua (Stage 8e-i)"
        )
        check(
            "skipProcessTarget defined in EbonClearance_ProcessBagsPanel.lua",
            pbSrc:find("function EC_compCache%.skipProcessTarget%(%)") ~= nil,
            "skipProcessTarget must live in EbonClearance_ProcessBagsPanel.lua (Stage 8e-i)"
        )
        check(
            "EbonClearance_ProcessBagsPanel.lua uses NS.MakeHeader (not bare MakeHeader)",
            pbSrc:find("NS%.MakeHeader%(") ~= nil
                and pbSrc:find("[^.%w_]MakeHeader%(") == nil,
            "panel build body must call NS.MakeHeader (the local lives in EbonClearance_Events.lua)"
        )
        check(
            "EbonClearance_ProcessBagsPanel.lua uses NS.MakeLabel (not bare MakeLabel)",
            pbSrc:find("NS%.MakeLabel%(") ~= nil
                and pbSrc:find("[^.%w_]MakeLabel%(") == nil,
            "panel build body must call NS.MakeLabel (the local lives in EbonClearance_Events.lua)"
        )
    end

    -- The four EC_compCache helpers must NOT be defined in
    -- EbonClearance_Events.lua anymore (would-be regression: a stale copy
    -- still sitting in the main file would clobber the new one).
    -- Match against a clean global-src concat: count occurrences in
    -- EbonClearance_Events.lua specifically.
    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "rearmProcessButton no longer defined in EbonClearance_Events.lua",
            ecSrc:find("function EC_compCache%.rearmProcessButton%(%)") == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the Stage 8e-i extracted body"
        )
        check(
            "refreshProcessPanel no longer defined in EbonClearance_Events.lua",
            ecSrc:find("function EC_compCache%.refreshProcessPanel%(%)") == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the Stage 8e-i extracted body"
        )
    end

    -- Registration call must use the _G lookup since the local was
    -- moved out of EbonClearance_Events.lua.
    check(
        "Process Bags panel registered via _G lookup in EbonClearance_Events.lua",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsProcessBags"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 41 (Stage 8e-ii): Merchant Settings panel extracted; widget
-- primitives exposed on NS.
-- ---------------------------------------------------------------------------
-- Stage 8e-ii moves the Merchant Settings Interface Options panel
-- (frame creation + the OnShow body that builds the vendor mode
-- dropdown, repair toggles, sliders, fast-mode checkbox, and per-
-- rarity rule rows) into EbonClearance_MerchantPanel.lua. Five
-- additional UI widget primitives needed NS exposure (the panel calls
-- each of them in its OnShow body): AddCheckbox, AddSlider,
-- ColorTextByQuality, StyleInputBox, FitScrollContent. Registration
-- in EbonClearance_Events.lua uses a _G lookup since the local MerchantPanel
-- binding no longer exists there.
do
    check(
        "NS.AddCheckbox exposed",
        src:find("NS%.AddCheckbox%s*=%s*AddCheckbox") ~= nil,
        "EbonClearance_Events.lua must publish NS.AddCheckbox for the Merchant Settings panel's OnShow body"
    )
    check(
        "NS.AddSlider exposed",
        src:find("NS%.AddSlider%s*=%s*AddSlider") ~= nil,
        "EbonClearance_Events.lua must publish NS.AddSlider for the Merchant Settings panel's OnShow body"
    )
    check(
        "NS.FitScrollContent exposed",
        src:find("NS%.FitScrollContent%s*=%s*EC_FitScrollContent") ~= nil,
        "EbonClearance_Events.lua must publish NS.FitScrollContent for the Merchant Settings panel's bottom-anchor call"
    )
    check(
        "NS.ColorTextByQuality exposed",
        src:find("NS%.ColorTextByQuality%s*=%s*ColorTextByQuality") ~= nil,
        "EbonClearance_Events.lua must publish NS.ColorTextByQuality for the Merchant Settings panel's rarity dropdown"
    )
    check(
        "NS.StyleInputBox exposed",
        src:find("NS%.StyleInputBox%s*=%s*StyleInputBox") ~= nil,
        "EbonClearance_Events.lua must publish NS.StyleInputBox for the Merchant Settings panel's iLvl input"
    )

    -- Read the new file to confirm the MerchantPanel frame + OnShow
    -- live there (not in EbonClearance_Events.lua) AND that the file uses
    -- the NS.* widget primitives (the bare locals only exist in
    -- EbonClearance_Events.lua's scope).
    local mpFile = io.open("EbonClearance_MerchantPanel.lua", "rb")
    if mpFile then
        local mpSrc = mpFile:read("*a") or ""
        mpFile:close()
        check(
            "MerchantPanel frame created in EbonClearance_MerchantPanel.lua",
            mpSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsMerchant"') ~= nil,
            "MerchantPanel frame creation must live in EbonClearance_MerchantPanel.lua (Stage 8e-ii)"
        )
        -- Avoid matching comment-line uses by stripping comment lines
        -- before the bare-call check. The comment line in the file
        -- header naturally references "MerchantPanel" by name.
        local codeOnly = (mpSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "EbonClearance_MerchantPanel.lua uses NS.AddCheckbox (not bare AddCheckbox)",
            codeOnly:find("NS%.AddCheckbox%(") ~= nil
                and codeOnly:find("[^.%w_]AddCheckbox%(") == nil,
            "OnShow body must call NS.AddCheckbox (the local lives in EbonClearance_Events.lua)"
        )
        check(
            "EbonClearance_MerchantPanel.lua uses NS.AddSlider (not bare AddSlider)",
            codeOnly:find("NS%.AddSlider%(") ~= nil
                and codeOnly:find("[^.%w_]AddSlider%(") == nil,
            "OnShow body must call NS.AddSlider (the local lives in EbonClearance_Events.lua)"
        )
        check(
            "EbonClearance_MerchantPanel.lua uses NS.FitScrollContent (not bare EC_FitScrollContent)",
            codeOnly:find("NS%.FitScrollContent%(") ~= nil
                and codeOnly:find("[^.%w_]EC_FitScrollContent%(") == nil,
            "OnShow body must call NS.FitScrollContent (the local lives in EbonClearance_Events.lua)"
        )
    end

    -- The MerchantPanel frame creation must NOT be duplicated in
    -- EbonClearance_Events.lua anymore (would clobber the new one if it were).
    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "MerchantPanel frame no longer created in EbonClearance_Events.lua",
            ecSrc:find('local MerchantPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the Stage 8e-ii extracted frame"
        )
    end

    -- Registration must use the _G lookup.
    check(
        "Merchant Settings panel registered via _G lookup in EbonClearance_Events.lua",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsMerchant"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )

    -- Eager NS.* calls at file load time are a load-order trap: this file
    -- loads BEFORE EbonClearance_Events.lua, so NS.ColorTextByQuality (and the
    -- other widget primitives) don't exist at file-load time. Calling them
    -- in a table constructor at file scope nil-errors out and the whole
    -- file aborts before the frame is created, which then breaks the
    -- _G[] registration lookup downstream. Function bodies that reference
    -- NS.* are fine (lazy lookup at call time); top-level table
    -- constructors are NOT.
    local mpFile2 = io.open("EbonClearance_MerchantPanel.lua", "rb")
    if mpFile2 then
        local mpSrc = mpFile2:read("*a") or ""
        mpFile2:close()
        -- Build callback start marker; everything BEFORE it is file-scope
        -- (load time). Everything inside the callback runs lazily.
        local buildStart = mpSrc:find("end,%s*function%(self,%s*content%)")
        if buildStart then
            local fileScope = mpSrc:sub(1, buildStart - 1)
            check(
                "EbonClearance_MerchantPanel.lua does not call NS.ColorTextByQuality at file scope (load-order trap)",
                fileScope:find("NS%.ColorTextByQuality%(") == nil,
                "NS.ColorTextByQuality must not be called at file scope; "
                    .. "this file loads BEFORE EbonClearance_Events.lua so the binding is nil at load time. "
                    .. "Move any such calls inside the OnShow build callback (lazy execution)."
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 42 (Issue B fix): every settings OnClick that writes a verdict-
-- impacting DB field must call NS.RefreshSellBorders so the slot tints
-- track the user's setting change immediately.
-- ---------------------------------------------------------------------------
-- Pre-fix behaviour: toggling the "Allow exact-rank duplicates" checkbox
-- (or any of the other affix / proc / per-rarity setting toggles) wrote
-- the SV but did not refresh the slot-border tint registry, so users had
-- to close and reopen their bags to see the new verdict reflected in
-- the host bag UI. Same root rule as Test 26 (list mutations) - any
-- write to a DB field that EC_IsSellable reads must repaint.
--
-- The check: for each pattern below, scan the full source for every
-- occurrence and verify NS.RefreshSellBorders appears in the next ~25
-- lines (~1000 chars) of source. Multiple matches for the same field
-- (e.g. protectAffixedRareItems wired twice in the same build callback)
-- all need the call - prevents future regressions where a future
-- contributor adds a fresh SetScript handler and forgets the refresh.
do
    local function eachOccurrence(pattern, fn)
        local startPos = 1
        while true do
            local s, e = src:find(pattern, startPos)
            if not s then
                return
            end
            fn(s, e)
            startPos = e + 1
        end
    end

    local function checkRefreshAfter(pattern, fieldLabel)
        local missing = 0
        local total = 0
        eachOccurrence(pattern, function(_, e)
            total = total + 1
            local window = src:sub(e + 1, e + 1000)
            if not window:find("NS%.RefreshSellBorders") then
                missing = missing + 1
            end
        end)
        check(
            "every write to " .. fieldLabel .. " is followed by NS.RefreshSellBorders",
            total > 0 and missing == 0,
            string.format(
                "expected refresh after each %s write; found %d write(s), %d missing the call within 1000 chars",
                fieldLabel,
                total,
                missing
            )
        )
    end

    checkRefreshAfter(
        "DB%.enableDeletion%s*=%s*delCB:GetChecked",
        "DB.enableDeletion (Deletion panel)"
    )
    checkRefreshAfter(
        "DB%.affixAllowExactDupes%s*=%s*cb:GetChecked",
        "DB.affixAllowExactDupes (BlacklistSettings panel)"
    )
    checkRefreshAfter(
        "DB%.protectAffixedRareItems%s*=%s*cb:GetChecked",
        "DB.protectAffixedRareItems (CharPanel + BlacklistSettings)"
    )
    checkRefreshAfter(
        "DB%.protectChanceOnHitItems%s*=%s*cb:GetChecked",
        "DB.protectChanceOnHitItems (CharPanel)"
    )
    checkRefreshAfter(
        "DB%.qualityRules%[qualityIdx%]%.enabled%s*=%s*v",
        "DB.qualityRules[qualityIdx].enabled (Merchant per-rarity)"
    )
    checkRefreshAfter(
        "DB%.qualityRules%[qualityIdx%]%.useEquippedILvl%s*=%s*self_:GetChecked",
        "DB.qualityRules[qualityIdx].useEquippedILvl (Merchant per-rarity)"
    )
    checkRefreshAfter(
        "DB%.qualityRules%[qualityIdx%]%.maxILvl%s*=%s*v",
        "DB.qualityRules[qualityIdx].maxILvl (Merchant per-rarity input commit)"
    )
    checkRefreshAfter(
        "DB%.qualityRules%[qualityIdx%]%.bindFilter%s*=%s*entry%.value",
        "DB.qualityRules[qualityIdx].bindFilter (Merchant per-rarity dropdown)"
    )

    -- EC_LoadProfile wholesale-rewrites DB.whitelist + DB.blacklist; it
    -- must follow up with NS.RefreshSellBorders so slot tints repaint.
    -- Same root rule as Test 26 / Test 42 - any write that changes
    -- EC_IsSellable's verdict must repaint.
    local function bodyHasRefresh(funcSig)
        local startIdx = src:find(funcSig)
        if not startIdx then
            return nil
        end
        local nextLocal = src:find("\nlocal function ", startIdx + 1) or #src
        local nextTbl = src:find("\nfunction [A-Za-z_]+%.", startIdx + 1) or #src
        local endIdx = math.min(nextLocal, nextTbl)
        local body = src:sub(startIdx, endIdx)
        return body:find("NS%.RefreshSellBorders") ~= nil
    end
    check(
        "EC_LoadProfile calls NS.RefreshSellBorders",
        bodyHasRefresh("local function EC_LoadProfile%(") == true,
        "profile load rewrites DB.whitelist + DB.blacklist wholesale; slot-border tints must repaint immediately"
    )
end

-- ---------------------------------------------------------------------------
-- Test 43 (section 4.5 of plan): per-category sell-border colours.
-- ---------------------------------------------------------------------------
-- v2.30.x replaced the single DB.sellBorderColor with a per-category
-- DB.sellBorderCategories table keyed by verdict reason (delete /
-- accountSell / charSell / junk / rule). Each category has its own
-- enable toggle + colour. The bagSlotWillSellCategory predicate
-- resolves which category applies to a given slot, and
-- applySellBorder paints the category's colour (or hides the border
-- if the category is disabled).
--
-- Locks in this test:
--   - EnsureDB creates DB.sellBorderCategories with all 5 expected keys
--   - bagSlotWillSellCategory is defined on EC_compCache
--   - applySellBorder reads from DB.sellBorderCategories (not the
--     legacy DB.sellBorderColor field)
--   - Five enable-checkbox global names exist (one per category)
do
    -- EnsureDB schema migration.
    check(
        "EnsureDB initialises DB.sellBorderCategories",
        src:find("DB%.sellBorderCategories%s*=%s*{}") ~= nil
            or src:find("type%(DB%.sellBorderCategories%)%s*~=%s*\"table\"") ~= nil,
        "EnsureDB must guard DB.sellBorderCategories with a type check + default empty table"
    )

    local categories = { "delete", "accountSell", "charSell", "junk", "rule" }
    for _, key in ipairs(categories) do
        check(
            "EnsureDB default for sellBorderCategories." .. key,
            src:find(key .. "%s*=%s*defaultCat") ~= nil,
            "EnsureDB must populate DB.sellBorderCategories." .. key
                .. " with an { enabled, color } default"
        )
    end

    -- Category-resolving predicate.
    check(
        "EC_compCache.bagSlotWillSellCategory defined",
        src:find("function EC_compCache%.bagSlotWillSellCategory%(") ~= nil,
        "the per-category resolver must be defined for applySellBorder to know which colour to paint"
    )

    -- applySellBorder reads the new per-category settings, not the
    -- legacy DB.sellBorderColor field (which stays in SVs for
    -- downgrade safety but is no longer consulted by the paint path).
    local bdFile = io.open("EbonClearance_BagDisplay.lua", "rb")
    if bdFile then
        local bdSrc = bdFile:read("*a") or ""
        bdFile:close()
        check(
            "applySellBorder reads DB.sellBorderCategories",
            bdSrc:find("DB%.sellBorderCategories") ~= nil,
            "the paint path must read the new per-category table, not the legacy single-colour field"
        )
        check(
            "applySellBorder does NOT read DB.sellBorderColor (legacy field)",
            bdSrc:find("DB%.sellBorderColor") == nil,
            "remove any remaining DB.sellBorderColor reads from BagDisplay; the legacy field is for SV downgrade only"
        )
    end

    -- The CharPanel iterates SELL_BORDER_CATEGORIES to build one row
    -- per verdict category. Lock that the table lists all 5 keys so a
    -- future refactor can't silently drop one of the rows.
    check(
        "CharPanel SELL_BORDER_CATEGORIES table exists",
        src:find("local SELL_BORDER_CATEGORIES%s*=") ~= nil,
        "the Character Settings panel must define a SELL_BORDER_CATEGORIES list (5 rows)"
    )
    for _, key in ipairs(categories) do
        check(
            "CharPanel SELL_BORDER_CATEGORIES includes " .. key,
            src:find('key%s*=%s*"' .. key .. '"') ~= nil,
            "the SELL_BORDER_CATEGORIES table must include { key = \"" .. key .. '" } so a row is built'
        )
    end
    -- And the row builder must use the key to name the checkbox so
    -- bug reports / external tooling can reference them by a stable
    -- name family.
    check(
        "CharPanel checkbox naming uses EbonClearanceSellBorderCB_<key>",
        src:find('"EbonClearanceSellBorderCB_"%s*%.%.%s*key') ~= nil,
        "the per-category enable checkbox should be named EbonClearanceSellBorderCB_<key> via concatenation"
    )
end

-- ---------------------------------------------------------------------------
-- Test 44 (v2.32.x, updated v2.35.1): affix tooltip label scheme.
-- ---------------------------------------------------------------------------
-- The random-affix tooltip branch distinguishes states using plain-
-- English "Keep" / "Will Sell" labels. v2.35.1 collapsed the
-- player-doesn't-own-this-rank states into a single collector-focused
-- "rank needed" label (the v2.32.x scheme split it into "new affix"
-- and "other rank known" - the distinction was noise; the user's
-- collection-side question is "do I need this exact rank?"):
--
--   Player owns this (family, rank) + setting OFF -> "Keep (affix rank known)"
--   Player owns this (family, rank) + setting ON  -> "Will Sell (you have this affix)"
--   Player doesn't own this rank                  -> "Keep (affix rank needed)"
--
-- The label scheme avoids "Protected" / "Allowed" verbs (too abstract
-- for a new player) and avoids the phrase "already known" (could be
-- confused with Blizzard's red "Already known" line on tomes).
do
    local tooltipFile = io.open("EbonClearance_Tooltip.lua", "rb")
    if tooltipFile then
        local ttSrc = tooltipFile:read("*a") or ""
        tooltipFile:close()
        -- Strip Lua line comments before checking - explanatory
        -- comments may reference historical strings and aren't a
        -- regression.
        local ttCode = ttSrc:gsub("%-%-[^\n]*", "")

        check(
            "Tooltip emits 'Keep (affix rank needed)' (rank-not-owned label)",
            ttCode:find("Keep %(affix rank needed%)") ~= nil,
            "the rank-not-owned case must use the v2.35.1 'Keep (affix rank needed)' label so the player reads the verdict + collector-side reason. Covers both 'completely new family' and 'have a different rank' - the v2.32.x scheme split those into two labels but the distinction was noise."
        )
        check(
            "Tooltip emits 'Keep (affix rank known)' (rank-owned + dupe-allow-off label)",
            ttCode:find("Keep %(affix rank known%)") ~= nil,
            "items whose (family, rank) pair the player already owns - via description-text match OR via the v2.35.1 family+rank fallback - get the 'rank known' label when dupe-allow is off"
        )
        check(
            "Tooltip emits 'Will Sell (you have this affix)' (auto-dupe label)",
            ttCode:find("Will Sell %(you have this affix%)") ~= nil,
            "the auto-dupe label must say 'Will Sell (you have this affix)' so the player sees the destination plus the reason"
        )

        -- Legacy strings must NOT appear in the live label-emit paths.
        check(
            "Tooltip no longer emits legacy 'Random affix' label",
            ttCode:find("Random affix") == nil,
            "the legacy 'Random affix' wording must be removed from EbonClearance_Tooltip.lua label-emit paths"
        )
        check(
            "Tooltip no longer emits 'already known' label",
            ttCode:find('already known') == nil,
            "the legacy 'already known' phrasing must be removed - 'Already known' is Blizzard's own tome line so re-using the phrase confused players"
        )
        check(
            "Tooltip no longer emits 'Protected - ' prefix",
            ttCode:find("Protected %-") == nil,
            "the v2.32.x label simplification replaced 'Protected - <reason>' with 'Keep (<reason>)' across all branches"
        )
        check(
            "Tooltip no longer emits 'Allowed - ' prefix",
            ttCode:find("Allowed %-") == nil,
            "the v2.32.x label simplification replaced 'Allowed - <destination>' with 'Will Sell (<destination>)' or 'Will Delete' across all branches"
        )

        -- playerKnows must be computed independently of
        -- affixAllowExactDupes - the whole point of the rewrite is to
        -- surface the known/unknown state regardless of the setting.
        check(
            "playerKnows is computed via playerHasAffixDescription independent of affixAllowExactDupes",
            ttCode:find("local playerKnows%s*=") ~= nil,
            "the affix branch must declare a `local playerKnows` that captures playerHasAffixDescription without gating on DB.affixAllowExactDupes"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 45 (Stage 8e-iii): Scavenger Settings panel extracted.
-- ---------------------------------------------------------------------------
-- Stage 8e-iii moves the Scavenger Settings Interface Options panel
-- (frame creation + OnShow body) into EbonClearance_ScavengerPanel.lua.
-- Smallest extraction yet because all five widget primitives the
-- OnShow body uses (MakeHeader, MakeLabel, AddCheckbox, AddSlider,
-- FitScrollContent) are already NS-exposed from 8e-i / 8e-ii prep -
-- zero new NS exposures needed.
do
    -- ScavengerPanel frame must be created in the new file (not in
    -- EbonClearance_Events.lua anymore).
    local spFile = io.open("EbonClearance_ScavengerPanel.lua", "rb")
    if spFile then
        local spSrc = spFile:read("*a") or ""
        spFile:close()
        check(
            "ScavengerPanel frame created in EbonClearance_ScavengerPanel.lua",
            spSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsScavenger"') ~= nil,
            "ScavengerPanel frame creation must live in EbonClearance_ScavengerPanel.lua (Stage 8e-iii)"
        )
        local code = (spSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "EbonClearance_ScavengerPanel.lua uses NS.MakeHeader (not bare MakeHeader)",
            code:find("NS%.MakeHeader%(") ~= nil
                and code:find("[^.%w_]MakeHeader%(") == nil,
            "panel build body must call NS.MakeHeader (the local lives in EbonClearance_Events.lua)"
        )
        check(
            "EbonClearance_ScavengerPanel.lua uses NS.AddCheckbox (not bare AddCheckbox)",
            code:find("NS%.AddCheckbox%(") ~= nil
                and code:find("[^.%w_]AddCheckbox%(") == nil,
            "panel build body must call NS.AddCheckbox"
        )
        check(
            "EbonClearance_ScavengerPanel.lua uses NS.AddSlider (not bare AddSlider)",
            code:find("NS%.AddSlider%(") ~= nil
                and code:find("[^.%w_]AddSlider%(") == nil,
            "panel build body must call NS.AddSlider"
        )
    end

    -- The ScavengerPanel local must NOT be re-created in EbonClearance_Events.lua.
    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "ScavengerPanel frame no longer created in EbonClearance_Events.lua",
            ecSrc:find('local ScavengerPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the Stage 8e-iii extracted frame"
        )
    end

    -- Registration uses the _G lookup.
    check(
        "Scavenger Settings panel registered via _G lookup in EbonClearance_Events.lua",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsScavenger"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 46 (Stage 8e-iv): Sell List + Account Sell List panels bundled.
-- ---------------------------------------------------------------------------
-- Stage 8e-iv moves the two sibling list-management panels
-- (WhitelistPanel + AccountWhitelistPanel) into a single bundled
-- file: EbonClearance_SellListPanels.lua. Both share the same
-- helpers (CreateListUI + EC_AddScanByQualityRow) so co-locating is
-- the right shape.
do
    check(
        "NS.CreateListUI exposed",
        src:find("NS%.CreateListUI%s*=%s*CreateListUI") ~= nil,
        "EbonClearance_Events.lua must publish NS.CreateListUI for split panels to build list UIs"
    )
    check(
        "NS.AddScanByQualityRow exposed",
        src:find("NS%.AddScanByQualityRow%s*=%s*EC_AddScanByQualityRow") ~= nil,
        "EbonClearance_Events.lua must publish NS.AddScanByQualityRow for the Sell List family panels"
    )

    local slFile = io.open("EbonClearance_SellListPanels.lua", "rb")
    if slFile then
        local slSrc = slFile:read("*a") or ""
        slFile:close()
        check(
            "WhitelistPanel frame in EbonClearance_SellListPanels.lua",
            slSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsWhitelist"') ~= nil,
            "WhitelistPanel frame must live in EbonClearance_SellListPanels.lua (Stage 8e-iv)"
        )
        check(
            "AccountWhitelistPanel frame in EbonClearance_SellListPanels.lua",
            slSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsAccountWhitelist"') ~= nil,
            "AccountWhitelistPanel frame must live in EbonClearance_SellListPanels.lua"
        )
        local code = (slSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "EbonClearance_SellListPanels.lua uses NS.CreateListUI (not bare CreateListUI)",
            code:find("NS%.CreateListUI%(") ~= nil
                and code:find("[^.%w_]CreateListUI%(") == nil,
            "panel builds must call NS.CreateListUI (the local lives in EbonClearance_Events.lua)"
        )
        check(
            "EbonClearance_SellListPanels.lua uses NS.AddScanByQualityRow",
            code:find("NS%.AddScanByQualityRow%(") ~= nil
                and code:find("[^.%w_]EC_AddScanByQualityRow%(") == nil,
            "panel builds must call NS.AddScanByQualityRow"
        )
    end

    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "WhitelistPanel no longer created in EbonClearance_Events.lua",
            ecSrc:find('local WhitelistPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the extracted frame"
        )
        check(
            "AccountWhitelistPanel no longer created in EbonClearance_Events.lua",
            ecSrc:find('local AccountWhitelistPanel%s*=') == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the extracted frame"
        )
    end

    check(
        "Sell List panel registered via _G lookup",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsWhitelist"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
    check(
        "Account Sell List panel registered via _G lookup",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsAccountWhitelist"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 47 (Stage 8e-v): Keep List + Delete List panels bundled.
-- ---------------------------------------------------------------------------
-- Stage 8e-v moves two sibling list-management panels (BlacklistPanel
-- and DeletePanel) into one bundled file. The Protection Settings
-- panel (BlacklistSettingsPanel) stays in EbonClearance_Events.lua for a
-- later stage - it's a different domain (auto-protect toggles, not
-- list management). Zero new NS exposures needed - both panels use
-- NS.MakeHeader / NS.MakeLabel / NS.CreateListUI already exposed in
-- earlier stages.
do
    local kdFile = io.open("EbonClearance_KeepDeletePanels.lua", "rb")
    if kdFile then
        local kdSrc = kdFile:read("*a") or ""
        kdFile:close()
        check(
            "BlacklistPanel frame in EbonClearance_KeepDeletePanels.lua",
            kdSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsBlacklist"') ~= nil,
            "BlacklistPanel (Keep List) frame must live in EbonClearance_KeepDeletePanels.lua (Stage 8e-v)"
        )
        check(
            "DeletePanel frame in EbonClearance_KeepDeletePanels.lua",
            kdSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsDeletion"') ~= nil,
            "DeletePanel (Delete List) frame must live in EbonClearance_KeepDeletePanels.lua"
        )
        local code = (kdSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "EbonClearance_KeepDeletePanels.lua uses NS.CreateListUI (not bare CreateListUI)",
            code:find("NS%.CreateListUI%(") ~= nil
                and code:find("[^.%w_]CreateListUI%(") == nil,
            "panel builds must call NS.CreateListUI (the local lives in EbonClearance_Events.lua)"
        )
    end

    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "BlacklistPanel no longer created in EbonClearance_Events.lua",
            ecSrc:find('local BlacklistPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the extracted frame"
        )
        check(
            "DeletePanel no longer created in EbonClearance_Events.lua",
            ecSrc:find('local DeletePanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the extracted frame"
        )
        -- Note: a Stage 8e-v sentinel check for BlacklistSettingsPanel
        -- staying in EbonClearance_Events.lua was removed when 8e-vi
        -- intentionally moved it. Test 48 below now locks
        -- BlacklistSettingsPanel's location in ProtectionPanel.lua.
    end

    check(
        "Keep List panel registered via _G lookup",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsBlacklist"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
    check(
        "Delete List panel registered via _G lookup",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsDeletion"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 48 (Stage 8e-vi): Protection Settings panel extracted.
-- ---------------------------------------------------------------------------
-- Stage 8e-vi moves the Protection Settings panel
-- (BlacklistSettingsPanel - internal frame name preserved from
-- v2.15.0 schema) into EbonClearance_ProtectionPanel.lua. Hosts the
-- auto-protect toggles + the v2.20.0 affix / chance-on-hit protection
-- toggles + affixAllowExactDupes. Three of the OnClick handlers
-- contain NS.RefreshSellBorders calls (Issue B fix) that carry over.
do
    local ppFile = io.open("EbonClearance_ProtectionPanel.lua", "rb")
    if ppFile then
        local ppSrc = ppFile:read("*a") or ""
        ppFile:close()
        check(
            "BlacklistSettingsPanel frame in EbonClearance_ProtectionPanel.lua",
            ppSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsBlacklistSettings"') ~= nil,
            "Protection Settings frame must live in EbonClearance_ProtectionPanel.lua (Stage 8e-vi)"
        )
        local code = (ppSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "EbonClearance_ProtectionPanel.lua uses NS.MakeHeader (not bare MakeHeader)",
            code:find("NS%.MakeHeader%(") ~= nil
                and code:find("[^.%w_]MakeHeader%(") == nil,
            "panel build must call NS.MakeHeader (the local lives in EbonClearance_Events.lua)"
        )
        check(
            "EbonClearance_ProtectionPanel.lua uses NS.FitScrollContent",
            code:find("NS%.FitScrollContent%(") ~= nil
                and code:find("[^.%w_]EC_FitScrollContent%(") == nil,
            "panel build must call NS.FitScrollContent"
        )
        -- Issue B fix invariant: the three affix/proc/dupe OnClick
        -- handlers carried over must still call NS.RefreshSellBorders.
        check(
            "Protection Settings OnClick handlers still call NS.RefreshSellBorders",
            select(2, ppSrc:gsub("NS%.RefreshSellBorders%(%)", "")) >= 3,
            "the three verdict-impacting toggles (affix protection, chance-on-hit, affixAllowExactDupes) each need their post-Issue-B refresh call to survive extraction"
        )
    end

    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "BlacklistSettingsPanel no longer created in EbonClearance_Events.lua",
            ecSrc:find('local BlacklistSettingsPanel') == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the Stage 8e-vi extracted frame"
        )
    end

    check(
        "Protection Settings panel registered via _G lookup",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsBlacklistSettings"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 49 (Stage 8e-vii): Item Highlighting panel extracted + dead code
-- cleanup.
-- ---------------------------------------------------------------------------
-- Stage 8e-vii moves CharPanel (Item Highlighting, internal frame name
-- "EbonClearanceOptionsCharacter" preserved) into
-- EbonClearance_ItemHighlightingPanel.lua. The dead CreateNameListUI
-- function (orphaned in §4.5 when the per-character allowlist UI was
-- decommissioned) is dropped in the same stage. Test 2 in
-- test_layout_reactivity.lua was updated to remove the now-obsolete
-- CreateNameListUI box:OnSizeChanged check.
do
    local ihFile = io.open("EbonClearance_ItemHighlightingPanel.lua", "rb")
    if ihFile then
        local ihSrc = ihFile:read("*a") or ""
        ihFile:close()
        check(
            "CharPanel frame in EbonClearance_ItemHighlightingPanel.lua",
            ihSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsCharacter"') ~= nil,
            "CharPanel (Item Highlighting) frame must live in EbonClearance_ItemHighlightingPanel.lua (Stage 8e-vii)"
        )
        check(
            "Item Highlighting panel name preserved",
            ihSrc:find('CharPanel%.name%s*=%s*"Item Highlighting"') ~= nil,
            "the v2.30.x panel name 'Item Highlighting' must survive the extraction"
        )
        local code = (ihSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "EbonClearance_ItemHighlightingPanel.lua uses NS.MakeHeader (not bare MakeHeader)",
            code:find("NS%.MakeHeader%(") ~= nil
                and code:find("[^.%w_]MakeHeader%(") == nil,
            "panel build must call NS.MakeHeader (the local lives in EbonClearance_Events.lua)"
        )
    end

    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "CharPanel no longer created in EbonClearance_Events.lua",
            ecSrc:find('local CharPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the Stage 8e-vii extracted frame"
        )
        check(
            "CreateNameListUI (dead code) dropped from EbonClearance_Events.lua",
            ecSrc:find('local function CreateNameListUI') == nil,
            "CreateNameListUI was orphaned in §4.5 (per-character allowlist UI decommission) and should be dropped in Stage 8e-vii"
        )
    end

    check(
        "Item Highlighting panel registered via _G lookup",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsCharacter"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 50 (Stage 8e-viii): Profiles + Import/Export panels bundled.
-- ---------------------------------------------------------------------------
-- Stage 8e-viii bundles two related panels into one new file:
-- ProfilesPanel (named-profile management) + ImportExportPanel
-- (profile pack + settings pack import/export). The Import/Export
-- region's file-scope helpers (EC_GetWhitelistForScope,
-- EC_ExportWhitelist, EC_ImportWhitelist, EC_EXPORT_PREFIX) and
-- EC_compCache.exportFullPack / importFullPack all move along with
-- the panels. Profile-mutation helpers + EC_HookScrollbarAutoHide
-- stay in EbonClearance_Events.lua as NS-exposed entry points.
do
    -- 5 new NS exposures for this stage.
    check(
        "NS.SaveProfile exposed",
        src:find("NS%.SaveProfile%s*=%s*EC_SaveProfile") ~= nil,
        "EbonClearance_Events.lua must publish NS.SaveProfile for the Profiles panel button OnClicks"
    )
    check(
        "NS.LoadProfile exposed",
        src:find("NS%.LoadProfile%s*=%s*EC_LoadProfile") ~= nil,
        "EbonClearance_Events.lua must publish NS.LoadProfile"
    )
    check(
        "NS.DeleteProfile exposed",
        src:find("NS%.DeleteProfile%s*=%s*EC_DeleteProfile") ~= nil,
        "EbonClearance_Events.lua must publish NS.DeleteProfile"
    )
    check(
        "NS.RenameProfile exposed",
        src:find("NS%.RenameProfile%s*=%s*EC_RenameProfile") ~= nil,
        "EbonClearance_Events.lua must publish NS.RenameProfile"
    )
    check(
        "NS.HookScrollbarAutoHide exposed",
        src:find("NS%.HookScrollbarAutoHide%s*=%s*EC_HookScrollbarAutoHide") ~= nil,
        "EbonClearance_Events.lua must publish NS.HookScrollbarAutoHide for the Profiles + ImportExport panels"
    )
    -- EC_PANEL_WIDTH is a file-scope local in EbonClearance_Events.lua that
    -- mutates dynamically in EC_UpdatePanelWidth; split panel files
    -- that need it for build-time SetSize calls must use the
    -- NS.GetPanelWidth() getter (returns the live value via upvalue
    -- closure) instead of dereferencing EC_PANEL_WIDTH as a global.
    check(
        "NS.GetPanelWidth exposed",
        src:find("NS%.GetPanelWidth%s*=%s*function") ~= nil,
        "EbonClearance_Events.lua must publish NS.GetPanelWidth for split panel files"
    )

    local ppFile = io.open("EbonClearance_ProfilesPanel.lua", "rb")
    if ppFile then
        local ppSrc = ppFile:read("*a") or ""
        ppFile:close()
        check(
            "ProfilesPanel frame in EbonClearance_ProfilesPanel.lua",
            ppSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsProfiles"') ~= nil,
            "ProfilesPanel frame must live in EbonClearance_ProfilesPanel.lua (Stage 8e-viii)"
        )
        check(
            "ImportExportPanel frame in EbonClearance_ProfilesPanel.lua",
            ppSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsImportExport"') ~= nil,
            "ImportExportPanel frame must also live in EbonClearance_ProfilesPanel.lua (bundled)"
        )
        local code = (ppSrc:gsub("\n%-%-[^\n]*", ""))
        check(
            "EbonClearance_ProfilesPanel.lua uses NS.SaveProfile (not bare EC_SaveProfile)",
            code:find("NS%.SaveProfile%(") ~= nil
                and code:find("[^.%w_]EC_SaveProfile%(") == nil,
            "panel must call NS.SaveProfile (the local lives in EbonClearance_Events.lua)"
        )
        check(
            "EbonClearance_ProfilesPanel.lua uses NS.HookScrollbarAutoHide",
            code:find("NS%.HookScrollbarAutoHide%(") ~= nil
                and code:find("[^.%w_]EC_HookScrollbarAutoHide%(") == nil,
            "panel must call NS.HookScrollbarAutoHide"
        )
        -- The build-time SetSize calls in this file must use the
        -- NS.GetPanelWidth() getter, not the bare EC_PANEL_WIDTH
        -- identifier (which would be nil here - EC_PANEL_WIDTH is a
        -- file-scope local in EbonClearance_Events.lua).
        check(
            "EbonClearance_ProfilesPanel.lua uses NS.GetPanelWidth() (not bare EC_PANEL_WIDTH)",
            code:find("NS%.GetPanelWidth%(%)") ~= nil
                and code:find("[^.%w_]EC_PANEL_WIDTH[^_%w]") == nil,
            "build-time SetSize calls must call NS.GetPanelWidth() so they read the live width value"
        )
        -- Every file-scope function in this split file that references
        -- DB.x or ADB.x must capture them at entry via
        -- `local DB = NS.DB` / `local ADB = NS.ADB`. Pre-fix the
        -- exportFullPack / importFullPack / EC_GetWhitelistForScope
        -- helpers all silently returned empty data because DB / ADB
        -- resolved to nil globals. Lock this so future helpers don't
        -- regress: count the file-scope function definitions vs. the
        -- DB-capture sites. (OnShow inner closures pick up DB via
        -- upvalue from the OnShow's capture, so they aren't counted
        -- against this invariant.)
        local fnCount = 0
        for _ in code:gmatch("function EC_compCache%.[a-zA-Z]+%(") do
            fnCount = fnCount + 1
        end
        for _ in code:gmatch("\nlocal function [A-Za-z_]+%(") do
            fnCount = fnCount + 1
        end
        local dbCaptureCount = 0
        for _ in code:gmatch("local DB%s*=%s*NS%.DB") do
            dbCaptureCount = dbCaptureCount + 1
        end
        -- The file has 2 panel OnShow handlers + 4 file-scope helpers
        -- that directly read DB / ADB (EC_GetWhitelistForScope,
        -- exportFullPack, importFullPack, EC_ImportWhitelist). The 5th
        -- file-scope helper EC_ExportWhitelist doesn't touch DB / ADB
        -- directly - it delegates to EC_GetWhitelistForScope - so it
        -- doesn't need its own capture. Expected: 2 + 4 = 6 captures.
        check(
            "EbonClearance_ProfilesPanel.lua: every file-scope function that touches DB captures it at entry",
            dbCaptureCount >= 6,
            string.format(
                "expected at least 6 'local DB = NS.DB' captures (2 OnShow + 4 helpers); found %d. Functions that read DB/ADB as globals after the file-scope move will silently return empty data.",
                dbCaptureCount
            )
        )
    end

    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "ProfilesPanel no longer created in EbonClearance_Events.lua",
            ecSrc:find('local ProfilesPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition would clobber the extracted frame"
        )
        check(
            "ImportExportPanel no longer created in EbonClearance_Events.lua",
            ecSrc:find('local ImportExportPanel%s*=%s*CreateFrame') == nil,
            "duplicate definition would clobber the extracted frame"
        )
        -- The file-scope ImportExport helpers also move with the panels.
        check(
            "EC_GetWhitelistForScope no longer defined in EbonClearance_Events.lua",
            ecSrc:find('local function EC_GetWhitelistForScope') == nil,
            "the helper is only used inside the ImportExport region and moves with it"
        )
    end

    check(
        "Profiles panel registered via _G lookup",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsProfiles"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must use the _G lookup"
    )
    check(
        "Import/Export panel registered via _G lookup",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsImportExport"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must use the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 51 (Stage 8e-ix-a): MainOptions panel + BuildMainPanel extracted.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-a moves three non-contiguous chunks from EbonClearance_Events.lua
-- into EbonClearance_MainPanel.lua:
--   - local MainOptions = CreateFrame(...) frame creation
--   - BuildMainPanel function body
--   - MainOptions:SetScript("OnShow", ...) panel-build handler
-- The panel-infra helpers (MakeHeader, MakeLabel, EC_PANEL_WIDTH,
-- EC_UpdatePanelWidth, etc.) stay in EbonClearance_Events.lua for later
-- stages.
do
    check(
        "NS.ResetSession exposed",
        src:find("NS%.ResetSession%s*=%s*EC_ResetSession") ~= nil,
        "EbonClearance_Events.lua must publish NS.ResetSession for the Main panel's Reset Session button"
    )

    local mpFile = io.open("EbonClearance_MainPanel.lua", "rb")
    if mpFile then
        local mpSrc = mpFile:read("*a") or ""
        mpFile:close()
        check(
            "MainOptions frame in EbonClearance_MainPanel.lua",
            mpSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsMain"') ~= nil,
            "MainOptions frame creation must live in EbonClearance_MainPanel.lua (Stage 8e-ix-a)"
        )
        check(
            "BuildMainPanel function in EbonClearance_MainPanel.lua",
            mpSrc:find("local function BuildMainPanel%(") ~= nil,
            "BuildMainPanel must move along with the MainOptions OnShow that calls it"
        )
        local code = (mpSrc:gsub("\n%-%-[^\n]*", ""))
        -- v2.36.x: the Reset Session button moved off MainPanel onto the
        -- new StatsPanel (along with every other stats widget). The check
        -- below now targets the StatsPanel source. MainPanel must still
        -- NOT call EC_ResetSession as a bare global.
        check(
            "EbonClearance_MainPanel.lua does not call EC_ResetSession as a bare global",
            code:find("[^.%w_]EC_ResetSession%(") == nil,
            "MainPanel must not reach into Events.lua's file-scope local; use NS.ResetSession if needed"
        )
        local statsPanelFile = io.open("EbonClearance_StatsPanel.lua", "rb")
        if statsPanelFile then
            local statsPanelSrc = statsPanelFile:read("*a") or ""
            statsPanelFile:close()
            local statsCode = (statsPanelSrc:gsub("\n%-%-[^\n]*", ""))
            check(
                "EbonClearance_StatsPanel.lua uses NS.ResetSession (not bare EC_ResetSession)",
                statsCode:find("NS%.ResetSession%(") ~= nil
                    and statsCode:find("[^.%w_]EC_ResetSession%(") == nil,
                "the Reset Session button (now on the Stats panel) must call NS.ResetSession (the local lives in EbonClearance_Events.lua)"
            )
        end
        check(
            "EbonClearance_MainPanel.lua uses NS.CopperToColoredText",
            code:find("NS%.CopperToColoredText%(") ~= nil
                and code:find("[^.%w_]CopperToColoredText%(") == nil,
            "stats display must call NS.CopperToColoredText (the local lives in EbonClearance_Events.lua)"
        )
        -- Catch other common file-scope-locals-as-globals traps from the
        -- extraction: ADDON_AUTHOR / ADDON_URL / EC_session are file-
        -- scope locals in EbonClearance_Events.lua that the byline + stats
        -- panel use. The new file must call them through NS.
        check(
            "EbonClearance_MainPanel.lua uses NS.ADDON_AUTHOR / NS.ADDON_URL",
            code:find("NS%.ADDON_AUTHOR") ~= nil
                and code:find("NS%.ADDON_URL") ~= nil
                and code:find("[^.%w_]ADDON_AUTHOR[^.%w_]") == nil
                and code:find("[^.%w_]ADDON_URL[^.%w_]") == nil,
            "byline must call NS.ADDON_AUTHOR / NS.ADDON_URL; bare globals would be nil"
        )
        check(
            "EbonClearance_MainPanel.lua uses NS.session (not bare EC_session)",
            code:find("NS%.session%.") ~= nil
                and code:find("[^.%w_]EC_session[^.%w_]") == nil,
            "stats display must call NS.session (the EC_session table lives in EbonClearance_Events.lua)"
        )
    end

    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "MainOptions no longer created in EbonClearance_Events.lua",
            ecSrc:find('local MainOptions%s*=%s*CreateFrame') == nil,
            "duplicate definition would clobber the Stage 8e-ix-a extracted frame"
        )
        check(
            "BuildMainPanel no longer defined in EbonClearance_Events.lua",
            ecSrc:find('local function BuildMainPanel%(') == nil,
            "BuildMainPanel must move with the panel; leftover definition in EbonClearance_Events.lua is dead code"
        )
        -- The 5 in-EbonClearance_Events.lua MainOptions call sites must all be
        -- replaced with _G[] lookups so they still work after the local
        -- binding moves out.
        check(
            "no bare MainOptions identifier references in EbonClearance_Events.lua",
            ecSrc:find("[^_%w\"]MainOptions[^_%w\"]") == nil,
            "every InterfaceOptionsFrame_OpenToCategory(MainOptions) and similar must use _G[\"EbonClearanceOptionsMain\"] after extraction"
        )
    end

    check(
        "Main panel registered via _G lookup",
        src:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsMain"%]%)') ~= nil,
        "post-extraction, EbonClearance_Events.lua must call InterfaceOptions_AddCategory with the _G lookup"
    )
end

-- ---------------------------------------------------------------------------
-- Test 52 (Stage 8e-ix-b): panel-width registry + reactivity layer
-- extracted to EbonClearance_PanelInfra.lua.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-b moves the panel-infrastructure block (EC_PANEL_WIDTH,
-- EC_UpdatePanelWidth, the widthRegistry, registerWidth /
-- registerScrollFit / setPanelWidth / refreshLayouts /
-- EC_HookScrollbarAutoHide / EC_WrapPanelInScrollFrame /
-- EC_FitScrollContent / initPanel) into EbonClearance_PanelInfra.lua.
-- The widget primitives (MakeHeader, MakeLabel, AddCheckbox,
-- AddSlider, ColorTextByQuality, StyleInputBox) + CreateListUI + the
-- list-row factories STAY in EbonClearance_Events.lua for 8e-ix-c / 8e-ix-d.
do
    local infraFile = io.open("EbonClearance_PanelInfra.lua", "rb")
    if infraFile then
        local infraSrc = infraFile:read("*a") or ""
        infraFile:close()
        check(
            "EC_PANEL_WIDTH local lives in EbonClearance_PanelInfra.lua",
            infraSrc:find("local EC_PANEL_WIDTH%s*=%s*440") ~= nil,
            "the panel-width local must live in EbonClearance_PanelInfra.lua (Stage 8e-ix-b)"
        )
        check(
            "EC_compCache.initPanel defined in EbonClearance_PanelInfra.lua",
            infraSrc:find("function EC_compCache%.initPanel%(") ~= nil,
            "initPanel must live in EbonClearance_PanelInfra.lua"
        )
        check(
            "EC_compCache.widthRegistry defined in EbonClearance_PanelInfra.lua",
            infraSrc:find("EC_compCache%.widthRegistry%s*=") ~= nil,
            "the reactive-layout registry must live in EbonClearance_PanelInfra.lua"
        )
        check(
            "NS.GetPanelWidth closure lives in EbonClearance_PanelInfra.lua",
            infraSrc:find("NS%.GetPanelWidth%s*=%s*function") ~= nil,
            "the getter closure must be co-located with EC_PANEL_WIDTH so the upvalue resolves correctly"
        )
        check(
            "EbonClearance_PanelInfra.lua uses NS.EnsureDB (not bare EnsureDB)",
            infraSrc:find("NS%.EnsureDB%(%)") ~= nil
                and infraSrc:find("[^.%w_]EnsureDB%(%)") == nil,
            "initPanel must call NS.EnsureDB (the local lives in EbonClearance_Events.lua)"
        )
        -- EC_Delay is a file-scope local in EbonClearance_Events.lua; the
        -- HookScrollbarAutoHide / FitScrollContent / refreshLayouts
        -- helpers all schedule deferred work and must call NS.Delay.
        local infraCode = (infraSrc:gsub("\n[^\n]*", function(line)
            local commentAt = line:find("%-%-", 1, false)
            if not commentAt then return line end
            return line:sub(1, commentAt - 1)
        end))
        check(
            "EbonClearance_PanelInfra.lua uses NS.Delay (not bare EC_Delay)",
            infraCode:find("NS%.Delay%(") ~= nil
                and infraCode:find("[^.%w_]EC_Delay%(") == nil,
            "deferred-work scheduling must call NS.Delay (the EC_Delay local lives in EbonClearance_Events.lua)"
        )
    end

    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        check(
            "EC_PANEL_WIDTH no longer declared in EbonClearance_Events.lua",
            ecSrc:find("local EC_PANEL_WIDTH%s*=%s*440") == nil,
            "duplicate definition would clobber the Stage 8e-ix-b extracted local"
        )
        check(
            "initPanel no longer defined in EbonClearance_Events.lua",
            ecSrc:find("function EC_compCache%.initPanel%(") == nil,
            "duplicate definition in EbonClearance_Events.lua would clobber the extracted body"
        )
        -- Strip Lua line comments before the bare-ref checks; comment
        -- lines that reference the old identifier are historical
        -- documentation, not live code. Strip ALL line comments
        -- regardless of leading whitespace (the simpler "\n--"-prefix
        -- gsub misses indented inline comments).
        local ecCode = (ecSrc:gsub("(\n[^\n]*)", function(line)
            local commentAt = line:find("%-%-", 1, false)
            if not commentAt then
                return line
            end
            return line:sub(1, commentAt - 1)
        end))
        check(
            "EbonClearance_Events.lua callers use NS.GetPanelWidth (not bare EC_PANEL_WIDTH)",
            ecCode:find("[^.%w_]EC_PANEL_WIDTH[^_%w]") == nil,
            "after the move, EbonClearance_Events.lua can no longer reference EC_PANEL_WIDTH as a local; all callers must use NS.GetPanelWidth()"
        )
        check(
            "EbonClearance_Events.lua callers use NS.HookScrollbarAutoHide (not bare)",
            ecCode:find("[^.%w_]EC_HookScrollbarAutoHide%(") == nil,
            "after the move, EbonClearance_Events.lua can no longer reference EC_HookScrollbarAutoHide as a local; all callers must use NS.HookScrollbarAutoHide()"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 53 (Stage 8e-ix-c): widget primitives extracted.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-c moves the six widget primitives (MakeHeader, MakeLabel,
-- AddCheckbox, AddSlider, StyleInputBox, ColorTextByQuality) into
-- EbonClearance_PanelWidgets.lua. The list-row factories
-- (EC_compCache.makeListRowFactory + buildList*Row helpers) +
-- CreateListUI + EC_AddScanByQualityRow STAY in EbonClearance_Events.lua for
-- Stage 8e-ix-d.
do
    local pwFile = io.open("EbonClearance_PanelWidgets.lua", "rb")
    if pwFile then
        local pwSrc = pwFile:read("*a") or ""
        pwFile:close()
        local widgets = { "MakeHeader", "MakeLabel", "AddCheckbox",
            "AddSlider", "StyleInputBox", "ColorTextByQuality" }
        for _, name in ipairs(widgets) do
            check(
                "EbonClearance_PanelWidgets.lua defines " .. name,
                pwSrc:find("local function " .. name .. "%(") ~= nil,
                name .. " must live in EbonClearance_PanelWidgets.lua (Stage 8e-ix-c)"
            )
        end
        -- NS exposures must also be co-located.
        check(
            "EbonClearance_PanelWidgets.lua exposes all 6 widgets on NS",
            pwSrc:find("NS%.MakeHeader%s*=%s*MakeHeader") ~= nil
                and pwSrc:find("NS%.MakeLabel%s*=%s*MakeLabel") ~= nil
                and pwSrc:find("NS%.AddCheckbox%s*=%s*AddCheckbox") ~= nil
                and pwSrc:find("NS%.AddSlider%s*=%s*AddSlider") ~= nil
                and pwSrc:find("NS%.StyleInputBox%s*=%s*StyleInputBox") ~= nil
                and pwSrc:find("NS%.ColorTextByQuality%s*=%s*ColorTextByQuality") ~= nil,
            "all 6 widget primitives must be exposed on NS so split panel files can call them"
        )
    end

    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        -- The widget primitives must NOT be re-defined in EbonClearance_Events.lua.
        for _, name in ipairs({ "MakeHeader", "MakeLabel", "AddCheckbox",
                "AddSlider", "StyleInputBox", "ColorTextByQuality" }) do
            check(
                name .. " no longer defined in EbonClearance_Events.lua",
                ecSrc:find("local function " .. name .. "%(") == nil,
                "duplicate definition would clobber the Stage 8e-ix-c extracted body"
            )
        end
        -- No bare StyleInputBox call sites in EbonClearance_Events.lua code
        -- (comments stripped) - all 3 in-EbonClearance_Events.lua callers
        -- inside the list-row factories were converted to
        -- NS.StyleInputBox.
        local ecCode = (ecSrc:gsub("\n[^\n]*", function(line)
            local at = line:find("%-%-", 1, false)
            if not at then return line end
            return line:sub(1, at - 1)
        end))
        check(
            "no bare StyleInputBox() call sites in EbonClearance_Events.lua code",
            ecCode:find("[^.%w_]StyleInputBox%(") == nil,
            "the 3 list-row-factory call sites must use NS.StyleInputBox after the move"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 54 (Stage 8e-ix-d): list widget extracted.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-d moves the list-row factories (makeListRowFactory,
-- buildListHeaderRow, buildListSearchAndSortRow, buildListScrollArea),
-- the CreateListUI widget body itself, and the shared
-- EC_AddScanByQualityRow into EbonClearance_ListWidget.lua. The file
-- lives after PanelInfra/PanelWidgets in the .toc load order so
-- NS.StyleInputBox and NS.HookScrollbarAutoHide are already published
-- by the time the row factories are defined. (v2.41.0 merged the old
-- buildListMatchRow "By name" add into the single buildListHeaderRow
-- input, so that factory no longer exists.)
--
-- Locks:
--   1. The new file defines the row-factory functions on EC_compCache.
--   2. CreateListUI is a file-scope local in the new file.
--   3. EC_AddScanByQualityRow is a file-scope local in the new file.
--   4. NS.CreateListUI and NS.AddScanByQualityRow are exposed from the
--      new file (not from EbonClearance_Events.lua).
--   5. EbonClearance_Events.lua no longer contains the function bodies or
--      the NS exposures (would clobber the new file's exposures).
--   6. EbonClearance_Events.lua no longer has a `local EC_activeIDBox` (moved
--      to NS.activeIDBox so the cross-file ChatEdit_InsertLink reader
--      and the buildListHeaderRow setter can share state).
--   7. The new file's CreateListUI body uses NS.GetListTable /
--      NS.AddItemToList / NS.PrintNicef / NS.Delay (bare locals would
--      be nil there).
do
    local lwFile = io.open("EbonClearance_ListWidget.lua", "rb")
    if lwFile then
        local lwSrc = lwFile:read("*a") or ""
        lwFile:close()
        local factories = { "makeListRowFactory", "buildListHeaderRow",
            "buildListSearchAndSortRow",
            "buildListScrollArea" }
        for _, name in ipairs(factories) do
            check(
                "EbonClearance_ListWidget.lua defines EC_compCache." .. name,
                lwSrc:find("function EC_compCache%." .. name .. "%(") ~= nil,
                name .. " must live in EbonClearance_ListWidget.lua (Stage 8e-ix-d)"
            )
        end
        check(
            "EbonClearance_ListWidget.lua defines local CreateListUI",
            lwSrc:find("local function CreateListUI%(") ~= nil,
            "CreateListUI must be a file-scope local in EbonClearance_ListWidget.lua"
        )
        check(
            "EbonClearance_ListWidget.lua defines local EC_AddScanByQualityRow",
            lwSrc:find("local function EC_AddScanByQualityRow%(") ~= nil,
            "EC_AddScanByQualityRow must be a file-scope local in EbonClearance_ListWidget.lua"
        )
        check(
            "EbonClearance_ListWidget.lua exposes NS.CreateListUI",
            lwSrc:find("NS%.CreateListUI%s*=%s*CreateListUI") ~= nil,
            "split panel files (Sell List, Keep List, etc.) call NS.CreateListUI"
        )
        check(
            "EbonClearance_ListWidget.lua exposes NS.AddScanByQualityRow",
            lwSrc:find("NS%.AddScanByQualityRow%s*=%s*EC_AddScanByQualityRow") ~= nil,
            "EbonClearance_SellListPanels.lua calls NS.AddScanByQualityRow"
        )
        -- The CreateListUI body must call NS.GetListTable etc., not the
        -- file-scope locals from EbonClearance_Events.lua which are no longer
        -- in scope after the move.
        check(
            "CreateListUI body uses NS.GetListTable",
            lwSrc:find("NS%.GetListTable%(") ~= nil,
            "the moved body must call NS.GetListTable; bare EC_GetListTable is nil here"
        )
        check(
            "CreateListUI body uses NS.AddItemToList",
            lwSrc:find("NS%.AddItemToList%(") ~= nil,
            "the moved body must call NS.AddItemToList; bare EC_AddItemToList is nil here"
        )
        check(
            "CreateListUI body uses NS.PrintNicef",
            lwSrc:find("NS%.PrintNicef%(") ~= nil,
            "the moved body must call NS.PrintNicef; bare PrintNicef is nil here"
        )
        check(
            "CreateListUI body uses NS.Delay",
            lwSrc:find("NS%.Delay%(") ~= nil,
            "the moved body must call NS.Delay; bare EC_Delay is nil here"
        )
        -- The buildListHeaderRow OnEditFocusGained/Lost handlers must
        -- read/write NS.activeIDBox (not the bare local that used to
        -- live in EbonClearance_Events.lua's main chunk).
        check(
            "buildListHeaderRow uses NS.activeIDBox",
            lwSrc:find("NS%.activeIDBox%s*=%s*self") ~= nil,
            "OnEditFocusGained must set NS.activeIDBox so the ChatEdit_InsertLink hook can read it"
        )
    end

    local ecFile = io.open("EbonClearance_Events.lua", "rb")
    if ecFile then
        local ecSrc = ecFile:read("*a") or ""
        ecFile:close()
        -- Strip comments line-by-line so doc references don't trigger
        -- the "moved body still here" failure.
        local ecCode = (ecSrc:gsub("\n[^\n]*", function(line)
            local at = line:find("%-%-", 1, false)
            if not at then return line end
            return line:sub(1, at - 1)
        end))
        -- Function bodies must NOT be redefined in EbonClearance_Events.lua.
        for _, name in ipairs({ "makeListRowFactory", "buildListHeaderRow",
                "buildListSearchAndSortRow",
                "buildListScrollArea" }) do
            check(
                "EC_compCache." .. name .. " no longer defined in EbonClearance_Events.lua",
                ecCode:find("function EC_compCache%." .. name .. "%(") == nil,
                "duplicate definition would clobber the Stage 8e-ix-d extracted body"
            )
        end
        check(
            "local CreateListUI no longer defined in EbonClearance_Events.lua",
            ecCode:find("local function CreateListUI%(") == nil,
            "duplicate definition would clobber the Stage 8e-ix-d extracted body"
        )
        check(
            "local EC_AddScanByQualityRow no longer defined in EbonClearance_Events.lua",
            ecCode:find("local function EC_AddScanByQualityRow%(") == nil,
            "duplicate definition would clobber the Stage 8e-ix-d extracted body"
        )
        check(
            "NS.CreateListUI no longer assigned in EbonClearance_Events.lua",
            ecCode:find("NS%.CreateListUI%s*=%s*CreateListUI") == nil,
            "duplicate NS.CreateListUI assignment would clobber the new file's exposure"
        )
        check(
            "NS.AddScanByQualityRow no longer assigned in EbonClearance_Events.lua",
            ecCode:find("NS%.AddScanByQualityRow%s*=%s*EC_AddScanByQualityRow") == nil,
            "duplicate NS.AddScanByQualityRow assignment would clobber the new file's exposure"
        )
        -- EC_activeIDBox is now NS-only. The bare local must be gone
        -- and ChatEdit_InsertLink must read NS.activeIDBox.
        check(
            "no `local EC_activeIDBox` declaration in EbonClearance_Events.lua",
            ecCode:find("local EC_activeIDBox%s*=") == nil,
            "EC_activeIDBox was promoted to NS.activeIDBox for cross-file access in Stage 8e-ix-d"
        )
        check(
            "ChatEdit_InsertLink hook reads NS.activeIDBox",
            ecCode:find("NS%.activeIDBox") ~= nil,
            "the shift-click-to-add reader must use NS.activeIDBox after Stage 8e-ix-d"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 55 (Stage 9): EbonClearance.lua renamed to EbonClearance_Events.lua.
-- ---------------------------------------------------------------------------
-- Stage 9 closes out the multi-stage file split (docs/CODE_REVIEW.md item 4)
-- by renaming the original monolith file. The rename is mechanical but has
-- several load-bearing references that all need to stay in lockstep:
--   * EbonClearance.toc must load EbonClearance_Events.lua (not the old
--     name); a stale .toc reference would cause the addon to fail to load
--     because the old file is gone.
--   * .github/workflows/release.yml's sed rules must target the new name;
--     a stale sed would silently leave ADDON_VERSION at the old value
--     after a release tag push.
--   * The ADDON_VERSION constant must live in EbonClearance_Events.lua
--     (the release sed pattern is filename-anchored).
--   * No stale EbonClearance.lua file is left in the working tree.
do
    local stillExists = io.open("EbonClearance.lua", "rb")
    check(
        "stale EbonClearance.lua file removed",
        stillExists == nil,
        "the rename to EbonClearance_Events.lua should have deleted the old file; a leftover copy would shadow the renamed one"
    )
    if stillExists then stillExists:close() end

    local newFile = io.open("EbonClearance_Events.lua", "rb")
    check(
        "EbonClearance_Events.lua exists",
        newFile ~= nil,
        "Stage 9 of the file split renamed EbonClearance.lua to this file"
    )
    if newFile then
        local newSrc = newFile:read("*a") or ""
        newFile:close()
        check(
            "ADDON_VERSION lives in EbonClearance_Events.lua",
            newSrc:find('local ADDON_VERSION%s*=%s*"v[0-9]+%.[0-9]+%.[0-9]+"') ~= nil,
            "release.yml's sed pattern is anchored to this file; the constant must stay here"
        )
    end

    local toc = io.open("EbonClearance.toc", "rb")
    if toc then
        local tocSrc = toc:read("*a") or ""
        toc:close()
        check(
            ".toc loads EbonClearance_Events.lua",
            tocSrc:find("EbonClearance_Events%.lua") ~= nil,
            "the .toc must reference the renamed file; the old EbonClearance.lua name was retired in Stage 9"
        )
        check(
            ".toc no longer references the old EbonClearance.lua name",
            tocSrc:find("\nEbonClearance%.lua") == nil,
            "leftover .toc reference would fail to load (the file is gone)"
        )
    end

    local release = io.open(".github/workflows/release.yml", "rb")
    if release then
        local relSrc = release:read("*a") or ""
        release:close()
        check(
            "release.yml sed targets EbonClearance_Events.lua",
            relSrc:find("EbonClearance_Events%.lua") ~= nil,
            "the ADDON_VERSION sed rule + cp + git add must reference the new filename after Stage 9"
        )
        -- Approximate "no bare EbonClearance.lua token". Lua's pattern
        -- lang has no lookbehind, so we walk lines and check that any
        -- match has a non-identifier char before it (i.e. is part of
        -- EbonClearance_*.lua, not the retired bare name).
        local hasBareOld = false
        for line in relSrc:gmatch("[^\n]+") do
            if line:find("[^_%w]EbonClearance%.lua") or line:find("^EbonClearance%.lua") then
                hasBareOld = true
                break
            end
        end
        check(
            "release.yml has no stale EbonClearance.lua reference",
            not hasBareOld,
            "release.yml should no longer reference the retired EbonClearance.lua name"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 56: tome protection (per-character).
-- ---------------------------------------------------------------------------
-- Two new DB toggles (DB.protectUnlearnedTomes default ON,
-- DB.protectAllTomes default OFF) drive a HARD veto in EC_IsSellable that
-- blocks vendoring of spell-teaching items even when on the Sell List.
-- Mirrors the v2.19.0 affix protection semantics, not v2.20.1 chance-on-
-- hit narrowing: the user must explicitly mark Allow Sell
-- (ADB.allowedItems[itemID]) to lift the protection. Detection is hybrid:
-- GetItemInfo class == "Recipe" is the fast path; tooltip scan for
-- `Use: Teaches you...` (locale-aware via ITEM_SPELL_TRIGGER_ONUSE)
-- covers class tomes and mount scrolls. Unlearned check via
-- ITEM_SPELL_KNOWN ("Already known") tooltip line. Two caches: tomeCache
-- (stable per itemID, never invalidated) and tomeIsKnownCache (character-
-- state-sensitive, wiped on LEARNED_SPELL_IN_TAB / SPELLS_CHANGED).
do
    -- EnsureDB defaults must be wired with the documented values.
    check(
        "EnsureDB defaults DB.protectUnlearnedTomes to true",
        src:find("DB%.protectUnlearnedTomes%s*=%s*true") ~= nil,
        "the new unlearned-tome protection must default ON to match the affix / chance-on-hit precedent"
    )
    check(
        "EnsureDB defaults DB.protectAllTomes to false",
        src:find("DB%.protectAllTomes%s*=%s*false") ~= nil,
        "the all-tomes variant defaults OFF; opt-in toggle"
    )

    -- Detection helpers must live on EC_compCache so all callers
    -- (EC_IsSellable, tooltip annotation, future call sites) share the
    -- same per-itemID caches.
    local helpers = {
        "itemIsTome", "playerKnowsTomeSpell",
        "liveTooltipIsTome", "liveTooltipPlayerKnowsTome",
    }
    for _, name in ipairs(helpers) do
        check(
            "EC_compCache." .. name .. " defined",
            src:find("function EC_compCache%." .. name .. "%(") ~= nil,
            name .. " must be attached to EC_compCache so the bag-item and live-tooltip paths share the cache"
        )
    end

    -- Both caches must be declared on EC_compCache in Core.lua so
    -- they exist at load time (no lazy init in helpers).
    local coreFile = io.open("EbonClearance_Core.lua", "rb")
    if coreFile then
        local coreSrc = coreFile:read("*a") or ""
        coreFile:close()
        check(
            "tomeCache declared on EC_compCache (Core)",
            coreSrc:find("tomeCache%s*=%s*{}") ~= nil,
            "tomeCache must exist at load so the is-a-tome lookup never hits nil"
        )
        check(
            "tomeIsKnownCache declared on EC_compCache (Core)",
            coreSrc:find("tomeIsKnownCache%s*=%s*{}") ~= nil,
            "tomeIsKnownCache must exist at load so the LEARNED_SPELL_IN_TAB wipe is safe"
        )
    end

    -- The cache invalidation must fire on LEARNED_SPELL_IN_TAB /
    -- SPELLS_CHANGED. The wipe is intentionally NOT debounced (it's
    -- one table reset; doing it synchronously avoids a 0.5 s window
    -- where a just-learned recipe still reads as unlearned).
    local eventsFile = io.open("EbonClearance_Events.lua", "rb")
    if eventsFile then
        local eventsSrc = eventsFile:read("*a") or ""
        eventsFile:close()
        -- Locate the LEARNED_SPELL_IN_TAB branch and look for the wipe
        -- within the next ~30 lines.
        local branchAt = eventsSrc:find('event == "LEARNED_SPELL_IN_TAB"', 1, true)
        check(
            "LEARNED_SPELL_IN_TAB branch wipes tomeIsKnownCache",
            branchAt
                and eventsSrc:sub(branchAt, branchAt + 1500):find("wipe%(EC_compCache%.tomeIsKnownCache%)") ~= nil,
            "the cache wipe must live in the event branch; without it a just-learned recipe stays \"unlearned\" until /reload"
        )
        -- The EC_IsSellable veto block must reference both toggles AND
        -- the Allow Sell bypass. Three patterns to find:
        check(
            "EC_IsSellable references DB.protectAllTomes",
            eventsSrc:find("DB%.protectAllTomes") ~= nil,
            "the veto must consult the aggressive all-tomes toggle"
        )
        check(
            "EC_IsSellable references DB.protectUnlearnedTomes",
            eventsSrc:find("DB%.protectUnlearnedTomes") ~= nil,
            "the veto must consult the unlearned-tome toggle"
        )
        check(
            "EC_IsSellable calls EC_compCache.itemIsTome",
            eventsSrc:find("EC_compCache%.itemIsTome%(") ~= nil,
            "the veto must dispatch to the cached tome detector"
        )
        check(
            "EC_IsSellable calls EC_compCache.playerKnowsTomeSpell",
            eventsSrc:find("EC_compCache%.playerKnowsTomeSpell%(") ~= nil,
            "the unlearned branch must consult the learned-state cache"
        )
        -- Hard-veto invariant: the tome block must include `return false`,
        -- not just demote qualityPass. The Sell List override pattern
        -- (from chance-on-hit v2.20.1) is intentionally NOT used; tomes
        -- require Allow Sell even with explicit list entries.
        local tomeBlockStart = eventsSrc:find("EC_compCache%.itemIsTome%(")
        if tomeBlockStart then
            -- Capture the next ~600 chars (covers the if/end block).
            local tomeBlock = eventsSrc:sub(tomeBlockStart, tomeBlockStart + 600)
            check(
                "EC_IsSellable tome block hard-vetoes via `return false`",
                tomeBlock:find("return false") ~= nil,
                "the tome veto must HARD-veto (return false) so Sell List membership doesn't bypass it; Allow Sell is the only bypass"
            )
            check(
                "EC_IsSellable tome block considers whitelistPass in the gate",
                eventsSrc:find("%(qualityPass or whitelistPass%)%s*\n%s*and %(DB%.protectAllTomes") ~= nil,
                "the tome gate must include whitelistPass so the protection fires even for Sell List entries"
            )
        end
    end

    -- The Protection Settings panel must wire two checkboxes that
    -- write the toggles AND call NS.RefreshSellBorders (so toggling
    -- the protection re-paints the bag tints immediately, matching
    -- Test 42's list-mutation invariant family).
    local protPanelFile = io.open("EbonClearance_ProtectionPanel.lua", "rb")
    if protPanelFile then
        local panelSrc = protPanelFile:read("*a") or ""
        protPanelFile:close()
        check(
            "ProtectionPanel writes DB.protectUnlearnedTomes",
            panelSrc:find("DB%.protectUnlearnedTomes%s*=") ~= nil,
            "the unlearned-tome checkbox OnClick must persist the new state"
        )
        check(
            "ProtectionPanel writes DB.protectAllTomes",
            panelSrc:find("DB%.protectAllTomes%s*=") ~= nil,
            "the all-tomes checkbox OnClick must persist the new state"
        )
        -- Both OnClick handlers must call NS.RefreshSellBorders.
        -- Count occurrences as a sanity check (one per checkbox + the
        -- pre-existing 3 in this file = at least 5 total).
        local refreshCount = 0
        for _ in panelSrc:gmatch("NS%.RefreshSellBorders") do
            refreshCount = refreshCount + 1
        end
        check(
            "ProtectionPanel calls NS.RefreshSellBorders at least 5 times",
            refreshCount >= 5,
            "Stage 8e-vi pinned 3 refresh calls; the two new tome toggles add 2 more (Issue B invariant family)"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 57: Fast Loot AntiDoS throttle.
-- ---------------------------------------------------------------------------
-- AzerothCore antidos_opcode_policies caps per-opcode packets/sec at
-- 5-8 by default. A tight `for i = 1, GetNumLootItems() do LootSlot(i) end`
-- loop on a multi-slot corpse exceeds that threshold and triggers a
-- KickPlayer action on PE-style servers. EC's v2.21.0 Fast Loot refactor
-- uses an OnUpdate-driven queue throttled to one LootSlot call per
-- ~110 ms; this test locks that design so a future refactor cannot
-- silently regress to a tight loop without CI catching it.
do
    -- Strip comment lines (per-line %-%- prefix) so docstrings referencing
    -- the bad pattern as a counter-example don't false-positive on the
    -- negative invariants below.
    local code = (src:gsub("\n[^\n]*", function(line)
        local at = line:find("%-%-", 1, false)
        if not at then return line end
        return line:sub(1, at - 1)
    end))

    -- 1. Queue table present with safe delay (>= 0.10 s = 100 ms).
    --    Pattern matches `lootQueue = { ... delay = 0.NN ... }`. Uses
    --    `.-` (non-greedy any-char) rather than `[^}]-` so the match
    --    spans nested table literals like `slots = {}` that appear
    --    before the delay field.
    local delayStr = src:match("lootQueue%s*=%s*{.-delay%s*=%s*(0%.%d+)")
    local delay = tonumber(delayStr or "")
    check(
        "Fast Loot lootQueue.delay >= 0.10 (AntiDoS throttle floor)",
        delay ~= nil and delay >= 0.10,
        "Fast Loot drain must throttle at >= 100 ms to stay below AzerothCore "
            .. "AntiDoS opcode rate limits (MaxAllowedCount is typically 5-8 "
            .. "packets/sec). Found: " .. tostring(delayStr)
    )

    -- 2. OnUpdate driver consults the throttle interval before each
    --    LootSlot call. Look for the time-since-last gate.
    check(
        "Fast Loot OnUpdate body checks (GetTime - lastLootAt) < delay",
        src:find("GetTime%(%)%s*%-%s*qs%.lastLootAt") ~= nil
            and src:find("<%s*qs%.delay") ~= nil,
        "the OnUpdate driver must consult qs.delay between LootSlot calls; "
            .. "without this gate the queue would drain in a single frame and "
            .. "trigger AntiDoS"
    )

    -- 3. Exactly one bare `LootSlot(` call in shipped code (comment-
    --    stripped). The legitimate call is the throttled LootSlot(slotIdx)
    --    inside the OnUpdate body. The "LootSlot" string literal in
    --    hooksecurefunc("LootSlot", ...) doesn't match because it's inside
    --    quotes. ConfirmLootSlot(slot) doesn't match because the preceding
    --    char "m" is alphanumeric (excluded by [^%w_]).
    local lootSlotCalls = 0
    for _ in code:gmatch("[^%w_]LootSlot%(") do
        lootSlotCalls = lootSlotCalls + 1
    end
    check(
        "exactly one LootSlot() call site in shipped source",
        lootSlotCalls == 1,
        "Fast Loot must dispatch through a single throttled LootSlot call site "
            .. "(the OnUpdate driver). Extra call sites can bypass the "
            .. "throttle and trigger AntiDoS kicks. Found " .. lootSlotCalls
            .. " call site(s)."
    )

    -- 4. Negative invariant - no tight `for ... do ... LootSlot()` loop
    --    anywhere in shipped source. Catches the kick-vulnerable pattern
    --    even if a future contributor restores the original v2.16.0 drain
    --    shape. The pattern matches a `for IDENT = NUM, ...` header on the
    --    same line as a LootSlot( call (the typical one-liner) AND a
    --    multi-line variant where the for-block contains LootSlot( before
    --    the matching end.
    local tightLoopOneLine = code:find(
        "for%s+[%w_]+%s*=%s*[%w_]+%s*,[^\n]-do[^\n]-[^%w_]LootSlot%("
    )
    local tightLoopMultiLine = false
    -- Scan each `for ... do` opening and look ahead bounded chars for
    -- LootSlot( before the matching `end`. Bounded because Lua patterns
    -- can't express balanced delimiters.
    for openIdx in code:gmatch("()for%s+[%w_]+%s*=%s*[%w_]+%s*,[^\n]*do") do
        local body = code:sub(openIdx, openIdx + 600)
        if body:find("[^%w_]LootSlot%(") and not body:find("qs%.delay") then
            tightLoopMultiLine = true
            break
        end
    end
    check(
        "no tight `for ... do ... LootSlot()` loop in shipped source",
        not tightLoopOneLine and not tightLoopMultiLine,
        "Fast Loot must NOT drain via a tight for-loop; AzerothCore AntiDoS "
            .. "will KickPlayer on packet burst. Use the EC_compCache.lootQueue "
            .. "OnUpdate-throttled queue instead."
    )

    -- 5. LOOT_READY is the right event source. LOOT_OPENED fires earlier
    --    and may queue against stale slot data, so it must NOT be
    --    registered as a separate event handler. The "LOOT_OPENED"
    --    string can still appear in comments (it does in the design
    --    rationale comment block at line ~2120); the check uses the
    --    comment-stripped `code` so doc references don't trip it.
    check(
        "LOOT_READY is registered (Fast Loot event source)",
        src:find('RegisterEvent%("LOOT_READY"%)') ~= nil,
        "LOOT_READY drives the lazy-build OnUpdate frame in EC_HandleLootReady"
    )
    check(
        "LOOT_OPENED is NOT registered as a separate handler",
        code:find('RegisterEvent%("LOOT_OPENED"%)') == nil,
        "Fast Loot must consume LOOT_READY only; LOOT_OPENED can fire before "
            .. "loot data is populated and would queue against stale slot info"
    )
end

-- ---------------------------------------------------------------------------
-- Test 58: Delete-List affix gate honours manual Allow Sell.
-- ---------------------------------------------------------------------------
-- Pre-v2.32.x bug: a Rare/Epic item with an affix that the user had
-- explicitly Alt+Right-Click -> Allow Sell'd (so ADB.allowedAffixes[key]
-- was set) could not be deleted via the Delete List. The sell-path gate
-- in EC_IsSellable releases the item on `manualAllow or autoDupe`; the
-- delete-path gate only checked `isDupe` (autoDupe only). Items with no
-- vendor value and an Allow-Sell-marked affix had no escape from the bag.
--
-- Fix: the affix gate also checks ADB.allowedAffixes (the manual Allow
-- Sell mark). Explicit user intent wins, matching the sell-path semantics.
--
-- v2.42.0: the affix gate moved from BuildQueue's inline delete branch
-- into the shared deleteListSlotEligible helper (EC_compCache method).
-- This test now locates the gate in the helper body.
--
-- This test locks the shape: any future refactor that drops the
-- manualAllow check from the delete-path affix gate will fail.
do
    local eventsFile = io.open("EbonClearance_Events.lua", "rb")
    if eventsFile then
        local eventsSrc = eventsFile:read("*a") or ""
        eventsFile:close()
        -- v2.42.0: the affix gate is in deleteListSlotEligible. Locate
        -- it by the function signature and grab the surrounding ~1500 chars.
        local blockStart = eventsSrc:find("function EC_compCache%.deleteListSlotEligible%(")
        if blockStart then
            local block = eventsSrc:sub(blockStart, blockStart + 2500)
            check(
                "BuildQueue delete-path affix gate references ADB.allowedAffixes",
                block:find("ADB%.allowedAffixes") ~= nil,
                "manual Allow Sell on an affix description must release the delete-list gate; without this the user has no way to delete a no-vendor-value affixed item they have explicitly allowed"
            )
            check(
                "BuildQueue delete-path affix gate uses `manualAllow or` shape",
                block:find("manualAllow") ~= nil
                    and block:find("not %(manualAllow or") ~= nil,
                "the delete-path gate must mirror the sell-path's `not (manualAllow or autoDupe)` shape so either bypass releases the protection"
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 59 (v2.32.x): lazy + incremental affix-catalog refresh.
-- ---------------------------------------------------------------------------
-- Background: a player who learned an affix at the Anvil and
-- immediately hovered a new drop saw a stale "Protected - Affix
-- found" verdict because the catalog refresh path was:
--   PE.ExtractionService update -> no event we listen to ->
--   wait for next BAG_UPDATE (120 ms debounce) ->
--   refreshExtractionIfDirty fires -> kicks off async refresh
--   refreshKnownAffixes (0.5 s spell-event debounce skipped here
--   because we call it directly, but the chunked OnUpdate scan
--   still takes 150-300 ms) -> map updated.
-- Total: ~300-500 ms after the BAG_UPDATE settled, plus the
-- "no event yet" gap if PE didn't fire BAG_UPDATE on extraction.
-- v2.32.x splits this in two:
--   1. refreshExtractionIfDirty does a SYNCHRONOUS INCREMENTAL
--      merge into the live knownAffixDescriptions map (driven by
--      the procIdToDescription cache, so per-call cost is O(new
--      affixes)). The full async refreshKnownAffixes is kept as a
--      fallback for two cases only: pre-PLAYER_LOGIN bootstrap
--      (map not yet a table) and learnedCount going DOWN.
--   2. EbonClearance_Tooltip.lua now calls refreshExtractionIfDirty
--      from inside the affix branch BEFORE playerHasAffixDescription,
--      so a fresh hover after a learn picks up the new state.
--
-- These two invariants lock the v2.32.x shape so a future refactor
-- that drops either piece (e.g. "consolidate by always going
-- through refreshKnownAffixes again") fails the test before merge.
do
    local protFile = io.open("EbonClearance_Protection.lua", "rb")
    if protFile then
        local protSrc = protFile:read("*a") or ""
        protFile:close()
        -- Extract the body of refreshExtractionIfDirty (function start to
        -- the closing `end` of the same function). Marker: function
        -- declaration line. Pattern-match the incremental-merge body
        -- inside.
        local startIdx = protSrc:find("function EC_compCache%.refreshExtractionIfDirty%(%)")
        local body
        if startIdx then
            -- Take ~3500 chars of body; the function is well under that.
            body = protSrc:sub(startIdx, startIdx + 3500)
            local nextFnIdx = body:find("\nfunction EC_compCache%.", 2)
            if nextFnIdx then
                body = body:sub(1, nextFnIdx - 1)
            end
        end
        check(
            "refreshExtractionIfDirty does an incremental merge into knownAffixDescriptions",
            body ~= nil
                and body:find("EC_compCache%.knownAffixDescriptions") ~= nil
                and body:find("map%[desc%]%s*=%s*true") ~= nil,
            "the v2.32.x refactor must add learned affixes directly to the live knownAffixDescriptions map so the first hover after a learn-at-Anvil sees the correct verdict; without this the user has to wait for the async chunked scan to settle"
        )
        check(
            "refreshExtractionIfDirty reads procIdToDescription cache (incremental path)",
            body ~= nil and body:find("procIdToDescription%[r%.id%]") ~= nil,
            "the incremental merge must hit the per-spellID description cache so repeated dirty-checks don't re-scan the same engraving spell every time"
        )
        check(
            "refreshExtractionIfDirty keeps the async rebuild as a fallback",
            body ~= nil and body:find("refreshKnownAffixes") ~= nil,
            "the function must still defer to refreshKnownAffixes when knownAffixDescriptions isn't bootstrapped yet or when learnedCount went down (un-learn); pure incremental can't drop stale entries"
        )
    end

    local tooltipFile = io.open("EbonClearance_Tooltip.lua", "rb")
    if tooltipFile then
        local ttSrc = tooltipFile:read("*a") or ""
        tooltipFile:close()
        -- Strip Lua line comments so the check only matches a live call
        -- site, not the explanatory comment block above it.
        local ttCode = ttSrc:gsub("%-%-[^\n]*", "")
        check(
            "EbonClearance_Tooltip.lua calls refreshExtractionIfDirty (lazy refresh)",
            ttCode:find("refreshExtractionIfDirty") ~= nil,
            "the affix branch must call refreshExtractionIfDirty before playerHasAffixDescription so a fresh hover picks up newly-learned affixes without waiting for the next BAG_UPDATE or combat-exit tick"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 60 (v2.32.x): liveTooltipPlayerKnowsTome reads live tooltip first.
-- ---------------------------------------------------------------------------
-- Background: PE's roguelite "Tome of Echo" mechanic doesn't teach a
-- Blizzard spell on use - it updates internal PE state, which means
-- LEARNED_SPELL_IN_TAB / SPELLS_CHANGED don't fire. The
-- tomeIsKnownCache wipe is wired to those events, so a cached `false`
-- (from a hover before the tome was used) stuck around forever and
-- the EC tooltip kept labelling the tome as "Protected - Tome
-- (unlearned)" even when Blizzard's own "Already known" line was
-- visible right above. This is the same cache-staleness shape as
-- the affix issue addressed in Test 59 but on a different cache.
--
-- v2.32.x fix: liveTooltipPlayerKnowsTome now scans the live tooltip
-- BEFORE consulting the cache. The cache becomes a side-effect
-- output (still useful to playerKnowsTomeSpell which has no live
-- tooltip), not a read-path fast-path that can pin stale state. The
-- live tooltip is what the user sees, so we read the same source.
do
    local protFile = io.open("EbonClearance_Protection.lua", "rb")
    if protFile then
        local protSrc = protFile:read("*a") or ""
        protFile:close()
        local fnStart = protSrc:find("function EC_compCache%.liveTooltipPlayerKnowsTome%(")
        if fnStart then
            -- Trim the body to the function only (~2000 chars is well over
            -- the function size; nextFn marker scopes precisely).
            local body = protSrc:sub(fnStart, fnStart + 2500)
            local nextFnIdx = body:find("\nfunction EC_compCache%.", 2)
            if nextFnIdx then
                body = body:sub(1, nextFnIdx - 1)
            end

            -- The defining-shape assertion: tooltip:GetName() (live
            -- tooltip read) must appear BEFORE the
            -- `return EC_compCache.tomeIsKnownCache[itemID]` cache-
            -- hit early-return. In the buggy v2.32.2 and earlier
            -- shape, the cache return was the first conditional in
            -- the function body (came BEFORE any tooltip read).
            local firstGetName = body:find("tooltip:GetName")
            local firstReturnCache = body:find("return EC_compCache%.tomeIsKnownCache")
            check(
                "liveTooltipPlayerKnowsTome reads the live tooltip BEFORE the cache (cache is side-effect output)",
                firstGetName
                    and firstReturnCache
                    and firstGetName < firstReturnCache,
                "the live tooltip is the authoritative source; the prior cache-first fast-path returned a stale `false` for PE Tome of Echo items that don't fire LEARNED_SPELL_IN_TAB on use"
            )
            -- The cache write at the end must still exist - it's what
            -- keeps playerKnowsTomeSpell (the bag-scan variant) hitting
            -- the corrected value on subsequent merchant cycles.
            check(
                "liveTooltipPlayerKnowsTome still writes the cache as a side effect",
                body:find("EC_compCache%.tomeIsKnownCache%[itemID%]%s*=%s*result") ~= nil,
                "the cache write is what propagates a live-tooltip-corrected verdict to the merchant cycle's playerKnowsTomeSpell path"
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 61 (v2.32.x): tome detection excludes vanity pets + mount scrolls.
-- ---------------------------------------------------------------------------
-- Background: the text-scan fallback in itemIsTome / liveTooltipIsTome
-- matches a "Use: Teaches" tooltip line - too broad. It also catches
-- vanity pet items ("Use: Teaches you how to summon this companion")
-- and mount-training scrolls ("Use: Teaches you how to ride...").
-- User-reported false positive: Disgusting Oozeling labelled
-- "Protected - Tome (unlearned)" despite being a vanity pet, not a
-- spell tome.
--
-- v2.32.x fix: both helpers return false early when GetItemInfo
-- reports class="Miscellaneous" with subclass in {"Companion",
-- "Mount"}. The check sits AFTER the class="Recipe" shortcut so
-- legitimate tomes / recipes still resolve via the fast path, and
-- the text-scan path below is preserved for genuinely-tome items
-- whose class isn't "Recipe" (rare custom PE formats).
do
    local protFile = io.open("EbonClearance_Protection.lua", "rb")
    if protFile then
        local protSrc = protFile:read("*a") or ""
        protFile:close()

        local liveStart = protSrc:find("function EC_compCache%.liveTooltipIsTome%(")
        local liveBody
        if liveStart then
            liveBody = protSrc:sub(liveStart, liveStart + 3500)
            local nextFnIdx = liveBody:find("\nfunction EC_compCache%.", 2)
            if nextFnIdx then
                liveBody = liveBody:sub(1, nextFnIdx - 1)
            end
        end
        check(
            "liveTooltipIsTome excludes Companion + Mount subtypes",
            liveBody ~= nil
                and liveBody:find('"Companion"', 1, true) ~= nil
                and liveBody:find('"Mount"', 1, true) ~= nil
                and liveBody:find('"Miscellaneous"', 1, true) ~= nil,
            "vanity pets and mount-training scrolls falsely matched the 'Use: Teaches' text scan; the exclusion gate (class=Miscellaneous + subclass=Companion/Mount) must be present in the tooltip-side helper"
        )
        check(
            "liveTooltipIsTome rejects collectible phrasings inside the text scan",
            liveBody ~= nil
                and liveBody:find('"this companion"', 1, true) ~= nil
                and liveBody:find('"this mount"', 1, true) ~= nil
                and liveBody:find('"how to ride"', 1, true) ~= nil,
            "GetItemInfo subclass is unreliable in 3.3.5a (pets often file under \"Junk\"); the tooltip-text reject is the second-line defence that catches the case based on actual Use-line phrasing"
        )

        local bagStart = protSrc:find("function EC_compCache%.itemIsTome%(")
        local bagBody
        if bagStart then
            bagBody = protSrc:sub(bagStart, bagStart + 3500)
            local nextFnIdx = bagBody:find("\nfunction EC_compCache%.", 2)
            if nextFnIdx then
                bagBody = bagBody:sub(1, nextFnIdx - 1)
            end
        end
        check(
            "itemIsTome excludes Companion + Mount subtypes",
            bagBody ~= nil
                and bagBody:find('"Companion"', 1, true) ~= nil
                and bagBody:find('"Mount"', 1, true) ~= nil
                and bagBody:find('"Miscellaneous"', 1, true) ~= nil,
            "the bag-item variant (used by EC_IsSellable in the merchant cycle) must mirror the live-tooltip exclusion so pets/mounts don't get caught as tomes during the auto-sell decision either"
        )
        check(
            "itemIsTome rejects collectible phrasings inside the text scan",
            bagBody ~= nil
                and bagBody:find('"this companion"', 1, true) ~= nil
                and bagBody:find('"this mount"', 1, true) ~= nil
                and bagBody:find('"how to ride"', 1, true) ~= nil,
            "same belt-and-braces text-content reject as liveTooltipIsTome; protects against pets that file under \"Junk\" in 3.3.5a where the subclass-based gate misses"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 62 (v2.33.x): isDowngradeVsEquipped narrows to {16} when 2H equipped.
-- ---------------------------------------------------------------------------
-- Bug reported by "Perfect Bidoof": a player wielding an iLvl 258 2H
-- (Justicebringer of Judgment) had every green 1H weapon in bags
-- labelled "Keep (Green, possible upgrade)" and refusing to sell, even
-- when the 1H was iLvl 134 - obviously not an upgrade.
--
-- Root cause: INVTYPE_WEAPON's candidate slots are {16, 17}. The
-- iLvl-vs-equipped loop bailed with `empty_slot` the moment it hit
-- slot 17 (because the 2H locks the offhand). That bailout is correct
-- for dual-wielders with one weapon equipped (the loot could fill the
-- offhand), but wrong when the main hand holds a 2H - the offhand is
-- locked, not unfilled. Fix: detect the main-hand 2H and narrow the
-- candidate slot list to {16} so the comparison happens against the
-- equipped 2H's iLvl.
--
-- Test asserts the function body contains the INVTYPE_2HWEAPON check
-- and the `slots = { 16 }` narrowing. A future refactor that drops
-- either piece fails this test before merge.
do
    local fnStart = src:find("function EC_compCache%.isDowngradeVsEquipped%(")
    local body
    if fnStart then
        body = src:sub(fnStart, fnStart + 3000)
        local nextFnIdx = body:find("\nfunction ", 2)
        if nextFnIdx then
            body = body:sub(1, nextFnIdx - 1)
        end
    end
    check(
        "isDowngradeVsEquipped checks main hand for INVTYPE_2HWEAPON",
        body ~= nil
            and body:find('"INVTYPE_2HWEAPON"', 1, true) ~= nil
            and body:find('GetInventoryItemLink') ~= nil,
        "the 2H-aware narrowing must read the main hand's equipLoc; without this, every 1H in bags gets falsely kept while the player wields a 2H"
    )
    check(
        "isDowngradeVsEquipped narrows slots to {16} when main hand is 2H",
        body ~= nil and body:find("slots%s*=%s*{%s*16%s*}") ~= nil,
        "the narrowing assignment must literally rewrite slots to {16}; the loop downstream then compares only against the main hand"
    )
    check(
        "isDowngradeVsEquipped narrows only when equipLoc is INVTYPE_WEAPON",
        body ~= nil and body:find('equipLoc%s*==%s*"INVTYPE_WEAPON"') ~= nil,
        "single-slot offhand equipLocs (SHIELD / HOLDABLE / WEAPONOFFHAND) keep the original empty_slot bailout - only the multi-slot INVTYPE_WEAPON case gets the 2H narrowing"
    )
end

-- ---------------------------------------------------------------------------
-- Test 63 (v2.33.x): checkBagsForUpgrades cleans stale "upgrade" entries.
-- ---------------------------------------------------------------------------
-- Bug reported by user "Blaken" (own test character): an Ornamental
-- Mace iLvl 17 sat in bags labelled "Keep (upgrade)" even though the
-- equipped Prospector Axe was iLvl 20 - the mace was added to the
-- Keep List during early levelling when the player had a sub-iLvl-17
-- starter weapon, and stayed on the list forever after the player
-- upgraded past it.
--
-- Root cause: checkBagsForUpgrades was one-way - it ADDED entries but
-- never re-evaluated them. The `if not DB.blacklist[itemID]` pre-
-- condition skipped already-listed items, and the upgradeProcessed
-- per-session memo skipped them again on later runs. The existing
-- `/ec clean upgrades apply` slash command was the only way to clean
-- stale entries, but users shouldn't need to remember a manual command
-- for an auto-protect path that's supposed to be hands-off.
--
-- Fix: re-evaluation pass at the top of checkBagsForUpgrades walks
-- DB.blacklistAuto entries with tag=="upgrade" and removes ones whose
-- iLvl is no longer above the lowest populated equipped slot.
do
    local fnStart = src:find("function EC_compCache%.checkBagsForUpgrades%(")
    local body
    if fnStart then
        body = src:sub(fnStart, fnStart + 5000)
        local nextFnIdx = body:find("\nfunction ", 2)
        if nextFnIdx then
            body = body:sub(1, nextFnIdx - 1)
        end
    end
    check(
        "checkBagsForUpgrades iterates DB.blacklistAuto and inspects autoTag",
        body ~= nil
            and body:find("for itemID, tag in pairs%(DB%.blacklistAuto%)") ~= nil
            and body:find('tag == "upgrade"') ~= nil,
        "the re-evaluation pass must walk DB.blacklistAuto and pick out 'upgrade' entries - other autoTags (equipped / set) have their own sync paths"
    )
    check(
        "checkBagsForUpgrades removes from both DB.blacklist and DB.blacklistAuto on stale entry",
        body ~= nil
            and body:find("DB%.blacklist%[itemID%]%s*=%s*nil") ~= nil
            and body:find("DB%.blacklistAuto%[itemID%]%s*=%s*nil") ~= nil,
        "removing only one side leaves the entry in a half-state; both DB.blacklist and DB.blacklistAuto need to drop the itemID together"
    )
    check(
        "checkBagsForUpgrades clears upgradeProcessed when releasing a stale entry",
        body ~= nil and body:find("EC_compCache%.upgradeProcessed%[itemID%]%s*=%s*nil") ~= nil,
        "without clearing the per-session memo, a future gear DOWNGRADE wouldn't re-add the item - the new-entry loop's processed-check would skip it"
    )
    check(
        "checkBagsForUpgrades cleanup respects empty slots conservatively",
        body ~= nil and body:find("if lowestEquipped and iLvl <= lowestEquipped then") ~= nil,
        "must only remove when lowestEquipped is non-nil (a slot is populated); when every candidate slot is empty, keep the entry rather than mass-clearing the Keep List on a temporary un-equip"
    )
    -- v2.44.0: class-restriction gate. Pre-v2.44.0 the upgrade sweep
    -- compared iLvl-vs-slot without ever checking whether the player's
    -- class could equip the item. Real player report (Murlocked): Mage
    -- with a relic in slot 18 was getting bows / relics flagged as
    -- "Keep (upgrade)" - items the class will never equip. Both the
    -- new-entry path and the stale-cleanup path must gate on
    -- IsUsableItem(itemID) == false (the false literal is the class
    -- veto; nil means uncached, which we must NOT treat as a veto
    -- because GetItemInfo / IsUsableItem race against item-cache
    -- warmup at /reload).
    check(
        "checkBagsForUpgrades gates new entries on IsUsableItem (class restriction)",
        body ~= nil and body:find("IsUsableItem%(itemID%)%s*==%s*false") ~= nil,
        "the new-entry path must skip items where IsUsableItem(itemID) returns false (class veto). Without this, bows on druids / relics on mages / plate on cloth classes get added to the Keep List as 'upgrade' candidates the player can never equip."
    )
    check(
        "checkBagsForUpgrades cleanup also self-heals wrong-class entries",
        body ~= nil
            and body:find("local unusable = IsUsableItem and IsUsableItem%(itemID%) == false") ~= nil,
        "the stale-cleanup path must ALSO check IsUsableItem so existing wrong-class entries (added pre-v2.44.0) get cleaned automatically on subsequent sweeps. Without this, players with already-polluted Keep Lists would have to run /ec clean upgrades manually to fix them."
    )
end

-- ---------------------------------------------------------------------------
-- v2.44.0 Test 92: affix-rank floor opt-out (Murlocked feature).
-- ---------------------------------------------------------------------------
-- Player can set DB.affixMinSellRank to N; affixed Rare/Epic items with
-- rank < N fall through the affix protection. The veto must be added
-- SYMMETRICALLY at every affix-decision site (sell, delete, process,
-- tooltip, sellinfo trace) or the surfaces disagree and the player sees
-- "Will Sell" but the merchant cycle refuses the item.
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("EbonClearance_Events.lua")
    local proc = fileSrc("EbonClearance_Process.lua")
    local tt = fileSrc("EbonClearance_Tooltip.lua")
    local bd = fileSrc("EbonClearance_BagDisplay.lua")
    local pp = fileSrc("EbonClearance_ProtectionPanel.lua")
    check("Test 92a: DB.affixMinSellRank is seeded in EnsureDB with default 0",
        ev:find("DB%.affixMinSellRank%s*=%s*0") ~= nil,
        "the schema must default to 0 (off) so existing v2.43.x saves see no behaviour change on upgrade")
    check("Test 92b: EC_IsSellable adds rankBelow to the affix veto",
        ev:find("if not %(manualAllow or autoDupe or rankBelow%) then") ~= nil,
        "the sell-path veto must accept rankBelow as a third release condition alongside manualAllow and autoDupe; without this the slider has no effect on the auto-rule sweep")
    check("Test 92c: worker delete path mirrors the rankBelow veto",
        ev:find("if not %(manualAllow or isDupe or rankBelow%) then") ~= nil,
        "the delete-path (deleteListSlotEligible) must accept rankBelow too. If sell and delete diverge on the same item the player sees the tooltip flip mid-session")
    check("Test 92d: canDisenchant adds rankBelow to the Process Bags affix-guard",
        proc:find("affixGuarded = not %(manualAllow or autoDupe or rankBelow%)") ~= nil,
        "Process Bags must also honour the rank floor so DE / Mill / Prospect see the same eligibility set the vendor cycle sees")
    check("Test 92e: tooltip annotation accepts rankBelow",
        tt:find("if manualAllow or autoDupe or rankBelow then") ~= nil,
        "EC_AnnotateTooltip must reflect the same verdict the vendor produces; otherwise an item shows 'Keep (affix protected)' on the tooltip then sells at the merchant")
    check("Test 92f: sellinfo trace step for rankBelow",
        bd:find("elseif rankBelow then") ~= nil
            and bd:find("rank %%s below your floor of %%d") ~= nil,
        "/ec sellinfo must show a distinct 'rank below floor' step so the player can trace why the protection released")
    check("Test 92g: ProtectionPanel renders the rank-floor slider",
        pp:find("EbonClearanceAffixMinSellRankSlider") ~= nil
            and pp:find("DB%.affixMinSellRank = v") ~= nil,
        "the Item Protection panel must surface DB.affixMinSellRank via an NS.AddSlider widget with the setter writing the new value; without this UI the player has no way to change the floor")
    check("Test 92i: EC_IsSellable adds affixRankPass + autoDupePass to the positive-signal check",
        ev:find("affixRankPass") ~= nil
            and ev:find("autoDupePass") ~= nil
            and ev:find("isJunk or qualityPass or whitelistPass or affixRankPass or autoDupePass") ~= nil,
        "BOTH the slider and the 'Allow selling affixes you already have' toggle must be standalone sell rules, not release-only levers. Without affixRankPass + autoDupePass in the positive-signal check, affixed Rare/Epic items would still need isJunk / qualityPass / whitelistPass to fire - which broke the user's mental model (Murlocked iterations: the slider IS the sell rule; 'Allow selling' IS the sell rule). Both must appear together so the two toggles behave symmetrically.")
    check("Test 92j: tooltip distinguishes rankBelowOnly with a Will Sell label",
        tt:find("rankBelowOnly") ~= nil
            and tt:find('Will Sell %(low%-rank affix%)') ~= nil
            and tt:find('statusTag = "willsell"') ~= nil,
        "when the rank floor is the only release path (no manualAllow, no autoDupe), the tooltip must say 'Will Sell (low-rank affix)' to match the addon's existing brief label style (compare 'Will Sell (junk)', 'Will Sell (Blue)'). The slider provides the sell signal directly via affixRankPass.")
    check("Test 92k: sellinfo trace exposes the affixRankRule step",
        bd:find("affixRankRule") ~= nil
            and bd:find("is below your 'Sell affixes below rank") ~= nil,
        "the trace must surface the rank rule as a distinct step alongside qualityRule / onSellList so /ec sellinfo correctly reports WHY a low-rank affixed item is selling. The wording mirrors the in-game slider label for player recognisability.")
    check("Test 92l: EC_IsSellable's exit recheck stays symmetric with the entrance gate",
        (function()
            local n, pat = 0, "isJunk or qualityPass or whitelistPass or affixRankPass or autoDupePass"
            local s, e = 1, nil
            while true do
                s, e = ev:find(pat, s, true)
                if not s then break end
                n = n + 1
                s = e + 1
            end
            return n >= 2
        end)(),
        "v2.44.1 bug: the entrance gate at the top of EC_IsSellable added affixRankPass / autoDupePass as positive sell signals, but a stale exit recheck below the chance-on-hit / tome blocks still used the old 3-term predicate (isJunk / qualityPass / whitelistPass). Items passing purely via affixRankPass or autoDupePass entered the function then silently returned false at the exit gate. The tooltip + /ec sellinfo trace re-implement the predicate separately and reported WILL SELL while the vendor cycle skipped the item. Both rechecks must use the same 5-term predicate so the trace and the seller agree.")
    check("Test 92h: rank slider Help entry exists",
        (function()
            local hp = fileSrc("EbonClearance_HelpPanel.lua")
            return hp:find('id = "gate%-affix%-rank%-floor"') ~= nil
        end)(),
        "the slider's [?] icon deep-links to this entry; without it Test 78 (every help icon must resolve to a real entry) breaks AND the player has no in-game explanation of what the slider does")
end

-- ---------------------------------------------------------------------------
-- v2.44.0 Test 93: Resilience auto-mark (Murlocked feature).
-- ---------------------------------------------------------------------------
-- DB.autoMarkResilience opts the player into a BAG_UPDATE-driven sweep
-- that adds items with a "Resilience" tooltip line to DB.deleteList.
-- Actual destruction still flows through the existing vendor / auto-
-- delete-on-pickup pipelines (both master-Enable-gated since v2.42.1).
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("EbonClearance_Events.lua")
    local prot = fileSrc("EbonClearance_Protection.lua")
    local core = fileSrc("EbonClearance_Core.lua")
    local kdp = fileSrc("EbonClearance_KeepDeletePanels.lua")
    check("Test 93a: DB.autoMarkResilience seeded in EnsureDB with default false",
        ev:find("DB%.autoMarkResilience%s*=%s*false") ~= nil,
        "must default OFF - the destination is the Delete List, which the player may have curated for other reasons, and an unsolicited auto-mark could surprise them")
    check("Test 93b: resilienceCache table is declared in Core",
        core:find("resilienceCache%s*=%s*{}") ~= nil,
        "the per-itemID cache mirrors the chanceOnHitCache pattern - without it every BAG_UPDATE re-scans every slot's tooltip and the perf cost compounds during AOE loot")
    check("Test 93c: itemHasResilience helper exists in Protection",
        prot:find("function EC_compCache%.itemHasResilience%(bag, slot, itemID%)") ~= nil
            and prot:find("Resilience") ~= nil
            and prot:find("EC_compCache%.scanBagItem%(bag, slot%)") ~= nil,
        "the detection must mirror itemHasChanceOnHit: cache-keyed by itemID, routed through scanBagItem (SetOwner-before-SetBagItem invariant from v2.38.3), substring-match on 'Resilience'")
    check("Test 93d: runAutoMarkResilience exists and gates on master Enable",
        ev:find("function EC_compCache%.runAutoMarkResilience%(%)") ~= nil
            and ev:find("EC_IsAddonEnabledForChar") ~= nil
            and ev:find("DB%.autoMarkResilience") ~= nil,
        "the sweep must short-circuit when master-disabled (same precedent as v2.42.1 auto-delete) AND when the feature toggle is off")
    check("Test 93e: runAutoMarkResilience fires from the BAG_UPDATE debounce",
        ev:find("EC_compCache%.runAutoMarkResilience%(%)") ~= nil,
        "must run from the coalesced 120ms debounce, not the raw BAG_UPDATE branch - otherwise AOE loot fires the sweep 5+ times in <100ms (the same anti-thrash invariant the auto-delete sweep follows)")
    check("Test 93f: KeepDeletePanels surfaces the resilience checkbox",
        kdp:find("EbonClearanceAutoMarkResilienceCB") ~= nil
            and kdp:find("DB%.autoMarkResilience") ~= nil,
        "the toggle must live on the Delete List panel next to autoDeleteOnPickup; same enabled-state rule (greyed when 'Allow items to be deleted' is off)")
end

-- ---------------------------------------------------------------------------
-- v2.44.4 Test 94: announce-auto-delete toggle (ayres ask).
-- ---------------------------------------------------------------------------
-- DB.announceAutoDelete gates BOTH the "Auto-deleted X" line from the
-- auto-delete-on-pickup sweep AND the "Marked for deletion (Resilience)"
-- line from the resilience auto-mark sweep. Default true (destructive
-- actions should be visible by default); player can silence via the
-- Keep / Delete panel checkbox.
do
    local function fileSrc(path)
        local fh = io.open(path, "rb")
        if not fh then return "" end
        local s = fh:read("*a") or ""
        fh:close()
        return s
    end
    local ev = fileSrc("EbonClearance_Events.lua")
    local kdp = fileSrc("EbonClearance_KeepDeletePanels.lua")
    local hp = fileSrc("EbonClearance_HelpPanel.lua")
    check("Test 94a: DB.announceAutoDelete seeded in EnsureDB with default true",
        ev:find("DB%.announceAutoDelete%s*=%s*true") ~= nil,
        "must default ON - the player should see destructive actions until they explicitly opt out. The off switch is a chat-noise convenience, not a safer default.")
    check("Test 94b: 'Auto-deleted' PrintNicef gated on the toggle",
        ev:find("announce and DB and DB%.announceAutoDelete ~= false") ~= nil,
        "the auto-delete-on-pickup chat line must respect the new toggle. ayres asked for the off switch; if the gate disappears the toggle becomes inert.")
    check("Test 94c: 'Marked for deletion (Resilience)' PrintNicef gated on the toggle",
        ev:find('Marked for deletion %(Resilience, unsellable%)') ~= nil
            and ev:find('if DB and DB%.announceAutoDelete ~= false then') ~= nil,
        "the resilience auto-mark chat line must respect the same toggle. The two messages are the same category of 'EC just touched something' notification - one toggle gates both.")
    check("Test 94d: KeepDeletePanels surfaces the announce checkbox",
        kdp:find("EbonClearanceAnnounceAutoDeleteCB") ~= nil
            and kdp:find("DB%.announceAutoDelete") ~= nil,
        "the toggle must live on the Delete List panel beneath the two sub-toggles it affects (autoCB + resilienceCB); same enabled-state rule (greyed when 'Allow items to be deleted' is off, since neither announcement can fire without deletion enabled)")
    check("Test 94e: Help FAQ entry exists",
        hp:find('id = "gate%-announce%-auto%-delete"') ~= nil,
        "the toggle needs an in-game explanation so a player who finds it in Interface Options understands what gets silenced. The help entry also documents that the manual vendor-cycle summary and lifetime stats are unaffected.")
end

-- ---------------------------------------------------------------------------
-- Test 64 (v2.33.x): EC_TryResummonScavenger self-gates on DB.summonGreedy.
-- ---------------------------------------------------------------------------
-- Bug reported by SLG: "constantly summoning Greedy Scavenger after
-- using a merchant even though I unchecked that option". Static
-- analysis of v2.33.0 found no bypass path - the only caller of
-- EC_TryResummonScavenger is EC_PetCheckTick which already gates on
-- DB.summonGreedy. But the function ITSELF didn't check, leaving the
-- contract one refactor away from breaking. A future caller that
-- adds an EC_TryResummonScavenger invocation without remembering the
-- outer gate reproduces SLG's symptom exactly.
--
-- v2.33.x: defensive DB.summonGreedy gate added at the top of
-- EC_TryResummonScavenger. Cheap (one branch), local to the function,
-- impossible to bypass from any caller. ADDON_GUIDE.md's
-- "EC_TryResummonScavenger only fires when EC_addonDismissed == true"
-- invariant is now extended: also only fires when the user has the
-- summon option on.
do
    local fnStart = src:find("function EC_TryResummonScavenger%(")
    local body
    if fnStart then
        body = src:sub(fnStart, fnStart + 1500)
        -- Take just the first ~1500 chars; the gate has to be near the
        -- top (before any side effects). If it's buried 20 lines deep
        -- below other guards, that's still vulnerable to future
        -- reordering.
    end
    check(
        "EC_TryResummonScavenger self-gates on DB.summonGreedy near the top",
        body ~= nil and body:find("if not DB or not DB%.summonGreedy then") ~= nil,
        "the defensive gate must live inside EC_TryResummonScavenger itself, not just in its caller - SLG's report showed the unchecked-summon option being violated, and the gate inside the function makes the contract impossible to bypass from any future caller that forgets the outer EC_PetCheckTick gate"
    )
end

-- ---------------------------------------------------------------------------
-- Test 65 (post-v2.33.1 audit): IsInSet must be defined in any file that
-- calls it bare; the defensive `IsInSet and IsInSet(...)` guard is banned.
-- ---------------------------------------------------------------------------
-- Background. Stage 7 of the file split (commit a24be7d) moved the Process
-- Bags engine to EbonClearance_Process.lua but silently dropped the file-
-- local IsInSet helper. The bag walk's Keep List skip-gate was written as
-- `if not skip and IsInSet and IsInSet(DB.blacklist, itemID) then` -
-- the defensive guard short-circuited on the unresolved IsInSet (resolving
-- to global nil) and the gate never fired. Keep-listed items appeared in
-- Process Bags as Disenchant / Mill / Prospect / Lockpick candidates.
--
-- This test locks two invariants per file:
--   (a) any file that calls IsInSet must also define it (or import as
--       `local IsInSet = ...`).
--   (b) the `IsInSet and IsInSet(` defensive pattern is banned, because
--       it's the construct that hid the Stage 7 bug. Either define IsInSet
--       in the file and drop the guard, or remove the call entirely.
do
    for _, path in ipairs(SOURCE_PATHS) do
        local f = io.open(path, "r")
        if f then
            local s = f:read("*a")
            f:close()

            -- Strip block / line comments so doc text containing the
            -- literal "IsInSet(" doesn't false-positive. Two passes:
            -- 1) entire `-- ...` line comments (greedy to EOL)
            -- 2) block comments `--[[ ... ]]` (rare in this codebase
            --    but defensive)
            local sCode = s:gsub("%-%-[^\n]*", ""):gsub("%-%-%[%[.-%]%]", "")

            -- Definition forms recognised:
            --   * `local function IsInSet(...)` - file-local body
            --   * `local IsInSet = ...` - file-local capture from NS
            --   * `function NS.IsInSet(...)` - canonical namespace
            --     publication (Core.lua only)
            -- A "call" is any other `IsInSet(` site. Definitions count
            -- as their own callers, so a file that only defines and
            -- never calls IsInSet passes trivially via hasDef.
            local hasDef = sCode:find("local%s+function%s+IsInSet%s*%(") ~= nil
                or sCode:find("local%s+IsInSet%s*=") ~= nil
                or sCode:find("function%s+NS%.IsInSet%s*%(") ~= nil
            local hasCall = sCode:find("IsInSet%s*%(") ~= nil

            if hasCall then
                check(
                    path .. " defines IsInSet because it calls it",
                    hasDef,
                    "any file that calls IsInSet must also define it as a file-local (or import via `local IsInSet = NS.IsInSet`). "
                        .. "Stage 7 had EbonClearance_Process.lua calling IsInSet without defining it; the bare call resolved to global nil and the Keep List skip-gate silently failed."
                )
                check(
                    path .. " does not use the `IsInSet and IsInSet(` defensive pattern",
                    sCode:find("IsInSet%s+and%s+IsInSet%s*%(") == nil,
                    "the `IsInSet and IsInSet(...)` defensive guard is banned because it hides the missing-definition bug. "
                        .. "If IsInSet is defined in this file the guard is dead code; if it isn't, the guard silently neutralises the call. "
                        .. "Either define IsInSet and drop the guard, or remove the call."
                )
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 66 (v2.34.x): per-character partition of EbonClearanceDB.
-- ---------------------------------------------------------------------------
-- Background. The .toc declares `## SavedVariables: EbonClearanceDB` which
-- makes the table account-wide. The documented intent (and the user
-- mental model) is that the lists, profiles, and per-mode preferences are
-- per-character. The mismatch surfaced in-game as the auto-Keep-equipped
-- tag leaking onto a freshly-logged alt that had never worn the item.
--
-- v2.34.x partitions inside EbonClearanceDB: top-level stays as the legacy
-- snapshot (downgrade safety + migration seed); each character's live
-- data lives at EbonClearanceDB.chars[charKey]. DB is a metatable proxy
-- so existing call sites stay unchanged. This test locks the structural
-- invariants:
--   * The PER_CHAR_FIELDS table is declared with the documented field
--     set (so a future contributor adding a new per-character field
--     remembers to include it here).
--   * EnsureDB walks PER_CHAR_FIELDS at migration time.
--   * EnsureDB initialises EbonClearanceDB.chars and seeds the per-
--     character namespace from the snapshot.
--   * DB is built via the proxy (setmetatable with __index + __newindex
--     branching on PER_CHAR_FIELDS).
--   * The PLAYER_LOGOUT branch no longer reassigns
--     `EbonClearanceDB = DB` (which would clobber the SV with the proxy).
do
    local expectedFields = {
        "blacklist",
        "blacklistAuto",
        "whitelist",
        "deleteList",
        "whitelistProfiles",
        "blacklistProfiles",
        "activeProfileName",
        "processIgnored",
        "processCollapsedModes",
    }

    check(
        "PER_CHAR_FIELDS table declared",
        src:find("local%s+PER_CHAR_FIELDS%s*=") ~= nil,
        "the per-character field set must live as a file-local table in EbonClearance_Events.lua so the proxy and the migration walk reference the same canonical list"
    )

    for _, name in ipairs(expectedFields) do
        check(
            "PER_CHAR_FIELDS includes " .. name,
            src:find(name .. "%s*=%s*true") ~= nil,
            "missing per-character field would route the field through the account-wide top-level (defeats the migration)"
        )
    end

    check(
        "EnsureDB initialises EbonClearanceDB.chars",
        src:find("EbonClearanceDB%.chars%s*==%s*nil") ~= nil,
        "EnsureDB must initialise the chars namespace on first load with the new schema"
    )

    check(
        "EnsureDB seeds per-character namespace from snapshot via deep copy",
        src:find("EC_DBDeepCopy%(EbonClearanceDB%[k%]%)") ~= nil,
        "each character's first load must deep-copy the legacy top-level snapshot into chars[charKey] so the pre-migration baseline survives and is consistent across characters"
    )

    check(
        "DB is built via EC_DBBuildProxy",
        src:find("DB%s*=%s*EC_DBBuildProxy%(") ~= nil,
        "DB must be the metatable proxy so per-char vs account-wide routing happens automatically at every call site"
    )

    check(
        "DB proxy uses metatable __index branching on PER_CHAR_FIELDS",
        src:find("__index%s*=%s*function") ~= nil and src:find("PER_CHAR_FIELDS%[k%]") ~= nil,
        "the proxy __index must branch on PER_CHAR_FIELDS membership; routing every read through PER_CHAR_FIELDS preserves the existing `DB.foo` call-site shape"
    )

    check(
        "DB proxy uses metatable __newindex branching on PER_CHAR_FIELDS",
        src:find("__newindex%s*=%s*function") ~= nil,
        "the proxy __newindex must route writes by PER_CHAR_FIELDS membership so per-character mutations don't leak to the account-wide top level"
    )

    -- Strip line + block comments so docstrings that mention the banned
    -- pattern in their explanation don't false-positive (matches the
    -- approach in Test 65). Only the executable assignment is forbidden.
    local srcCode = src:gsub("%-%-[^\n]*", ""):gsub("%-%-%[%[.-%]%]", "")
    check(
        "PLAYER_LOGOUT does NOT reassign EbonClearanceDB to DB",
        srcCode:find("EbonClearanceDB%s*=%s*DB[^%w_]") == nil
            and not srcCode:match("EbonClearanceDB%s*=%s*DB$"),
        "with DB as a proxy, the assignment that used to live in PLAYER_LOGOUT would overwrite the SavedVariable with an empty proxy table and wipe the user's data on next logout. The PLAYER_LOGOUT branch must not contain this assignment."
    )

    -- v2.34.x cross-character cleanup. Locks that the initial migration's
    -- merged-blacklist leak is repaired and gated by a one-shot per-char
    -- flag so it can't re-fire and clobber live data on each /reload.
    check(
        "EnsureDB cleanup gates on per-char _migratedV2 flag",
        srcCode:find("charNS%._migratedV2") ~= nil
            and srcCode:find("charNS%._migratedV2%s*=%s*true") ~= nil,
        "the cleanup must run exactly once per character. Without the gate, every /reload would re-drop blacklist entries the live auto-protect paths just re-added under this character's authoritative login."
    )

    check(
        "EnsureDB cleanup drops blacklist entries flagged in the legacy snapshot",
        srcCode:find("legacyAuto%s*=%s*EbonClearanceDB%.blacklistAuto") ~= nil
            and srcCode:find("charNS%.blacklist%[id%]%s*=%s*nil") ~= nil,
        "items present in the legacy snapshot's blacklistAuto were auto-added pre-migration (potentially by a DIFFERENT character) and must be dropped from this character's Keep list. Manual entries (no blacklistAuto tag) stay because they were explicit user intent."
    )

    check(
        "EnsureDB cleanup also clears matching entries from chars[k].blacklistAuto",
        srcCode:find("charNS%.blacklistAuto%[id%]%s*=%s*nil") ~= nil,
        "the per-character blacklistAuto map was deep-copied from the legacy snapshot at v2.34.0 migration time; the cleanup must clear the same set of legacy IDs from it too, so live auto-protect paths can repopulate authentically."
    )

    check(
        "EnsureDB cleanup arms pendingFreshInstallSync so live equip path repopulates",
        srcCode:find("EC_compCache%.pendingFreshInstallSync%s*=%s*true") ~= nil,
        "after dropping legacy auto entries, the live equipment sync must re-add the gear this character is currently wearing under their own login. The pendingFreshInstallSync flag is consumed by the PLAYER_LOGIN handler with a 2 s settle delay."
    )
end

-- ---------------------------------------------------------------------------
-- Test 67 (v2.34.x): bagSlotAffixData cache-poison guard.
-- ---------------------------------------------------------------------------
-- Background. A user reported that an Epic Rare/affixed item kept getting
-- vendored despite EC_AnnotateTooltip correctly displaying the
-- "Keep (new affix)" protection label. EC_IsSellable's affix gate calls
-- EC_compCache.bagSlotAffixData(bag, slot); the live-tooltip path that
-- the tooltip annotation uses doesn't share that helper. The divergence
-- traced to bagSlotAffixData's per-itemString cache: the original
-- implementation cached `false` unconditionally whenever parseAffixFromTitle
-- returned nil. Fresh affixed drops sometimes hit bagSlotAffixData BEFORE
-- the link's suffix-DBC field had been fully resolved client-side, so the
-- tooltip's TextLeft1 hadn't yet been populated with the affix-suffixed
-- name. The cold-cache scan failed to parse, cached `false`, and the
-- entry never got re-scanned for the rest of the session - while the
-- live tooltip (no cache) kept reading the now-populated title and
-- correctly identifying the affix.
--
-- Fix: only cache `false` when the title positively identifies the item
-- as not a PE roguelite affix - title is non-empty AND doesn't end with
-- a trailing roman-numeral rank suffix. Empty / cold titles are NOT
-- cached so the next call retries after the link loads.
--
-- This test locks the guard so a future regression that drops the
-- stability check would fail loudly in CI.
do
    -- Pull the bagSlotAffixData body out of the concatenated source.
    -- The function ends at the first `^end$` after the function header.
    local fnStart = src:find("function EC_compCache%.bagSlotAffixData%(")
    local body
    if fnStart then
        local searchFrom = fnStart
        local headerEnd = src:find("\n", searchFrom)
        if headerEnd then
            -- Find the matching end by scanning for the next line that is
            -- exactly `end` after our function start.
            local endPos = src:find("\nend\n", headerEnd, true)
            if endPos then
                body = src:sub(fnStart, endPos + 4)
            end
        end
    end

    check(
        "bagSlotAffixData function located",
        body ~= nil,
        "the cache-poison guard test cannot run without the function body; check Protection.lua hasn't been refactored away from a top-level `function EC_compCache.bagSlotAffixData(` definition"
    )

    if body then
        check(
            "bagSlotAffixData does not cache `false` unconditionally on parse failure",
            body:find("EC_compCache%.affixDataCache%[itemString%]%s*=%s*false") ~= nil
                and body:find("stableNoAffix") ~= nil,
            "the cache must be gated by a positive non-affix discriminator (title without a trailing roman-numeral rank suffix). Caching `false` unconditionally on parseAffixFromTitle returning nil reproduces the cold-tooltip cache-poison bug: a fresh affixed drop scanned before its title fully populated would be permanently masked, and EC_IsSellable would vendor the item despite EC_AnnotateTooltip correctly protecting it."
        )

        check(
            "bagSlotAffixData inspects the title text for the roman-suffix discriminator",
            body:find("titleText:match%(\" %[IVXLCDM%]%+\\?%$\"%)") ~= nil
                or body:find("titleText:match%(\" %[IVXLCDM%]\\?%+%\\?%$\"%)") ~= nil
                or body:find("%[IVXLCDM%]%+\\?%$") ~= nil,
            "the no-affix-cache guard depends on a roman-suffix absence check against the live title text - if the discriminator is changed or removed, the cold-tooltip cache-poison regression reappears"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 68 (v2.35.x): Gold-per-hour fields are partitioned per-character.
-- ---------------------------------------------------------------------------
-- The new bestGPH / bestGPHAt / bestGPHZone fields must live in
-- PER_CHAR_FIELDS so the v2.34.0 per-character partition migrates them
-- correctly. Without this, the GPH record would be account-wide and
-- every character would inherit the best from whichever character
-- happened to set it last. See
-- docs/specs/2026-05-26-gph-stats-design.md for the design.
do
    local gphFields = { "bestGPH", "bestGPHAt", "bestGPHZone" }
    for _, name in ipairs(gphFields) do
        check(
            "PER_CHAR_FIELDS includes " .. name,
            src:find(name .. "%s*=%s*true") ~= nil,
            "the GPH best-record field " .. name .. " must be in PER_CHAR_FIELDS so it routes through the per-character namespace; otherwise every character would share one record and the v2.34.0 partition would be silently violated"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 69 (v2.35.x): MainPanel GPH logic wires the 5-minute gate
-- and writes all three best-record fields atomically.
-- ---------------------------------------------------------------------------
-- The MainPanel RefreshStats body must:
--   * Read EC_session.startedAt (or NS.session.startedAt) for elapsed time
--   * Apply the 5-minute (300s) minimum-session gate before updating best
--   * Write DB.bestGPH, DB.bestGPHAt, and DB.bestGPHZone together when
--     the gate passes (no partial writes)
--
-- A regression that drops the 5-minute gate would let a 3-second
-- burst inflate the best forever. A regression that writes only
-- bestGPH without the timestamp / zone would render the second-line
-- context wrong ("Best ... in <stale zone>, <stale date>").
do
    local f = io.open("EbonClearance_MainPanel.lua", "r")
    local panelSrc
    if f then
        panelSrc = f:read("*a")
        f:close()
    end

    check(
        "MainPanel.lua found",
        panelSrc ~= nil,
        "test relies on reading the file directly; check the path or whether the panel has been renamed"
    )

    if panelSrc then
        check(
            "MainPanel reads session.startedAt for GPH elapsed time",
            panelSrc:find("session%.startedAt") ~= nil,
            "the session start timestamp must be read from EC_session.startedAt (or NS.session.startedAt) so the GPH rate calculation has the right base"
        )

        check(
            "MainPanel applies the 5-minute (300s) gate before updating best",
            panelSrc:find("elapsed%s*>=%s*300") ~= nil,
            "the bestGPH update must require at least 300 seconds of session to filter early-session burst noise; a missing gate lets a 3-second burst inflate the best"
        )

        check(
            "MainPanel writes DB.bestGPH on the best-update path",
            panelSrc:find("DB%.bestGPH%s*=%s*sessionGPH") ~= nil,
            "the bestGPH field must be written when the gate passes; otherwise the user's best record never updates"
        )

        check(
            "MainPanel writes DB.bestGPHAt on the best-update path",
            panelSrc:find("DB%.bestGPHAt%s*=%s*time%(%)") ~= nil
                or panelSrc:find("DB%.bestGPHAt%s*=%s*now") ~= nil,
            "the bestGPHAt timestamp must be written together with bestGPH so the panel can render the 'X days ago' context; a stale bestGPHAt would describe the wrong session. The write may use `time()` directly OR a `now` local hoisted from the same scope (v2.38.1: hoisted so the per-character DB and account-wide ADB writes share one timestamp)."
        )

        check(
            "MainPanel writes DB.bestGPHZone on the best-update path",
            panelSrc:find("DB%.bestGPHZone") ~= nil and panelSrc:find("GetRealZoneText") ~= nil,
            "the bestGPHZone snapshot via GetRealZoneText() must be written together with bestGPH so the panel can render the 'in <zone>' context"
        )

        check(
            "MainPanel uses a 10-second floor on session GPH rate calculation",
            panelSrc:find("elapsed%s*>=%s*10") ~= nil,
            "sub-10s extrapolation produces absurd Gold/Hour values (selling 1 grey in 1 second = thousands of g/h); the spec mandates a 10-second floor before the live rate displays"
        )

        check(
            "Reset Lifetime button zeroes bestGPH/At/Zone",
            panelSrc:find("DB%.bestGPH%s*=%s*0") ~= nil
                and panelSrc:find('DB%.bestGPHZone%s*=%s*""') ~= nil,
            "the Reset Lifetime button must wipe all three GPH best-record fields; partial reset (e.g., bestGPH back to 0 but stale bestGPHAt/Zone left in place) would render nonsensical 'Best 0g 0s 0c in <zone>' text on the next show"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 70 (v2.35.1): family-name fallback for the affix tooltip label.
-- ---------------------------------------------------------------------------
-- PE's item-side @affix@ line and spellbook-side engraving description can
-- disagree at the same rank (e.g. "Overwhelming Force II" item reads
-- "Increases your damage and healing done by 2%" while the engraving
-- spell tooltip reads "Increases damage and healing done by 4%" - same
-- rank, different wording AND different magnitude). The description-only
-- catalog match silently fails in that case and the tooltip falls back to
-- "Keep (new affix)" even though the player demonstrably owns the family.
--
-- v2.35.1 adds a family-name fallback: knownAffixFamilies set populated
-- during the spellbook walk + ExtractionService merge, queried by
-- playerHasAffixFamily when the description match misses. Distinct label
-- "Keep (other rank known)" surfaces the family-only match so users
-- aren't misled. Sell behaviour unchanged - autoDupe stays exact-rank.
do
    check(
        "Protection.lua declares knownAffixFamilyRanks nested catalog",
        src:find("EC_compCache%.knownAffixFamilyRanks%s*=%s*{}") ~= nil,
        "the family + rank fallback needs a nested map keyed by normalised family name with a per-family set of integer ranks; the v2.35.1 hotfix needs the rank dimension to distinguish 'same rank PE-data-disagrees' from 'different rank entirely'"
    )

    check(
        "Protection.lua defines normaliseAffixFamily helper",
        src:find("function EC_compCache%.normaliseAffixFamily%(") ~= nil,
        "normalisation must strip the leading 'of ' prefix common on item-parsed names AND the trailing roman-numeral rank common on spellbook names so both sources collapse to the same key"
    )

    check(
        "Protection.lua defines parseAffixNameRank helper",
        src:find("function EC_compCache%.parseAffixNameRank%(") ~= nil,
        "the catalog populator needs to extract (family, rank) from raw spell / ExtractionService names like 'Overwhelming Force II'; parseAffixNameRank does this via the existing roman-numeral parser"
    )

    check(
        "Protection.lua defines playerHasAffixFamily helper",
        src:find("function EC_compCache%.playerHasAffixFamily%(") ~= nil,
        "family-only lookup (any rank owned) drives the 'Keep (other rank known)' label - distinct from the exact (family, rank) check below"
    )

    check(
        "Protection.lua defines playerHasAffixRank helper",
        src:find("function EC_compCache%.playerHasAffixRank%(") ~= nil,
        "exact (family, rank) lookup is the load-bearing addition - it catches the case where the player has rank N learned but PE's item-side text differs from the spell-side text. Without this, the v2.35.1 fix would keep mislabelling that case 'other rank known'"
    )

    check(
        "Spellbook walk caches (family, rank) tables, not just family strings",
        src:find("spellbookFamilyCache") ~= nil
            and src:find("EC_compCache%.parseAffixNameRank%(sname%)") ~= nil,
        "the spell tooltip walk must capture rank via parseAffixNameRank so the cached entry carries both family and rank; family-only caching would lose the rank dimension and force a re-scan"
    )

    check(
        "ExtractionService merge captures (family, rank) from r.name",
        src:find("EC_compCache%.parseAffixNameRank%(tostring%(r%.name%)%)") ~= nil,
        "PE's ExtractionService records carry the affix name in r.name with the rank suffix; parseAffixNameRank extracts both during async (OnUpdate) AND synchronous (refreshExtractionIfDirty) merges so the family + rank catalog is complete from either entry path"
    )

    check(
        "refreshKnownAffixes scan state initialises families = {}",
        src:find("families%s*=%s*{}") ~= nil,
        "the scan state must seed an empty families set so the chunked walk has somewhere to push family entries; without it the OnUpdate body errors on nil-index of st.families"
    )

    check(
        "Spellbook walk completion assigns knownAffixFamilyRanks",
        src:find("EC_compCache%.knownAffixFamilyRanks%s*=%s*families") ~= nil,
        "the chunked walk must atomically publish the completed nested map to EC_compCache so subsequent playerHasAffixRank / playerHasAffixFamily lookups see the new data"
    )

    check(
        "Tooltip.lua computes playerKnowsRank as the description-fail fallback",
        src:find("playerKnowsRank") ~= nil
            and src:find("playerHasAffixRank%(affix%.name,%s*affix%.rank%)") ~= nil,
        "the (family, rank) check rescues the case where description match misses but the player demonstrably owns this rank (PE's item-side and spell-side text disagree at the same rank)"
    )

    check(
        "Tooltip.lua collapses playerKnows / playerKnowsRank into 'Keep (affix rank known)'",
        src:find("playerKnows%s+or%s+playerKnowsRank") ~= nil
            and src:find("Keep %(affix rank known%)") ~= nil,
        "exact-rank ownership via EITHER description match OR family-rank match must render the same 'Keep (affix rank known)' label - they mean the same thing collection-wise"
    )

    check(
        "Tooltip.lua uses 'Keep (affix rank needed)' for not-this-rank cases",
        src:find("Keep %(affix rank needed%)") ~= nil,
        "the player-doesn't-own-this-rank label covers BOTH 'completely new family' and 'have a different rank' in one collector-focused message ('I need this rank'). Distinct from the older three-label scheme which split family-known-but-rank-differs into 'other rank known' - that distinction was noise; what matters is 'do I need this specific rank?'"
    )

    check(
        "Tooltip.lua does NOT use the legacy 'Keep (new affix)' label",
        src:find("Keep %(new affix%)") == nil,
        "v2.35.1 collapses the new-family-and-different-rank distinction into 'Keep (affix rank needed)'; keeping the old 'new affix' label alongside would be redundant and confusing"
    )

    check(
        "Tooltip.lua does NOT use the legacy 'Keep (other rank known)' label",
        src:find("Keep %(other rank known%)") == nil,
        "v2.35.1 collapses the family-known-but-different-rank case into 'Keep (affix rank needed)' - same outcome from a collection POV"
    )

    -- v2.35.1 follow-up: the autoDupe-only branch must gate the
    -- "Will Sell (you have this affix)" label on an upstream
    -- "Will Sell" verdict existing in statusLine. Without that gate,
    -- the tooltip lies for any item whose quality rule is disabled or
    -- whose itemID isn't on any sell list: dupe-allow only releases
    -- the affix protection from vetoing, it doesn't add a sell signal,
    -- so the merchant cycle won't actually sell the item. The user-
    -- visible regression was an Epic item with Epic rule disabled
    -- showing "Will Sell (you have this affix)" but /ec sellinfo
    -- correctly reporting "won't sell - no rule matched".
    do
        local tooltipFile = io.open("EbonClearance_Tooltip.lua", "rb")
        if tooltipFile then
            local ttSrc = tooltipFile:read("*a") or ""
            tooltipFile:close()
            -- Find the autoDupe-only branch (the else after manualAllow
            -- inside the `if manualAllow or autoDupe` block).
            check(
                "autoDupe-only Will-Sell label is gated on upstream Will-Sell verdict",
                ttSrc:find('Will Sell %(you have this affix%)') ~= nil
                    and ttSrc:find('statusTag == "willsell"') ~= nil,
                "the 'Will Sell (you have this affix)' label must only fire when an upstream 'Will Sell' verdict already exists. v2.43.0 localized the labels, so the gate reads the English statusTag token (statusTag == \"willsell\") instead of introspecting the displayed string. Without this gate, the label fires for items that won't actually sell (quality rule disabled, not on any list) and creates a tooltip-vs-vendor divergence"
            )
            check(
                "autoDupe-only fallback when no upstream sell verdict is 'Keep (affix rank known)'",
                ttSrc:find('Keep %(affix rank known%)') ~= nil,
                "when dupe-allow is on but no rule fires, the tooltip must say 'Keep (affix rank known)' - the dupe-allow only releases the affix protection, it doesn't make the item sellable on its own"
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 71-77: v2.36.x Help / FAQ panel invariants.
-- ---------------------------------------------------------------------------
-- The Help panel ships a flat EC_HELP_ENTRIES table that drives the
-- rendered FAQ. The build callback splits the list on section markers
-- and renders each entry as a question + answer pair plus optional
-- "Open <panel>" button. These tests pin the structural invariants
-- (file present, section markers exist, frame exists, per-character
-- collapse state is partitioned correctly, slash help line exists,
-- chrome backdrop is applied) so a future contributor who renames a
-- helper or trims an entry by mistake gets a loud failure.
do
    local helpFile = io.open("EbonClearance_HelpPanel.lua", "rb")
    local helpSrc = nil
    if helpFile then
        helpSrc = helpFile:read("*a") or ""
        helpFile:close()
    end

    check(
        "Test 71: EbonClearance_HelpPanel.lua exists",
        helpSrc ~= nil,
        "Help / FAQ panel source file must be present at repo root"
    )

    if helpSrc then
        check(
            "Test 72: HelpPanel registers EbonClearanceOptionsHelp Interface Options frame",
            helpSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsHelp"') ~= nil
                and helpSrc:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsHelp"%]') ~= nil,
            "Help panel must create a frame named EbonClearanceOptionsHelp and register it with InterfaceOptions_AddCategory so /ec help can jump to it"
        )

        check(
            "Test 73: HelpPanel declares all six section markers",
            helpSrc:find('section = "gettingStarted"') ~= nil
                and helpSrc:find('section = "troubleshooting"') ~= nil
                and helpSrc:find('section = "gates"') ~= nil
                and helpSrc:find('section = "labels"') ~= nil
                and helpSrc:find('section = "processBags"') ~= nil
                and helpSrc:find('section = "discord"') ~= nil,
            "The six sections (gettingStarted, troubleshooting, gates, labels, processBags, discord) must each appear as a section marker entry in EC_HELP_ENTRIES so the build callback groups content correctly"
        )

        -- Count q/a pairs - rough invariant on entry table size.
        local entryCount = 0
        for _ in helpSrc:gmatch("\n%s*q = ") do
            entryCount = entryCount + 1
        end
        check(
            "Test 74: HelpPanel has at least 40 content entries",
            entryCount >= 40,
            "EC_HELP_ENTRIES must contain at least 40 q+a content entries (5 gettingStarted + 10 troubleshooting + 16 gates + 22 labels + 3 discord was the v2.36.x baseline); found " .. tostring(entryCount)
        )

        check(
            "Test 75: HelpPanel applies the v2.32.x list-panel chrome backdrop",
            helpSrc:find("applyChromeBackdrop") ~= nil
                and helpSrc:find('bgFile = "Interface\\\\Tooltips\\\\UI%-Tooltip%-Background"') ~= nil
                and helpSrc:find('edgeFile = "Interface\\\\Tooltips\\\\UI%-Tooltip%-Border"') ~= nil
                and helpSrc:find("edgeSize = 12") ~= nil,
            "Help panel must wrap its content area in a chrome-backdropped frame using the same UI-Tooltip-Border + edgeSize=12 + brown tint pattern as Process Bags / Sell List / Keep List / Profiles"
        )
    end

    -- Test 76: PER_CHAR_FIELDS must declare helpSectionsCollapsed so the
    -- v2.34.x partition routes the per-character key correctly. Without
    -- this entry, the collapse state would be account-wide and the
    -- v2.34.x SavedVariables-partition migration would not migrate it.
    do
        local eventsFile = io.open("EbonClearance_Events.lua", "rb")
        if eventsFile then
            local eventsSrc = eventsFile:read("*a") or ""
            eventsFile:close()
            check(
                "Test 76: PER_CHAR_FIELDS includes helpSectionsCollapsed",
                eventsSrc:find("helpSectionsCollapsed = true") ~= nil,
                "PER_CHAR_FIELDS in EbonClearance_Events.lua must include `helpSectionsCollapsed = true` so the per-character partition migrates the collapse state correctly"
            )

            check(
                "Test 77: /ec help mentions the Help panel",
                eventsSrc:find("Help panel in Interface Options") ~= nil,
                "The /ec help slash-command output must include a pointer to the new Help panel so players know it exists"
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 80: v2.36.x Stats sub-panel split.
-- ---------------------------------------------------------------------------
-- Stats widgets (statsMoney, statsSold, statsDeleted, statsRepairs,
-- statsRepairCost, statsSessionGPH, statsBestGPH, statsAvgWorth,
-- statsMostSold, statsNote, EbonClearanceResetStatsBtn) used to live on
-- the Main panel. v2.36.x moves them to a dedicated Stats panel so the
-- Main panel can read as a welcome page and Stats has room to grow.
do
    local statsFile = io.open("EbonClearance_StatsPanel.lua", "rb")
    local statsSrc = nil
    if statsFile then
        statsSrc = statsFile:read("*a") or ""
        statsFile:close()
    end

    check(
        "Test 80: EbonClearance_StatsPanel.lua exists",
        statsSrc ~= nil,
        "Stats sub-panel source file must be present at repo root"
    )

    if statsSrc then
        -- Test 80a: the Stats frame is created in EbonClearance_StatsPanel.lua,
        -- but InterfaceOptions_AddCategory is called from EbonClearance_Events.lua
        -- so the sub-panel sort position is controlled at one place. Verify
        -- both halves. Sort order: Main / Merchant / Protection / Scavenger
        -- / Highlighting / Stats / Sell List / ... (main settings first,
        -- then Stats, then the list group). The test pins the boundary by
        -- checking Highlighting -> Stats -> Whitelist (Sell List) appear in
        -- that order.
        local evFile = io.open("EbonClearance_Events.lua", "rb")
        local evSrc = evFile and evFile:read("*a") or ""
        if evFile then evFile:close() end
        check(
            "Test 80a: Stats panel registers EbonClearanceOptionsStats frame",
            statsSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsStats"') ~= nil
                and evSrc:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsStats"%]') ~= nil
                and evSrc:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsCharacter"%][%s%S]-InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsStats"%][%s%S]-InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsWhitelist"%]') ~= nil,
            "Stats panel must create a frame named EbonClearanceOptionsStats (in StatsPanel.lua) and Events.lua must register it via InterfaceOptions_AddCategory between Item Highlighting and Sell List (sort order: main settings first, then Stats, then the list group)"
        )

        check(
            "Test 80b: Stats panel attaches statsMoney + statsSessionGPH + statsBestGPH fields",
            statsSrc:find("panel%.statsMoney") ~= nil
                and statsSrc:find("panel%.statsSessionGPH") ~= nil
                and statsSrc:find("panel%.statsBestGPH") ~= nil,
            "Stats panel must hang the same panel.statsX attachments that MainPanel used to, so RefreshStats can write to them after the split"
        )
    end

    -- MainPanel post-split should NO LONGER create stats widgets.
    local mainFile = io.open("EbonClearance_MainPanel.lua", "rb")
    if mainFile then
        local mainSrc = mainFile:read("*a") or ""
        mainFile:close()
        check(
            "Test 80c: MainPanel no longer creates statsMoney FontString",
            mainSrc:find('panel%.statsMoney = money') == nil
                and mainSrc:find("statsMoney = content:CreateFontString") == nil,
            "After v2.36.x split, MainPanel must not attach statsMoney; that lives on the new Stats panel"
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 79: every Help entry has a non-empty unique id.
-- ---------------------------------------------------------------------------
-- Settings panels deep-link into Help via these ids (see NS.AddHelpIcon /
-- NS.OpenHelpEntry, added in later tasks). If two entries share an id,
-- the deep-link is ambiguous; if an entry lacks an id, no panel can
-- link to it. Counts unique ids and asserts no duplicates.
do
    local helpFile = io.open("EbonClearance_HelpPanel.lua", "rb")
    if helpFile then
        local hsrc = helpFile:read("*a") or ""
        helpFile:close()
        local idsSeen = {}
        local duplicates = {}
        for id in hsrc:gmatch('id = "([^"]+)"') do
            if idsSeen[id] then
                duplicates[#duplicates + 1] = id
            end
            idsSeen[id] = (idsSeen[id] or 0) + 1
        end
        local count = 0
        for _ in pairs(idsSeen) do count = count + 1 end
        check(
            "Test 79: at least 40 unique help entry ids exist",
            count >= 40 and #duplicates == 0,
            "Help entries must have unique id fields. Count: " .. count .. " unique; duplicates: " .. table.concat(duplicates, ", ")
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 82: NS.AddHelpIcon widget primitive exists in PanelWidgets.lua.
-- ---------------------------------------------------------------------------
-- v2.36.x: settings panels deep-link into the Help panel via small [?]
-- icons. The widget primitive lives in EbonClearance_PanelWidgets.lua
-- alongside NS.MakeHeader / NS.MakeLabel / NS.AddCheckbox.
do
    local f = io.open("EbonClearance_PanelWidgets.lua", "rb")
    if f then
        local src = f:read("*a") or ""
        f:close()
        check(
            "Test 82: NS.AddHelpIcon helper is defined",
            src:find("NS%.AddHelpIcon") ~= nil
                and src:find("function .*MakeHelpIcon") ~= nil
                and src:find("NS%.OpenHelpEntry") ~= nil,
            "EbonClearance_PanelWidgets.lua must define MakeHelpIcon and expose it as NS.AddHelpIcon. The OnClick must call NS.OpenHelpEntry(entryId) if it exists."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 83: NS.OpenHelpEntry deep-link API + scroll-to-entry + flash.
-- ---------------------------------------------------------------------------
-- Settings panels call NS.AddHelpIcon (PanelWidgets.lua), which on click
-- invokes NS.OpenHelpEntry(entryId). That function lives in HelpPanel.lua
-- and must: (a) stash the pending entry id on HelpPanel, (b) auto-expand
-- the owning section via DB.helpSectionsCollapsed, (c) open the Help
-- panel via InterfaceOptionsFrame_OpenToCategory (called twice for the
-- 3.3.5a workaround). The refreshLayout pass then consumes the pending
-- target: scrolls the entry to the top of the viewport, flashes briefly.
do
    local f = io.open("EbonClearance_HelpPanel.lua", "rb")
    if f then
        local src = f:read("*a") or ""
        f:close()
        check(
            "Test 83: NS.OpenHelpEntry exists with required wiring",
            src:find("function NS%.OpenHelpEntry") ~= nil
                and src:find("InterfaceOptionsFrame_OpenToCategory") ~= nil
                and src:find("helpSectionsCollapsed") ~= nil
                and src:find("_scrollGeneration") ~= nil,
            "HelpPanel.lua must define NS.OpenHelpEntry that expands the owning section via DB.helpSectionsCollapsed, opens the panel via InterfaceOptionsFrame_OpenToCategory, and uses a _scrollGeneration counter so rapid clicks supersede cleanly."
        )
        check(
            "Test 83a: OpenHelpEntry schedules SetVerticalScroll + flash with generation guard",
            src:find("SetVerticalScroll") ~= nil
                and src:find('|cff00ffff') ~= nil
                and src:find("NS%.Delay") ~= nil
                and src:find("HelpPanel%._scrollGeneration ~= gen") ~= nil,
            "OpenHelpEntry must schedule a delayed scroll (SetVerticalScroll on the outer scroll frame) and a visible flash (swap inline |cffffff00 for |cff00ffff on the q FontString, then restore), both gated by a generation check so a superseded click's tasks no-op."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 78: every NS.AddHelpIcon entryId references a real Help entry.
-- ---------------------------------------------------------------------------
-- Settings panels deep-link into Help via NS.AddHelpIcon(..., "entryId").
-- This test scans every panel source file for those calls, extracts the
-- referenced entry id (the last quoted string arg before the closing
-- paren), and asserts each id exists as `id = "..."` in EC_HELP_ENTRIES
-- (EbonClearance_HelpPanel.lua). Catches drift when a Help entry is
-- removed or renamed without updating the panels that link to it.
do
    local helpFile = io.open("EbonClearance_HelpPanel.lua", "rb")
    if helpFile then
        local helpSrc = helpFile:read("*a") or ""
        helpFile:close()
        local definedIds = {}
        for id in helpSrc:gmatch('id = "([^"]+)"') do
            definedIds[id] = true
        end

        local panelFiles = {
            "EbonClearance_ProtectionPanel.lua",
            "EbonClearance_MerchantPanel.lua",
            "EbonClearance_ScavengerPanel.lua",
            "EbonClearance_ItemHighlightingPanel.lua",
            "EbonClearance_ProcessBagsPanel.lua",
            "EbonClearance_SellListPanels.lua",
            "EbonClearance_KeepDeletePanels.lua",
            "EbonClearance_ProfilesPanel.lua",
            "EbonClearance_MainPanel.lua",
            "EbonClearance_StatsPanel.lua",
        }
        local missing = {}
        for _, fname in ipairs(panelFiles) do
            local pf = io.open(fname, "rb")
            if pf then
                local psrc = pf:read("*a") or ""
                pf:close()
                -- Match NS.AddHelpIcon(parent, anchor, p1, p2, x, y, "entryId")
                -- Pattern: capture the last quoted string before the ")".
                for id in psrc:gmatch('AddHelpIcon%([^)]-"([^"]+)"%s*%)') do
                    if not definedIds[id] then
                        missing[#missing + 1] = fname .. " -> " .. id
                    end
                end
            end
        end
        check(
            "Test 78: every NS.AddHelpIcon entryId exists in EC_HELP_ENTRIES",
            #missing == 0,
            "Settings panels reference these missing help ids: " .. table.concat(missing, "; ")
        )
    end
end

-- ---------------------------------------------------------------------------
-- Tests 84-85: Mill / Prospect tooltip-scan robustness.
-- ---------------------------------------------------------------------------
-- Two distinct bugs hid the PROSPECT section from Process Bags:
--
--   1) Color-code wrapping: the byte-exact `txt == marker` compare failed
--      against `|cFFFFFF00Prospectable|r`. Fixed by normaliseTooltipLine
--      (strips |c...|r and trims). Test 84 pins it.
--
--   2) Cache poisoning: canMill and canProspect shared one processCache
--      with a "none" sentinel meaning "scanned, no match found", but
--      ambiguous about WHICH marker was searched. With both Inscription
--      and Jewelcrafting trained, canMill ran first for every item; ore
--      missed the Millable marker, got cached as "none", and canProspect
--      then returned false without ever scanning. v2.36.x unifies the
--      scan: one pass per itemID checks BOTH markers and caches the
--      classification (Mill / Prospect / none). Test 85 pins it.
do
    local f = io.open("EbonClearance_Process.lua", "rb")
    if f then
        local src = f:read("*a") or ""
        f:close()
        check(
            "Test 84: processTooltipHasLine strips color codes before marker compare",
            src:find("normaliseTooltipLine") ~= nil
                and src:find("|c%%x%%x%%x%%x%%x%%x%%x%%x") ~= nil
                and src:find("local txt = normaliseTooltipLine%(line:GetText%(%)%)") ~= nil
                and src:find("if txt == millMarker") ~= nil
                and src:find("txt == prospectMarker") ~= nil,
            "EbonClearance_Process.lua must define normaliseTooltipLine (color-strip + trim) and use it inside processTooltipHasLine's loop to normalise each tooltip line before comparing against the Mill / Prospect markers. The byte-exact `txt == marker` compare against the raw color-wrapped line silently broke Mill / Prospect detection."
        )

        check(
            "Test 85: processTooltipHasLine scans both Mill + Prospect markers in one pass",
            src:find("local millMarker = ITEM_MILLABLE") ~= nil
                and src:find("local prospectMarker = ITEM_PROSPECTABLE") ~= nil
                and src:find('result = "Mill"') ~= nil
                and src:find('result = "Prospect"') ~= nil
                and src:find("function EC_compCache%.processTooltipHasLine%(bag, slot, itemID%)") ~= nil,
            "processTooltipHasLine must scan for BOTH markers in one tooltip pass and cache the resulting classification. The previous single-marker API let canMill poison the cache with 'none' before canProspect could scan, hiding the PROSPECT section for any player with both professions trained."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 86: Delete List wins over sell signals (cycle + trace agreement).
-- ---------------------------------------------------------------------------
-- Pre-v2.37.0 BuildQueue checked EC_IsSellable first and only fell
-- through to the Delete-List branch when the item was not sellable. A
-- grey item on the Delete List was queued as a sell because greyAutoSell
-- returned true. The bag tint + tooltip annotation followed the inverse
-- order ("delete" tint wins) so the cycle and the UI disagreed. v2.37.0
-- reversed BuildQueue's per-slot dispatch: the Delete-List branch fires
-- first, and the sell branch only runs when the slot did not queue a
-- delete. describeSellability got a parallel Delete-List step + a
-- WILL DELETE summary override so /ec sellinfo agrees with the cycle.
do
    local evf = io.open("EbonClearance_Events.lua", "rb")
    local bdf = io.open("EbonClearance_BagDisplay.lua", "rb")
    if evf and bdf then
        local evSrc = evf:read("*a") or ""
        evf:close()
        local bdSrc = bdf:read("*a") or ""
        bdf:close()

        -- BuildQueue: the Delete-List check (now delegated to
        -- EC_compCache.deleteListSlotEligible) must appear before the
        -- `EC_IsSellable(bag, slot,` call inside the bag-walk loop.
        -- v2.42.0: the inline IsInSet(DB.deleteList, id) check moved into the
        -- shared deleteListSlotEligible helper so vendor-delete and
        -- auto-delete-on-pickup apply identical policy. BuildQueue now
        -- calls deleteListSlotEligible; the ordering invariant is verified
        -- by finding the helper call before EC_IsSellable in the function body.
        local fnStart = evSrc:find("local function BuildQueue%(")
        local fnEnd = fnStart and evSrc:find("\nend\n", fnStart) or nil
        local body = fnStart and fnEnd and evSrc:sub(fnStart, fnEnd) or ""
        local deleteCheckPos = body:find('deleteListSlotEligible%(bag, slot%)')
        local sellableCheckPos = body:find("EC_IsSellable%(bag, slot,")
        check(
            "Test 86: BuildQueue checks Delete List BEFORE EC_IsSellable",
            deleteCheckPos ~= nil
                and sellableCheckPos ~= nil
                and deleteCheckPos < sellableCheckPos,
            "BuildQueue must call deleteListSlotEligible(bag, slot) before EC_IsSellable so explicit destructive intent wins over sell signals (greyAutoSell, Sell List, quality rules). Pre-v2.37.0 had the order reversed and the Delete List silently lost to greyAutoSell on grey items."
        )

        check(
            "Test 86a: describeSellability surfaces a Delete-List verdict + WILL DELETE summary",
            bdSrc:find("deleteListVerdict") ~= nil
                and bdSrc:find("WILL DELETE at the next vendor visit") ~= nil
                and bdSrc:find("local willDelete = onDeleteList and deletionEnabled") ~= nil,
            "describeSellability must add a deleteListVerdict step and override the summary with WILL DELETE when the item is on Delete List + Enable Deletion is on. Otherwise /ec sellinfo would silently disagree with the tooltip + cycle."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 87: v2.37.0 Keep List bag-border highlighting.
-- ---------------------------------------------------------------------------
-- v2.37.0 adds a sixth sell-border category, "keep", that paints a
-- distinct slot border on items the player manually added to the Keep
-- List (DB.blacklist minus DB.blacklistAuto entries). Pure visual-
-- reassurance feature - no behaviour change, just a new colour gated
-- by the existing per-category enable + colour-picker UI.
--
-- The four sub-tests verify the four touch points stay in lockstep:
-- defaults init, resolver order, panel row, Help entry. See
-- docs/specs/2026-05-28-keep-highlighting-design.md.
do
    local evf = io.open("EbonClearance_Events.lua", "rb")
    local bdf = io.open("EbonClearance_BagDisplay.lua", "rb")
    local ihf = io.open("EbonClearance_ItemHighlightingPanel.lua", "rb")
    local hpf = io.open("EbonClearance_HelpPanel.lua", "rb")
    if evf and bdf and ihf and hpf then
        local evSrc = evf:read("*a") or ""
        evf:close()
        local bdSrc = bdf:read("*a") or ""
        bdf:close()
        local ihSrc = ihf:read("*a") or ""
        ihf:close()
        local hpSrc = hpf:read("*a") or ""
        hpf:close()

        check(
            "Test 87: EnsureDB seeds DB.sellBorderCategories.keep with enabled=false default",
            evSrc:find("keep = { enabled = false, color = {") ~= nil
                and evSrc:find("delete = defaultCat%(") ~= nil
                and evSrc:find("accountSell = defaultCat%(") ~= nil,
            "EnsureDB's CAT_DEFAULTS must include a 'keep' entry. Keep ships enabled=false (opt-in) while every other category uses defaultCat() (enabled=true). The asymmetry keeps existing v2.36.x setups visually identical on upgrade - the player has to tick the Keep row to pick up the new tint."
        )

        -- The Keep check must sit between the Delete check and the
        -- IsSellable bail. Keep-listed items return false from
        -- EC_IsSellable (that's the protection mechanism), so the
        -- resolver has to short-circuit before that bail to surface
        -- the "keep" verdict.
        local fnStart = bdSrc:find("function EC_compCache%.bagSlotWillSellCategory%(")
        local fnEnd = fnStart and bdSrc:find("\nend\n", fnStart) or nil
        local body = fnStart and fnEnd and bdSrc:sub(fnStart, fnEnd) or ""
        local deletePos = body:find("IsInSet%(DB%.deleteList,")
        local keepPos = body:find("IsInSet%(DB%.blacklist,")
        local sellablePos = body:find("NS%.IsSellable%(bag, slot,")
        check(
            "Test 87a: bagSlotWillSellCategory checks Keep List between Delete and IsSellable",
            deletePos ~= nil
                and keepPos ~= nil
                and sellablePos ~= nil
                and deletePos < keepPos
                and keepPos < sellablePos,
            "Keep-listed items return false from EC_IsSellable, so the 'keep' verdict has to be resolved BEFORE that bail. Order must be: deleteList -> blacklist (Keep) -> IsSellable -> remaining categories. The blacklistAuto guard excludes auto-protected entries from the manual-only border scope."
        )

        check(
            "Test 87b: Item Highlighting panel registers a 'keep' category row",
            ihSrc:find('{ key = "keep", label = L%["Keep List') ~= nil,
            "Item Highlighting panel's SELL_BORDER_CATEGORIES table must include a 'keep' row so the player can toggle the new border and repaint its colour. Adding the category to EnsureDB without surfacing it in the panel makes it invisible to the user."
        )

        check(
            "Test 87c: tshoot-bag-borders Help entry mentions Keep",
            hpSrc:find("tshoot%-bag%-borders") ~= nil
                and hpSrc:find('"They\'re off by default%..-Delete, Keep, Account Sell') ~= nil,
            "The tshoot-bag-borders Help entry's category list must include Keep alongside the existing categories so the deep-link from the new row's [?] points at accurate text."
        )
    end
end

-- ---------------------------------------------------------------------------
-- Test 88: v2.37.0 Borrows from Ivo's EC fork + Ebon_QoL.
-- ---------------------------------------------------------------------------
-- Three independent borrows landed in v2.37.0:
--   A. AffixDebugDump diagnostic event logger + /ec affixdebug slash
--      sub-command + /ec bugreport integration.
--   B. "Already known by this character" tooltip annotation on tomes /
--      recipes the player has learned. Reuses the existing
--      tomeIsKnownCache from EbonClearance_Protection.lua.
--   C. Item-level text overlay on equippable gear, gated by a master
--      toggle + 3 surface sub-toggles (bags / paperdoll / merchant).
-- See docs/specs/2026-05-28-keep-highlighting-design.md.
do
    local protf = io.open("EbonClearance_Protection.lua", "rb")
    local evf2 = io.open("EbonClearance_Events.lua", "rb")
    local ttf = io.open("EbonClearance_Tooltip.lua", "rb")
    local bdf2 = io.open("EbonClearance_BagDisplay.lua", "rb")
    local ihf2 = io.open("EbonClearance_ItemHighlightingPanel.lua", "rb")
    if protf and evf2 and ttf and bdf2 and ihf2 then
        local protSrc = protf:read("*a") or ""
        protf:close()
        local evSrc = evf2:read("*a") or ""
        evf2:close()
        local ttSrc = ttf:read("*a") or ""
        ttf:close()
        local bdSrc2 = bdf2:read("*a") or ""
        bdf2:close()
        local ihSrc2 = ihf2:read("*a") or ""
        ihf2:close()

        -- Borrow A: AffixDebugDump function + the six call sites
        local hasFn = protSrc:find("local function AffixDebugDump") ~= nil
            and protSrc:find("EC_compCache%.AffixDebugDump = AffixDebugDump") ~= nil
        local kindCount = 0
        for _ in protSrc:gmatch('AffixDebugDump%("bag%.affix%.cache"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("bag%.affix%.scan"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("spellbook%.affix%.hit"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("extraction%.affix%.hit"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("knownAffixes%.start"') do
            kindCount = kindCount + 1
        end
        for _ in protSrc:gmatch('AffixDebugDump%("knownAffixes%.done"') do
            kindCount = kindCount + 1
        end
        local slashOK = evSrc:find('if cmd == "affixdebug" then') ~= nil
            and evSrc:find("affixDebugEnabled") ~= nil
        check(
            "Test 88: Borrow A - AffixDebugDump fn + 6 kind probes + /ec affixdebug slash",
            hasFn and kindCount == 6 and slashOK,
            "AffixDebugDump must be defined, exposed on EC_compCache, called at all six probe sites (bag.affix.cache, bag.affix.scan, spellbook.affix.hit, extraction.affix.hit, knownAffixes.start, knownAffixes.done), and surfaced via /ec affixdebug. Found "
                .. tostring(kindCount)
                .. " call sites (expected 6)."
        )

        -- Borrow B: "Already known by this character" tooltip line.
        check(
            "Test 88a: Borrow B - 'Already known by this character' tooltip annotation",
            ttSrc:find("Already known by this character") ~= nil
                and ttSrc:find("liveTooltipIsTome") ~= nil
                and ttSrc:find("liveTooltipPlayerKnowsTome") ~= nil
                and ttSrc:find('statusTag ~= "tome_have"') ~= nil,
            "EC_AnnotateTooltip must add the 'Already known by this character' line for tome/recipe items the player has learned, gated on liveTooltipIsTome + liveTooltipPlayerKnowsTome, and dedupe against the existing tome-protection block's '(... you have)' label so the same info doesn't render twice. v2.43.0 localized the labels, so the dedupe reads the English statusTag token (statusTag ~= \"tome_have\") instead of introspecting the displayed string."
        )

        -- v2.37.0 polish: affix protection wins over chance-on-hit in
        -- the tooltip annotation when both apply on the same item. PE
        -- rule: chance-on-hit can't be extracted from an affixed item
        -- (must extract affix first), so the affix label is the
        -- meaningful one. Test pins the dedupe pattern that prevents
        -- the chance-on-hit block from overwriting an affix label.
        check(
            "Test 88a-precedence: affix label wins over chance-on-hit in tooltip",
            ttSrc:find('affixKept = %(statusTag == "affixknown"') ~= nil
                and ttSrc:find("elseif affixKept then") ~= nil,
            "EC_AnnotateTooltip's chance-on-hit block must detect an affix-rank Keep verdict already resolved and skip the chance-on-hit override. v2.43.0 localized the labels, so the detection reads the English statusTag token (affixknown / affixneeded) instead of introspecting the displayed string. Without this, items carrying both an affix AND a chance-on-hit proc show 'Keep (chance-on-hit proc)' instead of the more meaningful affix label."
        )

        -- Borrow C: DB schema + renderer + equipLoc whitelist.
        local schemaOK = evSrc:find("DB%.itemLevelOverlay%.enabled = false") ~= nil
            and evSrc:find("DB%.itemLevelOverlay%.bags = true") ~= nil
            and evSrc:find("DB%.itemLevelOverlay%.paperdoll = false") ~= nil
            and evSrc:find("DB%.itemLevelOverlay%.merchant = false") ~= nil
        local rendererOK = bdSrc2:find("function EC_compCache%.applyItemLevelOverlay") ~= nil
            and bdSrc2:find("EC_ITEM_LEVEL_EQUIP_LOCS") ~= nil
            and bdSrc2:find("NS%.RefreshItemLevelOverlay") ~= nil
        check(
            "Test 88b: Borrow C - DB schema + renderer + equipLoc whitelist",
            schemaOK and rendererOK,
            "EnsureDB must seed DB.itemLevelOverlay {enabled=false, bags=true, paperdoll=false, merchant=false}; BagDisplay must define applyItemLevelOverlay + the EC_ITEM_LEVEL_EQUIP_LOCS whitelist + NS.RefreshItemLevelOverlay. Without the schema, the panel toggles read nil and the renderer bails."
        )

        -- Borrow C UI: master + 3 sub-toggles + the sync helper.
        check(
            "Test 88c: Borrow C - Item Highlighting panel surfaces master + 3 sub-toggles",
            ihSrc2:find("EbonClearanceILvlMainCB") ~= nil
                and ihSrc2:find('"EbonClearanceILvlCB_" %.%. sub%.key') ~= nil
                and ihSrc2:find('{ key = "bags"') ~= nil
                and ihSrc2:find('{ key = "paperdoll"') ~= nil
                and ihSrc2:find('{ key = "merchant"') ~= nil
                and ihSrc2:find("syncILvlSubsEnabled") ~= nil,
            "Item Highlighting panel must create the master toggle frame (EbonClearanceILvlMainCB), build the 3 sub-toggle frames via the SUB_TOGGLES loop with keys bags/paperdoll/merchant, and define the syncILvlSubsEnabled helper that greys the subs out when the master is off."
        )

        -- v2.37.0 polish: Borrow C extras - font-size slider, host bag-UI
        -- hook (Bagnon/ElvUI), and panel scroll-wrap so the new section
        -- doesn't push existing content off the visible area.
        check(
            "Test 88d: Borrow C polish - font-size slider + host hook + scroll-wrap",
            ihSrc2:find("EbonClearanceILvlFontSizeSlider") ~= nil
                and bdSrc2:find("function EC_compCache%.installHostBagItemLevelHook") ~= nil
                and bdSrc2:find("EC_applyItemLevelFont") ~= nil
                and ihSrc2:find("function%(self, content%)") ~= nil
                and ihSrc2:find("end, true%)") ~= nil
                and ihSrc2:find("NS%.FitScrollContent%(content,") ~= nil,
            "Borrow C polish must: (a) add EbonClearanceILvlFontSizeSlider in Item Highlighting; (b) define EC_compCache.installHostBagItemLevelHook so the bags surface paints under Bagnon/ElvUI; (c) re-apply font via EC_applyItemLevelFont so slider changes propagate; (d) scroll-wrap the panel via initPanel's wrapScroll arg + FitScrollContent so the new section doesn't push existing content off the visible area."
        )

        -- v2.37.0: parallel (Hit-proc) tag on chance-on-hit-carrying
        -- list entries. Mirrors the (affix-gated) tag's plumbing -
        -- account-scoped table, stamped at list-add + tooltip
        -- backfill, rendered in ListWidget.
        local menuf = io.open("EbonClearance_BagContextMenu.lua", "rb")
        local lwf = io.open("EbonClearance_ListWidget.lua", "rb")
        if menuf and lwf then
            local menuSrc = menuf:read("*a") or ""
            menuf:close()
            local lwSrc = lwf:read("*a") or ""
            lwf:close()
            check(
                "Test 88e: (Hit-proc) tag - schema + add-stamp + tooltip backfill + render",
                evSrc:find('if type%(ADB%.chanceOnHitListedItems%) ~= "table" then') ~= nil
                    and menuSrc:find("ADB%.chanceOnHitListedItems%[itemID%] = true") ~= nil
                    and ttSrc:find("ADB%.chanceOnHitListedItems%[id%] = true") ~= nil
                    and lwSrc:find("procSet and procSet%[id%]") ~= nil
                    and lwSrc:find('%(Hit%-proc%)') ~= nil,
                "Chance-on-hit list entries get a '(Hit-proc)' tag mirroring the affix-gated plumbing: EnsureAccountDB seeds the table; BagContextMenu stamps on add; Tooltip backfills on hover; ListWidget reads the set and appends the tag."
            )
        end

        -- v2.37.0: /ec affixdebug must also appear in the Main panel's
        -- slash command reference (not only the /ec help chat output).
        local mpf = io.open("EbonClearance_MainPanel.lua", "rb")
        if mpf then
            local mpSrc = mpf:read("*a") or ""
            mpf:close()
            check(
                "Test 88f: /ec affixdebug listed in Main panel slash command reference",
                mpSrc:find("/ec affixdebug") ~= nil,
                "The Main panel's Slash Commands section must list /ec affixdebug alongside the other commands so players can discover it without typing /ec help."
            )
        end

        -- v2.38.0: Quickstart wizard. The new EbonClearance_QuickstartPanel.lua
        -- file must register the panel, expose NS.Quickstart.Apply, define
        -- ANSWER_MAP / PRESETS with the four shipped preset keys, and
        -- CRITICALLY must never reference DB.whitelist / DB.blacklist /
        -- DB.deleteList / ADB.whitelist - the wizard writes settings only,
        -- never user list data. Events.lua must define EC_APPLY_QUICKSTART
        -- popup (and not the now-dead EC_WELCOME popup). MainPanel must
        -- render the Quickstart row. EnsureDB must seed _needsQuickstartOpen
        -- on fresh install.
        local qpf = io.open("EbonClearance_QuickstartPanel.lua", "rb")
        local mpf3 = io.open("EbonClearance_MainPanel.lua", "rb")
        if qpf and mpf3 then
            local qpSrc = qpf:read("*a") or ""
            qpf:close()
            local mpSrc3 = mpf3:read("*a") or ""
            mpf3:close()
            check(
                "Test 88m: Quickstart wizard wired + settings-only invariant",
                qpSrc:find("local PRESETS%s*=%s*{") ~= nil
                    and qpSrc:find("recommended") ~= nil
                    and qpSrc:find("cautious") ~= nil
                    and qpSrc:find("farmer") ~= nil
                    and qpSrc:find("power") ~= nil
                    and qpSrc:find("local ANSWER_MAP%s*=%s*{") ~= nil
                    and qpSrc:find("NS%.Quickstart%s*=%s*{") ~= nil
                    and qpSrc:find("autoOpenContainers") ~= nil
                    and qpSrc:find("protectAllTomes") ~= nil
                    and qpSrc:find("itemLevelOverlay%.paperdoll") ~= nil
                    and qpSrc:find("itemLevelOverlay%.merchant") ~= nil
                    and qpSrc:find("maxILvl") ~= nil
                    -- Settings-only invariant: NEVER touch user list data
                    and qpSrc:find("DB%.whitelist") == nil
                    and qpSrc:find("DB%.blacklist") == nil
                    and qpSrc:find("DB%.deleteList") == nil
                    and qpSrc:find("ADB%.whitelist") == nil
                    -- Main panel surfaces a Quickstart entry point
                    and mpSrc3:find("Open Quickstart") ~= nil
                    -- Events.lua: new popup, dead old popup gone, auto-open flag
                    and evSrc:find('StaticPopupDialogs%["EC_APPLY_QUICKSTART"%]') ~= nil
                    and evSrc:find('StaticPopupDialogs%["EC_WELCOME"%]') == nil
                    and evSrc:find("_needsQuickstartOpen") ~= nil,
                "Quickstart panel must define ANSWER_MAP + PRESETS (4 keys); expose NS.Quickstart.Apply; cover the v2.38.0-added fields (autoOpenContainers / protectAllTomes / iLvl surfaces / qualityRules.maxILvl); never reference user list data; MainPanel must surface a Quickstart entry point; Events.lua must define EC_APPLY_QUICKSTART, NOT define EC_WELCOME, and set _needsQuickstartOpen on fresh install."
            )
        end

        -- v2.38.1: Stats panel character/account split. Locks the
        -- schema, the helper-driven write path, the view toggle UI, and
        -- the view-aware reset branching so regressions surface in CI.
        local spf = io.open("EbonClearance_StatsPanel.lua", "rb")
        local mpf4 = io.open("EbonClearance_MainPanel.lua", "rb")
        if spf and mpf4 then
            local spS = spf:read("*a") or ""
            spf:close()
            local mpS4 = mpf4:read("*a") or ""
            mpf4:close()
            check(
                "Test 88aa: ADB.accountStats schema seeded by EnsureAccountDB",
                evSrc:find("ADB%.accountStats%s*=%s*{}") ~= nil
                    and evSrc:find("AS%.totalCopper%s*=%s*0") ~= nil
                    and evSrc:find("AS%.bestGPHChar") ~= nil
                    and evSrc:find("AS%.startedAt%s*=%s*time%(%)") ~= nil,
                "EnsureAccountDB must initialise ADB.accountStats with the per-character mirror fields + bestGPHChar + startedAt timestamp."
            )
            check(
                "Test 88ab: EC_BumpStat + EC_BumpStatBucket helpers defined",
                evSrc:find("local function EC_BumpStat%(field, delta%)") ~= nil
                    and evSrc:find("local function EC_BumpStatBucket%(bucket, key, delta%)") ~= nil
                    and evSrc:find("ADB%.accountStats%[field%]") ~= nil
                    and evSrc:find("ADB%.accountStats%[bucket%]") ~= nil,
                "Both helpers must exist and structurally mirror writes from DB.* to ADB.accountStats.*."
            )
            check(
                "Test 88ac: stat-write sites converted to helpers (no remaining inline DB.totalCopper increments)",
                evSrc:find('EC_BumpStat%("totalCopper"') ~= nil
                    and evSrc:find('EC_BumpStat%("totalItemsSold"') ~= nil
                    and evSrc:find('EC_BumpStat%("totalItemsDeleted"') ~= nil
                    and evSrc:find('EC_BumpStat%("totalRepairs"') ~= nil
                    and evSrc:find('EC_BumpStatBucket%("soldItemCounts"') ~= nil
                    and evSrc:find('EC_BumpStatBucket%("deletedItemCounts"') ~= nil
                    and evSrc:find('EC_BumpStatBucket%("soldItemsByQuality"') ~= nil
                    and evSrc:find('EC_BumpStatBucket%("deletedItemsByQuality"') ~= nil
                    and evSrc:find('EC_BumpStatBucket%("processCastCounts"') ~= nil
                    and evSrc:find('EC_BumpStatBucket%("copperByZone"') ~= nil,
                "Every stat increment site must route through EC_BumpStat / EC_BumpStatBucket so the ADB.accountStats mirror is structurally guaranteed."
            )
            check(
                "Test 88ad: StatsPanel renders the view toggle + started-at note",
                spS:find("panel%._statsView") ~= nil
                    and spS:find('local charRadio = CreateFrame%("CheckButton"') ~= nil
                    and spS:find('local acctRadio = CreateFrame%("CheckButton"') ~= nil
                    and spS:find("startedAtNote") ~= nil,
                "StatsPanel must render Character / Account radio buttons + the started-at one-liner so the user knows where account totals begin."
            )
            check(
                "Test 88ae: RefreshStats reads from view-selected source",
                mpS4:find("panel%._statsView") ~= nil
                    and mpS4:find("ADB%.accountStats") ~= nil
                    and mpS4:find('view%s*==%s*"account"') ~= nil
                    and mpS4:find("src%.totalCopper") ~= nil,
                "RefreshStats must pick its source table based on panel._statsView and read from src.* instead of hard-coding DB.*."
            )
            check(
                "Test 88af: ResetLifetimeStats branches on view",
                mpS4:find('view%s*==%s*"account"') ~= nil
                    and mpS4:find("AS%.totalCopper%s*=%s*0") ~= nil
                    and mpS4:find("AS%.bestGPHChar%s*=%s*\"\"") ~= nil,
                "Reset Lifetime in Account view must clear ADB.accountStats.* + bestGPHChar; Character view keeps clearing DB.*."
            )
            check(
                "Test 88ag: account-side bestGPH writes during RefreshStats",
                mpS4:find("AS%.bestGPH%s*=%s*sessionGPH") ~= nil
                    and mpS4:find("AS%.bestGPHChar%s*=%s*%(UnitName") ~= nil,
                "When a session beats the account-wide best, RefreshStats must stamp both the new record AND the character name onto ADB.accountStats so the Account view can show 'on <CharName>'."
            )
            -- v2.38.2: Turbo Mode FinishRun-fires-once invariant.
            -- The OnUpdate batch loop runs N iterations per tick. If the
            -- queue exhausts mid-batch, every remaining iteration would
            -- re-enter `if not action then FinishRun() end` and bump
            -- DB.totalCopper / EC_session.copper N times instead of once,
            -- plus print "Vendoring complete!" N times. The guard is
            -- belt-and-braces: a top-of-DoNextAction `if not
            -- vendorRunning then return end` + a `break` in the batch
            -- for-loop that checks the same flag.
            check(
                "Test 88ah: DoNextAction guards against vendorRunning=false at the top",
                evSrc:find("if not EC_compCache%.vendorRunning then\n%s*return\n%s*end") ~= nil,
                "DoNextAction must early-return when vendorRunning is false. Without this, Turbo Mode's batch loop re-fires FinishRun once per remaining batch slot after the queue drains, inflating totalCopper / session counters Nx and spamming chat."
            )
            check(
                "Test 88ai: Turbo Mode batch loop breaks on vendorRunning=false",
                evSrc:find("for _ = 1, batch do\n%s*DoNextAction%(%)\n%s*-- v2%.38%.2: stop iterating the moment FinishRun fires%.") ~= nil
                    or evSrc:find("DoNextAction%(%)\n%s*-- v2%.38%.2:") ~= nil,
                "The OnUpdate batch loop must break as soon as FinishRun flips vendorRunning to false. Otherwise the remaining iterations call DoNextAction with an empty queue and re-fire FinishRun."
            )
            check(
                "Test 88aj: StatsPanel has a 1Hz OnUpdate refresher gated on visibility",
                spS:find('StatsPanel:SetScript%("OnUpdate"') ~= nil
                    and spS:find("_statsTickAcc") ~= nil
                    and spS:find("self:IsShown%(%)") ~= nil,
                "Without an OnUpdate refresher gated on IsShown, the Stats panel goes static the moment the player opens it - lifetime + session totals update in memory but the displayed numbers stay frozen until close+reopen. The (session +N) suffix v2.38.1 added makes the staleness glaring."
            )
            -- v2.38.3: Process Bags diagnostic. Without a structural
            -- lock, the slash command wiring + Help FAQ + dump builder
            -- could drift apart silently (e.g., command kept but Help
            -- entry deleted, or builder renamed without updating the
            -- /ec processdebug handler).
            local brf = io.open("EbonClearance_BugReport.lua", "rb")
            local hpf = io.open("EbonClearance_HelpPanel.lua", "rb")
            if brf and hpf then
                local brS = brf:read("*a") or ""
                brf:close()
                local hpS = hpf:read("*a") or ""
                hpf:close()
                check(
                    "Test 88ak: /ec processdebug diagnostic wired end-to-end",
                    brS:find("EC_BuildProcessDebugDump") ~= nil
                        and brS:find("NS%.ShowProcessDebugDump%s*=") ~= nil
                        and evSrc:find('cmd == "processdebug"') ~= nil
                        and evSrc:find("NS%.ShowProcessDebugDump%(%)") ~= nil
                        and mpS4:find("processdebug") ~= nil
                        and hpS:find("bug%-process%-debug") ~= nil,
                    "The /ec processdebug command must have: a builder (EC_BuildProcessDebugDump), namespace exposure (NS.ShowProcessDebugDump), a slash handler in Events.lua, a row in Main panel's SLASH_ROWS, AND a Help FAQ entry. Players hitting Mill/Prospect detection bugs need a paste-and-share dump path - same shape /ec affixdebug took for the affix pipeline."
                )
                -- v2.38.3: the scan tooltip silently loses SetOwner
                -- mid-session (another addon iterating UIParent children
                -- triggers a Hide), after which raw SetBagItem populates
                -- zero lines and every tooltip-scan predicate (Mill /
                -- Prospect / Soulbound / chance-on-hit / lockpick /
                -- bind / openable / known-tome / known-recipe) silently
                -- returns false. Routing every SetBagItem through the
                -- shared scanBagItem helper that re-establishes the
                -- owner is the structural fix. This test makes sure no
                -- file regresses to raw SetBagItem on the scan tooltip.
                local function countRawSetBagItem(src)
                    local n = 0
                    for _ in src:gmatch("scanTooltip:SetBagItem") do
                        n = n + 1
                    end
                    for _ in src:gmatch("scanTip%(%):SetBagItem") do
                        n = n + 1
                    end
                    return n
                end
                local procSrc = (function()
                    local fh = io.open("EbonClearance_Process.lua", "rb")
                    if not fh then return "" end
                    local s = fh:read("*a") or ""
                    fh:close()
                    return s
                end)()
                local protSrc = (function()
                    local fh = io.open("EbonClearance_Protection.lua", "rb")
                    if not fh then return "" end
                    local s = fh:read("*a") or ""
                    fh:close()
                    return s
                end)()
                check(
                    "Test 88am: scanBagItem helper defined in Events.lua",
                    evSrc:find("function EC_compCache%.scanBagItem%(bag, slot%)") ~= nil
                        and evSrc:find("EC_scanTooltip:SetOwner%(UIParent, \"ANCHOR_NONE\"%)") ~= nil
                        and evSrc:find("EC_scanTooltip:SetBagItem%(bag, slot%)") ~= nil,
                    "EC_compCache.scanBagItem must re-establish SetOwner before SetBagItem so the scan never silently no-ops when ownership has been lost mid-session."
                )
                -- v2.38.3: ordering lock. Re-arranging the helper body
                -- to put SetOwner AFTER SetBagItem would silently break
                -- everything again (the SetBagItem call would land on a
                -- tooltip with no owner and populate zero lines). Test
                -- 88am only verifies presence; this one verifies order.
                local function bodyPositions(src)
                    local fnStart = src:find("function EC_compCache%.scanBagItem%(bag, slot%)")
                    if not fnStart then return nil end
                    local bodyEnd = src:find("\nend", fnStart, true)
                    if not bodyEnd then return nil end
                    local body = src:sub(fnStart, bodyEnd)
                    local ownerAt = body:find("SetOwner")
                    local clearAt = body:find("ClearLines")
                    local setBagAt = body:find("SetBagItem")
                    return ownerAt, clearAt, setBagAt
                end
                local ownerAt, clearAt, setBagAt = bodyPositions(evSrc)
                check(
                    "Test 88am-ordering: scanBagItem body calls SetOwner BEFORE SetBagItem",
                    ownerAt and setBagAt and ownerAt < setBagAt
                        and clearAt and clearAt < setBagAt,
                    "Inside the scanBagItem body, SetOwner must precede SetBagItem (and ClearLines must precede SetBagItem). Reversing the order would re-introduce the silent zero-line scan bug v2.38.3 fixed."
                )
                check(
                    "Test 88an: no raw scanTooltip:SetBagItem calls outside the helper",
                    countRawSetBagItem(procSrc) == 0
                        and countRawSetBagItem(protSrc) == 0
                        and countRawSetBagItem(evSrc) <= 1
                        and countRawSetBagItem(brS) == 0,
                    "Every tooltip-scan call site must route through cc.scanBagItem so the SetOwner-before-SetBagItem invariant is structural, not a comment. The single permitted Events.lua reference is the helper body itself. Process.lua, Protection.lua, and BugReport.lua must contain zero raw `:SetBagItem(bag, slot)` against the scan tooltip."
                )
                -- v2.38.3: positive coverage. Every helper that scans
                -- the bag tooltip must reference cc.scanBagItem so that
                -- a future scan-using helper added in Process.lua or
                -- Protection.lua doesn't slip past Test 88an by using
                -- a different scan API (e.g. :SetHyperlink). At least
                -- one EC_compCache.scanBagItem call per scan-heavy file.
                check(
                    "Test 88ao: every scan-heavy file routes through EC_compCache.scanBagItem",
                    procSrc:find("EC_compCache%.scanBagItem%(") ~= nil
                        and protSrc:find("EC_compCache%.scanBagItem%(") ~= nil,
                    "Process.lua and Protection.lua each have multiple tooltip-scan helpers (processTooltipHasLine, canPickLock, processIsSoulbound, itemHasChanceOnHit, bagSlotAffixData, known-tome / known-recipe scans). Each file must contain at least one EC_compCache.scanBagItem call so a future helper that scans by a different API still has the surrounding pattern available."
                )
                check(
                    "Test 88al: Process debug dump surfaces every gate layer",
                    brS:find("Spell knowledge gates") ~= nil
                        and brS:find("IsSpellKnown") ~= nil
                        and brS:find("Tooltip marker globals") ~= nil
                        and brS:find("ITEM_MILLABLE") ~= nil
                        and brS:find("ITEM_PROSPECTABLE") ~= nil
                        and brS:find("Bag walk") ~= nil
                        and brS:find("buildProcessSummary") ~= nil
                        and brS:find("tooltip dump") ~= nil,
                    "The dump must expose every layer that decides Process Bags eligibility (spell knowledge, tooltip globals, per-slot scan, summary counts, and a sample tooltip dump for the first Mill/Prospect hits) so a single paste tells us which layer is failing for the player."
                )
                -- v2.39.1: master Enable discoverability locks. Each
                -- check below closes one half of the veeco bug class
                -- (real player on v2.39.0 with DB.enabled=false who
                -- could not figure out how to flip it back on because
                -- the only paths were minimap right-click and a
                -- keybind). Tests pin the three additive surfaces.
                check(
                    "Test 88ap: Main panel routes Enable checkbox through EbonClearance_ToggleEnabled",
                    mpS4:find("EbonClearanceMainEnableCB") ~= nil
                        and mpS4:find("EbonClearance_ToggleEnabled%(%)") ~= nil
                        and mpS4:find("panel%.enableCB%s*=") ~= nil,
                    "The Main panel Enable checkbox must use NS.AddCheckbox + route the setter through EbonClearance_ToggleEnabled() (NOT a direct DB.enabled = write) so the chat message + sound feedback stay identical to the minimap right-click path. The checkbox must also be stored on the panel (panel.enableCB) so OnShow / slash handlers can re-sync it."
                )
                check(
                    "Test 88aq: /ec status, /ec enable, /ec disable slash subcommands wired",
                    evSrc:find('cmd == "status" or cmd == "enable" or cmd == "disable"') ~= nil
                        and evSrc:find("[Cc]urrently %%s") ~= nil
                        and evSrc:find("[Aa]lready enabled") ~= nil
                        and evSrc:find("[Aa]lready disabled") ~= nil,
                    "Three slash subcommands must exist so a player who can't see the minimap (right-click hidden, button moved out of the way by a host UI replacement) has a chat-driven recovery path. status reports current state; enable / disable flip only if a change is needed (idempotent), reusing EbonClearance_ToggleEnabled() so messaging stays consistent."
                )
                check(
                    "Test 88ar: Help FAQ has a tshoot-not-working entry covering the master toggle",
                    hpS:find('id = "tshoot%-not%-working"') ~= nil
                        and hpS:find("master Enable toggle") ~= nil
                        and hpS:find("/ec enable") ~= nil
                        and hpS:find("Sell%-border tint") ~= nil,
                    "Help FAQ must include the recovery entry for the master Enable toggle (covers the three flip paths + explains why bag borders stay visible when the addon is disabled). Per feedback_release_includes_help_faq memory: any player-facing change MUST update Help/FAQ in the same patch."
                )
                -- v2.39.1 follow-up: bidirectional sync. The toggle
                -- helper must be the single source of truth - it
                -- writes DB.enabled, prints chat, plays sound, AND
                -- refreshes every UI surface that mirrors the state
                -- (minimap icon desaturation, Main panel checkbox).
                -- The two inline-flip sites in Minimap.lua
                -- (right-click handler + LDB launcher) must route
                -- through the helper, not write DB.enabled directly.
                -- Without these checks, a future refactor could
                -- re-introduce divergent toggle paths and the panel
                -- vs minimap icon would silently drift out of sync.
                local minimapSrc = (function()
                    local fh = io.open("EbonClearance_Minimap.lua", "rb")
                    if not fh then return "" end
                    local s = fh:read("*a") or ""
                    fh:close()
                    return s
                end)()
                check(
                    "Test 88as: EbonClearance_ToggleEnabled refreshes minimap icon + panel checkbox",
                    evSrc:find('_G%["EbonClearanceMinimapButton"%]') ~= nil
                        and evSrc:find("mb%.icon:SetDesaturated%(not DB%.enabled%)") ~= nil
                        and evSrc:find('_G%["EbonClearanceOptionsMain"%]') ~= nil
                        and evSrc:find("mp%.enableCB:SetChecked") ~= nil,
                    "The toggle helper must be the single source of truth: after flipping DB.enabled, it MUST refresh the minimap icon AND the Main panel checkbox so a flip via any entry point keeps every UI surface in sync. Without this, panel ↔ minimap stay out of sync depending on which surface the user clicked."
                )
                -- v2.40.1: Process Bags cast button must paint a
                -- cooldown swirl + disable during GCD. The macrotext
                -- is "/cast Spell" followed by "/use bag slot" - if
                -- /cast fails during the GCD, /use STILL runs and
                -- equips the (equippable) item. Players on PE who've
                -- shortened cast times below the 1.5s GCD trip this
                -- constantly. The fix is structural: a Cooldown
                -- overlay tied to GetSpellCooldown + a
                -- SPELL_UPDATE_COOLDOWN listener that disables the
                -- button while the armed spell is on CD. This test
                -- locks the wiring so a future contributor who
                -- "simplifies" the rearm path can't silently drop the
                -- guard.
                local pbpSrc = (function()
                    local fh = io.open("EbonClearance_ProcessBagsPanel.lua", "rb")
                    if not fh then return "" end
                    local s = fh:read("*a") or ""
                    fh:close()
                    return s
                end)()
                -- v2.41.2: keybind discoverability + tip honesty. The
                -- old Process Bags tip read "hold it to drain a stack"
                -- which is factually wrong - WoW doesn't auto-repeat
                -- bound actions. A player report (Ralickan) followed
                -- the tip, held the key, saw nothing happen. This test
                -- locks all three patch pieces in one shot so any of
                -- them silently disappearing in a future refactor
                -- shows up in CI.
                -- v2.41.2: canDisenchant must filter on equipLoc, not
                -- just IsEquippableItem + quality. Bags are equippable
                -- (they go in bag slots) and a green-quality bag like
                -- Traveler's Backpack slipped through, queued for DE,
                -- and the server refused the cast with "Item cannot
                -- be disenchanted" (real player report). This test
                -- locks the blacklist + the equipLoc read so a future
                -- refactor can't silently drop the guard.
                check(
                    "Test 88aw: canDisenchant filters out bags / quivers / tabards / shirts via equipLoc",
                    procSrc:find("NON_DE_EQUIP_LOCS%s*=%s*{") ~= nil
                        and procSrc:find("INVTYPE_BAG%s*=%s*true") ~= nil
                        and procSrc:find("INVTYPE_QUIVER%s*=%s*true") ~= nil
                        and procSrc:find("INVTYPE_TABARD%s*=%s*true") ~= nil
                        and procSrc:find("INVTYPE_BODY%s*=%s*true") ~= nil
                        and procSrc:find("local _, _, quality, _, _, _, _, _, equipLoc = GetItemInfo") ~= nil
                        and procSrc:find("NON_DE_EQUIP_LOCS%[equipLoc%]") ~= nil,
                    "canDisenchant must read equipLoc (9th GetItemInfo return, unlocalised) and reject INVTYPE_BAG / INVTYPE_QUIVER / INVTYPE_TABARD / INVTYPE_BODY (and INVTYPE_AMMO for belt-and-braces). Without this, a green-quality bag passes IsEquippableItem + the quality gate and the queue shows it for Disenchant; the server then refuses the cast and the player has to skip it manually."
                )
                check(
                    "Test 88av: Process Bags keybind tip rewritten + help icon + FAQ entry wired",
                    pbpSrc:find("hold it to drain") == nil
                        and pbpSrc:find("one cast per press") ~= nil
                        and pbpSrc:find('"process%-keybind"') ~= nil
                        and hpS:find('id = "process%-keybind"') ~= nil
                        and hpS:find('panel = "EbonClearanceOptionsProcessBags"') ~= nil,
                    "Process Bags tip must not promise hold-to-drain behaviour (WoW fires keybinds once per press; the addon cannot auto-repeat a SecureActionButton click). The new tip text must say 'one cast per press', a help icon next to it must deep-link to the process-keybind FAQ entry, and that entry must exist in EbonClearance_HelpPanel.lua with the EbonClearanceOptionsProcessBags panel link. A future contributor who removes any of the three pieces sees this test go red."
                )
                check(
                    "Test 88au: Process Bags cast button has a post-click lockout with effective-cast-time floor",
                    pbpSrc:find('CreateFrame%("Cooldown"') ~= nil
                        and pbpSrc:find('"CooldownFrameTemplate"') ~= nil
                        and pbpSrc:find("local function startProcessCastCooldown") ~= nil
                        and pbpSrc:find("EC_compCache%.startProcessCastCooldown") ~= nil
                        and pbpSrc:find('SetScript%("PostClick"') ~= nil
                        and pbpSrc:find("PROCESS_BUTTON_FLOOR_SECONDS%s*=%s*1") ~= nil
                        and pbpSrc:find('RegisterEvent%("UNIT_SPELLCAST_START"%)') ~= nil
                        and pbpSrc:find('UnitCastingInfo%("player"%)') ~= nil
                        and pbpSrc:find("armedSpellName") ~= nil
                        and pbpSrc:find("castBtn:Disable") ~= nil
                        and pbpSrc:find("castBtn:Enable") ~= nil
                        and pbpSrc:find("castCD:SetCooldown") ~= nil
                        and pbpSrc:find("noOCC") ~= nil
                        and pbpSrc:find("noCooldownCount") ~= nil,
                    "Process Bags cast button must lock out after every click for max(effective cast time, 1 s). Otherwise a click during the cast-time-less-than-GCD window falls through /cast (silent fail) into /use (equips the item). Cast duration must come from UnitCastingInfo at UNIT_SPELLCAST_START (the effective value with haste/talent/server reductions applied), NOT GetSpellInfo (returns the unmodified base cast time). PostClick still applies the floor immediately so a fast double-click in the pre-cast window can't slip past. Cooldown frame must also opt out of OmniCC-style numeric overlays via noOCC + noCooldownCount."
                )
                check(
                    "Test 88at: Minimap right-click + LDB launcher route through EbonClearance_ToggleEnabled",
                    minimapSrc:find("DB%.enabled%s*=%s*not%s+DB%.enabled") == nil
                        and (function()
                            local count = 0
                            for _ in minimapSrc:gmatch("EbonClearance_ToggleEnabled%(%)") do
                                count = count + 1
                            end
                            return count >= 2
                        end)(),
                    "Minimap.lua must NOT contain any direct `DB.enabled = not DB.enabled` flip - the right-click handler AND the LDB launcher both have to route through EbonClearance_ToggleEnabled() so all UI surfaces (icon + panel checkbox) stay in sync. Requires at least 2 calls to the helper from this file (one per inline-flip site we replaced)."
                )
            end
        end

        -- v2.38.0: Quickstart iteration regression locks. Each row below
        -- closes a bug we hit during in-game iteration so the same trap
        -- can't sneak back in.
        local qpf2 = io.open("EbonClearance_QuickstartPanel.lua", "rb")
        local bcmf = io.open("EbonClearance_BagContextMenu.lua", "rb")
        if qpf2 and bcmf then
            local qpS = qpf2:read("*a") or ""
            qpf2:close()
            local bcS = bcmf:read("*a") or ""
            bcmf:close()
            check(
                "Test 88n: Quickstart - standalone frame (NOT a sidebar sub-panel)",
                qpS:find("CreateFrame%(\"Frame\",%s*\"EbonClearanceOptionsQuickstart\",%s*UIParent%)") ~= nil
                    and qpS:find('InterfaceOptions_AddCategory%(QuickstartPanel%)') == nil
                    and qpS:find('QuickstartPanel%.parent%s*=%s*"EbonClearance"') == nil,
                "Quickstart must be parented to UIParent + must NOT register itself as an Interface Options sub-panel (that's the whole 'only reachable from Main panel' point). The chrome sets the parent; no .parent = sub-panel marker."
            )
            check(
                "Test 88o: Quickstart - TOOLTIP strata + Toplevel + UISpecialFrames",
                qpS:find('SetFrameStrata%("TOOLTIP"%)') ~= nil
                    and qpS:find("SetToplevel%(true%)") ~= nil
                    and qpS:find('table%.insert%(UISpecialFrames,%s*"EbonClearanceOptionsQuickstart"%)') ~= nil,
                "Quickstart must sit at TOOLTIP strata (highest) so it lands above any host addon's Interface Options chrome wrappers. Toplevel auto-raises on click, and UISpecialFrames lets Escape close it."
            )
            check(
                "Test 88p: Quickstart - draggable + clamped to screen",
                qpS:find("SetMovable%(true%)") ~= nil
                    and qpS:find('RegisterForDrag%("LeftButton"%)') ~= nil
                    and qpS:find('SetScript%("OnDragStart",%s*QuickstartPanel%.StartMoving%)') ~= nil
                    and qpS:find("SetClampedToScreen%(true%)") ~= nil,
                "Quickstart must be draggable (StartMoving/StopMovingOrSizing) and clamped to the screen so dragging near the edge can't lose the frame."
            )
            check(
                "Test 88q: Quickstart - confirmation popup escalated to TOOLTIP strata",
                qpS:find('dialog:SetFrameStrata%("TOOLTIP"%)') ~= nil,
                "Without this, the EC_APPLY_QUICKSTART StaticPopup renders behind the Quickstart frame because StaticPopups default to DIALOG strata."
            )
            check(
                "Test 88r: Quickstart - chrome inited flag mirrors content frame",
                qpS:find("QuickstartPanel%.inited%s*=%s*QuickstartContent%.inited") ~= nil,
                "Cross-panel refresh loop (in EC_ApplyQuickstart) gates on p.inited. Because initPanel runs on QuickstartContent (not the chrome frame), the chrome's inited flag has to be mirrored or the active-preset tag won't refresh on preset switch."
            )
            check(
                "Test 88s: Quickstart - active tag anchored below + below button, NOT right of it",
                qpS:find('SetPoint%("TOP",%s*presetButtons%[activeKey%],%s*"BOTTOM"') ~= nil,
                "Right-of-button placement (the earlier iteration) put the 'active' text next to the neighbouring preset button and looked like it belonged to that one. Centered below the active button is the correct placement."
            )
            check(
                "Test 88t: Quickstart - Q5b stop-anchor repositions on mode change",
                qpS:find("self%.q5bStop:ClearAllPoints%(%)") ~= nil,
                "When the iLvl mode toggles between dynamic / fixed, the four cap-input rows show or hide. The stop anchor that the next question chains to must reposition so the layout doesn't leave a phantom gap below hidden rows."
            )
            check(
                "Test 88t2: Quickstart - cap-row editboxes do NOT call :Enable() (Cataclysm+ only)",
                qpS:find("capBoxes%[q%]:Enable%(%)") == nil,
                "v2.44.3 bug: EditBox:Enable() / Disable() are Cataclysm+ additions. Calling them on 3.3.5a throws 'attempt to call method Enable (a nil value)' the moment the user toggles Q5b to fixed mode. The editbox is enabled by default - Show()/Hide() on the parent row is the right hook. If a future change genuinely needs enable/disable, use EnableMouse(true/false) and EnableKeyboard(true/false), which DO exist on 3.3.5a."
            )
            check(
                "Test 88u: Quickstart - chat confirm includes preset name (not just 'applied')",
                qpS:find('PRESETS%[presetKey%]%.name') ~= nil,
                "The chat message after applying a preset must include which preset was applied, not just say 'Quickstart applied'."
            )
            check(
                "Test 88v: Quickstart - preset tooltip shows description only (no redundant title)",
                qpS:find('GameTooltip:SetText%(p%.desc') ~= nil
                    and qpS:find('GameTooltip:SetText%(p%.name') == nil,
                "The button label already shows the preset name; the tooltip title repeating it is redundant noise."
            )
            check(
                "Test 88w: Quickstart - immediate-apply on radio click (no separate Apply step)",
                qpS:find("EC_ApplyAnswerImmediate%(questionKey,%s*opt%.value%)") ~= nil
                    and qpS:find('btn:SetText%("Apply changes"%)') == nil,
                "Each radio click writes its answer to DB immediately. The standalone 'Apply changes' button from earlier iterations is gone; only Close remains."
            )
            check(
                "Test 88x: Quickstart - snapshot happens INSIDE initPanel callbacks, after EnsureDB",
                qpS:find("EC_compCache%.initPanel%(QuickstartContent") ~= nil
                    and qpS:find("workingAnswers,%s*workingFixedCaps%s*=%s*snapshotAnswersFromDB%(DB%)") ~= nil,
                "Snapshot before EnsureDB runs (initPanel calls EnsureDB at its top) leaves DB nil or partial and the build callback errors silently. Snapshot must live INSIDE the initPanel refresh + build callbacks."
            )
            check(
                "Test 88y: Quickstart - frame width >= 640 so labels at EC_PANEL_WIDTH fit",
                qpS:find("QuickstartPanel:SetSize%(6") ~= nil,
                "EC's MakeLabel sizes FontStrings to EC_PANEL_WIDTH (the Interface Options container width ~580). A narrower standalone frame clips the labels on the right side. Width must be at least 640 (parsing accepts SetSize(6**, ...) ie. >= 600 prefix)."
            )
            check(
                "Test 88z: BagContextMenu - cursor anchor clamped to screen bounds",
                bcS:find("cx > maxX") ~= nil
                    and bcS:find("UIParent:GetWidth%(%)") ~= nil,
                "Alt+Right-Clicking a bag item near the right edge (common with host bag UI adapters that pin bags right) used to clip the EC popup off the screen. The clamp keeps the popup's right/bottom edges inside UIParent bounds."
            )
        end

        -- v2.37.7: Turbo Mode batch-vendor. EnsureDB seeds DB.turboMode
        -- false. EC_EffectiveBatchSize returns the batch count gated on
        -- DB.turboMode. Worker OnUpdate uses the batch count in a loop
        -- so the v2.0.11 single-item invariant still holds when Turbo is
        -- off (batch=1) but multiple items pop per fire when on.
        local merf = io.open("EbonClearance_MerchantPanel.lua", "rb")
        if merf then
            local merSrc = merf:read("*a") or ""
            merf:close()
            check(
                "Test 88l: Turbo Mode batch-vendor wired",
                evSrc:find("DB%.turboMode%s*=%s*false") ~= nil
                    and evSrc:find("local function EC_EffectiveBatchSize") ~= nil
                    and evSrc:find("local batch = EC_EffectiveBatchSize%(%)") ~= nil
                    and evSrc:find("for _ = 1, batch do") ~= nil
                    and merSrc:find("EbonClearanceTurboModeCB") ~= nil
                    and merSrc:find("Time between sells") ~= nil,
                "EnsureDB seeds turboMode=false; EC_EffectiveBatchSize gates on DB.turboMode; worker loops the batch; Merchant panel renders the Turbo checkbox + relabelled slider."
            )
        end

        -- v2.37.6: /ec perf self-diagnostic. The command must exist
        -- in the slash dispatch, list cache sizes for the major
        -- per-itemID caches, and be discoverable from the Main panel
        -- slash reference + /ec help output.
        local mpf2 = io.open("EbonClearance_MainPanel.lua", "rb")
        if mpf2 then
            local mpSrc2 = mpf2:read("*a") or ""
            mpf2:close()
            check(
                "Test 88j: /ec perf wired + discoverable",
                evSrc:find('if cmd == "perf"') ~= nil
                    and evSrc:find("GetAddOnMemoryUsage") ~= nil
                    and evSrc:find("affixDataCache") ~= nil
                    and mpSrc2:find("/ec perf") ~= nil,
                "/ec perf must exist in the slash dispatch, surface GetAddOnMemoryUsage, count the per-itemID caches, and appear in the Main panel slash reference."
            )
            -- v2.37.6: clickable Run buttons for slash commands. The
            -- Main panel's Slash Commands section now stacks per-row
            -- frames; runnable commands get a Run button that calls
            -- SlashCmdList["EBONCLEARANCE"] with the command string.
            check(
                "Test 88k: Main panel SLASH_ROWS table + Run-button wiring present",
                mpSrc2:find("SLASH_ROWS%s*=%s*{") ~= nil
                    and mpSrc2:find('SlashCmdList%["EBONCLEARANCE"%]') ~= nil
                    and mpSrc2:find('btn:SetText%(L%["Run"%]%)') ~= nil,
                "The Main panel must define the SLASH_ROWS table, create Run buttons, and dispatch via SlashCmdList[\"EBONCLEARANCE\"] so players can click commands instead of typing."
            )
        end

        -- v2.37.5: Random-affix bag-slot border category. New entry
        -- in DB.sellBorderCategories.affix (default OFF), wired through
        -- bagSlotWillSellCategory + listed in the Item Highlighting
        -- panel's SELL_BORDER_CATEGORIES array. The detection reuses
        -- EC_compCache.bagSlotAffixData.
        local bdf = io.open("EbonClearance_BagDisplay.lua", "rb")
        local ihpf = io.open("EbonClearance_ItemHighlightingPanel.lua", "rb")
        if bdf and ihpf then
            local bdSrc = bdf:read("*a") or ""
            bdf:close()
            local ihpSrc = ihpf:read("*a") or ""
            ihpf:close()
            check(
                "Test 88i: random-affix border category wired + listed in UI",
                evSrc:find("affix%s*=%s*{%s*enabled%s*=%s*false") ~= nil
                    and bdSrc:find("hasAffixForBorder") ~= nil
                    and bdSrc:find('return "affix"') ~= nil
                    and ihpSrc:find('key%s*=%s*"affix"') ~= nil,
                "DB defaults must seed affix as opt-in; bagSlotWillSellCategory must return 'affix' for affixed items; ItemHighlightingPanel must list the row in SELL_BORDER_CATEGORIES."
            )
        end

        -- v2.37.4: Process Bags chrome restoration on second OnShow.
        -- The v2.37.3 OnHide handler hides processScrollBg as a "belt-
        -- and-braces" measure against combat-lockdown bleed-through;
        -- without a matching Show() in the OnShow refresh path the
        -- chrome stays hidden after a panel-switch round-trip. The
        -- refresh callback must Show processScrollBg on every entry.
        local pbpf = io.open("EbonClearance_ProcessBagsPanel.lua", "rb")
        if pbpf then
            local pbpSrc = pbpf:read("*a") or ""
            pbpf:close()
            check(
                "Test 88h: Process Bags refresh callback re-shows processScrollBg",
                pbpSrc:find("self%.processScrollBg:Show%(%)") ~= nil
                    and pbpSrc:find("self%.processScrollBg:Hide%(%)") ~= nil,
                "OnHide hides processScrollBg; without a matching Show in the OnShow refresh path the panel chrome stays hidden on subsequent opens."
            )
        end

        -- v2.37.4 (audit issue #4): side-meta prune for affixedListedItems
        -- and chanceOnHitListedItems. The helper must exist, be exposed on
        -- NS, get called from EC_RemoveItemFromList, and the Clear All
        -- path in ListWidget must snapshot keys before wipe + call the
        -- helper per id.
        local lwf2 = io.open("EbonClearance_ListWidget.lua", "rb")
        if lwf2 then
            local lwSrc2 = lwf2:read("*a") or ""
            lwf2:close()
            check(
                "Test 88g: side-meta prune helper present + wired on remove + wired on Clear All",
                evSrc:find("local function EC_PruneSideMetaForItem%(") ~= nil
                    and evSrc:find("NS%.PruneSideMetaForItem%s*=%s*EC_PruneSideMetaForItem") ~= nil
                    and evSrc:find("EC_PruneSideMetaForItem%(itemID%)") ~= nil
                    and lwSrc2:find("NS%.PruneSideMetaForItem%(cleared%[i%]%)") ~= nil,
                "Removing the last list entry for an itemID must clear ADB.affixedListedItems[id] and ADB.chanceOnHitListedItems[id] so the side meta doesn't accumulate orphans. Clear All must snapshot itemIDs before wipe and prune per id."
            )
        end
    end
end

-- ---------------------------------------------------------------------------
-- Test 88aa (v2.42.0): auto-delete-on-pickup is gated + debounce-sourced and
-- shares the delete-eligibility + delete-execution helpers with the vendor
-- path. Locks the two EC-TRAP decisions (no combat gate is fine BECAUSE the
-- scan is gated + cursor-guarded + vendor-exclusive; one-per-cycle relies on
-- running from the coalesced debounce, never the raw BAG_UPDATE branch).
-- ---------------------------------------------------------------------------
do
    local f = io.open("EbonClearance_Events.lua", "rb")
    if f then
        local s = f:read("*a") or ""
        f:close()
        local fnStart = s:find("function EC_compCache%.runAutoDeleteOnPickup%(")
        check("Test 88aa: runAutoDeleteOnPickup is defined", fnStart ~= nil,
            "the auto-delete-on-pickup scan must exist on EC_compCache")
        if fnStart then
            local body = s:sub(fnStart, fnStart + 2400)
            check("Test 88aa: scan gates on autoDeleteOnPickup + enableDeletion",
                body:find("autoDeleteOnPickup") ~= nil and body:find("enableDeletion") ~= nil,
                "both toggles must gate the scan")
            -- v2.42.1: the master Enable toggle MUST veto the sweep,
            -- same as the vendor cycle. Without this, a player who
            -- turns the addon off via the minimap can still trigger
            -- destructive deletes by marking items + /reload (real
            -- repro from Sanavesa on v2.42.0).
            check("Test 88aa: scan honours the master Enable toggle (DB.enabled)",
                body:find("EC_IsAddonEnabledForChar") ~= nil,
                "must early-return when EC_IsAddonEnabledForChar is false, same as the vendor cycle - the master toggle is the user's kill switch for every destructive path")
            check("Test 88aa: scan skips during a vendor cycle",
                body:find("vendorRunning") ~= nil,
                "must not fight an active vendor cycle")
            check("Test 88aa: scan guards free cursor + a visible delete popup",
                body:find("GetCursorInfo") ~= nil and body:find("StaticPopup1") ~= nil,
                "must not clobber the cursor or start a delete while a DELETE_* popup is up (gating on a visible popup, not pendingDelete, so non-popup deletes don't wedge the cascade)")
            check("Test 88aa: scan uses the shared eligibility helper",
                body:find("deleteListSlotEligible") ~= nil,
                "must share delete policy with BuildQueue, not duplicate it")
        end
        local dbStart = s:find('EC_compCache%.bagUpdateFrame:SetScript%("OnUpdate"')
        local dbBody = dbStart and s:sub(dbStart, dbStart + 2600) or ""
        check("Test 88aa: auto-delete runs from the BAG_UPDATE debounce frame",
            dbBody:find("runAutoDeleteOnPickup") ~= nil,
            "the scan must be called from the 120ms debounce OnUpdate, not the raw BAG_UPDATE branch (coalescing)")
        local _, execCount = s:gsub("executeBagSlotDelete%(", "")
        check("Test 88aa: vendor + auto delete share executeBagSlotDelete",
            s:find("function EC_compCache%.executeBagSlotDelete%(") ~= nil and execCount >= 3,
            "DoNextAction and runAutoDeleteOnPickup must both call the shared executeBagSlotDelete (defn + 2 call sites)")
    end
end

-- ---------------------------------------------------------------------------
-- Result.
-- ---------------------------------------------------------------------------
print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
