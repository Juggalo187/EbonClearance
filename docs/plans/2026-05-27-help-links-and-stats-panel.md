# Help links + Stats panel split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip duplicated explanation text from every settings panel, replace it with clickable `[?]` icons that deep-link into specific Help panel entries, and split the Stats widgets off the Main panel onto their own sub-panel.

**Architecture:** Two related but independent feature blocks. Phase 1 splits Stats into a new sub-panel (`EbonClearance_StatsPanel.lua`), leaving Main as welcome+orientation. Phase 2 adds stable `id` fields to every Help entry, builds an `NS.AddHelpIcon` widget helper and `NS.OpenHelpEntry(id)` deep-link API, then migrates each settings panel to use `[?]` icons instead of inline explanations. New "Process Bags" Help section gets added to cover the four processing modes. Cross-reference integrity is enforced by static tests.

**Tech Stack:** WoW 3.3.5a Lua 5.1 (no `C_Timer`, no `goto`), Blizzard Interface Options framework, EbonClearance's existing `EC_compCache.initPanel` + `setPanelWidth` reactive-layout infrastructure.

**Spec:** [docs/specs/2026-05-27-help-links-and-stats-panel-design.md](../specs/2026-05-27-help-links-and-stats-panel-design.md)

---

## Files affected

**New files:**
- `EbonClearance_StatsPanel.lua` — new sub-panel holding every stat widget

**Modified files:**
- `EbonClearance_MainPanel.lua` — strip stats widgets, leave welcome + orientation
- `EbonClearance_Events.lua` — `RefreshStats` re-pointed; `InterfaceOptions_AddCategory` sort order updated; `helpSectionsCollapsed` defaults extended for new `processBags` key
- `EbonClearance_HelpPanel.lua` — `id` fields on every entry, new Process Bags section, `NS.OpenHelpEntry` API, scroll-to-entry + flash logic, OnShow collapse defaults extended
- `EbonClearance_PanelWidgets.lua` — new `MakeHelpIcon` primitive exposed as `NS.AddHelpIcon`
- `EbonClearance_ProtectionPanel.lua` — strip notes, add `[?]` icons
- `EbonClearance_MerchantPanel.lua` — strip notes, add `[?]` icons
- `EbonClearance_ScavengerPanel.lua` — strip notes, add `[?]` icons
- `EbonClearance_ItemHighlightingPanel.lua` — strip notes, add `[?]` icons
- `EbonClearance_ProcessBagsPanel.lua` — strip notes, add `[?]` icons
- `EbonClearance_SellListPanels.lua` — top-of-panel `[?]` on Sell List + Account Sell List
- `EbonClearance_KeepDeletePanels.lua` — top-of-panel `[?]` on Keep + Delete
- `EbonClearance_ProfilesPanel.lua` — top-of-panel `[?]` on Profiles + Import/Export
- `EbonClearance.toc` — add `EbonClearance_StatsPanel.lua` to load order
- `.github/workflows/release.yml` — add new file to packaging glob
- `tests/test_perf_guardrails.lua` — Test 73 update, Tests 78-80 added, GPH invariants (Tests 22-23) re-pointed
- `tests/test_layout_reactivity.lua` — add new file to SOURCE_PATHS
- `tests/test_no_addon_references.lua` — add new file to SOURCE_PATHS
- `CHANGELOG.md` — version entry

---

## Phase 1: Stats panel split (Tasks 1-7)

### Task 1: Add failing test for Stats panel registration

**Files:**
- Test: `tests/test_perf_guardrails.lua` (modify; add new test block at end before "Result")

- [ ] **Step 1: Write the failing test**

Append before the `-- Result.` section (currently around line 4525-4540):

```lua
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
        check(
            "Test 80a: Stats panel registers EbonClearanceOptionsStats frame",
            statsSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsStats"') ~= nil
                and statsSrc:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsStats"%]') ~= nil,
            "Stats panel must create a frame named EbonClearanceOptionsStats and register it with InterfaceOptions_AddCategory"
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && lua tests/test_perf_guardrails.lua 2>&1 | tail -10`
Expected: FAIL with "Test 80: EbonClearance_StatsPanel.lua exists" because the file doesn't exist yet.

- [ ] **Step 3: Commit the failing test**

```bash
cd "c:/Users/chris/Wow Addons/EbonClearance"
git add tests/test_perf_guardrails.lua
git commit -m "test: Stats panel split invariants (Test 80, failing)"
```

---

### Task 2: Create EbonClearance_StatsPanel.lua skeleton

**Files:**
- Create: `EbonClearance_StatsPanel.lua`
- Modify: `EbonClearance.toc`
- Modify: `.github/workflows/release.yml`
- Modify: `tests/test_perf_guardrails.lua` (SOURCE_PATHS)
- Modify: `tests/test_layout_reactivity.lua` (SOURCE_PATHS)
- Modify: `tests/test_no_addon_references.lua` (SOURCE_PATHS)

- [ ] **Step 1: Create the empty panel file**

Create `EbonClearance_StatsPanel.lua`:

```lua
-- EbonClearance_StatsPanel - dedicated stats sub-panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Holds every stat widget (statsMoney, statsSold, statsDeleted, statsRepairs,
-- statsRepairCost, statsSessionGPH, statsBestGPH + zone/when sub-line,
-- statsAvgWorth, statsMostSold, statsNote, EbonClearanceResetStatsBtn).
-- These used to live on the Main panel; v2.36.x split them out so the Main
-- panel can read as a welcome page and Stats can grow.
--
-- RefreshStats (defined in EbonClearance_MainPanel.lua pre-split; re-homed
-- here post-split) writes to the panel.statsX attachments below. The
-- attachments are the public contract with the rest of the addon:
-- EbonClearance_Events.lua's data-change handlers call RefreshStats; this
-- file owns the panel object that holds the FontStrings.

local NS = select(2, ...)
local EC_compCache = NS.compCache

local StatsPanel = CreateFrame("Frame", "EbonClearanceOptionsStats", InterfaceOptionsFramePanelContainer)
StatsPanel.name = "Stats"
StatsPanel.parent = "EbonClearance"

StatsPanel:SetScript("OnShow", function(panel)
    local DB = NS.DB
    EC_compCache.initPanel(panel, function(self)
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, function(self, content)
        -- Heading. Same -16 y offset as Keep List / Sell List etc.
        NS.MakeHeader(content, "Stats", -16)

        -- Lifetime + session stats. Each panel.statsX is the contract
        -- with RefreshStats (called from EbonClearance_Events.lua's data
        -- handlers). Order matches the old MainPanel layout for visual
        -- continuity.
        local prev = content
        local function makeStatRow(yOffset, key, anchorPrev)
            local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            if anchorPrev == content then
                fs:SetPoint("TOPLEFT", content, "TOPLEFT", 16, yOffset)
            else
                fs:SetPoint("TOPLEFT", anchorPrev, "BOTTOMLEFT", 0, yOffset)
            end
            EC_compCache.setPanelWidth(fs, 16)
            fs:SetJustifyH("LEFT")
            panel[key] = fs
            return fs
        end

        local money = makeStatRow(-44, "statsMoney", content)
        local sold = makeStatRow(-6, "statsSold", money)
        local deleted = makeStatRow(-6, "statsDeleted", sold)
        local repairs = makeStatRow(-6, "statsRepairs", deleted)
        local repairCost = makeStatRow(-6, "statsRepairCost", repairs)
        local sessionGPH = makeStatRow(-6, "statsSessionGPH", repairCost)
        local bestGPH = makeStatRow(-6, "statsBestGPH", sessionGPH)
        local avgWorth = makeStatRow(-6, "statsAvgWorth", bestGPH)
        local mostSold = makeStatRow(-6, "statsMostSold", avgWorth)

        -- Footnote about buyback exclusion.
        local statsNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        statsNote:SetPoint("TOPLEFT", mostSold, "BOTTOMLEFT", 0, -4)
        EC_compCache.setPanelWidth(statsNote, 16)
        statsNote:SetJustifyH("LEFT")
        statsNote:SetText("|cff888888Stats don't account for items bought back from a merchant.|r")
        panel.statsNote = statsNote

        -- Reset Lifetime button (same global name + behaviour as before).
        local resetBtn = CreateFrame("Button", "EbonClearanceResetStatsBtn", content, "UIPanelButtonTemplate")
        resetBtn:SetSize(170, 22)
        resetBtn:SetPoint("TOPLEFT", statsNote, "BOTTOMLEFT", 0, -10)
        resetBtn:SetText("Reset Lifetime Stats")
        resetBtn:SetScript("OnClick", function()
            if NS.ResetLifetimeStats then
                NS.ResetLifetimeStats()
            end
            if NS.RefreshStats then
                NS.RefreshStats()
            end
        end)

        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end)
end)

InterfaceOptions_AddCategory(_G["EbonClearanceOptionsStats"])
```

