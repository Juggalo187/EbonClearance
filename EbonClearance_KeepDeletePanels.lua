-- EbonClearance_KeepDeletePanels - Keep List + Delete List Interface Options panels.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-v of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Keep List + Delete List panels - sibling list-management UIs
-- bundled together. Both use the shared CreateListUI helper and have
-- the same panel rhythm (header + description + hint + list).
--
-- The Protection Settings panel (BlacklistSettingsPanel - auto-protect
-- toggles for equipped / upgrades / sets / affixes / chance-on-hit)
-- stays in EbonClearance.lua for now; it's a different domain
-- (settings, not list management) and will move in a later stage.
--
-- Moved into this file:
--   * local DeletePanel = CreateFrame(...) + OnShow build (Delete List)
--   * local BlacklistPanel = CreateFrame(...) + OnShow build (Keep List)
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth
--   * NS.DB captured at each OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.CreateListUI (8e-iv)
--   * NS.RefreshSellBorders (BagDisplay) - used by the Enable deletion
--     toggle's OnClick to repaint Delete category tints

local NS = select(2, ...)
local EC_compCache = NS.compCache

local DeletePanel = CreateFrame("Frame", "EbonClearanceOptionsDeletion", InterfaceOptionsFramePanelContainer)
DeletePanel.name = "Delete List"
DeletePanel.parent = "EbonClearance"

DeletePanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        NS.MakeHeader(self, "Deletion Settings", -16)
        local delDesc = NS.MakeLabel(
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
            -- Toggling deletion changes EC_IsSellable / BuildQueue's
            -- delete-list verdict for every Delete List slot. Repaint
            -- so the slot tints track immediately without requiring a
            -- bag close/reopen. Same rule as the list-mutation refresh
            -- invariant (Test 26 in test_perf_guardrails.lua).
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)

        self.listUI = NS.CreateListUI(self, "Delete List", "deleteList", 16, -130)
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

local BlacklistPanel = CreateFrame("Frame", "EbonClearanceOptionsBlacklist", InterfaceOptionsFramePanelContainer)
BlacklistPanel.name = "Keep List"
BlacklistPanel.parent = "EbonClearance"

BlacklistPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
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
        NS.MakeHeader(self, "Keep List (Do Not Sell)", -16)
        local blDesc = NS.MakeLabel(
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

        self.listUI = NS.CreateListUI(self, "Protected Items", "blacklist", 16, -130)
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", blHint, "BOTTOMLEFT", 0, -16)
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)
