-- EbonClearance_ProcessBagsPanel - Process Bags Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-i of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The v2.22.0 Process Bags UI panel: the SecureActionButton-driven
-- batch Disenchant / Milling / Prospecting / Lockpicking workflow.
--
-- Moved into this file:
--   * ProcessBagsPanel frame (named "EbonClearanceOptionsProcessBags")
--   * EC_compCache.rearmProcessButton - rewrites the cast button's
--     macrotext between casts; gated on panel visibility / keybind to
--     avoid the per-BAG_UPDATE rearm cost when the user isn't using
--     the workflow (see test_perf_guardrails.lua Test 3).
--   * EC_compCache.updateProcessSelection - moves the armed cursor
--     forward and re-rearms.
--   * EC_compCache.skipProcessTarget - PLAYER_REGEN_ENABLED hook for
--     in-combat skip retries.
--   * EC_compCache.refreshProcessPanel - rebuilds the scrollable
--     row list inside the panel (collapsible sections per mode).
--   * The panel:SetScript("OnShow", ...) panel-build body that
--     constructs the SecureActionButton + dropdowns + scroll list.
--
-- The PROFESSION ENGINE (spell IDs, eligibility predicates, summary
-- builder) lives in EbonClearance_Process.lua; this file is the UI
-- layer only.
--
-- Cross-file dependencies read inline:
--   * NS.compCache (Core) - canDisenchant, canMill, canProspect,
--     buildProcessSummary, processCache, initPanel, registerWidth,
--     setPanelWidth, refreshLayouts
--   * NS.DB - captured at function entry per helper / OnShow
--   * NS.MakeHeader, NS.MakeLabel (EbonClearance.lua) - panel-text
--     primitives; NS-exposed for split files
--   * NS.PrintNice, NS.PrintNicef (EbonClearance.lua) - chat output
--   * Various WoW globals - CreateFrame, UIDropDownMenu_*,
--     GameTooltip, PlaySound, InCombatLockdown, GetBindingKey, etc.

local NS = select(2, ...)
local EC_compCache = NS.compCache

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
    local DB = NS.DB
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
        -- v2.40.1: stash the armed spell name so the GCD listener
        -- knows which cooldown to watch and the rearm path can paint
        -- the cooldown swirl on initial entry.
        panel.armedSpellName = entry.spellName
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
        panel.armedSpellName = nil
        if panel.castBtnLabel then
            panel.castBtnLabel:SetText("Process Next")
        end
        if panel.nextItemLabel then
            panel.nextItemLabel:SetText("|cffaaaaaaNothing eligible.|r")
        end
    end
    EC_compCache.updateProcessSelection()
end

-- v2.40.1: post-click button lockout. After the user clicks Process
-- Next we keep the secure button :Disable()d for a short window so
-- a second click can't fall through /cast (silent fail during cast
-- or GCD) into /use (which equips the item).
--
-- Duration design: max(effective cast time, 1.5 s). The 1.5 s floor
-- protects players on servers where Disenchant / Mill / Prospect cast
-- time has been shortened below the global cooldown - if cast = 0.3 s
-- a no-floor cooldown would re-enable the button mid-GCD and the next
-- click would still trigger the equip. 1.5 s matches the standard
-- WoW GCD and has comfortable headroom over Project Ebonhold's 1 s
-- effective GCD; chosen after in-game iteration (1.0 felt rushed,
-- 1.25 closer, 1.5 felt right).
--
-- Iteration history:
--   * First attempt tracked GetSpellCooldown directly; the user
--     reported the resulting swirl as "far too long" (1.5 s standard
--     GCD vs. their 1 s GCD).
--   * Second attempt used GetSpellInfo's cast time (PostClick-driven).
--     GetSpellInfo returns the BASE cast time and does NOT honour
--     haste / talent / server-side reductions, so the swirl visibly
--     ran longer than the actual cast on shortened-cast servers.
--   * Current: PostClick applies the floor immediately (protects the
--     50 ms window before UNIT_SPELLCAST_START fires), then
--     UNIT_SPELLCAST_START reads the EFFECTIVE duration from
--     UnitCastingInfo and re-arms the lockout to match. The swirl
--     ends with the cast, falling back to the 1.5 s floor for instant
--     or very-short casts.
local PROCESS_BUTTON_FLOOR_SECONDS = 1.5
local activeLockoutToken = 0
local function startProcessCastCooldown(spellName, duration)
    local panel = _G["EbonClearanceOptionsProcessBags"]
    if not panel or not panel.castBtn or not panel.castCD then
        return
    end
    if not spellName or spellName == "" then
        return
    end
    duration = duration or PROCESS_BUTTON_FLOOR_SECONDS
    if duration < PROCESS_BUTTON_FLOOR_SECONDS then
        duration = PROCESS_BUTTON_FLOOR_SECONDS
    end
    -- Token-stamp the lockout so a stale NS.Delay callback from the
    -- PostClick-floor invocation doesn't re-enable the button while a
    -- longer UNIT_SPELLCAST_START-driven lockout is still running.
    activeLockoutToken = activeLockoutToken + 1
    local myToken = activeLockoutToken
    panel.castCD:SetCooldown(GetTime(), duration)
    panel.castCD:Show()
    panel.castBtn:Disable()
    if NS.Delay then
        NS.Delay(duration, function()
            if myToken ~= activeLockoutToken then
                return
            end
            local p = _G["EbonClearanceOptionsProcessBags"]
            if not p or not p.castBtn or not p.castCD then
                return
            end
            p.castCD:Hide()
            -- Only re-enable if there's still something armed; the
            -- rearm path may have intentionally Disable()d the button
            -- after a queue exhaustion.
            if p.armedSpellName then
                p.castBtn:Enable()
            end
        end)
    end
