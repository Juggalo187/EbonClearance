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
-- stays in EbonClearance_Events.lua for now; it's a different domain
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
local L = NS.L

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
        local heading = NS.MakeHeader(self, L["Deletion Settings"], -16)
        NS.AddHelpIcon(self, heading, "LEFT", "RIGHT", 8, 0, "what-are-the-lists")
        local delDesc = NS.MakeLabel(
            self,
            L["Items on this list are destroyed when bags are scanned. This cannot be undone."],
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
            L["Add items by shift-clicking them, dragging them in, or typing the item ID below."]
        )

        local autoCB, refreshAutoCBEnabled

        local delCB =
            CreateFrame("CheckButton", "EbonClearanceEnableDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
        delCB:SetPoint("TOPLEFT", delHint, "BOTTOMLEFT", 0, -6)
        delCB:SetChecked(DB.enableDeletion)
        local dt = _G[delCB:GetName() .. "Text"]
        if dt then
            dt:SetText(L["Allow items to be deleted"])
            dt:SetWidth(420)
            dt:SetJustifyH("LEFT")
        end
        delCB:SetScript("OnClick", function()
            DB.enableDeletion = delCB:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            -- v2.42.0: turning deletion OFF also disarms auto-delete-on-pickup
            -- (not just greys it). Avoids an "armed but inactive" limbo, and
            -- means re-enabling deletion requires re-ticking auto-delete -
            -- which re-runs the confirm gate and kicks a fresh scan.
            if not DB.enableDeletion and DB.autoDeleteOnPickup then
                DB.autoDeleteOnPickup = false
                if autoCB then
                    autoCB:SetChecked(false)
                end
            end
            -- Toggling deletion changes EC_IsSellable / BuildQueue's
            -- delete-list verdict for every Delete List slot. Repaint
            -- so the slot tints track immediately without requiring a
            -- bag close/reopen. Same rule as the list-mutation refresh
            -- invariant (Test 26 in test_perf_guardrails.lua).
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
            autoText:SetText(L["Auto-delete these items the moment they enter your bags"])
            autoText:SetWidth(420)
            autoText:SetJustifyH("LEFT")
        end
        -- v2.44.0: Resilience auto-mark sub-toggle. Adds PvP gear with
        -- the "Resilience" tooltip line to this Delete List on the
        -- next BAG_UPDATE - the existing vendor / auto-delete-on-
        -- pickup pipelines then destroy it. Same enabled-state rule
        -- as autoCB: greyed when "Allow items to be deleted" is off.
        -- Asked for by Murlocked: PvP gear on PE has sellPrice = 0
        -- and clutters bags after farming.
        local resilienceCB =
            CreateFrame("CheckButton", "EbonClearanceAutoMarkResilienceCB", self, "InterfaceOptionsCheckButtonTemplate")
        resilienceCB:SetPoint("TOPLEFT", autoCB, "BOTTOMLEFT", 0, -2)
        resilienceCB:SetChecked(DB.autoMarkResilience)
        local resilienceText = _G[resilienceCB:GetName() .. "Text"]
        if resilienceText then
            resilienceText:SetText(L["Auto-mark PvP gear (Resilience) for deletion"])
            resilienceText:SetWidth(420)
            resilienceText:SetJustifyH("LEFT")
        end

        refreshAutoCBEnabled = function()
            if DB.enableDeletion then
                autoCB:Enable()
                resilienceCB:Enable()
                if autoText then
                    autoText:SetTextColor(1, 1, 1)
                end
                if resilienceText then
                    resilienceText:SetTextColor(1, 1, 1)
                end
            else
                autoCB:Disable()
                resilienceCB:Disable()
                if autoText then
                    autoText:SetTextColor(0.5, 0.5, 0.5)
                end
                if resilienceText then
                    resilienceText:SetTextColor(0.5, 0.5, 0.5)
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

        -- v2.44.0: Resilience auto-mark OnClick. No confirmation
        -- popup - this only adds items to the Delete List (a
        -- reversible, non-destructive action). The actual deletion
        -- still flows through enableDeletion + the user's vendor
        -- visit or autoDeleteOnPickup, both of which are gated.
        -- Kicks one debounce scan so items already in bags get
        -- marked the moment the toggle goes on.
        resilienceCB:SetScript("OnClick", function()
            DB.autoMarkResilience = resilienceCB:GetChecked() and true or false
            PlaySound(DB.autoMarkResilience and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
            if DB.autoMarkResilience and EC_compCache.bagUpdateFrame then
                EC_compCache.bagUpdatePending = true
                EC_compCache.bagUpdateAccum = 0
                EC_compCache.bagUpdateFrame:Show()
            end
        end)

        self.listUI = NS.CreateListUI(self, L["Delete List"], "deleteList", 16, -130)
        -- v2.11.0: anchor BOTTOMRIGHT so the list stretches with the panel
        -- on Interface Options frame resize - mirrors the Whitelist /
        -- Blacklist / Account-Whitelist setups. Without this the list box
        -- stays at its build-time width and the search row + add-matching
        -- row buttons drift outside the panel boundary on shrink.
        self.listUI:ClearAllPoints()
        -- v2.42.0: anchor below the auto-delete sub-toggle (not a fixed
        -- y-offset) so the list always clears the checkboxes even as the
        -- description / hint text wraps. Mirrors the Keep List panel's
        -- anchor-to-hint approach.
        -- v2.44.0: re-anchored below the new resilience auto-mark
        -- toggle so the list still clears every checkbox in the
        -- header strip.
        self.listUI:SetPoint("TOPLEFT", resilienceCB, "BOTTOMLEFT", 0, -12)
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
        local heading = NS.MakeHeader(self, L["Keep List"], -16)
        NS.AddHelpIcon(self, heading, "LEFT", "RIGHT", 8, 0, "what-are-the-lists")
        local blDesc = NS.MakeLabel(
            self,
            L["Items the addon should never touch. Good for things you'd rather sell at the auction house yourself."],
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
            L["|cffaaaaaaAutomatic protection rules (equipped gear, upgrades, gear sets, affixes, chance-on-hit, tomes) are on the |r|cffffb84dProtection Settings|r|cffaaaaaa panel.|r"]
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
        blHint:SetText(L["Add items by shift-clicking them, dragging them in, or typing the item ID."])

        self.listUI = NS.CreateListUI(self, L["Protected Items"], "blacklist", 16, -130)
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", blHint, "BOTTOMLEFT", 0, -16)
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)
