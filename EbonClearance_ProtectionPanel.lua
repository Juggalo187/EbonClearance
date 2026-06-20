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
-- inline because two of the toggles (dupeAffixCB / allTomeCB) carry
-- dynamic status-feedback FontStrings that the flat-row AddCheckbox
-- format can't host. The explanatory notes that used to sit under
-- every toggle were stripped in Task 15 of the help-link refactor;
-- each toggle now links to its Help-panel entry via NS.AddHelpIcon
-- next to the label.

local NS = select(2, ...)
local EC_compCache = NS.compCache
local L = NS.L

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

        NS.MakeHeader(content, L["Protection Settings"], -16)
        local desc = NS.MakeLabel(
            content,
            L["Rules that keep specific items safe from selling. You can override any of them on a single item with Alt+Right-Click - Allow Sell."],
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
            aeText:SetText(L["Keep gear you're wearing"])
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
        if aeText then
            NS.AddHelpIcon(content, aeText, "LEFT", "RIGHT", 6, 0, "gate-equipped-never-sells")
        end

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
        autoUpgradeCB:SetPoint("TOPLEFT", autoEquipCB, "BOTTOMLEFT", 0, -10)
        autoUpgradeCB:SetChecked(DB.autoProtectUpgrades)
        local auText = _G[autoUpgradeCB:GetName() .. "Text"]
        if auText then
            auText:SetText(L["Keep upgrades found in bags"])
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
        if auText then
            NS.AddHelpIcon(content, auText, "LEFT", "RIGHT", 6, 0, "tshoot-upgrade-keep")
        end

        -- v2.13.0 Equipment Manager protection. Catches the dual-spec /
        -- off-set gap: items assigned to your alternate Blizzard equipment
        -- set sit in bags between swaps and aren't protected by
        -- autoAddEquipped (which only catches currently-equipped slots).
        -- One-shot sync at toggle, then EQUIPMENT_SETS_CHANGED reactive.
        local autoSetCB =
            CreateFrame("CheckButton", "EbonClearanceAutoProtectSetsCB", content, "InterfaceOptionsCheckButtonTemplate")
        autoSetCB:SetPoint("TOPLEFT", autoUpgradeCB, "BOTTOMLEFT", 0, -10)
        autoSetCB:SetChecked(DB.autoProtectEquipmentSets)
        local asText = _G[autoSetCB:GetName() .. "Text"]
        if asText then
            asText:SetText(L["Keep items in your saved equipment sets"])
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
        if asText then
            NS.AddHelpIcon(content, asText, "LEFT", "RIGHT", 6, 0, "label-keep-gear-set")
        end

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
        autoAffixCB:SetPoint("TOPLEFT", autoSetCB, "BOTTOMLEFT", 0, -10)
        autoAffixCB:SetChecked(DB.protectAffixedRareItems)
        local aaText = _G[autoAffixCB:GetName() .. "Text"]
        if aaText then
            aaText:SetText(L["Keep blue/purple items with affixes"])
            EC_compCache.setPanelWidth(aaText, 60)
            aaText:SetJustifyH("LEFT")
        end
        autoAffixCB:SetScript("OnClick", function(cb)
            DB.protectAffixedRareItems = cb:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            -- Same refresh as the second autoAffixCB OnClick handler
            -- below (the second SetScript in this build callback). This first handler is replaced by
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
        if aaText then
            NS.AddHelpIcon(content, aaText, "LEFT", "RIGHT", 6, 0, "gate-affix-protection")
        end

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
        -- Indent further right than the parent toggle so the child sits
        -- a column to the right. (Pre-Task 15 this used the parent's
        -- explanatory note as an indented anchor; the note is gone now,
        -- so we apply the +26 indent directly against the parent CB.)
        dupeAffixCB:SetPoint("TOPLEFT", autoAffixCB, "BOTTOMLEFT", 26, -8)
        dupeAffixCB:SetChecked(DB.affixAllowExactDupes)
        local daText = _G[dupeAffixCB:GetName() .. "Text"]
        if daText then
            daText:SetText(L["Allow selling affixes you already have"])
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
            -- v2.44.0: re-evaluate the active-state explainer so the
            -- note shows / clears the moment the toggle flips.
            if self.UpdateDupeAffixEnabled then
                self.UpdateDupeAffixEnabled()
            end
        end)
        self.dupeAffixCB = dupeAffixCB
        if daText then
            NS.AddHelpIcon(content, daText, "LEFT", "RIGHT", 6, 0, "gate-allow-rank-dupes")
        end

        -- Status / explainer FontString. Carries both:
        --   * The disabled-state status messages ("PE not detected" /
        --     "Turn on affix protection above").
        --   * v2.44.0 active-state explainer that the toggle is an
        --     independent sell rule (real player feedback: the
        --     toggle and the rank slider felt like they were
        --     fighting; making each one's note explain its scope
        --     resolves the confusion at the point of toggling).
        local dupeAffixNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        dupeAffixNote:SetPoint("TOPLEFT", dupeAffixCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(dupeAffixNote, 86)
        dupeAffixNote:SetJustifyH("LEFT")
        if dupeAffixNote.SetWordWrap then
            dupeAffixNote:SetWordWrap(true)
        end
        self.dupeAffixNote = dupeAffixNote

        -- v2.44.0: affix-rank floor slider. Asked for by Murlocked - on
        -- servers like PE where affixed Rare/Epic items saturate the
        -- bag, the player typically wants to keep only high-rank
        -- drops and sell the rest. The slider sets a minimum rank;
        -- anything below the threshold falls through the affix
        -- protection and is eligible for normal sell / delete /
        -- process rules. 0 means "off" (no threshold), 1-5 maps to
        -- rank I through V. Cleaning up the slider label below
        -- replaces the default "Sell affixes below rank: N" with
        -- "Off" when the value is 0 (a numeric "0" alongside ranks
        -- I-V reads as confusing).
        local rankSlider = NS.AddSlider(
            content,
            "EbonClearanceAffixMinSellRankSlider",
            dupeAffixNote,
            L["Sell affixes below rank"],
            0,
            5,
            1,
            function()
                return DB.affixMinSellRank or 0
            end,
            function(v)
                DB.affixMinSellRank = v
                -- Repaint the sell-border tints: changing the floor
                -- flips EC_IsSellable's verdict for every affixed
                -- Rare/Epic item in bags. Matches the dupeAffixCB /
                -- autoAffixCB OnClick patterns above.
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end,
            -14,
            "%d"
        )
        -- v2.44.0: align the slider with dupeAffixCB. AddSlider anchors
        -- to its anchor's BOTTOMLEFT at the anchor's x position;
        -- dupeAffixNote sits at +26 from dupeAffixCB (its own indent
        -- under the parent toggle), which would put the slider at
        -- double the indent. Shift left by 26 px so the slider lines
        -- up with dupeAffixCB visually - both are siblings under the
        -- parent affix-protection toggle.
        rankSlider:ClearAllPoints()
        rankSlider:SetPoint("TOPLEFT", dupeAffixNote, "BOTTOMLEFT", -26, -14)
        EC_compCache.setPanelWidth(rankSlider, 100)
        local function refreshRankSliderLabel(value)
            local txt = _G["EbonClearanceAffixMinSellRankSliderText"]
            if not txt then
                return
            end
            if value == 0 then
                txt:SetText(L["Sell affixes below rank"] .. ": " .. L["Off"])
            else
                txt:SetText(L["Sell affixes below rank"] .. ": " .. tostring(value))
            end
        end
        rankSlider:HookScript("OnValueChanged", function(_, v)
            refreshRankSliderLabel(v)
        end)
        refreshRankSliderLabel(DB.affixMinSellRank or 0)
        local rankLow = _G["EbonClearanceAffixMinSellRankSliderLow"]
        if rankLow then
            rankLow:SetText(L["Off"])
        end
        local rankHigh = _G["EbonClearanceAffixMinSellRankSliderHigh"]
        if rankHigh then
            rankHigh:SetText("5")
        end
        self.rankSlider = rankSlider
        if NS.AddHelpIcon then
            local sliderText = _G["EbonClearanceAffixMinSellRankSliderText"]
            if sliderText then
                NS.AddHelpIcon(content, sliderText, "LEFT", "RIGHT", 6, 0, "gate-affix-rank-floor")
            end
        end

        -- v2.44.0: explainer note under the rank slider. Mirrors the
        -- dupeAffixNote's active-state explainer so the OR-relationship
        -- between the two affix-sell rules is visible at both points
        -- of toggling, not only in the Rule Summary. Hidden when the
        -- slider is Off (0) since there's nothing to explain.
        local rankSliderNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        rankSliderNote:SetPoint("TOPLEFT", rankSlider, "BOTTOMLEFT", 0, -6)
        EC_compCache.setPanelWidth(rankSliderNote, 86)
        rankSliderNote:SetJustifyH("LEFT")
        if rankSliderNote.SetWordWrap then
            rankSliderNote:SetWordWrap(true)
        end
        rankSliderNote:SetText("")
        self.rankSliderNote = rankSliderNote
        local function refreshRankSliderNote(value)
            if (value or 0) > 0 then
                rankSliderNote:SetText(
                    L["|cff888888Sells affixes below this rank, even ones you haven't extracted. Independent of the toggle above.|r"]
                )
            else
                rankSliderNote:SetText("")
            end
        end
        rankSlider:HookScript("OnValueChanged", function(_, v)
            refreshRankSliderNote(v)
        end)
        refreshRankSliderNote(DB.affixMinSellRank or 0)

        -- Greys-out the child CB when the parent toggle is off OR when PE
        -- isn't detected, and swaps in a status line for that case.
        -- Called on init, on the parent CB's OnClick, and on every
        -- refresh-callback fire.
        local function UpdateDupeAffixEnabled()
            local peOn = EC_compCache.peDetected and EC_compCache.peDetected()
            local parentOn = DB.protectAffixedRareItems == true
            if peOn and parentOn then
                dupeAffixCB:Enable()
                if rankSlider and rankSlider.Enable then
                    rankSlider:Enable()
                end
                if daText then
                    daText:SetTextColor(1, 1, 1)
                end
                -- v2.44.0: active-state explainer. Tells the player
                -- this toggle is its own rule, independent of the
                -- rank slider directly below. The two are an OR -
                -- without this note, players hit the confusion that
                -- "I set the slider to 3 but rank-IV items still
                -- sell because I have this on too." Real player
                -- feedback (Serv): toggles felt like they were
                -- fighting until each one's scope was explained at
                -- the toggle itself.
                if DB.affixAllowExactDupes then
                    dupeAffixNote:SetText(
                        L["|cff888888Sells affixes at ranks you already own. Independent of the rank slider below.|r"]
                    )
                else
                    dupeAffixNote:SetText("")
                end
                -- v2.44.0: keep the rank-slider note in sync with the
                -- parent / slider state too.
                if refreshRankSliderNote then
                    refreshRankSliderNote(DB.affixMinSellRank or 0)
                end
            else
                dupeAffixCB:Disable()
                if rankSlider and rankSlider.Disable then
                    rankSlider:Disable()
                end
                if daText then
                    daText:SetTextColor(0.5, 0.5, 0.5)
                end
                if not peOn then
                    dupeAffixNote:SetText(
                        L["|cff888888Project Ebonhold addon not detected. This option needs PE to know which affixes you have.|r"]
                    )
                else
                    dupeAffixNote:SetText(L["|cff888888Turn on the affix protection above to use this option.|r"])
                end
                -- v2.44.0: collapse the rank-slider explainer when
                -- the parent toggle is off (the slider has no effect).
                if rankSliderNote then
                    rankSliderNote:SetText("")
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
        -- parent toggle's indent column.
        -- v2.44.0: re-anchored to the new rankSlider (which now sits
        -- between dupeAffixNote and procCB). Slider sits at the
        -- dupeAffixNote's +26 indent; procCB returns to the parent
        -- toggle column via -26 (slider was already indented).
        -- v2.44.0: re-anchored from rankSlider to rankSliderNote so the
        -- procCB shifts down when the explainer note is visible (and
        -- back up when the slider is Off and the note collapses).
        procCB:SetPoint("TOPLEFT", rankSliderNote, "BOTTOMLEFT", -26, -10)
        procCB:SetChecked(DB.protectChanceOnHitItems)
        local pcText = _G[procCB:GetName() .. "Text"]
        if pcText then
            pcText:SetText(L["Keep items with chance-on-hit procs"])
            EC_compCache.setPanelWidth(pcText, 60)
            pcText:SetJustifyH("LEFT")
        end
        self.procCB = procCB
        if pcText then
            NS.AddHelpIcon(content, pcText, "LEFT", "RIGHT", 6, 0, "gate-chance-on-hit")
        end

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
        unlearnedTomeCB:SetPoint("TOPLEFT", procCB, "BOTTOMLEFT", 0, -10)
        unlearnedTomeCB:SetChecked(DB.protectUnlearnedTomes)
        local utText = _G[unlearnedTomeCB:GetName() .. "Text"]
        if utText then
            utText:SetText(L["Keep unlearned tomes and recipes"])
            EC_compCache.setPanelWidth(utText, 60)
            utText:SetJustifyH("LEFT")
        end
        self.unlearnedTomeCB = unlearnedTomeCB
        if utText then
            NS.AddHelpIcon(content, utText, "LEFT", "RIGHT", 6, 0, "gate-tome-recipe")
        end

        -- Child toggle: extends protection to already-known items.
        -- Indented +26 from the parent CB so it sits a column further
        -- right (matches the affix-dupe pattern; pre-Task 15 this
        -- inherited the indent from the parent's explanatory note, but
        -- the note was stripped and the indent is now applied directly).
        local allTomeCB = CreateFrame(
            "CheckButton",
            "EbonClearanceProtectAllTomesCB",
            content,
            "InterfaceOptionsCheckButtonTemplate"
        )
        allTomeCB:SetPoint("TOPLEFT", unlearnedTomeCB, "BOTTOMLEFT", 26, -8)
        allTomeCB:SetChecked(DB.protectAllTomes)
        local atText = _G[allTomeCB:GetName() .. "Text"]
        if atText then
            atText:SetText(L["Keep them even after you learn them"])
            EC_compCache.setPanelWidth(atText, 86)
            atText:SetJustifyH("LEFT")
        end
        self.allTomeCB = allTomeCB
        if atText then
            NS.AddHelpIcon(content, atText, "LEFT", "RIGHT", 6, 0, "label-tome-have")
        end

        -- Status-feedback FontString. After Task 15 the explanatory text
        -- for the active case lives in the Help panel ([?] icon above);
        -- this note now only carries the disabled-state status message
        -- ("Turn on the protection above"). FitScrollContent uses this
        -- as the bottom-most widget so the scroll area still sizes
        -- correctly when the note is empty.
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
                allTomeNote:SetText("")
            else
                allTomeCB:Disable()
                if atText then
                    atText:SetTextColor(0.5, 0.5, 0.5)
                end
                allTomeNote:SetText(L["|cff888888Turn on the protection above to use this option.|r"])
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