end
EC_compCache.startProcessCastCooldown = startProcessCastCooldown

-- v2.40.1: process-spell name cache. UNIT_SPELLCAST_START's arg2 is
-- the localised spell name, so we resolve each spell ID's name once
-- and keep a set for O(1) membership tests in the event handler.
-- Lazy-built on first event so it survives the file-load timing
-- (GetSpellInfo can return nil during ADDON_LOADED on some clients).
local processSpellNames
local function getProcessSpellNames()
    if processSpellNames then
        return processSpellNames
    end
    processSpellNames = {}
    local ids = {
        EC_compCache.SPELL_DISENCHANT,
        EC_compCache.SPELL_MILLING,
        EC_compCache.SPELL_PROSPECTING,
        EC_compCache.SPELL_PICK_LOCK,
    }
    for _, id in ipairs(ids) do
        local n = id and GetSpellInfo(id)
        if n and n ~= "" then
            processSpellNames[n] = true
        end
    end
    return processSpellNames
end

-- v2.40.1: cast-start driver. Reads the EFFECTIVE cast duration off
-- UnitCastingInfo and re-arms the lockout to match. UnitCastingInfo
-- returns startTime / endTime in milliseconds, so the difference gives
-- a seconds duration that includes any haste / talent / server-side
-- reductions the GetSpellInfo cast-time field misses. Floor still
-- applies via startProcessCastCooldown.
local castStartDriver = CreateFrame("Frame")
castStartDriver:RegisterEvent("UNIT_SPELLCAST_START")
castStartDriver:SetScript("OnEvent", function(_, _, unit, spellName)
    if unit ~= "player" or not spellName then
        return
    end
    if not getProcessSpellNames()[spellName] then
        return
    end
    local _, _, _, _, startTime, endTime = UnitCastingInfo("player")
    local duration = PROCESS_BUTTON_FLOOR_SECONDS
    if startTime and endTime then
        local effective = (endTime - startTime) / 1000
        if effective > duration then
            duration = effective
        end
    end
    startProcessCastCooldown(spellName, duration)
end)

