-- EbonClearance_MerchantPanel - Merchant Settings Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ii of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Merchant Settings UI panel: vendor mode dropdown, repair toggles,
-- vendor interval / max-items sliders, fast-mode toggle, per-rarity
-- rule rows (White/Green/Blue/Epic with iLvl caps + bind filter +
-- useEquippedILvl toggle).
--
-- Moved into this file:
--   * EC_WHITELIST_QUALITIES dropdown data (rarity labels for the
--     per-rarity rule rows)
--   * MerchantPanel frame (named "EbonClearanceOptionsMerchant")
--   * EC_MERCHANT_MODES dropdown data (Goblin / Normal / All)
--   * The MerchantPanel OnShow handler (the panel-build body that
--     constructs all the dropdowns, sliders, and per-rarity rule rows)
--
-- Cross-file dependencies read inline:
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth,
--     refreshLayouts, getBindType
--   * NS.DB captured at OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (EbonClearance.lua) - panel text;
--     NS-exposed in Stage 8e-i.
--   * NS.AddCheckbox / NS.AddSlider / NS.ColorTextByQuality /
--     NS.StyleInputBox / NS.FitScrollContent (EbonClearance.lua) -
--     panel widget primitives; NS-exposed as Stage 8e-ii prep.
--   * NS.PrintNice / NS.PrintNicef (EbonClearance.lua) - chat output.
--   * Various WoW globals - CreateFrame, UIDropDownMenu_*,
--     PlaySound, GameTooltip, etc.

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- Quality-threshold options shared by the Merchant Settings panel.
--
-- The table is constructed inside the OnShow build callback (not at file
-- load time) because this file loads BEFORE EbonClearance.lua and the
-- NS.ColorTextByQuality binding doesn't exist yet at load. Eager table
-- construction would call nil here. The build callback runs lazily on
-- first OnShow, by which time EbonClearance.lua has loaded and NS is
-- fully populated. The OnShow build is gated by initPanel's "build
-- only once" lock so this evaluates exactly once per session, same as
-- the original file-scope upvalue.
local EC_WHITELIST_QUALITIES   -- assigned inside the build callback below

local MerchantPanel = CreateFrame("Frame", "EbonClearanceOptionsMerchant", InterfaceOptionsFramePanelContainer)
MerchantPanel.name = "Merchant Settings"
MerchantPanel.parent = "EbonClearance"

local EC_MERCHANT_MODES = {
    { text = "|cffb6ffb6Goblin Merchant|r Only", value = "goblin" },
    { text = "Normal Merchants Only", value = "any" },
    -- v2.13.x: renamed from "Both (All Merchants)" and made the new default
    -- in EnsureDB so brand-new users without the Goblin Merchant pet still
    -- get useful auto-vendor behaviour at normal merchants out of the box.
    { text = "All Merchants", value = "both" },
}

MerchantPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.repairCB then
            self.repairCB:SetChecked(DB.repairGear)
        end
        if self.guildRepairCB then
            self.guildRepairCB:SetChecked(DB.repairUseGuildBank)
        end
        if self.keepBagsCB then
            self.keepBagsCB:SetChecked(DB.keepBagsOpen)
        end
        if self.speedSlider then
            self.speedSlider:SetValue(DB.vendorInterval or 0.1)
        end
        if self.fastModeCB then
            self.fastModeCB:SetChecked(DB.fastMode)
        end
        if self.RefreshMerchantModeDropDown then
            self:RefreshMerchantModeDropDown()
        end
        for q = 1, 4 do
            local cb = self["qualityRow" .. q .. "CB"]
            local input = self["qualityRow" .. q .. "Input"]
            local dd = self["qualityRow" .. q .. "DD"]
            local useEqCB = self["qualityRow" .. q .. "UseEq"]
            if cb and DB.qualityRules and DB.qualityRules[q] then
                cb:SetChecked(DB.qualityRules[q].enabled)
            end
            if input and DB.qualityRules and DB.qualityRules[q] then
                input:SetText(tostring(DB.qualityRules[q].maxILvl or 0))
            end
            if dd and DB.qualityRules and DB.qualityRules[q] and self._BindFilterText then
                UIDropDownMenu_SetText(dd, self._BindFilterText(DB.qualityRules[q].bindFilter))
            end
            -- v2.12.0: refresh the per-rarity Use-equipped-iLvl tickbox
            -- and the maxILvl input's enabled state. The applyInputEnabled
            -- helper was stashed on the row's main checkbox at build time.
            if useEqCB and DB.qualityRules and DB.qualityRules[q] then
                useEqCB:SetChecked(DB.qualityRules[q].useEquippedILvl == true)
            end
            if cb and cb._applyInputEnabled then
                cb._applyInputEnabled()
            end
        end
    end, function(self, content)
        -- Build-time table population. See the EC_WHITELIST_QUALITIES
        -- declaration above for why this can't run at file load.
        EC_WHITELIST_QUALITIES = {
            { text = NS.ColorTextByQuality(1, "White (Common)"), value = 1 },
            { text = NS.ColorTextByQuality(2, "Green (Uncommon)"), value = 2 },
            { text = NS.ColorTextByQuality(3, "Blue (Rare)"), value = 3 },
            { text = NS.ColorTextByQuality(4, "Purple (Epic)"), value = 4 },
        }

        NS.MakeHeader(content, "Merchant Settings", -16)
        -- Panel-specific intro only. Generic "grey junk auto-sells" cross-cut
        -- removed; it's covered on the Main panel.
        NS.MakeLabel(content, "Change which items sell automatically, and at which merchants.", 16, -44)

        -- Merchant mode dropdown
        local modeLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        modeLabel:SetPoint("TOPLEFT", 16, -76)
        modeLabel:SetText("Sell at:")

        local modeDD = CreateFrame("Frame", "EbonClearanceMerchantModeDD", content, "UIDropDownMenuTemplate")
        modeDD:SetPoint("LEFT", modeLabel, "RIGHT", -8, -2)

        local function GetModeText(mode)
            for _, entry in ipairs(EC_MERCHANT_MODES) do
                if entry.value == mode then
                    return entry.text
                end
            end
            return EC_MERCHANT_MODES[1].text
        end

        local function MerchantModeInit(_frame, level)
            for _, entry in ipairs(EC_MERCHANT_MODES) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = entry.text
                info.value = entry.value
                info.checked = (DB.merchantMode == entry.value)
                info.func = function()
                    DB.merchantMode = entry.value
                    UIDropDownMenu_SetText(modeDD, entry.text)
                    PlaySound("igMainMenuOptionCheckBoxOn")
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end

        UIDropDownMenu_SetWidth(modeDD, 180)
        UIDropDownMenu_SetText(modeDD, GetModeText(DB.merchantMode))
        UIDropDownMenu_Initialize(modeDD, MerchantModeInit)

        self.RefreshMerchantModeDropDown = function()
            UIDropDownMenu_SetText(modeDD, GetModeText(DB.merchantMode))
        end

        local repairCB =
            CreateFrame("CheckButton", "EbonClearanceRepairGearCB", content, "InterfaceOptionsCheckButtonTemplate")
        -- Shifted up 14 px (was -110) to follow the removed grey-junk line above
        -- the dropdown; preserves the original visual gap between dropdown and
        -- this checkbox.
        repairCB:SetPoint("TOPLEFT", 16, -96)
        repairCB:SetChecked(DB.repairGear)
        local rt = _G[repairCB:GetName() .. "Text"]
        if rt then
            rt:SetText("Repair gear while selling")
            rt:SetWidth(420)
            rt:SetJustifyH("LEFT")
        end
        repairCB:SetScript("OnClick", function()
            DB.repairGear = repairCB:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        self.repairCB = repairCB

        -- Guild-bank funded repair. Indented under the master repair toggle so
        -- the visual hierarchy reads "repair, and prefer guild bank if I can".
        -- The runtime path falls back to personal gold whenever the bank can't
        -- supply the full amount, so toggling this on is safe even on alts who
        -- aren't in a guild.
        local guildRepairCB =
            CreateFrame("CheckButton", "EbonClearanceRepairGuildBankCB", content, "InterfaceOptionsCheckButtonTemplate")
        guildRepairCB:SetPoint("TOPLEFT", repairCB, "BOTTOMLEFT", 22, -2)
        guildRepairCB:SetChecked(DB.repairUseGuildBank)
        local grt = _G[guildRepairCB:GetName() .. "Text"]
        if grt then
            grt:SetText("Pay from guild bank when possible")
            EC_compCache.setPanelWidth(grt, 80)
            grt:SetJustifyH("LEFT")
        end
        guildRepairCB:SetScript("OnClick", function()
            DB.repairUseGuildBank = guildRepairCB:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        self.guildRepairCB = guildRepairCB

        local keepBagsCB =
            CreateFrame("CheckButton", "EbonClearanceKeepBagsOpenCB", content, "InterfaceOptionsCheckButtonTemplate")
        keepBagsCB:SetPoint("TOPLEFT", guildRepairCB, "BOTTOMLEFT", -22, -6)
        keepBagsCB:SetChecked(DB.keepBagsOpen)
        local kbt = _G[keepBagsCB:GetName() .. "Text"]
        if kbt then
            kbt:SetText("Keep bags open after talking to a merchant")
            EC_compCache.setPanelWidth(kbt, 60)
            kbt:SetJustifyH("LEFT")
        end
        keepBagsCB:SetScript("OnClick", function()
            DB.keepBagsOpen = keepBagsCB:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        self.keepBagsCB = keepBagsCB

        local speedSlider = NS.AddSlider(
            content,
            "EbonClearanceVendoringSpeedSlider",
            keepBagsCB,
            "Vendoring Speed",
            0.05,
            0.500,
            0.01,
            function()
                return DB.vendorInterval or 0.1
            end,
            function(v)
                DB.vendorInterval = v
            end,
            -16
        )
        self.speedSlider = speedSlider
        speedSlider:SetWidth(200)

        local fastModeCB = NS.AddCheckbox(
            content,
            "EbonClearanceFastModeCB",
            speedSlider,
            "Fast Mode (0.05 s interval, 160-item cap)",
            function()
                return DB.fastMode
            end,
            function(v)
                DB.fastMode = v
            end,
            -16
        )
        self.fastModeCB = fastModeCB

        local fastModeNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fastModeNote:SetPoint("TOPLEFT", fastModeCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(fastModeNote, 60)
        fastModeNote:SetJustifyH("LEFT")
        if fastModeNote.SetWordWrap then
            fastModeNote:SetWordWrap(true)
        end
        fastModeNote:SetText(
            "|cff888888Sells faster. May cause disconnects on unstable connections - turn off if it does.|r"
        )

        -- Quality threshold (v2.4.0+): three per-rarity rows, each independently
        -- togglable with its own optional max iLvl. Replaces the old single-dropdown
        -- "sell up to quality X" model. Default all off; opt-in per rarity.
        local thresholdHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        thresholdHeader:SetPoint("TOPLEFT", fastModeNote, "BOTTOMLEFT", -26, -24)
        thresholdHeader:SetText("Quality Threshold")

        local thresholdDesc = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        thresholdDesc:SetPoint("TOPLEFT", thresholdHeader, "BOTTOMLEFT", 0, -4)
        EC_compCache.setPanelWidth(thresholdDesc, 16)
        thresholdDesc:SetJustifyH("LEFT")
        if thresholdDesc.SetWordWrap then
            thresholdDesc:SetWordWrap(true)
        end
        thresholdDesc:SetText(
            "Sell rules for each rarity. Tick the box to turn a rule on. Tick |cffffff00Use equipped iLvl|r to compare against what you're wearing in that slot (recommended). Or set a fixed |cffffff00max iLvl|r - 0 means sell every item of that rarity. |cffaaaaaaYour Sell List always sells; your Keep List always keeps.|r"
        )

        -- v2.10.0: bind-type filter options shared across all four rarity rows.
        -- "any" = today's behaviour (rule applies regardless of bind type);
        -- "boe" / "bop" restrict to items the tooltip says bind on equip /
        -- on pickup. Items with no bind line at all read as "any" from
        -- EC_compCache.getBindType so reagents/consumables/quest items are
        -- protected when bindFilter is "boe" or "bop".
        local EC_BIND_FILTER_OPTIONS = {
            { text = "Any bind type", value = "any" },
            { text = "BoE only", value = "boe" },
            { text = "BoP only", value = "bop" },
        }
        local function EC_BindFilterText(value)
            for _, entry in ipairs(EC_BIND_FILTER_OPTIONS) do
                if entry.value == value then
                    return entry.text
                end
            end
            return EC_BIND_FILTER_OPTIONS[1].text
        end

        -- Build a row per rarity. Each row: checkbox on the left, "max iLvl:"
        -- label + numeric input on the right (0-300). Below the checkbox, a
        -- "Bind: <Any/BoE/BoP>" dropdown that gates the rule on bind type.
        -- Returns the bind dropdown so the next row's anchor descends past
        -- the second line cleanly.
        local function MakeQualityRow(anchor, qualityIdx, labelText, yOff)
            local cb = NS.AddCheckbox(
                content,
                "EbonClearanceQualityRow" .. qualityIdx .. "CB",
                anchor,
                labelText,
                function()
                    return DB.qualityRules[qualityIdx].enabled
                end,
                function(v)
                    DB.qualityRules[qualityIdx].enabled = v
                    -- Per-rarity rule flip changes EC_IsSellable's
                    -- qualityPass for every slot of this rarity.
                    -- Repaint so slot tints track immediately. Same
                    -- rule as the list-mutation refresh invariant.
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end,
                yOff
            )

            local input =
                CreateFrame("EditBox", "EbonClearanceQualityRow" .. qualityIdx .. "Input", content, "InputBoxTemplate")
            input:SetSize(50, 20)
            -- Anchored to content's right edge with a small margin. Content's
            -- right edge already sits 26 px inside the panel (scrollbar gutter),
            -- so -6 here matches the original panel-anchored -32 offset visually.
            input:SetPoint("RIGHT", content, "RIGHT", -6, 0)
            input:SetPoint("TOP", cb, "TOP", 0, -2)
            input:SetAutoFocus(false)
            input:SetNumeric(true)
            input:SetMaxLetters(3)
            input:SetText(tostring(DB.qualityRules[qualityIdx].maxILvl or 0))
            NS.StyleInputBox(input)

            local lbl = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            lbl:SetPoint("RIGHT", input, "LEFT", -6, 0)
            lbl:SetText("max iLvl:")

            -- v2.12.0: per-rarity "Use equipped iLvl" tickbox. When checked,
            -- the maxILvl input is ignored at runtime and the cap is the
            -- player's currently-equipped iLvl in the same slot (per-item
            -- via EC_compCache.isDowngradeVsEquipped). The input is visibly
            -- disabled while this is checked so the user understands the
            -- maxILvl number isn't being applied.
            local useEqCB = CreateFrame(
                "CheckButton",
                "EbonClearanceQualityRow" .. qualityIdx .. "UseEqCB",
                content,
                "InterfaceOptionsCheckButtonTemplate"
            )
            useEqCB:SetPoint("RIGHT", lbl, "LEFT", -8, 0)
            useEqCB:SetChecked(DB.qualityRules[qualityIdx].useEquippedILvl == true)
            -- The InterfaceOptionsCheckButtonTemplate auto-creates a label
            -- to the RIGHT of the box; that label would extend rightward
            -- into the "max iLvl:" field on this layout. Blank the
            -- auto-generated label and place a separate FontString to the
            -- LEFT of the box instead so the row reads
            -- "<rarity>  Use equipped iLvl [✓]  max iLvl: [   ]".
            local autoLabel = _G[useEqCB:GetName() .. "Text"]
            if autoLabel then
                autoLabel:SetText("")
            end
            local useEqText = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            useEqText:SetPoint("RIGHT", useEqCB, "LEFT", -2, 0)
            useEqText:SetText("Use equipped iLvl")

            -- Re-anchor the rarity-row checkbox's auto-label so its right edge
            -- is bounded by the "Use equipped iLvl" text's left edge. The
            -- shared AddCheckbox helper applies a fixed 420 px label width
            -- which fits the wider Main / Protection Settings panels but
            -- overruns the right-anchored max-iLvl input on this row at
            -- narrow panel widths. Anchoring instead of fixed-width lets the
            -- rarity name truncate cleanly rather than visually colliding
            -- with the iLvl controls.
            local rowLabel = _G[cb:GetName() .. "Text"]
            if rowLabel then
                rowLabel:ClearAllPoints()
                rowLabel:SetPoint("LEFT", cb, "RIGHT", 4, 1)
                rowLabel:SetPoint("RIGHT", useEqText, "LEFT", -8, 0)
                rowLabel:SetJustifyH("LEFT")
                if rowLabel.SetWordWrap then
                    rowLabel:SetWordWrap(false)
                end
                if rowLabel.SetNonSpaceWrap then
                    rowLabel:SetNonSpaceWrap(false)
                end
            end

            useEqCB.tooltipText = "Use equipped iLvl"
            useEqCB.tooltipRequirement = "When checked, the cap for this rarity is your currently-equipped iLvl in the same slot. "
                .. "Items below auto-sell. Multi-slot items (rings, trinkets, weapons) compare against the "
                .. "worst equipped slot. Empty slots are skipped."

            local function applyInputEnabled()
                local on = DB.qualityRules[qualityIdx].useEquippedILvl == true
                if on then
                    -- 3.3.5a EditBox doesn't expose Enable/Disable - use
                    -- SetEditable + EnableMouse to actually block input,
                    -- and grey both the field text and the "max iLvl:" label
                    -- so the disabled state is obvious.
                    if input.SetEditable then
                        input:SetEditable(false)
                    end
                    input:EnableMouse(false)
                    if input.HasFocus and input:HasFocus() then
                        input:ClearFocus()
                    end
                    input:SetTextColor(0.5, 0.5, 0.5)
                    if lbl.SetTextColor then
                        lbl:SetTextColor(0.5, 0.5, 0.5)
                    end
                else
                    if input.SetEditable then
                        input:SetEditable(true)
                    end
                    input:EnableMouse(true)
                    input:SetTextColor(1, 1, 1)
                    if lbl.SetTextColor then
                        lbl:SetTextColor(1, 0.82, 0)
                    end
                end
            end
            applyInputEnabled()

            useEqCB:SetScript("OnClick", function(self_)
                DB.qualityRules[qualityIdx].useEquippedILvl = self_:GetChecked() and true or false
                applyInputEnabled()
                PlaySound("igMainMenuOptionCheckBoxOn")
                -- Toggling useEquippedILvl switches the per-rarity
                -- rule between fixed-cap and dynamic-cap modes - same
                -- slot verdict can flip either direction. Repaint so
                -- tints track.
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end)
            cb._applyInputEnabled = applyInputEnabled

            local function commit()
                local v = tonumber(input:GetText() or "0") or 0
                if v < 0 then
                    v = 0
                end
                if v > 300 then
                    v = 300
                end
                DB.qualityRules[qualityIdx].maxILvl = v
                input:SetText(tostring(v))
                -- Cap change flips qualityPass for every slot at the
                -- threshold; repaint so tints track. Note: this fires
                -- on every focus-lost (every commit), which is the
                -- right granularity - per-keystroke firing would be
                -- wasted work.
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end
            input:SetScript("OnEnterPressed", function()
                input:ClearFocus()
            end)
            input:SetScript("OnEscapePressed", function()
                input:SetText(tostring(DB.qualityRules[qualityIdx].maxILvl or 0))
                input:ClearFocus()
            end)
            input:SetScript("OnEditFocusLost", commit)

            -- Bind-type filter dropdown on a second line below the checkbox.
            -- Indented to align with the checkbox label so the rule reads as
            -- "[x] Blue (Rare) max iLvl: [200] / Bind: [Any bind type]".
            local bindLbl = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            bindLbl:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 26, -4)
            bindLbl:SetText("Bind:")

            local bindDD = CreateFrame(
                "Frame",
                "EbonClearanceQualityRow" .. qualityIdx .. "BindDD",
                content,
                "UIDropDownMenuTemplate"
            )
            bindDD:SetPoint("LEFT", bindLbl, "RIGHT", -8, -2)

            local function BindFilterInit(_frame, _level)
                for _, entry in ipairs(EC_BIND_FILTER_OPTIONS) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = entry.text
                    info.value = entry.value
                    info.checked = (DB.qualityRules[qualityIdx].bindFilter == entry.value)
                    info.func = function()
                        DB.qualityRules[qualityIdx].bindFilter = entry.value
                        UIDropDownMenu_SetText(bindDD, entry.text)
                        PlaySound("igMainMenuOptionCheckBoxOn")
                        -- Bind-filter change can drop or restore many
                        -- slots from qualityPass at once; repaint.
                        if NS.RefreshSellBorders then
                            NS.RefreshSellBorders()
                        end
                    end
                    UIDropDownMenu_AddButton(info, _level)
                end
            end
            UIDropDownMenu_SetWidth(bindDD, 120)
            UIDropDownMenu_SetText(bindDD, EC_BindFilterText(DB.qualityRules[qualityIdx].bindFilter))
            UIDropDownMenu_Initialize(bindDD, BindFilterInit)

            return cb, input, bindDD, useEqCB
        end

        -- All four rarity rows anchor their checkbox to the threshold description,
        -- not to the previous row's dropdown. The dropdown's left edge is offset
        -- by the UIDropDownMenuTemplate's internal padding (~16 px), and chaining
        -- row N to row N-1's dropdown made each successive row staircase right.
        -- A single shared anchor with explicit -y offsets keeps every checkbox,
        -- bind label, and dropdown on the same X column.
        --
        -- Per-row vertical budget: ~28 px (checkbox + label) + ~6 px gap + ~30 px
        -- dropdown frame + ~10 px gap to next row = ~74 px. -78 leaves a small
        -- breathing margin between rows without overlapping the dropdown's
        -- bottom shadow.
        local row1CB, row1Input, row1DD, row1UseEq =
            MakeQualityRow(thresholdDesc, 1, EC_WHITELIST_QUALITIES[1].text, -10)
        local row2CB, row2Input, row2DD, row2UseEq =
            MakeQualityRow(thresholdDesc, 2, EC_WHITELIST_QUALITIES[2].text, -88)
        local row3CB, row3Input, row3DD, row3UseEq =
            MakeQualityRow(thresholdDesc, 3, EC_WHITELIST_QUALITIES[3].text, -166)
        local row4CB, row4Input, row4DD, row4UseEq =
            MakeQualityRow(thresholdDesc, 4, EC_WHITELIST_QUALITIES[4].text, -244)

        self.qualityRow1CB, self.qualityRow1Input, self.qualityRow1DD, self.qualityRow1UseEq =
            row1CB, row1Input, row1DD, row1UseEq
        self.qualityRow2CB, self.qualityRow2Input, self.qualityRow2DD, self.qualityRow2UseEq =
            row2CB, row2Input, row2DD, row2UseEq
        self.qualityRow3CB, self.qualityRow3Input, self.qualityRow3DD, self.qualityRow3UseEq =
            row3CB, row3Input, row3DD, row3UseEq
        self.qualityRow4CB, self.qualityRow4Input, self.qualityRow4DD, self.qualityRow4UseEq =
            row4CB, row4Input, row4DD, row4UseEq

        -- Stash the BindFilterText helper on the panel so the inited refresh
        -- block can update each dropdown's display text without re-defining
        -- the option set.
        self._BindFilterText = EC_BindFilterText

        -- Size the scroll content to fit the bottom-most widget so the scrollbar
        -- range matches actual content. Purple Epic's bind dropdown is now the
        -- lowest widget on the panel.
        NS.FitScrollContent(content, row4DD)
    end, true)
end)