**Note on `ResetLifetimeStats`:** the existing reset button in `EbonClearance_MainPanel.lua` zeroes `DB.totalCopper`, `DB.totalItemsSold`, etc., plus `DB.bestGPH`, `DB.bestGPHAt`, `DB.bestGPHZone`. Move that body into a function `NS.ResetLifetimeStats` exposed from `EbonClearance_MainPanel.lua` so the new Stats panel can call it. (Task 4 handles the move.)

- [ ] **Step 2: Add to .toc load order**

Modify `EbonClearance.toc` — insert `EbonClearance_StatsPanel.lua` after `EbonClearance_MainPanel.lua`:

```
EbonClearance_MainPanel.lua
EbonClearance_StatsPanel.lua
EbonClearance_PanelInfra.lua
```

- [ ] **Step 3: Add to release.yml packaging glob**

Modify `.github/workflows/release.yml` — add `EbonClearance_StatsPanel.lua` to the `cp` line:

```yaml
             EbonClearance_MainPanel.lua EbonClearance_StatsPanel.lua EbonClearance_PanelInfra.lua \
```

- [ ] **Step 4: Add to all three test SOURCE_PATHS**

Modify `tests/test_perf_guardrails.lua`, `tests/test_layout_reactivity.lua`, and `tests/test_no_addon_references.lua` — find the SOURCE_PATHS table and add `"EbonClearance_StatsPanel.lua"` after `"EbonClearance_MainPanel.lua"`:

```lua
    "EbonClearance_MainPanel.lua",
    "EbonClearance_StatsPanel.lua",
    "EbonClearance_PanelInfra.lua",
```

- [ ] **Step 5: Syntax check + run failing test**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_StatsPanel.lua && lua tests/test_perf_guardrails.lua 2>&1 | tail -10`
Expected: Test 80, 80a pass. Test 80b passes (panel.statsMoney is attached). Test 80c may still fail (MainPanel hasn't been stripped yet — that's Task 5).

- [ ] **Step 6: Commit**

```bash
git add EbonClearance_StatsPanel.lua EbonClearance.toc .github/workflows/release.yml tests/test_perf_guardrails.lua tests/test_layout_reactivity.lua tests/test_no_addon_references.lua
git commit -m "feat: add EbonClearance_StatsPanel.lua sub-panel"
```

---

### Task 3: Expose `NS.RefreshStats` and `NS.ResetLifetimeStats` from MainPanel

Currently `RefreshStats` is a local variable closed over by MainPanel's `OnShow`. The Stats panel needs to call it. Move it to a named function exposed via `NS`.

**Files:**
- Modify: `EbonClearance_MainPanel.lua`

- [ ] **Step 1: Identify the RefreshStats closure**

Read `EbonClearance_MainPanel.lua` lines 280-400 (approximate). `RefreshStats = function() ... end` is a closure that reads `self`, `DB`, `NS.session`. `self` is the MainPanel frame.

- [ ] **Step 2: Replace `RefreshStats = function() ... end` with `function NS.RefreshStats() ... end`**

Inside the function body, replace every `self.statsMoney`, `self.statsSold`, etc. with a panel-lookup at the top:

```lua
function NS.RefreshStats()
    local panel = _G["EbonClearanceOptionsStats"]
    if not panel or not panel.statsMoney then
        return
    end
    -- The rest of the body: replace `self.statsX` with `panel.statsX`
    -- ... (same code, just renamed receiver)
end
```

**Important:** the call site in MainPanel's `OnShow` that schedules a `RefreshStats()` after `GetItemInfo` warmup currently calls the local `RefreshStats`. Change it to call `NS.RefreshStats()`.

- [ ] **Step 3: Identify and extract the Reset Lifetime button's onClick body**

Find the existing `resetBtn:SetScript("OnClick", function() ... end)` in MainPanel. Cut the body, wrap it as `function NS.ResetLifetimeStats() ... end` at file scope (above `OnShow`).

- [ ] **Step 4: Run syntax + tests**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_MainPanel.lua && lua tests/test_perf_guardrails.lua 2>&1 | grep -E "RESULT|FAIL"`
Expected: All existing tests pass. Test 80 family: 80, 80a, 80b pass; 80c fails (MainPanel still creates stats widgets).

- [ ] **Step 5: Commit**

```bash
git add EbonClearance_MainPanel.lua
git commit -m "refactor: expose NS.RefreshStats and NS.ResetLifetimeStats as namespace functions"
```

---

### Task 4: Strip stats widgets from MainPanel

**Files:**
- Modify: `EbonClearance_MainPanel.lua`

- [ ] **Step 1: Remove the stats widget creation block**

In MainPanel's build callback, delete every widget creation between (and including):
- `local money = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")` ...
- ... through to and including the Reset Lifetime button creation
- The `panel.statsX = X` attachments
- The `setPanelWidth(bestGPH, 16)`, `setPanelWidth(mostSold, 16)`, `setPanelWidth(statsNote, 16)` calls

Keep:
- Heading (`MakeHeader`)
- Welcome text (`welcomeLabel`, `descLabel2`, `mainTip`)
- Slash command list (`cmdText`)
- Addon-enabled toggle

The build callback shrinks substantially. Adjust any remaining anchor references that pointed at the removed widgets (e.g. if `cmdText` was anchored to `resetBtn:BOTTOMLEFT`, re-anchor to `mainTip:BOTTOMLEFT` instead).

- [ ] **Step 2: Re-flow the remaining widget anchors**

Walk top-to-bottom; each remaining widget anchors to its predecessor. The order should be:

1. heading (TOPLEFT 16, -16)
2. welcomeLabel (TOPLEFT heading.BOTTOMLEFT 0, -8)
3. descLabel2 (TOPLEFT welcomeLabel.BOTTOMLEFT 0, -4)
4. mainTip (TOPLEFT descLabel2.BOTTOMLEFT 0, -10)
5. cmdText (TOPLEFT mainTip.BOTTOMLEFT 0, -16)

Confirm with a quick read after deletion.

- [ ] **Step 3: Run syntax + tests**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_MainPanel.lua && lua tests/test_perf_guardrails.lua 2>&1 | grep -E "RESULT|FAIL"`
Expected: Test 80c passes. All previous tests still pass.

- [ ] **Step 4: Commit**

```bash
git add EbonClearance_MainPanel.lua
git commit -m "refactor: strip stats widgets from MainPanel; Main is now welcome+orientation"
```

---

### Task 5: Update RefreshStats GPH invariant tests (Tests 22-23)

The existing perf-guardrails Tests 22+ assert "MainPanel writes DB.bestGPH on the best-update path". After Task 3-4, `RefreshStats` is in MainPanel but writes to `_G["EbonClearanceOptionsStats"]`. The tests still match because they grep `EbonClearance_MainPanel.lua` for the writes. Verify by running tests first; if they fail because the writes moved with `RefreshStats`, update the test target file.

**Files:**
- Modify: `tests/test_perf_guardrails.lua`

- [ ] **Step 1: Run the existing tests**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && lua tests/test_perf_guardrails.lua 2>&1 | grep -E "bestGPH|FAIL"`
Expected: Tests "MainPanel writes DB.bestGPH on the best-update path" etc. still pass (the writes are in `NS.RefreshStats` which is still in MainPanel.lua).

