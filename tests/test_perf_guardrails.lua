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

local SOURCE_PATH = "EbonClearance.lua"

local f, err = io.open(SOURCE_PATH, "r")
if not f then
    io.stderr:write("FAIL: cannot open " .. SOURCE_PATH .. ": " .. tostring(err) .. "\n")
    os.exit(1)
end
local src = f:read("*a")
f:close()

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
    local hasProtectedLabel = src:find("Protected %- Chance on hit") ~= nil
    local hasSellLabel = src:find("Allowed %- Choose List") ~= nil
    local hasAccountSellLabel = src:find("Allowed %- Account Sell") ~= nil
    local hasCharSellLabel = src:find("Allowed %- Character Sell") ~= nil
    local hasDeleteLabel = src:find("Allowed %- Delete") ~= nil
    check("tooltip annotation emits 'Protected - Chance on hit' for unmarked items",
          hasProtectedLabel)
    check("tooltip annotation emits 'Allowed - Choose List' when no list chosen",
          hasSellLabel,
          "v2.26.0: marked items with no list membership get a call-to-action label, not the misleading 'Allowed - Sell'")
    check("tooltip annotation emits 'Allowed - Account Sell' when on Account Sell List",
          hasAccountSellLabel,
          "marked + on ADB.whitelist - label must reflect the actual destination")
    check("tooltip annotation emits 'Allowed - Character Sell' when on Character Sell List",
          hasCharSellLabel,
          "marked + on DB.whitelist - label must reflect the actual destination")
    check("tooltip annotation emits 'Allowed - Delete' when on Delete List",
          hasDeleteLabel,
          "marked + on DB.deleteList - label must reflect the actual destination")
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
    local hasAllowText = src:find('btn:SetText%("Allow Sell"%)') ~= nil
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
        -- Look for an assignment of "none" to processCache inside the
        -- function body. The exact form is:
        --     EC_compCache.processCache[itemID] = "none"
        local writesNone = body:find('processCache%[itemID%]%s*=%s*"none"') ~= nil
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
        local body = src:sub(fnStart, fnStart + 12000)
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
        local body = src:sub(fnStart, fnStart + 12000)
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
        local body = src:sub(fnStart, fnStart + 12000)
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
