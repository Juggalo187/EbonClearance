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