- [ ] **Step 2: If tests fail, update their grep target**

If the bestGPH writes moved to StatsPanel.lua instead (unlikely with this design), update the test's file path. If they still pass (expected outcome), no test change needed.

- [ ] **Step 3: Commit (only if test was changed)**

```bash
git add tests/test_perf_guardrails.lua
git commit -m "test: re-point GPH invariants if RefreshStats moved files"
```

---

### Task 6: Reorder InterfaceOptions_AddCategory list in Events.lua

**Files:**
- Modify: `EbonClearance_Events.lua` (around lines 4558-4568 per the file we read earlier)

- [ ] **Step 1: Locate the InterfaceOptions_AddCategory block**

The block currently registers panels in this order (in EbonClearance_Events.lua):
1. Main
2. Merchant
3. BlacklistSettings (Protection)
4. Scavenger
5. Character (Highlighting)
6. Whitelist (Sell List)
7. AccountWhitelist
8. Blacklist (Keep)
9. Deletion (Delete)
10. ProcessBags
11. Profiles
12. ImportExport

Note: the Stats panel's own `InterfaceOptions_AddCategory` call (in `EbonClearance_StatsPanel.lua`) runs at file load, which is after all panels register in Events.lua's tail because StatsPanel.lua loads before Events.lua. Actually check `.toc` load order — StatsPanel loads before Events. So Stats registers first, then Events registers the rest at file scope. That orders Stats LAST in the sub-panel sort because addition order = display order.

To put Stats between Main and Merchant, the registration in Events.lua needs to happen AFTER StatsPanel registers itself. The cleanest fix: move the existing Events.lua sort-order block to call `InterfaceOptions_AddCategory` in a controlled order.

Currently Main is registered with `InterfaceOptions_AddCategory(_G["EbonClearanceOptionsMain"])` somewhere (around line 4539 per earlier grep). Find it and reorder.

Reorder the Events.lua block to:

```lua
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsMain"]) -- Main
-- StatsPanel registers itself in EbonClearance_StatsPanel.lua at file load.
-- The .toc loads StatsPanel BEFORE Events.lua so it appears in the
-- sub-panel list between Main (above) and Merchant (below).
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsMerchant"]) -- Merchant Settings
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsBlacklistSettings"]) -- Protection Settings
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsScavenger"]) -- Scavenger Settings
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsCharacter"]) -- Item Highlighting
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsWhitelist"]) -- Sell List
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsAccountWhitelist"]) -- Account Sell List
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsBlacklist"]) -- Keep List
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsDeletion"]) -- Delete List
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsProcessBags"]) -- Process Bags
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsProfiles"]) -- Profiles
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsImportExport"]) -- Import/Export
```

The issue: `InterfaceOptions_AddCategory` order in WoW determines list order. If StatsPanel.lua calls `InterfaceOptions_AddCategory(_G["EbonClearanceOptionsStats"])` at file load AND that file loads after Main registers (which happens at Events.lua file load), then Stats appears AFTER all the Events.lua registrations.

Cleanest fix: remove the auto-`InterfaceOptions_AddCategory` from `EbonClearance_StatsPanel.lua` and let `EbonClearance_Events.lua` register Stats explicitly in the desired position:

```lua
-- In EbonClearance_StatsPanel.lua, remove the trailing:
--   InterfaceOptions_AddCategory(_G["EbonClearanceOptionsStats"])
-- Events.lua will register it in the correct sort position.
```

Then in `EbonClearance_Events.lua` add `InterfaceOptions_AddCategory(_G["EbonClearanceOptionsStats"])` between Main and Merchant:

```lua
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsMain"]) -- Main
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsStats"]) -- Stats
InterfaceOptions_AddCategory(_G["EbonClearanceOptionsMerchant"]) -- Merchant Settings
-- ... rest unchanged
```

- [ ] **Step 2: Remove the AddCategory call from StatsPanel.lua**

Edit `EbonClearance_StatsPanel.lua` and delete the last line `InterfaceOptions_AddCategory(_G["EbonClearanceOptionsStats"])`. Replace with a comment:

```lua
-- Stats panel is registered with InterfaceOptions_AddCategory from
-- EbonClearance_Events.lua so its sort position (between Main and
-- Merchant) is controlled at one place.
```

- [ ] **Step 3: Update Test 80a to match**

Test 80a currently asserts:
```lua
statsSrc:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsStats"%]') ~= nil
```

