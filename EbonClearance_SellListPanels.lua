-- EbonClearance_SellListPanels - Sell List + Account Sell List Interface Options panels.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-iv of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Sell List + Account Sell List panels - sibling pair (same
-- concept, different scope: per-character vs account-wide). Both are
-- list-management UIs anchored on the shared CreateListUI helper.
--
-- Moved into this file:
--   * local WhitelistPanel = CreateFrame(...) + OnShow build
--   * local AccountWhitelistPanel = CreateFrame(...) + OnShow build
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth
--   * NS.DB captured at each OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.CreateListUI / NS.AddScanByQualityRow (8e-iv prep)
--   * Various WoW globals - CreateFrame, etc.

local NS = select(2, ...)
local EC_compCache = NS.compCache

local WhitelistPanel = CreateFrame("Frame", "EbonClearanceOptionsWhitelist", InterfaceOptionsFramePanelContainer)
WhitelistPanel.name = "Sell List"
WhitelistPanel.parent = "EbonClearance"

WhitelistPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        NS.MakeHeader(self, "Sell List", -16)

        -- Panel-specific description only. Cross-cutting info (grey junk
        -- auto-sell, quality threshold) lives on the Main panel to avoid
        -- repeating the same explanation on every list page.
        local descLabel = NS.MakeLabel(
            self,
            "Items this character should always sell. Use the |cffb6ffb6Add from bags|r buttons to add by colour, or shift-click an item to add it.",
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
            "|cffaaaaaaThis list is per-character. For items every alt should sell, use the |r|cffb6ffb6Account Sell List|r|cffaaaaaa instead.|r"
        )

        -- Cascade-anchor the scan row to the grey note's BOTTOMLEFT so it stays
        -- below regardless of how many lines the description / note wrap to.
        local scanRow = NS.AddScanByQualityRow(self, descNote, "whitelist", "the Sell List", function()
            if self.listUI then
                self.listUI:Refresh()
            end
        end, 0, -10)

        self.listUI = NS.CreateListUI(self, "Manual Add (Shift-click item or type ID)", "whitelist", 16, -118)
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", scanRow, "BOTTOMLEFT", 0, -16)
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)

local AccountWhitelistPanel =
    CreateFrame("Frame", "EbonClearanceOptionsAccountWhitelist", InterfaceOptionsFramePanelContainer)
AccountWhitelistPanel.name = "Account Sell List"
AccountWhitelistPanel.parent = "EbonClearance"

AccountWhitelistPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        NS.MakeHeader(self, "Account Sell List", -16)
        local descLabel = NS.MakeLabel(
            self,
            "Items |cffffff00every|r character on this account should sell. Good for shared trash like reagents or seasonal drops.",
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
        descNote:SetText("|cffaaaaaaThis list isn't part of profiles - it stays the same when you switch profiles.|r")

        -- Cascade-anchor the scan row to the grey note's BOTTOMLEFT so it stays
        -- below regardless of how many lines the description / note wrap to.
        local scanRow = NS.AddScanByQualityRow(self, descNote, "accountWhitelist", "the Account Sell List", function()
            if self.listUI then
                self.listUI:Refresh()
            end
        end, 0, -10)

        self.listUI = NS.CreateListUI(self, "Account-Wide Items", "accountWhitelist", 16, -118)
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", scanRow, "BOTTOMLEFT", 0, -16)
        -- Fill remaining vertical space rather than fixed-height; mirrors
        -- WhitelistPanel and avoids bottom-row clipping at narrow widths.
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)
