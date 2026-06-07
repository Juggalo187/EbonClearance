# Auto-Delete-on-Pickup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add an opt-in (default OFF) option that destroys Delete-List items the moment they enter the bags, instead of only at a vendor.

**Architecture:** Hook the existing 120ms BAG_UPDATE debounce; reuse the existing pickup -> delete -> auto-confirm path one item per cycle; extract two shared helpers (`deleteListSlotEligible`, `executeBagSlotDelete`) so the vendor delete and the new auto-delete share identical policy + execution by construction.

**Tech Stack:** WoW 3.3.5a / Lua 5.1. No unit-test framework (WoW API not mockable) - verification is `luac -p` + the five static suites + in-game smoke.

---

## Project conventions (read first)

- **Verify before committing.** Do NOT commit until confirmed in-game (destructive feature). Each task runs `luac -p` + the five suites but does NOT commit; a single commit + tag happens in the final task after the user's in-game smoke.
- Five suites: `lua tests/test_layout_reactivity.lua && lua tests/test_perf_guardrails.lua && lua tests/test_comment_hygiene.lua && lua tests/test_comms_version.lua && lua tests/test_guildshare.lua`
- No em dashes (U+2014). Player-facing text brief + plain.
- **Scope correction vs spec:** `DB.enableDeletion` is account-wide (top-level, NOT in `PER_CHAR_FIELDS`). The new `DB.autoDeleteOnPickup` matches it: account-wide, EnsureDB nil-default only, NOT added to `PER_CHAR_FIELDS`. (The Delete List items themselves stay per-character; the toggle is global, exactly like `enableDeletion`.)

## File structure

- `EbonClearance_Events.lua` - DB default; two shared helpers (`deleteListSlotEligible`, `executeBagSlotDelete`); route `BuildQueue` + `DoNextAction` through them; `runAutoDeleteOnPickup` + debounce call; `EC_CONFIRM_AUTODELETE` popup.
- `EbonClearance_KeepDeletePanels.lua` - dependent sub-checkbox + confirm-on-enable.
- `tests/test_perf_guardrails.lua` - new invariant.
- Docs: `CHANGELOG.md`, `EbonClearance_HelpPanel.lua`, `README.md`, `docs/ADDON_GUIDE.md`.

---

## Task 1: DB default (account-wide)

**Files:** Modify `EbonClearance_Events.lua` (EnsureDB, after the `enableDeletion` default)

- [ ] **Step 1: Add the nil-default**

Find:
```lua
    if type(DB.enableDeletion) ~= "boolean" then
        DB.enableDeletion = true
    end
```
Replace with:
```lua
    if type(DB.enableDeletion) ~= "boolean" then
        DB.enableDeletion = true
    end
    -- v2.42.0: auto-delete Delete-List items on pickup. Account-wide (top-
    -- level) to match its gate enableDeletion; default OFF (destructive, opt-in).
    if type(DB.autoDeleteOnPickup) ~= "boolean" then
        DB.autoDeleteOnPickup = false
    end
```

- [ ] **Step 2: Verify** - `luac -p EbonClearance_Events.lua` -> OK. Do NOT add `autoDeleteOnPickup` to `PER_CHAR_FIELDS`.

---

## Task 2: Extract `deleteListSlotEligible` + route BuildQueue through it

