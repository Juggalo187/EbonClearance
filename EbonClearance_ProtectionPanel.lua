-- EbonClearance_ProtectionPanel - Protection Settings Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-vi of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Protection Settings UI panel (named "Protection Settings" in
-- the sidebar; internal frame name "EbonClearanceOptionsBlacklistSettings"
-- preserves the v2.15.0 schema). Hosts the auto-protect toggles
-- (autoAddEquipped / autoProtectUpgrades / autoProtectEquipmentSets)
-- and the v2.20.0 affix + chance-on-hit protection toggles + the
-- affixAllowExactDupes setting.
--
-- Moved into this file:
--   * local BlacklistSettingsPanel = CreateFrame(...) frame creation
--   * The Protection Settings OnShow handler (panel-build body)
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth,
--     syncEquipped, checkBagsForUpgrades, syncEquipmentSets, peDetected
--   * NS.DB captured at OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.FitScrollContent (8e-ii)
--   * NS.RefreshSellBorders (BagDisplay) - used by the affix /
--     chance-on-hit / affixAllowExactDupes OnClick handlers per the
--     Issue B fix (Test 42 invariant)
--
-- The panel does NOT use AddCheckbox / AddSlider; it builds checkboxes
-- inline because the layout has explanatory notes interleaved between
-- the toggles that don't fit AddCheckbox's flat row format.