-- Repaints the persistent "armed" highlight on the row whose entryIndex
-- matches EC_compCache.armedIndex. Called from rearm so any cursor
-- change (skip arrow, left-click on a row, BAG_UPDATE re-arm) reflects
-- in the list immediately. Cheap loop; rows table is small.
function EC_compCache.updateProcessSelection()
    local DB = NS.DB
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
    local DB = NS.DB
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
    local DB = NS.DB
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
                -- v2.41.0: item icon at the left of the row, matching the
                -- editable list panels. Texture set per-row below from the
                -- bag slot. SetTexCoord crops the stock icon border.
                local icon = row:CreateTexture(nil, "ARTWORK")
                icon:SetSize(18, 18)
                icon:SetPoint("LEFT", row, "LEFT", 2, 0)
                icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                row.icon = icon
                local txt = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                txt:SetPoint("LEFT", icon, "RIGHT", 6, 0)
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
                    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
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
                        NS.PrintNicef(
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
            -- v2.41.0: row icon from the live bag slot (always cached for
            -- items in your own bags); question-mark fallback for safety.
            local iconTex = GetContainerItemInfo(entry.bag, entry.slot)
            row.icon:SetTexture(iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")
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

-- v2.37.3: combat-lockdown defensive path. The Process Bags panel
-- contains a SecureActionButton (the "Process Next" cast button), and
-- SecureActionButtonTemplate creation + the SetAttribute calls inside
-- the build callback are protected during combat lockdown. Two bugs
-- reported in-game on v2.37.x:
--   (1) Switching FROM Process Bags TO another EC list panel during
--       combat leaves the Process Bags rows bleeding through behind
--       the new panel - the Interface Options framework's Hide()
--       propagation breaks on the secure-button-having panel.
--   (2) First-time open of Process Bags via the sidebar during combat
--       (which bypasses the minimap middle-click defer) aborts the
--       build callback partway, leaving self.inited=true but most
--       widgets unbuilt. Subsequent opens take the refresh path and
--       the panel stays empty.
--
-- Fix (1) - OnHide: hide the scroll content frame explicitly so the
--   rows can't render even if the framework's Hide didn't propagate.
-- Fix (2) - OnShow: if we're not yet built AND in combat lockdown,
--   show a placeholder message and arm a one-shot retry on
--   PLAYER_REGEN_ENABLED that Hides + Shows the panel to re-trigger
--   OnShow once lockdown clears.
local function EC_ensureCombatPlaceholder(self)
    if self.combatPlaceholder then
        return self.combatPlaceholder
    end
    local fs = self:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("CENTER")
    fs:SetJustifyH("CENTER")
    fs:SetText("|cffffb84dProcess Bags will load when combat ends.|r")
    fs:Hide()
    self.combatPlaceholder = fs
    return fs
end

local function EC_armCombatExitRetry(self)
    if self._combatExitRetryFrame then
        return
    end
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function()
        f:UnregisterAllEvents()
        self._combatExitRetryFrame = nil
        if self.combatPlaceholder then
            self.combatPlaceholder:Hide()
        end
        if not self.inited and self:IsShown() then
            -- Re-fire OnShow now that lockdown is clear so initPanel's
            -- build callback can run the secure-attribute calls.
            self:Hide()
            self:Show()
        end
    end)
    self._combatExitRetryFrame = f
end

ProcessBagsPanel:SetScript("OnHide", function(self)
    -- Belt-and-braces hide: when the Interface Options framework can't
    -- propagate hide cleanly through the secure-button-having panel,
    -- the scroll content frame keeps its rows visible behind whichever
    -- panel shows next. Explicit Hide() on the scroll background
    -- propagates to its rowScroll + rowContent + every row child.
    if self.processScrollBg then
        self.processScrollBg:Hide()
    end
end)

ProcessBagsPanel:SetScript("OnShow", function(self)
    -- v2.37.3: defer first-time build until out of combat. The secure
    -- attributes set inside the build callback (castBtn type, macro,
    -- click registration) are protected and will silently abort the
    -- build mid-way during lockdown, leaving the panel in a half-
    -- initialised state that subsequent OnShow refresh-paths can't
    -- recover from.
    if not self.inited and InCombatLockdown and InCombatLockdown() then
        local placeholder = EC_ensureCombatPlaceholder(self)
        placeholder:Show()
        EC_armCombatExitRetry(self)
        return
    end
    -- v2.37.4: hide the combat placeholder if it's lingering (the
    -- combat-exit retry handler also clears it, but a fresh OnShow
    -- from a non-lockdown state must clear it too in case the panel
    -- was opened-during-combat then closed without the retry firing).
    if self.combatPlaceholder then
        self.combatPlaceholder:Hide()
    end
    -- v2.37.3: combat-lockdown bleed-through from Process Bags into
    -- other EC panels is a known WoW protection-model quirk. Attempts
    -- to hide / fade / cover the panel from either side were all
    -- silently no-op'd by combat lockdown (the panel contains a
    -- SecureActionButton, which protects the entire panel chain).
    -- Living with the quirk for now - the cast button has to stay
    -- Secure to function at all, so the only real fix would be a
    -- larger refactor of the Process Bags UI shape.
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        -- v2.37.4: counterpart to the OnHide processScrollBg:Hide().
        -- The OnHide handler (added in v2.37.3) was framed as
        -- "belt-and-braces with no cost" but had a cost: subsequent
        -- OnShow calls take the refresh path here (because inited is
        -- true) and the row scroll background stays hidden, leaving
        -- the panel looking empty even though it's built. Re-Show on
        -- every refresh so a panel-switch round-trip restores the
        -- chrome.
        if self.processScrollBg then
            self.processScrollBg:Show()
        end
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
        local heading = NS.MakeHeader(content, "Process Bags", -16)
        if NS.AddHelpIcon then
            NS.AddHelpIcon(content, heading, "LEFT", "RIGHT", 6, 0, "process-bags-overview")
        end
        local desc = NS.MakeLabel(
            content,
            "Disenchant, mill, prospect, or pick locks in bulk. |cffffd870Left-click|r a row to select it. |cffffd870Right-click|r a row to hide it (|cffffb84dClear Ignored|r brings them back). Click |cffffb84dProcess Next|r to cast on the selected row.",
            16,
            -44
        )

        local tip = NS.MakeLabel(
            content,
            "|cff888888Tip: bind a key to Process Next in Key Bindings, then hold it to drain a stack without clicking.|r",
            16,
            -44
        )
        tip:ClearAllPoints()
        tip:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -8)

        local keepTip = NS.MakeLabel(
            content,
            "|cff888888Items on your Keep List are hidden here - the Keep List wins over Process Bags. Remove an item from the Keep List to make it processable.|r",
            16,
            -44
        )
        keepTip:ClearAllPoints()
        keepTip:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", 0, -4)

        local sbCB = CreateFrame(
            "CheckButton",
            "EbonClearanceProcessIncludeSoulboundCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        sbCB:SetPoint("TOPLEFT", keepTip, "BOTTOMLEFT", 0, -10)
        sbCB:SetChecked(DB.processIncludeSoulbound)
        local sbText = _G[sbCB:GetName() .. "Text"]
        if sbText then
            sbText:SetText("Include Soulbound items (disenchant only)")
            EC_compCache.setPanelWidth(sbText, 60)
            sbText:SetJustifyH("LEFT")
        end
        sbCB:SetScript("OnClick", function(cb)
            DB.processIncludeSoulbound = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            EC_compCache.refreshProcessPanel()
        end)
        self.includeSoulboundCB = sbCB
        if sbText and NS.AddHelpIcon then
            NS.AddHelpIcon(content, sbText, "LEFT", "RIGHT", 6, 0, "process-disenchant")
        end

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

        -- Help icon for the disenchant settings row (soulbound checkbox
        -- above + quality cap dropdown). Sits between the dropdown and
        -- the Clear Ignored button; the clear button re-anchors below.
        local ddHelp
        if NS.AddHelpIcon then
            ddHelp = NS.AddHelpIcon(content, dd, "LEFT", "RIGHT", 0, 2, "process-disenchant")
        end

        -- Clear-ignored button. Sits to the right of the DE dropdown
        -- (after the help icon, when present). Hidden when there's
        -- nothing to clear so the panel doesn't carry chrome for a
        -- never-used state.
        local clearBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        clearBtn:SetSize(150, 20)
        if ddHelp then
            clearBtn:SetPoint("LEFT", ddHelp, "RIGHT", 4, 0)
        else
            clearBtn:SetPoint("LEFT", dd, "RIGHT", 8, 2)
        end
        clearBtn:SetText("Clear Ignored (0)")
        clearBtn:Hide()
        clearBtn:SetScript("OnClick", function()
            DB.processIgnored = {}
            NS.PrintNice("Process Bags ignored list cleared.")
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

        -- v2.32.x: list area uses its own ScrollFrame so the scrollbar
        -- sits inside the chrome (matches the Sell / Keep / Delete /
        -- Profiles pattern). Chrome anchors below the dropdown down to
        -- just above the bottom button strip; a UIPanelScrollFrame
        -- inside it holds the section headers + item rows.

        local scrollBg = CreateFrame("Frame", nil, content)
        scrollBg:SetPoint("TOPLEFT", ddLabel, "BOTTOMLEFT", -4, -16)
        scrollBg:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -12, 62)
        scrollBg:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        scrollBg:SetBackdropColor(0, 0, 0, 0.6)
        scrollBg:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)
        self.processScrollBg = scrollBg

        -- Inner scroll for the rows. Same anchor offsets as the list-
        -- widget panels (6 / -28) so the scrollbar sits inside the
        -- chrome border with consistent spacing.
        local rowScroll = CreateFrame(
            "ScrollFrame",
            "EbonClearanceProcessRowScroll",
            scrollBg,
            "UIPanelScrollFrameTemplate"
        )
        rowScroll:SetPoint("TOPLEFT", 6, -6)
        rowScroll:SetPoint("BOTTOMRIGHT", -28, 6)

        local rowContent = CreateFrame("Frame", nil, rowScroll)
        rowContent:SetSize(NS.GetPanelWidth() - 50, 1)
        rowScroll:SetScrollChild(rowContent)
        NS.HookScrollbarAutoHide(rowScroll)
        EC_compCache.registerWidth(rowContent, 50)
        self.processRowScroll = rowScroll

        -- rowAnchor at the top of the scroll content. Rows / headers
        -- stack downwards from here. The old rowAnchorOffset (200,
        -- which reserved space for the static controls when the whole
        -- panel scrolled) is now 0 because the static controls live
        -- outside the scroll area entirely.
        local rowAnchor = CreateFrame("Frame", nil, rowContent)
        rowAnchor:SetPoint("TOPLEFT", 0, 0)
        rowAnchor:SetPoint("TOPRIGHT", rowContent, "TOPRIGHT", 0, 0)
        rowAnchor:SetHeight(1)
        self.rowAnchor = rowAnchor
        self.rowAnchorOffset = 0

        -- Empty state inside rowContent so it scrolls with the list
        -- area and renders on top of the chrome backdrop.
        local empty = rowContent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        empty:SetPoint("TOPLEFT", rowAnchor, "TOPLEFT", 8, -4)
        EC_compCache.setPanelWidth(empty, 70)
        empty:SetJustifyH("LEFT")
        if empty.SetWordWrap then
            empty:SetWordWrap(true)
        end
        empty:SetText(
            "|cff888888No eligible items. Learn Disenchant, Milling, Prospecting, or Pick Lock and pick up some loot to fill this list.|r"
        )
        empty:Hide()
        self.emptyState = empty

        self.content = rowContent
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

        -- v2.40.1: post-click button lockout + cooldown swirl. The
        -- cast macro is "/cast SpellName" followed by "/use bag slot".
        -- If the player clicks during the GCD, /cast silently no-ops
        -- but /use still runs - and /use on an equippable item equips
        -- it. Players on PE who shorten Mill / Prospect / Disenchant
        -- cast times below the GCD saw this constantly. Fix: after
        -- each click, paint the standard cooldown swirl AND :Disable()
        -- the button for max(cast time, 1 s). PostClick fires after
        -- the secure click processes; we read the just-fired spell
        -- name off the panel and start the lockout. Floor protects
        -- against shortened cast times falling under the server's
        -- actual GCD (1 s on Project Ebonhold).
        local castCD = CreateFrame("Cooldown", "EbonClearanceProcessCastCD", castBtn, "CooldownFrameTemplate")
        castCD:SetAllPoints(castBtn)
        castCD:SetDrawEdge(false)
        -- v2.40.1: opt out of OmniCC / CooldownCount-style numeric
        -- overlays. The 3.3.5a CooldownFrameTemplate has no built-in
        -- countdown text - but players running OmniCC see numbers on
        -- every Cooldown frame in the UI unless the frame carries one
        -- of these flags. We want the swirl only (the button text
        -- already says "Process Next (<mode>)", a number on top reads
        -- as visual noise).
        castCD.noOCC = true
        castCD.noCooldownCount = true
        self.castCD = castCD

        castBtn:SetScript("PostClick", function()
            -- Floor-only lockout fires immediately on click. The
            -- UNIT_SPELLCAST_START handler re-arms with the actual
            -- effective cast duration the moment the cast bar shows
            -- up (typically ~10-50 ms later). Without this initial
            -- floor, a fast double-click in that pre-cast window
            -- would slip past the lockout entirely.
            local spellName = self.armedSpellName
            if spellName and EC_compCache.startProcessCastCooldown then
                EC_compCache.startProcessCastCooldown(spellName, PROCESS_BUTTON_FLOOR_SECONDS)
            end
        end)

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

        -- v2.32.x: panel no longer scroll-wrapped. The list area has
        -- its own dedicated ScrollFrame inside scrollBg above, so the
        -- outer panel scrollbar is gone. Static controls fit the
        -- standard Interface Options viewport without needing the
        -- outer scroll.

        EC_compCache.refreshProcessPanel()
    end)
end)