**Files:** Modify `EbonClearance_Events.lua` (add helper just before `local function BuildQueue`; replace BuildQueue's delete-branch body)

- [ ] **Step 1: Add the shared eligibility helper** (insert immediately above the `local function BuildQueue(` line)

```lua
-- v2.42.0: shared Delete-List eligibility predicate. Returns (itemID, count,
-- quality) when the bag slot holds a Delete-List item eligible for destruction
-- (on the list, not locked, and not affix-protected), else nil. Used by both
-- BuildQueue's delete branch and runAutoDeleteOnPickup so vendor-delete and
-- auto-delete apply identical policy with zero drift. Affix protection is the
-- only veto (per-link, user can't anticipate which copy rolls an affix);
-- quest items / tomes / profession tools are NOT protected - the Delete List
-- is explicit user intent.
function EC_compCache.deleteListSlotEligible(bag, slot)
    local DB = NS.DB
    if not (DB and DB.deleteList) then
        return nil
    end
    local id = GetContainerItemID(bag, slot)
    if not (id and IsInSet(DB.deleteList, id)) then
        return nil
    end
    local _, count, locked = GetContainerItemInfo(bag, slot)
    if not (count and count > 0) or locked then
        return nil
    end
    local _, _, quality = GetItemInfo(id)
    if DB.protectAffixedRareItems and quality and quality >= 3 then
        local affix = EC_compCache.bagSlotAffixData(bag, slot)
        if affix then
            local affixKey = affix.description
                and EC_compCache.normaliseAffixDesc
                and EC_compCache.normaliseAffixDesc(affix.description)
            local ADB = NS.ADB
            local manualAllow = affixKey and ADB and ADB.allowedAffixes and ADB.allowedAffixes[affixKey]
            local isDupe = DB.affixAllowExactDupes
                and EC_compCache.playerHasAffixDescription(affix.description)
            if not (manualAllow or isDupe) then
                return nil -- affix-protected
            end
        end
    end
    return id, count, quality
end
```

- [ ] **Step 2: Route BuildQueue through it.** In BuildQueue's slot loop, the delete branch currently is `local queuedDelete = false` then `if deletionOn then ... end` containing the inline `GetContainerItemID` / `IsInSet` / `GetContainerItemInfo` / affix-protection / `queue[#queue+1]` logic (the big block with the v2.13.8 / v2.19.0 / v2.20.1 / v2.23.0 / v2.32.x comments). Replace that entire `if deletionOn then ... end` block with:

```lua
            if deletionOn then
                -- v2.42.0: policy now lives in the shared helper (also used by
                -- the auto-delete-on-pickup scan) so the two never drift.
                local id, count, quality = EC_compCache.deleteListSlotEligible(bag, slot)
                if id then
                    queue[#queue + 1] = {
                        type = "delete",
                        bag = bag,
                        slot = slot,
                        itemID = id,
                        count = count,
                        quality = quality,
                    }
                    queuedDelete = true
                end
            end
```
(Keep the surrounding `local queuedDelete = false` line above and the sell branch below unchanged. `queuedDelete` still gates the sell branch exactly as before.)

- [ ] **Step 3: Verify** - `luac -p EbonClearance_Events.lua` -> OK. Run the five suites -> all pass (behaviour identical; `test_perf_guardrails` Test for the delete path / affix cache should stay green).

---

## Task 3: Extract `executeBagSlotDelete` + route DoNextAction through it

**Files:** Modify `EbonClearance_Events.lua` (add helper near `deleteListSlotEligible`; replace DoNextAction's delete branch)

- [ ] **Step 1: Add the shared delete-execution helper** (insert just below `deleteListSlotEligible`)

```lua
-- v2.42.0: shared destructive delete of one bag slot. Picks the item up,
-- queues pendingDelete (so HookDeletePopupOnce auto-confirms the DELETE_*
-- popup), deletes it, and bumps the deletion stats - identical accounting for
-- the vendor path and the auto-delete path. `announce` true prints one chat
-- line (auto-delete); the vendor path passes false (it has its own summary).
-- Returns true if the delete was issued.
function EC_compCache.executeBagSlotDelete(bag, slot, itemID, count, quality, announce)
    ClearCursor()
    PickupContainerItem(bag, slot)
    if GetCursorInfo() ~= "item" then
        ClearCursor()
        EC_compCache.pendingDelete = nil
        return false
    end
    EC_compCache.pendingDelete = { bag = bag, slot = slot, itemID = itemID }
    DeleteCursorItem()
    ClearCursor()
    local delCount = count or 1
    EC_BumpStat("totalItemsDeleted", delCount)
    EC_session.deleted = EC_session.deleted + delCount
    if itemID then
        EC_BumpStatBucket("deletedItemCounts", itemID, delCount)
    end
    if quality then
        EC_BumpStatBucket("deletedItemsByQuality", quality, delCount)
    end
    if announce then
        local link = select(2, GetItemInfo(itemID)) or ("item:" .. tostring(itemID))
        PrintNicef("Auto-deleted %s.", link)
    end
    return true
end
```
(Note: `EC_BumpStat`, `EC_BumpStatBucket`, `EC_session`, `PrintNicef` are file-scope locals in `EbonClearance_Events.lua` - confirm they are in scope at the helper's location; they are all defined in this file's main chunk.)

- [ ] **Step 2: Route DoNextAction's delete branch through it.** Replace the existing `elseif action.type == "delete" then ... end` block (the one doing `ClearCursor()` / `PickupContainerItem` / `GetCursorInfo` / `pendingDelete` / `DeleteCursorItem` / stat bumps) with:

```lua
    elseif action.type == "delete" then
        EC_compCache.executeBagSlotDelete(action.bag, action.slot, action.itemID, action.count, action.quality, false)
    end
```

- [ ] **Step 3: Verify** - `luac -p EbonClearance_Events.lua` -> OK. Five suites -> pass. (Vendor delete behaviour is byte-identical: same pickup/delete/stats, announce=false so no new chat.)

---

## Task 4: `runAutoDeleteOnPickup` + debounce hook

**Files:** Modify `EbonClearance_Events.lua` (add the function near the helpers; add the call inside the bagUpdate debounce OnUpdate)

- [ ] **Step 1: Add the scan function** (insert below `executeBagSlotDelete`)

```lua
-- v2.42.0: auto-delete-on-pickup scan. Runs from the BAG_UPDATE debounce only.
-- Deletes ONE eligible Delete-List item per cycle; the deletion fires another
-- BAG_UPDATE which re-fires the debounce for the next one, self-terminating
-- when none remain (ineligible items are skipped, so no loop).
-- EC-TRAP: one-per-cycle by design (no batch loop) - it reuses the single
-- pendingDelete slot + the HookDeletePopupOnce auto-confirm cleanly. Do NOT
-- "optimise" into a batch delete; that breaks the single-popup serialisation.
-- EC-TRAP: deliberately NOT gated on InCombatLockdown - DeleteCursorItem is
-- not combat-protected on 3.3.5a and farming happens in combat, which is the
-- whole point of the feature. Do NOT add a combat guard.
function EC_compCache.runAutoDeleteOnPickup()
    local DB = NS.DB
    if not (DB and DB.enableDeletion and DB.autoDeleteOnPickup) then
        return
    end
    if EC_compCache.vendorRunning then
        return -- don't fight an active vendor cycle
    end
    if EC_compCache.pendingDelete then
        return -- a delete is already in flight (popup not yet confirmed)
    end
    if GetCursorInfo() then
        return -- player is holding something; don't clobber the cursor
    end
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local id, count, quality = EC_compCache.deleteListSlotEligible(bag, slot)
            if id then
                EC_compCache.executeBagSlotDelete(bag, slot, id, count, quality, true)
                return -- one per debounce cycle
            end
        end
    end
end
```

- [ ] **Step 2: Call it from the debounce OnUpdate.** In `EC_compCache.bagUpdateFrame:SetScript("OnUpdate", ...)`, find the tail:
```lua
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
end)
```
Replace with:
```lua
    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end
    -- v2.42.0: auto-delete-on-pickup runs from the debounce (NOT the raw
    -- BAG_UPDATE branch) so the coalescing invariant holds.
    if EC_compCache.runAutoDeleteOnPickup then
        EC_compCache.runAutoDeleteOnPickup()
    end
end)
```

- [ ] **Step 3: Verify** - `luac -p EbonClearance_Events.lua` -> OK. Five suites -> pass (esp. `test_perf_guardrails` Test 1 BAG_UPDATE coalescing: the auto-delete is inside the debounce frame, not the raw branch).

---

## Task 5: Confirm popup + Delete List panel sub-checkbox

**Files:** Modify `EbonClearance_Events.lua` (register popup near `EC_CONFIRM_CLEAR_LIST`); modify `EbonClearance_KeepDeletePanels.lua` (Delete List panel build)

- [ ] **Step 1: Register the confirm popup** (insert immediately after the `StaticPopupDialogs["EC_CONFIRM_CLEAR_LIST"] = { ... }` block)

```lua
-- v2.42.0: confirm enabling auto-delete-on-pickup (irreversible behaviour).
-- OnAccept invokes the callback passed via StaticPopup_Show's data arg,
-- mirroring the EC_CONFIRM_CLEAR_LIST pattern.
StaticPopupDialogs["EC_CONFIRM_AUTODELETE"] = {
    text = "Auto-delete permanently destroys Delete List items the instant they're looted - no vendor step, no undo. Turn it on?",
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
```

- [ ] **Step 2: Add the dependent sub-checkbox.** In `EbonClearance_KeepDeletePanels.lua`, the Delete List panel build creates `delCB` (the "Allow items to be deleted" checkbox) and wires its OnClick, then builds the list UI. Make two edits:

(a) Forward-declare the refresh helper + sub-checkbox above `delCB`'s creation. Find:
```lua
        local delCB =
            CreateFrame("CheckButton", "EbonClearanceEnableDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
```
Replace with:
```lua
        local autoCB, refreshAutoCBEnabled

        local delCB =
            CreateFrame("CheckButton", "EbonClearanceEnableDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
```

(b) In `delCB`'s OnClick, after the `RefreshSellBorders` block, refresh the sub-toggle's enabled state. Find:
```lua
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)
```
Replace with:
```lua
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
            if refreshAutoCBEnabled then
                refreshAutoCBEnabled()
            end
        end)

        -- v2.42.0: auto-delete-on-pickup sub-toggle, dependent on "Allow items
        -- to be deleted". Greyed + disabled when deletion is off. Enabling
        -- requires an explicit confirm (irreversible) and kicks one debounce
        -- scan so items already in bags get cleaned.
        autoCB =
            CreateFrame("CheckButton", "EbonClearanceAutoDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
        autoCB:SetPoint("TOPLEFT", delCB, "BOTTOMLEFT", 0, -2)
        autoCB:SetChecked(DB.autoDeleteOnPickup)
        local autoText = _G[autoCB:GetName() .. "Text"]
        if autoText then
            autoText:SetText("Auto-delete these items the moment they enter your bags")
            autoText:SetWidth(420)
            autoText:SetJustifyH("LEFT")
        end
        refreshAutoCBEnabled = function()
            if DB.enableDeletion then
                autoCB:Enable()
                if autoText then
                    autoText:SetTextColor(1, 1, 1)
                end
            else
                autoCB:Disable()
                if autoText then
                    autoText:SetTextColor(0.5, 0.5, 0.5)
                end
            end
        end
        refreshAutoCBEnabled()
        autoCB:SetScript("OnClick", function()
            if autoCB:GetChecked() then
                autoCB:SetChecked(false) -- stay off until confirmed
                local dialog = StaticPopup_Show("EC_CONFIRM_AUTODELETE")
                if dialog then
                    dialog.data = function()
                        DB.autoDeleteOnPickup = true
                        autoCB:SetChecked(true)
                        PlaySound("igMainMenuOptionCheckBoxOn")
                        -- clean items already in bags via one debounce scan
                        if EC_compCache.bagUpdateFrame then
                            EC_compCache.bagUpdatePending = true
                            EC_compCache.bagUpdateAccum = 0
                            EC_compCache.bagUpdateFrame:Show()
                        end
                    end
                end
            else
                DB.autoDeleteOnPickup = false
                PlaySound("igMainMenuOptionCheckBoxOff")
            end
        end)
```
(The list UI is created below this and re-anchors itself; it currently anchors at y=-130, which still clears the new checkbox. Leave the list UI block unchanged.)

- [ ] **Step 3: Verify** - `luac -p EbonClearance_Events.lua EbonClearance_KeepDeletePanels.lua` -> OK. Five suites -> pass.

---

## Task 6: Perf-guardrail invariant

**Files:** Modify `tests/test_perf_guardrails.lua` (add a new test block at the end, before the final results print)

- [ ] **Step 1: Add the invariant** (static-pattern check; `src` is the concatenated source the suite already builds)

```lua
-- ---------------------------------------------------------------------------
-- Test NN (v2.42.0): auto-delete-on-pickup is gated + debounce-sourced, and
-- shares the delete-eligibility + delete-execution helpers with the vendor path.
-- ---------------------------------------------------------------------------
do
    local fnStart = src:find("function EC_compCache%.runAutoDeleteOnPickup%(")
    check("runAutoDeleteOnPickup is defined", fnStart ~= nil,
        "the auto-delete scan must exist on EC_compCache")
    if fnStart then
        local body = src:sub(fnStart, fnStart + 1400)
        check("runAutoDeleteOnPickup gates on autoDeleteOnPickup + enableDeletion",
            body:find("autoDeleteOnPickup") ~= nil and body:find("enableDeletion") ~= nil,
            "both toggles must gate the scan")
        check("runAutoDeleteOnPickup skips during a vendor cycle",
            body:find("vendorRunning") ~= nil, "must not fight an active vendor cycle")
        check("runAutoDeleteOnPickup guards a free cursor + in-flight delete",
            body:find("GetCursorInfo") ~= nil and body:find("pendingDelete") ~= nil,
            "must not clobber the cursor or overlap a pending delete")
        check("runAutoDeleteOnPickup uses the shared eligibility helper",
            body:find("deleteListSlotEligible") ~= nil,
            "must share policy with BuildQueue, not duplicate it")
    end
    -- The auto-delete must be invoked from the debounce frame, never the raw
    -- BAG_UPDATE branch, so coalescing holds.
    local dbStart = src:find("EC_compCache%.bagUpdateFrame:SetScript%(\"OnUpdate\"")
    local dbBody = dbStart and src:sub(dbStart, dbStart + 2200) or ""
    check("auto-delete runs from the BAG_UPDATE debounce frame",
        dbBody:find("runAutoDeleteOnPickup") ~= nil,
        "the scan must be called from the 120ms debounce OnUpdate, not the raw BAG_UPDATE branch")
    -- BuildQueue and the auto path share the same execution helper.
    check("vendor + auto delete share executeBagSlotDelete",
        src:find("function EC_compCache%.executeBagSlotDelete%(") ~= nil
            and select(2, src:gsub("executeBagSlotDelete%(", "")) >= 2,
        "both DoNextAction and runAutoDeleteOnPickup must call executeBagSlotDelete")
end
```
(Use the next free Test number in the file's sequence for the comment header; match the file's existing `check(...)` helper signature.)

- [ ] **Step 2: Verify** - `lua tests/test_perf_guardrails.lua` -> `RESULT: all tests passed`. Run all five suites -> green.

---

## Task 7: Docs, full verification, in-game smoke, ship

**Files:** Modify `CHANGELOG.md`, `EbonClearance_HelpPanel.lua`, `README.md`, `docs/ADDON_GUIDE.md`

- [ ] **Step 1: CHANGELOG** - add a `### v2.42.0` stanza at the top (after the `---`), describing: opt-in auto-delete of Delete-List items on pickup (default off, gated by "Allow items to be deleted", same protection policy as vendor delete, confirm-on-enable, one chat line per deletion, works in combat); note the two shared helpers; note the new per-... (account-wide) `DB.autoDeleteOnPickup`, additive + downgrade-safe.

- [ ] **Step 2: Help/FAQ** - add an entry to `EbonClearance_HelpPanel.lua` (near the Delete List entries): Q "What does auto-delete on pickup do?" A: explains it destroys Delete-List items the instant they're looted (no vendor step, no undo), is off by default, lives on the Delete List panel under "Allow items to be deleted", uses the same protections as vendor deletion, and prints a line per deletion. Add a `[?]` `AddHelpIcon` next to the new checkbox in `KeepDeletePanels.lua` deep-linking to this entry (entry id e.g. `auto-delete-on-pickup`).

- [ ] **Step 3: README** - in the Delete List / Configuration area, add a sentence: an optional "auto-delete on pickup" toggle destroys Delete-List items as they're looted (off by default), to cut vendor trips while farming.

- [ ] **Step 4: ADDON_GUIDE** - document the two shared helpers (`deleteListSlotEligible`, `executeBagSlotDelete`), the debounce hook, and the two `EC-TRAP` notes (no combat gate; one-per-cycle) in the "Gotchas and refactoring traps" section.

- [ ] **Step 5: Full verification** - `luac -p` on all changed `.lua`; all five suites green; the U+2014 scan (`git diff --name-only` then grep each changed file for the U+2014 codepoint, e.g. `grep -HnP '\x{2014}'`) returns nothing.

- [ ] **Step 6: Hand to user for in-game smoke (DO NOT commit before this).** Confirm: enabling shows the confirm popup; a looted Delete-List grey vanishes + "Auto-deleted <item>" line; an affix-protected listed Rare is NOT deleted; a quest item on the list IS deleted; it fires in combat; nothing happens during a vendor cycle; an item held on the cursor is not clobbered; toggling "Allow items to be deleted" off greys the sub-toggle; enabling with junk already in bags cleans it.

- [ ] **Step 7: Ship (after in-game OK).** Commit code + tests + docs; push; tag `v2.42.0`; watch the Release workflow; `git pull --rebase` to sync the version-bump bot commit.

---

## Self-review notes
- Spec coverage: DB (T1), shared eligibility helper + BuildQueue (T2), shared execution + DoNextAction (T3), trigger/scan/debounce + EC-TRAPs (T4), confirm popup + dependent checkbox + clean-on-enable (T5), test invariant (T6), feedback line (T3 announce), docs/version (T7). All spec points covered.
- The one-per-cycle + no-combat-gate decisions are encoded as `EC-TRAP` comments AND locked by the Task 6 invariant.
- `deleteListSlotEligible` returns `(id, count, quality)`; both call sites consume that exact shape. `executeBagSlotDelete(bag, slot, itemID, count, quality, announce)` - both call sites pass that exact arg order.