local NS = select(2, ...)
local EC_compCache = NS.compCache

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
    local DB = NS.DB
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
        if self.unlearnedTomeCB then
            self.unlearnedTomeCB:SetChecked(DB.protectUnlearnedTomes)
        end
        if self.allTomeCB then
            self.allTomeCB:SetChecked(DB.protectAllTomes)
        end
        if self.UpdateAllTomeEnabled then
            self:UpdateAllTomeEnabled()
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

        NS.MakeHeader(content, "Protection Settings", -16)
        local desc = NS.MakeLabel(
            content,
            "Rules that keep specific items safe from selling. You can override any of them on a single item with Alt+Right-Click - Allow Sell.",
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
            aeText:SetText("Keep gear you're wearing")
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
            "|cff888888Anything you wear is kept automatically. Alt+Right-Click to remove an item from the Keep List.|r"
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
            auText:SetText("Keep upgrades found in bags")
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
            "|cff888888Items with a higher item level than what you're wearing get kept.|r"
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
            asText:SetText("Keep items in your saved equipment sets")
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
            "|cff888888Every item in your saved gear sets is kept. Removing a set doesn't unkeep its items - Alt+Right-Click to remove them.|r"
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
            aaText:SetText("Keep blue/purple items with affixes")
            EC_compCache.setPanelWidth(aaText, 60)
            aaText:SetJustifyH("LEFT")
        end
        autoAffixCB:SetScript("OnClick", function(cb)
            DB.protectAffixedRareItems = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            -- Same refresh as the second autoAffixCB OnClick handler
            -- below (line ~7392). This first handler is replaced by
            -- the second a few lines later within the same build
            -- callback, so the body never runs in practice - but the
            -- refresh is included for symmetry so the verdict-toggle
            -- refresh invariant (Test 42) catches BOTH SetScript sites
            -- without special-casing the dead one. Future contributors
            -- who add a third autoAffixCB:SetScript will get the
            -- refresh by default.
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
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
            "|cff888888Items like |cffffb84d'of Fortified by Pain IV'|r|cff888888 are never sold or deleted, even if they're on a list.|r"
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
            daText:SetText("Allow selling affixes you already have")
            EC_compCache.setPanelWidth(daText, 86)
            daText:SetJustifyH("LEFT")
        end
        dupeAffixCB:SetScript("OnClick", function(cb)
            DB.affixAllowExactDupes = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            -- Toggling the dupe-allow flag changes EC_IsSellable's
            -- verdict for every affixed Rare/Epic item the player has
            -- already extracted. Without this refresh, slot tints stay
            -- frozen until the host bag UI repaints (bag close/reopen).
            -- Same rule as the list-mutation refresh invariant.
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
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
                    "|cff888888If you already have the affix at this rank, drops follow your normal sell rules. Different ranks stay protected so you can still collect them all.|r"
                )
            else
                dupeAffixCB:Disable()
                if daText then
                    daText:SetTextColor(0.5, 0.5, 0.5)
                end
                if not peOn then
                    dupeAffixNote:SetText(
                        "|cff888888Project Ebonhold addon not detected. This option needs PE to know which affixes you have.|r"
                    )
                else
                    dupeAffixNote:SetText("|cff888888Turn on the affix protection above to use this option.|r")
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
            -- Toggling the master affix-protection flag flips
            -- EC_IsSellable's verdict for every affixed Rare/Epic slot.
            -- Repaint so the borders track immediately. Same rule as
            -- the list-mutation refresh invariant.
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
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
            pcText:SetText("Keep items with chance-on-hit procs")
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
            "|cff888888Items with a |cffffb84d'Chance on hit:'|r|cff888888 effect are kept unless you add them to a list yourself.|r"
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
            -- Same reasoning as the affix-protection toggles: flipping
            -- this changes EC_IsSellable's verdict for every chance-on-
            -- hit item not on the Allow Sell list. Repaint immediately
            -- so the user sees the effect of their setting change.
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)

        -- Tome protection. Parent + child checkbox pair mirroring the
        -- affix-dupe shape above:
        --   * Parent (unlearnedTomeCB) controls DB.protectUnlearnedTomes -
        --     when ON, unlearned spell-teaching items (recipes, tomes,
        --     scrolls) are protected.
        --   * Child (allTomeCB), indented and only enabled when parent is
        --     ON, controls DB.protectAllTomes - extends the protection to
        --     items the character has already learned.
        -- Both HARD-VETO in EC_IsSellable: a protected tome / recipe
        -- cannot be vendored even when on the Sell List - the user must
        -- explicitly Alt+Right-Click -> Allow Sell first. Mirrors affix-
        -- protection semantics (v2.19.0), not chance-on-hit (v2.20.1).
        local unlearnedTomeCB = CreateFrame(
            "CheckButton",
            "EbonClearanceProtectUnlearnedTomesCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        unlearnedTomeCB:SetPoint("TOPLEFT", procNote, "BOTTOMLEFT", -26, -10)
        unlearnedTomeCB:SetChecked(DB.protectUnlearnedTomes)
        local utText = _G[unlearnedTomeCB:GetName() .. "Text"]
        if utText then
            utText:SetText("Keep unlearned tomes and recipes")
            EC_compCache.setPanelWidth(utText, 60)
            utText:SetJustifyH("LEFT")
        end
        self.unlearnedTomeCB = unlearnedTomeCB

        local unlearnedTomeNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        unlearnedTomeNote:SetPoint("TOPLEFT", unlearnedTomeCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(unlearnedTomeNote, 60)
        unlearnedTomeNote:SetJustifyH("LEFT")
        if unlearnedTomeNote.SetWordWrap then
            unlearnedTomeNote:SetWordWrap(true)
        end
        unlearnedTomeNote:SetText(
            "|cff888888Tomes and recipes you don't know yet are kept. To sell one anyway, Alt+Right-Click |cffffb84d-> Allow Sell|r|cff888888. Adding it to the Sell List alone won't override the protection.|r"
        )

        -- Child toggle: extends protection to already-known items.
        -- Indented under the parent's note (matches the affix-dupe
        -- pattern - +0 x-offset under the +26-indented note puts the
        -- child a column further right than the parent).
        local allTomeCB = CreateFrame(
            "CheckButton",
            "EbonClearanceProtectAllTomesCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        allTomeCB:SetPoint("TOPLEFT", unlearnedTomeNote, "BOTTOMLEFT", 0, -8)
        allTomeCB:SetChecked(DB.protectAllTomes)
        local atText = _G[allTomeCB:GetName() .. "Text"]
        if atText then
            atText:SetText("Keep them even after you learn them")
            EC_compCache.setPanelWidth(atText, 86)
            atText:SetJustifyH("LEFT")
        end
        self.allTomeCB = allTomeCB

        local allTomeNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        allTomeNote:SetPoint("TOPLEFT", allTomeCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(allTomeNote, 86)
        allTomeNote:SetJustifyH("LEFT")
        if allTomeNote.SetWordWrap then
            allTomeNote:SetWordWrap(true)
        end
        self.allTomeNote = allTomeNote

        allTomeCB:SetScript("OnClick", function(cb)
            DB.protectAllTomes = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)

        -- Greys-out the child CB when the parent is off, swapping the
        -- explanatory note for a status line. Same shape as
        -- UpdateDupeAffixEnabled above.
        local function UpdateAllTomeEnabled()
            local parentOn = DB.protectUnlearnedTomes == true
            if parentOn then
                allTomeCB:Enable()
                if atText then
                    atText:SetTextColor(1, 1, 1)
                end
                allTomeNote:SetText(
                    "|cff888888Useful for saving spares for alts (different characters know different tomes / recipes) or selling them at the auction house yourself.|r"
                )
            else
                allTomeCB:Disable()
                if atText then
                    atText:SetTextColor(0.5, 0.5, 0.5)
                end
                allTomeNote:SetText("|cff888888Turn on the protection above to use this option.|r")
            end
        end
        self.UpdateAllTomeEnabled = UpdateAllTomeEnabled
        UpdateAllTomeEnabled()

        unlearnedTomeCB:SetScript("OnClick", function(cb)
            DB.protectUnlearnedTomes = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            UpdateAllTomeEnabled()
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)

        NS.FitScrollContent(content, allTomeNote)
    end, true)
end)