The Stats file no longer has that call (it's in Events now). Update Test 80a to check Events.lua instead:

```lua
-- Replace 80a logic with:
local eventsFile = io.open("EbonClearance_Events.lua", "rb")
local eventsSrc = eventsFile and eventsFile:read("*a") or ""
if eventsFile then eventsFile:close() end
check(
    "Test 80a: EbonClearanceOptionsStats registered in sort position",
    statsSrc:find('CreateFrame%("Frame", "EbonClearanceOptionsStats"') ~= nil
        and eventsSrc:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsStats"%]') ~= nil
        and (eventsSrc:find('InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsStats"%].-InterfaceOptions_AddCategory%(_G%["EbonClearanceOptionsMerchant"%]')) ~= nil,
    "Stats panel must register in Events.lua between Main and Merchant"
)
```

- [ ] **Step 4: Run tests**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_StatsPanel.lua EbonClearance_Events.lua && lua tests/test_perf_guardrails.lua 2>&1 | grep -E "RESULT|FAIL|Test 80"`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add EbonClearance_StatsPanel.lua EbonClearance_Events.lua tests/test_perf_guardrails.lua
git commit -m "feat: register Stats sub-panel between Main and Merchant in InterfaceOptions sort order"
```

---

### Task 7: Phase 1 in-game verification checkpoint

Per the project memory rule "Pause for user verification before commit/push/tag", surface a checkpoint here. The user opens the game, opens Interface Options, confirms:

- [ ] **Step 1: Hand off to user**

Report status:
```
Phase 1 (Stats panel split) complete and committed:
- Stats panel exists at EbonClearance_StatsPanel.lua
- Sort order: Main / Stats / Merchant / ...
- MainPanel is welcome+orientation only
- RefreshStats writes to new panel
- All tests pass

Please verify in-game:
1. /reload
2. Open Interface Options → EbonClearance
3. Confirm "Main" sub-panel shows welcome + slash commands, no stats
4. Confirm new "Stats" sub-panel appears with all stat lines
5. Click Reset Lifetime Stats and confirm it works
6. Vendor some items and confirm stats update on the Stats panel
```

Wait for user confirmation before starting Phase 2.

---

## Phase 2: Help-link foundation (Tasks 8-13)

### Task 8: Add `id` fields to existing help entries

**Files:**
- Modify: `EbonClearance_HelpPanel.lua`

- [ ] **Step 1: Write failing tests for id presence + uniqueness**

Add to `tests/test_perf_guardrails.lua` before the result section:

```lua
-- ---------------------------------------------------------------------------
-- Test 79: every Help entry has a non-empty unique id.
-- ---------------------------------------------------------------------------
-- Settings panels deep-link into Help via these ids (see NS.AddHelpIcon /
-- NS.OpenHelpEntry). If two entries share an id, the deep-link is
-- ambiguous; if an entry lacks an id, no panel can link to it.
do
    local helpFile = io.open("EbonClearance_HelpPanel.lua", "rb")
    if helpFile then
        local src = helpFile:read("*a") or ""
        helpFile:close()
        local idsSeen = {}
        local duplicates = {}
        for id in src:gmatch('id = "([^"]+)"') do
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && lua tests/test_perf_guardrails.lua 2>&1 | grep "Test 79"`
Expected: FAIL with "Count: 0 unique" because no entries have ids yet.

- [ ] **Step 3: Add id fields to every content entry**

In `EbonClearance_HelpPanel.lua`, edit each content entry in `EC_HELP_ENTRIES`. Section markers (entries with `section = "key"`) do NOT get ids. Content entries (those with `q = "..."` and `a = "..."`) DO. Use kebab-case stable identifiers.

Full mapping (in order — these MUST be unique):

**Section 1: Getting started**
- "What does EbonClearance do?" → `id = "what-does-ec-do"`
- "I just installed this..." → `id = "first-steps"`
- "What are the Sell, Keep, and Delete lists?" → `id = "what-are-the-lists"`
- "How do I see what will happen to an item?" → `id = "see-item-decision"`
- "What are the slash commands?" → `id = "slash-commands"`

**Section 2: Troubleshooting**
- "Why isn't this item selling?" → `id = "tshoot-why-not-selling"`
- "EbonClearance keeps adding my equipped gear..." → `id = "tshoot-equipped-keep"`
- "Items keep appearing on the Keep List as 'Keep (upgrade)'..." → `id = "tshoot-upgrade-keep"`
- "What does 'Keep (affix rank known)'..." → `id = "tshoot-affix-rank"`
- "Why are my Sell / Keep / Delete lists different..." → `id = "tshoot-per-char-lists"`
- "How do I share a Sell List..." → `id = "share-sell-list-across-chars"`
- "The Goblin Merchant isn't being summoned..." → `id = "tshoot-goblin-not-summoning"`
- "The bag-slot border colors aren't showing." → `id = "tshoot-bag-borders"`
- "How do I disable EbonClearance on one specific character?" → `id = "tshoot-disable-per-char"`
- "How do I see exactly why a bag item will or won't sell?" → `id = "tshoot-sellinfo"`

**Section 3: How sell decisions work**
- "Order of checks" → `id = "gate-order-of-checks"`
- "Grey items always sell" → `id = "gate-grey-items"`
- "Items must have a vendor price" → `id = "gate-vendor-price"`
- "Quality rules (White / Green / Blue / Epic)" → `id = "gate-quality-rules"`
- "Fixed iLvl cap vs. Use equipped iLvl" → `id = "gate-fixed-vs-equipped-ilvl"`
- "Bind-type filter" → `id = "gate-bind-type"`
- "Currently-equipped items never sell" → `id = "gate-equipped-never-sells"`
- "Keep List blocks selling" → `id = "gate-keep-list-blocks"`
- "Project Ebonhold affix protection" → `id = "gate-affix-protection"`
- "Allow exact-rank duplicates" → `id = "gate-allow-rank-dupes"`
- "Manual Allow Sell (Alt+Right-Click)" → `id = "gate-manual-allow-sell"`
- "Chance-on-hit protection" → `id = "gate-chance-on-hit"`
- "Tome / recipe protection" → `id = "gate-tome-recipe"`
- "Quest item safety net" → `id = "gate-quest-items"`
- "Profession tool safety net" → `id = "gate-profession-tools"`
- "Delete List path" → `id = "gate-delete-list"`

**Section 4: Tooltip labels**
- Each tooltip label gets `id = "label-<simplified-label>"`:
  - "Keep" → `id = "label-keep"`
  - "Keep (equipped)" → `id = "label-keep-equipped"`
  - "Keep (upgrade)" → `id = "label-keep-upgrade"`
  - "Keep (in gear set)" → `id = "label-keep-gear-set"`
  - "Keep (auto)" → `id = "label-keep-auto"`
  - "Keep (quest item)" → `id = "label-keep-quest"`
  - "Keep (profession tool)" → `id = "label-keep-prof-tool"`
  - "Keep (affix rank known)" → `id = "label-affix-rank-known"`
  - "Keep (affix rank needed)" → `id = "label-affix-rank-needed"`
  - "Keep (chance-on-hit proc)" → `id = "label-chance-on-hit"`
  - "Keep (new Tome) / Keep (new Recipe)" → `id = "label-new-tome-recipe"`
  - "Keep (Tome you have) / Keep (Recipe you have)" → `id = "label-tome-have"`
  - "Will Sell" → `id = "label-will-sell"`
  - "Will Sell (your Account List)" → `id = "label-will-sell-account"`
  - "Will Sell (your Character List)" → `id = "label-will-sell-char"`
  - "Will Sell (junk)" → `id = "label-will-sell-junk"`
  - "Will Sell (Blue, lower than equipped), etc." → `id = "label-will-sell-quality-rule"`
  - "Will Sell (you have this affix)" → `id = "label-will-sell-affix-dupe"`
  - "Will Delete" → `id = "label-will-delete"`
  - "Won't Sell (equipped)" → `id = "label-wont-sell-equipped"`
  - "Won't Sell (no value)" → `id = "label-wont-sell-no-value"`
  - "Override on - add to a list to sell" → `id = "label-override-no-rule"`

**Section 5: Reporting bugs**
- "Found a bug?..." → `id = "bug-report-flow"`
- "What does /ec bugreport include?" → `id = "bug-report-contents"`
- "Direct message vs. the thread" → `id = "bug-dm-vs-thread"`

For each entry, add `id = "<the-id>",` as the first or second field, e.g.:

```lua
{
    id = "what-does-ec-do",
    q = "What does EbonClearance do?",
    a = "...",
    panel = nil,
},
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_HelpPanel.lua && lua tests/test_perf_guardrails.lua 2>&1 | grep "Test 79"`
Expected: PASS with "at least 40 unique help entry ids exist".

- [ ] **Step 5: Commit**

```bash
git add EbonClearance_HelpPanel.lua tests/test_perf_guardrails.lua
git commit -m "feat: add stable id fields to every Help entry (Test 79 invariant)"
```

---

### Task 9: Add Process Bags Help section

**Files:**
- Modify: `EbonClearance_HelpPanel.lua`

- [ ] **Step 1: Write failing test for new section + entries**

Append to `tests/test_perf_guardrails.lua`:

```lua
-- ---------------------------------------------------------------------------
-- Test 81: Process Bags Help section exists with 5 entries.
-- ---------------------------------------------------------------------------
do
    local helpFile = io.open("EbonClearance_HelpPanel.lua", "rb")
    if helpFile then
        local src = helpFile:read("*a") or ""
        helpFile:close()
        check(
            "Test 81a: processBags section marker exists",
            src:find('section = "processBags"') ~= nil,
            "EC_HELP_ENTRIES must include a processBags section marker"
        )
        local expected = {
            "process-bags-overview",
            "process-disenchant",
            "process-mill",
            "process-prospect",
            "process-picklocks",
        }
        for _, id in ipairs(expected) do
            check(
                "Test 81b: Process Bags entry id '" .. id .. "' exists",
                src:find('id = "' .. id .. '"') ~= nil,
                "Process Bags help entry with id '" .. id .. "' must exist"
            )
        end
    end
end
```

- [ ] **Step 2: Run failing test**

Run: `lua tests/test_perf_guardrails.lua 2>&1 | grep "Test 81"`
Expected: All 6 Test 81 assertions fail.

- [ ] **Step 3: Add the Process Bags section to EC_HELP_ENTRIES**

In `EbonClearance_HelpPanel.lua`, insert this block between Section 4 (Tooltip labels) and Section 5 (Reporting bugs):

```lua
    -- ===================================================================
    -- Section 5: Process Bags
    -- ===================================================================
    { section = "processBags", title = "Process Bags" },

    {
        id = "process-bags-overview",
        q = "What does Process Bags do?",
        a = "Process Bags is a bulk processor for materials in your bags. Open it from /ec, pick a mode (Disenchant, Mill, Prospect, or Pick Locks), and the addon arms your cursor with the matching spell or item. Click bag slots in sequence; the addon respects the spell's cooldown and skips items that don't qualify. Useful for turning a stack of green drops into Enchant dust without 30 manual right-clicks.",
        panel = "EbonClearanceOptionsProcessBags",
    },
    {
        id = "process-disenchant",
        q = "Disenchant mode",
        a = "Requires the Enchanting profession. Arms Disenchant on your cursor. Click bag slots holding Uncommon (Green) or Rare (Blue) Weapons / Armor to turn them into Enchanting dust, essences, and shards. Items without Enchanting eligibility are skipped.",
        panel = "EbonClearanceOptionsProcessBags",
    },
    {
        id = "process-mill",
        q = "Mill mode",
        a = "Requires Inscription. Arms Milling on your cursor. Click bag slots holding stacks of 5+ herbs to turn them into pigments. Stacks smaller than 5 are skipped.",
        panel = "EbonClearanceOptionsProcessBags",
    },
    {
        id = "process-prospect",
        q = "Prospect mode",
        a = "Requires Jewelcrafting. Arms Prospecting on your cursor. Click bag slots holding stacks of 5+ ore to turn them into gems and rare prospects. Stacks smaller than 5 are skipped.",
        panel = "EbonClearanceOptionsProcessBags",
    },
    {
        id = "process-picklocks",
        q = "Pick Locks mode",
        a = "Requires the Rogue Pick Lock ability. Arms Pick Lock on your cursor. Click bag slots holding lockboxes (Junkboxes, Mageweave Pouches, Heavy Junkboxes, etc.) to open them.",
        panel = "EbonClearanceOptionsProcessBags",
    },

```

- [ ] **Step 4: Update OnShow defaults to include processBags**

In the OnShow handler:

```lua
    if type(DB.helpSectionsCollapsed) ~= "table" then
        DB.helpSectionsCollapsed = {
            gettingStarted = true,
            troubleshooting = true,
            gates = true,
            labels = true,
            processBags = true,
            discord = true,
        }
    end
    for _, key in ipairs({ "gettingStarted", "troubleshooting", "gates", "labels", "processBags", "discord" }) do
        if type(DB.helpSectionsCollapsed[key]) ~= "boolean" then
            DB.helpSectionsCollapsed[key] = true
        end
    end
```

- [ ] **Step 5: Update Test 73 to expect 6 section markers**

In `tests/test_perf_guardrails.lua`, find Test 73 and change:

```lua
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
```

- [ ] **Step 6: Run all tests**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_HelpPanel.lua && lua tests/test_perf_guardrails.lua 2>&1 | grep -E "RESULT|FAIL"`
Expected: All tests pass, including Test 73, 79, 81.

- [ ] **Step 7: Commit**

```bash
git add EbonClearance_HelpPanel.lua tests/test_perf_guardrails.lua
git commit -m "feat: add Process Bags Help section (5 entries) and ids"
```

---

### Task 10: Build `NS.AddHelpIcon` widget helper

**Files:**
- Modify: `EbonClearance_PanelWidgets.lua`

- [ ] **Step 1: Write failing test**

Add to `tests/test_perf_guardrails.lua`:

```lua
-- ---------------------------------------------------------------------------
-- Test 82: NS.AddHelpIcon exists in EbonClearance_PanelWidgets.lua.
-- ---------------------------------------------------------------------------
do
    local f = io.open("EbonClearance_PanelWidgets.lua", "rb")
    if f then
        local src = f:read("*a") or ""
        f:close()
        check(
            "Test 82: NS.AddHelpIcon helper is defined",
            src:find("NS%.AddHelpIcon") ~= nil
                and src:find("function .*AddHelpIcon") ~= nil,
            "EbonClearance_PanelWidgets.lua must define NS.AddHelpIcon as a panel-widget primitive"
        )
    end
end
```

- [ ] **Step 2: Run failing test**

Run: `lua tests/test_perf_guardrails.lua 2>&1 | grep "Test 82"`
Expected: FAIL.

- [ ] **Step 3: Implement MakeHelpIcon**

In `EbonClearance_PanelWidgets.lua`, after the existing `MakeLabel` or `MakeHeader` (find a good spot near other widget primitives), add:

```lua
-- MakeHelpIcon: small clickable [?] anchored next to a setting. Click
-- deep-links into the Help panel via NS.OpenHelpEntry(entryId), which
-- opens Help, expands the section containing the target entry, scrolls
-- the entry to the top of the viewport, and briefly flashes it.
--
-- Args:
--   parent       - frame to parent the icon to
--   anchorWidget - widget to anchor next to (the setting's label or row)
--   anchorPoint  - anchor on the icon (typically "LEFT")
--   relPoint     - anchor on the target (typically "RIGHT")
--   xOff, yOff   - pixel offset
--   entryId      - stable id of the Help entry to deep-link to
--
-- Returns the Button frame so the caller can chain further anchors.
local function MakeHelpIcon(parent, anchorWidget, anchorPoint, relPoint, xOff, yOff, entryId)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(20, 18)
    btn:SetPoint(anchorPoint, anchorWidget, relPoint, xOff or 4, yOff or 0)
    btn:RegisterForClicks("LeftButtonUp")

    local fs = btn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetAllPoints(btn)
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("MIDDLE")
    fs:SetText("|cffffff00[?]|r")
    btn:SetFontString(fs)

    -- Hover highlight.
    btn:SetScript("OnEnter", function(self)
        fs:SetText("|cffffffaa[?]|r")
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Click for help", 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function()
        fs:SetText("|cffffff00[?]|r")
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)

    btn:SetScript("OnClick", function()
        if NS.OpenHelpEntry then
            NS.OpenHelpEntry(entryId)
        end
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    return btn
end
NS.AddHelpIcon = MakeHelpIcon
```

- [ ] **Step 4: Add `GameTooltip` and `PlaySound` to .luacheckrc if not already allowed**

Check `.luacheckrc` — `GameTooltip` and `PlaySound` should already be in the globals list. If `GameTooltip` is missing, add it. `PlaySound` is already there (verified earlier).

- [ ] **Step 5: Run tests**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_PanelWidgets.lua && lua tests/test_perf_guardrails.lua 2>&1 | grep -E "Test 82|RESULT"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add EbonClearance_PanelWidgets.lua tests/test_perf_guardrails.lua .luacheckrc
git commit -m "feat: NS.AddHelpIcon panel-widget primitive (clickable [?] icon)"
```

---

### Task 11: Build `NS.OpenHelpEntry(entryId)` API

**Files:**
- Modify: `EbonClearance_HelpPanel.lua`

- [ ] **Step 1: Write failing test**

```lua
-- ---------------------------------------------------------------------------
-- Test 83: NS.OpenHelpEntry deep-link API is defined.
-- ---------------------------------------------------------------------------
do
    local f = io.open("EbonClearance_HelpPanel.lua", "rb")
    if f then
        local src = f:read("*a") or ""
        f:close()
        check(
            "Test 83: NS.OpenHelpEntry exists and references InterfaceOptionsFrame_OpenToCategory",
            src:find("NS%.OpenHelpEntry") ~= nil
                and src:find("function .*OpenHelpEntry") ~= nil
                and src:find("InterfaceOptionsFrame_OpenToCategory") ~= nil
                and src:find("_pendingScrollEntryId") ~= nil,
            "HelpPanel must define NS.OpenHelpEntry that opens the Help panel and stashes a _pendingScrollEntryId for refreshLayout to consume"
        )
    end
end
```

- [ ] **Step 2: Run failing test**

Run: `lua tests/test_perf_guardrails.lua 2>&1 | grep "Test 83"`
Expected: FAIL.

- [ ] **Step 3: Implement NS.OpenHelpEntry**

In `EbonClearance_HelpPanel.lua`, near the bottom (before the file's final `InterfaceOptions_AddCategory` call if present, otherwise after the OnShow handler), add:

```lua
-- NS.OpenHelpEntry(entryId): deep-link from settings panels into the
-- Help panel's specific entry. Steps:
--   1. Find which section owns the entry (by walking EC_HELP_ENTRIES).
--   2. Set DB.helpSectionsCollapsed[ownerSection] = false so the section
--      auto-expands when the panel shows.
--   3. Stash HelpPanel._pendingScrollEntryId so the refreshLayout pass
--      knows to scroll the target widget into view + flash it.
--   4. Open InterfaceOptions to the Help panel (double-call for the
--      3.3.5a workaround).
function NS.OpenHelpEntry(entryId)
    if not entryId then
        -- Defensive: bare open without scroll.
        if InterfaceOptionsFrame_OpenToCategory and _G["EbonClearanceOptionsHelp"] then
            InterfaceOptionsFrame_OpenToCategory(_G["EbonClearanceOptionsHelp"])
            InterfaceOptionsFrame_OpenToCategory(_G["EbonClearanceOptionsHelp"])
        end
        return
    end

    -- Walk EC_HELP_ENTRIES to find the owning section.
    local ownerSection = nil
    for _, entry in ipairs(EC_HELP_ENTRIES) do
        if entry.section then
            ownerSection = entry.section
        elseif entry.id == entryId then
            break
        end
    end

    -- Expand the owning section so the entry is visible.
    if NS.DB and ownerSection then
        NS.DB.helpSectionsCollapsed = NS.DB.helpSectionsCollapsed or {}
        NS.DB.helpSectionsCollapsed[ownerSection] = false
    end

    -- Stash the pending scroll target for refreshLayout's post-pass.
    HelpPanel._pendingScrollEntryId = entryId

    -- Open the panel (double-call for the 3.3.5a workaround).
    if InterfaceOptionsFrame_OpenToCategory and _G["EbonClearanceOptionsHelp"] then
        InterfaceOptionsFrame_OpenToCategory(_G["EbonClearanceOptionsHelp"])
        InterfaceOptionsFrame_OpenToCategory(_G["EbonClearanceOptionsHelp"])
    end
end
```

Note: `HelpPanel` is the local frame created earlier in the file. If `NS.OpenHelpEntry` is defined at file scope after the `local HelpPanel = CreateFrame(...)` line, it can reference `HelpPanel` directly. Confirm the placement order; if needed, define `NS.OpenHelpEntry` immediately after `HelpPanel`'s creation.

- [ ] **Step 4: Run tests**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_HelpPanel.lua && lua tests/test_perf_guardrails.lua 2>&1 | grep -E "Test 83|RESULT"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EbonClearance_HelpPanel.lua tests/test_perf_guardrails.lua
git commit -m "feat: NS.OpenHelpEntry deep-link API"
```

---

### Task 12: Wire scroll-to-entry + flash effect into refreshLayout

**Files:**
- Modify: `EbonClearance_HelpPanel.lua`

- [ ] **Step 1: Add the scroll-to-entry pass at the end of refreshLayout**

Find the `refreshLayout(panel)` function in HelpPanel.lua. After the existing widget-anchor loop and the `FitScrollContent` call, add the scroll-to-entry logic:

```lua
        -- Pending deep-link from NS.OpenHelpEntry. Scroll the target
        -- entry to the top of the viewport and flash it briefly.
        if panel._pendingScrollEntryId then
            local targetId = panel._pendingScrollEntryId
            panel._pendingScrollEntryId = nil

            -- Locate the renderItem with matching id. EC_HELP_ENTRIES is
            -- ordered; renderItems is built in the same order so we can
            -- walk renderItems and match against entry ids via a
            -- parallel index.
            local targetWidget = nil
            local idx = 0
            for _, entry in ipairs(EC_HELP_ENTRIES) do
                if not entry.section then
                    idx = idx + 1
                    if entry.id == targetId then
                        -- The Nth content entry corresponds to the Nth
                        -- "q" renderItem. renderItems contains section,
                        -- q, a, button (optional), sep entries; find the
                        -- Nth q widget.
                        local qCount = 0
                        for _, item in ipairs(items) do
                            if item.kind == "q" then
                                qCount = qCount + 1
                                if qCount == idx then
                                    targetWidget = item.widget
                                    break
                                end
                            end
                        end
                        break
                    end
                end
            end

            if targetWidget then
                -- Compute scroll offset so the target widget sits at the
                -- top of the OUTER scroll viewport.
                local scrollName = (panel:GetName() or "EbonClearanceOptionsHelp") .. "Scroll"
                local scrollFrame = _G[scrollName]
                if scrollFrame and scrollFrame.SetVerticalScroll then
                    -- Defer the scroll by 0.1s + 0.5s so FontString
                    -- heights settle (same two-pass pattern as
                    -- FitScrollContent).
                    local function doScroll()
                        if not targetWidget.GetTop or not scrollFrame.GetTop then
                            return
                        end
                        local widgetTop = targetWidget:GetTop()
                        local scrollTop = scrollFrame:GetTop()
                        if not widgetTop or not scrollTop then
                            return
                        end
                        local offset = scrollTop - widgetTop
                        if offset < 0 then offset = 0 end
                        -- Clamp to verticalScrollRange.
                        local range = scrollFrame:GetVerticalScrollRange() or 0
                        if offset > range then offset = range end
                        scrollFrame:SetVerticalScroll(offset)
                    end
                    if NS.Delay then
                        NS.Delay(0.1, doScroll)
                        NS.Delay(0.5, doScroll)
                    else
                        doScroll()
                    end
                end

                -- Flash: yellow tint pulse for 0.5s.
                if targetWidget.SetTextColor and NS.Delay then
                    targetWidget:SetTextColor(1, 1, 0.4)
                    NS.Delay(0.5, function()
                        if targetWidget.SetTextColor then
                            -- Restore the colour code embedded in the
                            -- q FontString text. Setting (1,1,0) keeps
                            -- the |cff...|r override active.
                            targetWidget:SetTextColor(1, 1, 1)
                        end
                    end)
                end
            end
        end
```

Insert this block at the bottom of `refreshLayout`, after the existing `if prev and NS.FitScrollContent then ... end` block.

- [ ] **Step 2: Write a test that the scroll-to logic exists**

```lua
-- Append to existing Test 83 block or as Test 83a:
check(
    "Test 83a: HelpPanel refreshLayout consumes _pendingScrollEntryId with SetVerticalScroll",
    helpSrc:find("_pendingScrollEntryId") ~= nil
        and helpSrc:find("SetVerticalScroll") ~= nil
        and helpSrc:find("targetWidget:SetTextColor") ~= nil,
    "refreshLayout must read _pendingScrollEntryId, set the outer scroll's verticalScroll, and apply a flash tint to the target widget"
)
```

(Add the helpSrc local at top of the test scope to make this work.)

- [ ] **Step 3: Run tests**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_HelpPanel.lua && lua tests/test_perf_guardrails.lua 2>&1 | grep -E "Test 83|RESULT"`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add EbonClearance_HelpPanel.lua tests/test_perf_guardrails.lua
git commit -m "feat: scroll-to-entry + flash effect for NS.OpenHelpEntry"
```

---

### Task 13: Add Test 78 cross-reference integrity

**Files:**
- Modify: `tests/test_perf_guardrails.lua`

- [ ] **Step 1: Write the cross-reference check**

```lua
-- ---------------------------------------------------------------------------
-- Test 78: every NS.AddHelpIcon call references an entry id that exists.
-- ---------------------------------------------------------------------------
-- Settings panels deep-link into Help via NS.AddHelpIcon(..., "entryId").
-- This test scans every settings panel file for those calls and verifies
-- each referenced id exists in EC_HELP_ENTRIES. Catches drift when a Help
-- entry is renamed or removed without updating the panels that link to it.
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
                -- Match NS.AddHelpIcon(parent, anchor, point1, point2, x, y, "entryId")
                -- The id is the LAST string arg in the call. Pattern looks
                -- for AddHelpIcon followed by a quoted string before the ).
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
```

- [ ] **Step 2: Run test**

Run: `lua tests/test_perf_guardrails.lua 2>&1 | grep "Test 78"`
Expected: PASS (no panels have AddHelpIcon calls yet, so there are zero references and the test trivially passes).

- [ ] **Step 3: Commit**

```bash
git add tests/test_perf_guardrails.lua
git commit -m "test: Test 78 cross-reference integrity for NS.AddHelpIcon entryIds"
```

---

### Task 14: Phase 2 foundation in-game checkpoint

- [ ] **Step 1: Hand off to user for in-game verification**

Report:
```
Phase 2 foundation complete:
- Every Help entry has a stable id
- New "Process Bags" Help section with 5 entries
- NS.AddHelpIcon widget primitive
- NS.OpenHelpEntry(id) deep-link API + scroll-to + flash
- Test 73, 78, 79, 81, 82, 83 all passing

Please verify in-game:
1. /reload
2. Open Help panel; expand "Process Bags" section
3. Confirm the 5 new entries render correctly
4. (No [?] icons exist yet on other panels - that's the next phase)
```

Wait for confirmation before per-panel migration.

---

## Phase 3: Per-panel migration (Tasks 15-22)

The migration tasks share a pattern: per panel, strip the duplicated explanation text, then add `NS.AddHelpIcon` next to each toggle/group. Each task is one panel.

### Task 15: Migrate Protection Settings panel

**Files:**
- Modify: `EbonClearance_ProtectionPanel.lua`

- [ ] **Step 1: Audit existing notes**

Read the panel file end-to-end. Identify each FontString that exists only to describe a setting (typically `setPanelWidth(noteFs, 16)` with multi-line `SetText` content). List them.

- [ ] **Step 2: Strip each duplicated note**

For each note, delete its FontString creation block. Update the anchor chain so the next widget anchors to whatever the deleted note was anchored to.

- [ ] **Step 3: Add [?] icons next to each toggle/group**

For each setting, add a call to `NS.AddHelpIcon` right after creating the toggle. Mapping:

```lua
-- After creating the "Keep gear you're wearing" checkbox:
NS.AddHelpIcon(self, autoEquipCB, "LEFT", "RIGHT", 8, 0, "gate-equipped-never-sells")

-- After "Keep looted upgrades":
NS.AddHelpIcon(self, autoUpgradeCB, "LEFT", "RIGHT", 8, 0, "label-keep-upgrade")

-- After "Keep gear sets":
NS.AddHelpIcon(self, autoGearSetCB, "LEFT", "RIGHT", 8, 0, "label-keep-gear-set")

-- After "Allow exact-rank duplicates":
NS.AddHelpIcon(self, allowDupesCB, "LEFT", "RIGHT", 8, 0, "gate-allow-rank-dupes")

-- After "Protect chance-on-hit":
NS.AddHelpIcon(self, protectProcCB, "LEFT", "RIGHT", 8, 0, "gate-chance-on-hit")

-- After "Protect tomes / recipes":
NS.AddHelpIcon(self, protectTomesCB, "LEFT", "RIGHT", 8, 0, "gate-tome-recipe")
```

(Replace the variable names with the actual checkbox locals from the file.)

- [ ] **Step 4: Keep one-line panel intro**

The panel should still have a heading + 1-2 sentences explaining what the panel is for. The detailed per-toggle notes go away; the panel-level description stays terse.

- [ ] **Step 5: Run syntax + tests**

Run: `cd "c:/Users/chris/Wow Addons/EbonClearance" && luac -p EbonClearance_ProtectionPanel.lua && lua tests/test_perf_guardrails.lua 2>&1 | grep -E "RESULT|FAIL"`
Expected: All tests pass, including Test 78 (cross-reference) verifying every entryId exists.

- [ ] **Step 6: Commit**

```bash
git add EbonClearance_ProtectionPanel.lua
git commit -m "refactor: strip duplicated notes from Protection Settings; add [?] help icons"
```

- [ ] **Step 7: In-game verification checkpoint**

Hand off:
```
Protection Settings migration complete. Please verify in-game:
1. /reload
2. Open Interface Options → EbonClearance → Protection Settings
3. Confirm panel is visibly shorter (notes removed)
4. Confirm each toggle has a [?] icon to its right
5. Hover one [?] - tooltip should show "Click for help"
6. Click one [?] - Help panel should open, correct section expand, entry highlight briefly
7. Confirm all toggles still function (tick/untick saves state)
```

Wait for user OK before next panel.

---

### Task 16: Migrate Merchant Settings panel

**Files:**
- Modify: `EbonClearance_MerchantPanel.lua`

- [ ] **Step 1-4: Same migration pattern**

Use the same audit-strip-add pattern. Mapping for AddHelpIcon entry IDs:

```lua
-- Per-rarity rule groups (each row of: rarity label + iLvl mode picker
-- + iLvl input + bind dropdown). Add ONE [?] per rarity row anchored at
-- the end of the row, linking to the quality-rules gate.
NS.AddHelpIcon(self, whiteRowAnchor, "LEFT", "RIGHT", 8, 0, "gate-quality-rules")
NS.AddHelpIcon(self, greenRowAnchor, "LEFT", "RIGHT", 8, 0, "gate-quality-rules")
NS.AddHelpIcon(self, blueRowAnchor, "LEFT", "RIGHT", 8, 0, "gate-quality-rules")
NS.AddHelpIcon(self, epicRowAnchor, "LEFT", "RIGHT", 8, 0, "gate-quality-rules")

-- iLvl mode picker (Fixed vs Use equipped):
NS.AddHelpIcon(self, ilvlModeDropdown, "LEFT", "RIGHT", 8, 0, "gate-fixed-vs-equipped-ilvl")

-- Bind-type filter dropdown:
NS.AddHelpIcon(self, bindFilterDropdown, "LEFT", "RIGHT", 8, 0, "gate-bind-type")
```

- [ ] **Step 5: Verify + commit + checkpoint** (same pattern as Task 15)

```bash
git add EbonClearance_MerchantPanel.lua
git commit -m "refactor: strip duplicated notes from Merchant Settings; add [?] help icons"
```

---

### Task 17: Migrate Scavenger Settings panel

**Files:**
- Modify: `EbonClearance_ScavengerPanel.lua`

- [ ] **Step 1-5: Same pattern.** Mapping:

```lua
-- Top of panel:
NS.AddHelpIcon(self, panelHeader, "LEFT", "RIGHT", 8, 0, "tshoot-goblin-not-summoning")

-- Per-toggle:
NS.AddHelpIcon(self, summonScavengerCB, "LEFT", "RIGHT", 8, 0, "tshoot-goblin-not-summoning")
NS.AddHelpIcon(self, autoLootCycleCB, "LEFT", "RIGHT", 8, 0, "tshoot-goblin-not-summoning")
```

- [ ] **Step 6: Commit + checkpoint**

```bash
git add EbonClearance_ScavengerPanel.lua
git commit -m "refactor: strip duplicated notes from Scavenger Settings; add [?] help icons"
```

---

### Task 18: Migrate Item Highlighting panel

**Files:**
- Modify: `EbonClearance_ItemHighlightingPanel.lua`

Mapping:
```lua
NS.AddHelpIcon(self, enableTintsCB, "LEFT", "RIGHT", 8, 0, "tshoot-bag-borders")
-- Per-category checkboxes (Delete, Account Sell, Character Sell, Junk, Rule):
NS.AddHelpIcon(self, deleteCategoryCB, "LEFT", "RIGHT", 8, 0, "tshoot-bag-borders")
-- ... etc per category
```

Commit + checkpoint as before.

---

### Task 19: Migrate Process Bags panel

**Files:**
- Modify: `EbonClearance_ProcessBagsPanel.lua`

Mapping:
```lua
-- Top-of-panel general help:
NS.AddHelpIcon(self, panelHeader, "LEFT", "RIGHT", 8, 0, "process-bags-overview")

-- Per-mode dropdown / button:
NS.AddHelpIcon(self, disenchantModeBtn, "LEFT", "RIGHT", 8, 0, "process-disenchant")
NS.AddHelpIcon(self, millModeBtn, "LEFT", "RIGHT", 8, 0, "process-mill")
NS.AddHelpIcon(self, prospectModeBtn, "LEFT", "RIGHT", 8, 0, "process-prospect")
NS.AddHelpIcon(self, picklocksModeBtn, "LEFT", "RIGHT", 8, 0, "process-picklocks")
```

Commit + checkpoint.

---

### Task 20: Migrate list panels (Sell + Account Sell + Keep + Delete)

**Files:**
- Modify: `EbonClearance_SellListPanels.lua` (Sell List + Account Sell List)
- Modify: `EbonClearance_KeepDeletePanels.lua` (Keep List + Delete List)

For each list panel: ONE `[?]` icon at the top of the panel, anchored next to the heading or description, linking to `what-are-the-lists`.

- Sell List → `what-are-the-lists`
- Account Sell List → `share-sell-list-across-chars`
- Keep List → `what-are-the-lists`
- Delete List → `what-are-the-lists`

```lua
-- Example for Keep List in EbonClearance_KeepDeletePanels.lua:
NS.AddHelpIcon(self, headerFontString, "LEFT", "RIGHT", 8, 0, "what-are-the-lists")
```

Commit each file separately so each panel's change is isolated:

```bash
git add EbonClearance_SellListPanels.lua
git commit -m "refactor: add [?] help icons to Sell List + Account Sell List"

git add EbonClearance_KeepDeletePanels.lua
git commit -m "refactor: add [?] help icons to Keep List + Delete List"
```

Single checkpoint at the end (these are similar enough).

---

### Task 21: Migrate Profiles + Import/Export

**Files:**
- Modify: `EbonClearance_ProfilesPanel.lua`

We need two new Help entries first (the spec mentioned this). Add to `EC_HELP_ENTRIES` in `EbonClearance_HelpPanel.lua`:

- New entry in Section 1 (Getting started) or Section 2 (Troubleshooting): "What are Profiles?" → `id = "what-are-profiles"`
- New entry: "What does Import/Export do?" → `id = "what-is-import-export"`

Insert them in the existing structure (Getting started is the natural fit).

Then in `EbonClearance_ProfilesPanel.lua`:

```lua
NS.AddHelpIcon(self, profilesHeader, "LEFT", "RIGHT", 8, 0, "what-are-profiles")
NS.AddHelpIcon(self, importExportHeader, "LEFT", "RIGHT", 8, 0, "what-is-import-export")
```

Commit:
```bash
git add EbonClearance_HelpPanel.lua EbonClearance_ProfilesPanel.lua
git commit -m "feat: add Profiles + Import/Export help entries and [?] icons"
```

Checkpoint with user.

---

### Task 22: Main + Stats panel-level [?]

**Files:**
- Modify: `EbonClearance_MainPanel.lua`
- Modify: `EbonClearance_StatsPanel.lua`

Add one [?] at the top of each:

```lua
-- MainPanel:
NS.AddHelpIcon(self, heading, "LEFT", "RIGHT", 8, 0, "what-does-ec-do")

-- StatsPanel:
NS.AddHelpIcon(panel, heading, "LEFT", "RIGHT", 8, 0, "what-does-ec-do")
-- (or a new stats-specific entry if you'd rather - not required)
```

Commit:
```bash
git add EbonClearance_MainPanel.lua EbonClearance_StatsPanel.lua
git commit -m "feat: add [?] help icons to Main + Stats panel headers"
```

---

## Phase 4: Final integration (Tasks 23-25)

### Task 23: Final luacheck + stylua sweep

- [ ] **Step 1: Run linters**

```bash
cd "c:/Users/chris/Wow Addons/EbonClearance"
stylua *.lua
luacheck *.lua
```

Expected: stylua makes no changes (or only minor whitespace), luacheck reports 0 warnings.

- [ ] **Step 2: Fix any warnings**

If luacheck reports new globals (`GameTooltip`, etc.), add them to `.luacheckrc`. Don't silence with blanket directives.

- [ ] **Step 3: Run all three test suites**

```bash
lua tests/test_perf_guardrails.lua && lua tests/test_layout_reactivity.lua && lua tests/test_no_addon_references.lua
```

Expected: all pass.

- [ ] **Step 4: Commit any lint fixes**

```bash
git add -p
git commit -m "chore: stylua + luacheck cleanup post-migration"
```

---

### Task 24: Update CHANGELOG.md

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the version entry**

Pick the next version (e.g. v2.36.0). Add a stanza:

```markdown
### v2.36.0

**Help system + panel cleanup pass.**

- New **Stats** sub-panel. Stats widgets (money earned, items sold, items deleted, repairs, repair cost, session and best gold-per-hour, average worth, most sold) move off the Main panel onto their own sub-panel between Main and Merchant Settings. The Main panel now reads as a welcome page.
- New **Process Bags** Help section. Five new entries cover what Process Bags does and each mode (Disenchant / Mill / Prospect / Pick Locks).
- Every dense settings panel now has clickable `[?]` icons next to each setting. Clicking `[?]` opens the Help panel, expands the relevant section, scrolls the target entry to the top, and briefly highlights it.
- Panel notes simplified across the board. Protection Settings, Merchant Settings, Scavenger Settings, Item Highlighting, and Process Bags now read at a glance; detailed explanations live in the Help panel.
- Help entries have stable ids so deep-links survive future text edits.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: CHANGELOG.md v2.36.0 entry"
```

---

### Task 25: Final acceptance run + tag

- [ ] **Step 1: Full test sweep**

```bash
cd "c:/Users/chris/Wow Addons/EbonClearance"
luac -p *.lua  # syntax check every file
stylua --check *.lua
luacheck *.lua
lua tests/test_perf_guardrails.lua
lua tests/test_layout_reactivity.lua
lua tests/test_no_addon_references.lua
```

Expected: all clean, all passing.

- [ ] **Step 2: Hand off final acceptance to user**

```
v2.36.0 ready. All tests pass, no luacheck warnings, stylua clean.

Final in-game verification:
1. /reload on a fresh character with no SavedVariables
2. Walk the full settings tree: Main → Stats → Merchant → Protection → Scavenger → Highlighting → Sell List → Account Sell List → Keep List → Delete List → Process Bags → Profiles → Import/Export → Help
3. Confirm each [?] click takes you to the right help entry
4. Confirm the Stats panel shows after some vendor activity
5. Confirm the Help panel "Process Bags" section reads cleanly

When happy, push the tag:
  git push origin master
  git tag v2.36.0
  git push origin v2.36.0
The release workflow will package + publish.
```

Wait for user to push the tag. Don't auto-tag per the verify-then-ship rule.

---

## Self-review

**Spec coverage** — walked through the spec section-by-section:
- Part 1 (Stats panel split): Tasks 1-7 cover panel creation, RefreshStats re-pointing, strip from Main, sort order, GPH test re-pointing
- Part 2 (Help-link foundation): Tasks 8-13 cover id fields, Process Bags section, AddHelpIcon, OpenHelpEntry, scroll-to-entry + flash, Test 78 integrity
- Per-panel migration (acceptance criterion 4): Tasks 15-22 cover Protection, Merchant, Scavenger, Highlighting, Process Bags, list panels, Profiles, Main + Stats
- Final integration (acceptance criteria 7-10): Tasks 23-25 cover linting, CHANGELOG, full sweep

**Placeholder scan** — no TBDs, no "add appropriate error handling", no "similar to Task N", no orphan references. Test code is in every test step. Code is in every implementation step.

**Type/name consistency** — `NS.AddHelpIcon` used consistently across tasks. `_pendingScrollEntryId` named the same in OpenHelpEntry and refreshLayout. Section keys (`processBags`, etc.) consistent between OnShow defaults and section markers.

---

## Execution Handoff

**Plan complete and saved to `docs/plans/2026-05-27-help-links-and-stats-panel.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for a plan this long; the subagent does Task N, reports, I review the diff, and we move on.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batching with checkpoints between phases. Slower but everything in one context.

**Which approach?**
