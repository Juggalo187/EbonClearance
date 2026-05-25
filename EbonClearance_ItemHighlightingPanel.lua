-- EbonClearance_ItemHighlightingPanel - Item Highlighting Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-vii of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Item Highlighting UI panel (v2.30.x rename of the former
-- Character Settings panel; internal frame name
-- "EbonClearanceOptionsCharacter" preserved for SV compatibility).
-- Hosts the master sell-border toggle + the five per-category
-- enable/colour rows (delete / accountSell / charSell / junk / rule).
--
-- Moved into this file:
--   * local CharPanel = CreateFrame(...) frame creation
--   * The CharPanel OnShow handler (panel-build body that constructs
--     the master toggle + the SELL_BORDER_CATEGORIES iteration that
--     builds one enable+colour row per category + the
--     RefreshSellBorderSwatch helper that re-syncs every swatch on
--     panel reshow)
--
-- Cleanups bundled into this stage:
--   - The dead CreateNameListUI function (~170 LOC) is dropped. It
--     was orphaned in §4.5 when the per-character allowlist UI was
--     decommissioned along with the panel rename. Zero call sites in
--     any shipped file confirmed via grep.
--   - Orphan comment headers from Stages 8e-v / 8e-vi extractions
--     are stripped from EbonClearance.lua (BlacklistPanel and
--     BlacklistSettingsPanel docstrings that survived the moves).
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel
--   * NS.DB captured at OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.RefreshSellBorders (BagDisplay) - used by the master toggle
--     and each per-category enable / colour-picker OnClick handler
--     to repaint slot tints immediately (Issue B refresh invariant)

local NS = select(2, ...)
local EC_compCache = NS.compCache

local CharPanel = CreateFrame("Frame", "EbonClearanceOptionsCharacter", InterfaceOptionsFramePanelContainer)
CharPanel.name = "Item Highlighting"
CharPanel.parent = "EbonClearance"

CharPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.sellBorderCB then
            self.sellBorderCB:SetChecked(DB.sellBorderEnabled)
        end
        if self.RefreshSellBorderSwatch then
            self:RefreshSellBorderSwatch()
        end
        if self.showItemIDCB then
            self.showItemIDCB:SetChecked(DB.showItemIDOnTooltip)
        end
    end, function(self)
        NS.MakeHeader(self, "Item Highlighting", -16)
        -- v2.30.x: panel repurposed from "Character Settings" to focus
        -- entirely on bag-item highlighting. The per-character enable
        -- allowlist was removed (minimap toggle covers that use case);
        -- DB.enableOnlyListedChars is force-disabled in EnsureDB and
        -- DB.allowedChars sits dormant in the SV for downgrade safety.
        local bagDesc = NS.MakeLabel(
            self,
            "Coloured borders around bag items so you can see what will sell, what's junk, and what's protected - at a glance. Icons are untouched.",
            16,
            -44
        )

        local sbCB =
            CreateFrame("CheckButton", "EbonClearanceSellBorderCB", self, "InterfaceOptionsCheckButtonTemplate")
        sbCB:SetPoint("TOPLEFT", bagDesc, "BOTTOMLEFT", 0, -8)
        sbCB:SetChecked(DB.sellBorderEnabled)

        -- Text auto-sizes to its content (no width snapshot) so the colour
        -- button can dock immediately to the text's right edge without
        -- overlapping. The standard checkbox-template text anchors LEFT of
        -- the checkbox icon already; only the wrap width was the problem.
        local sbText = _G[sbCB:GetName() .. "Text"]
        if sbText then
            sbText:SetText("Show borders")
            sbText:SetJustifyH("LEFT")
        end

        sbCB:SetScript("OnClick", function()
            DB.sellBorderEnabled = sbCB:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
        end)
        self.sellBorderCB = sbCB

        -- v2.30.x: per-category colour pickers. One enable checkbox +
        -- one swatch + one Change-colour button per verdict category.
        -- Each row is anchored to the previous row so the column flows
        -- naturally and the bottom-most row drives the listUI anchor.
        --
        -- Category display order matches the tooltip annotation
        -- priority order: Delete first (highest visibility), then the
        -- two Sell lists, then Junk, then per-rarity rule.
        local SELL_BORDER_CATEGORIES = {
            { key = "delete", label = "Delete List (red)" },
            { key = "accountSell", label = "Account Sell List (green)" },
            { key = "charSell", label = "Character Sell List (cyan)" },
            { key = "junk", label = "Junk - greys (low-alpha grey)" },
            { key = "rule", label = "Quality rule match (gold)" },
        }
        local catSwatchUpdaters = {}

        local lastRowAnchor = sbCB
        for i, cat in ipairs(SELL_BORDER_CATEGORIES) do
            local key = cat.key
            -- Per-category enable checkbox. First row indents 18 px
            -- relative to the master toggle so the rows visually nest
            -- under it; subsequent rows align with the first.
            local catCB = CreateFrame(
                "CheckButton",
                "EbonClearanceSellBorderCB_" .. key,
                self,
                "InterfaceOptionsCheckButtonTemplate"
            )
            local xOff = (i == 1) and 18 or 0
            local yOff = (i == 1) and -6 or -4
            catCB:SetPoint("TOPLEFT", lastRowAnchor, "BOTTOMLEFT", xOff, yOff)
            catCB:SetChecked(DB.sellBorderCategories[key].enabled)
            local catCBText = _G[catCB:GetName() .. "Text"]
            if catCBText then
                catCBText:SetText(cat.label)
                catCBText:SetJustifyH("LEFT")
            end
            catCB:SetScript("OnClick", function()
                DB.sellBorderCategories[key].enabled = catCB:GetChecked() and true or false
                PlaySound("igMainMenuOptionCheckBoxOn")
                if NS.RefreshSellBorders then
                    NS.RefreshSellBorders()
                end
            end)

            -- Per-category swatch and Change-colour button on the same
            -- row, to the right of the label.
            local catSwatch = self:CreateTexture(nil, "OVERLAY")
            catSwatch:SetSize(16, 16)
            local swatchAnchor = catCBText or catCB
            catSwatch:SetPoint("LEFT", swatchAnchor, "RIGHT", 12, 0)
            catSwatch:SetTexture("Interface\\Buttons\\WHITE8X8")

            local function updateCatSwatch()
                local entry = DB.sellBorderCategories[key]
                if entry and entry.color then
                    local c = entry.color
                    catSwatch:SetVertexColor(c.r, c.g, c.b, 1)
                end
            end
            updateCatSwatch()
            catSwatchUpdaters[#catSwatchUpdaters + 1] = updateCatSwatch

            local catBtn = CreateFrame(
                "Button",
                "EbonClearanceSellBorderColorBtn_" .. key,
                self,
                "UIPanelButtonTemplate"
            )
            catBtn:SetSize(110, 22)
            catBtn:SetPoint("LEFT", catSwatch, "RIGHT", 6, 0)
            catBtn:SetText("Change colour")
            catBtn:SetScript("OnClick", function()
                local c = DB.sellBorderCategories[key].color
                local function commit(r, g, b, a)
                    c.r, c.g, c.b, c.a = r, g, b, a
                    updateCatSwatch()
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end

                local pickerInfo = {
                    r = c.r,
                    g = c.g,
                    b = c.b,
                    -- 3.3.5a opacity convention: 0 = fully opaque,
                    -- 1 = fully transparent. Our stored alpha is the
                    -- inverse; flip on the way in, flip back on the
                    -- way out.
                    opacity = 1 - (c.a or 0.9),
                    hasOpacity = true,
                    swatchFunc = function()
                        local r, g, b = ColorPickerFrame:GetColorRGB()
                        local a = 1 - (OpacitySliderFrame:GetValue() or 0)
                        commit(r, g, b, a)
                    end,
                    opacityFunc = function()
                        local r, g, b = ColorPickerFrame:GetColorRGB()
                        local a = 1 - (OpacitySliderFrame:GetValue() or 0)
                        commit(r, g, b, a)
                    end,
                    cancelFunc = function(prev)
                        if not prev then
                            return
                        end
                        commit(prev.r, prev.g, prev.b, 1 - (prev.opacity or 0))
                    end,
                }
                OpenColorPicker(pickerInfo)
                -- 3.3.5a quirk: the InterfaceOptions container can sit
                -- at the same frame-strata as the colour picker, so
                -- the picker renders behind it on some clients. Force
                -- the picker to the top AFTER OpenColorPicker has
                -- reset the frame state.
                if ColorPickerFrame then
                    ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
                    if ColorPickerFrame.Raise then
                        ColorPickerFrame:Raise()
                    end
                end
            end)

            lastRowAnchor = catCB
        end

        -- Tooltip section. Opt-in itemID annotation that appends the
        -- numeric item ID to the EC tooltip status line. Defaults OFF;
        -- power users (bug reports, list authoring by ID) flip this on.
        -- The -18 x-offset un-nests this section from the indented
        -- per-category rows above so the header aligns with the master
        -- sell-border toggle.
        local tipHeader = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        tipHeader:SetPoint("TOPLEFT", lastRowAnchor, "BOTTOMLEFT", -18, -16)
        tipHeader:SetText("Tooltip")

        local idCB = CreateFrame(
            "CheckButton",
            "EbonClearanceShowItemIDCB",
            self,
            "InterfaceOptionsCheckButtonTemplate"
        )
        idCB:SetPoint("TOPLEFT", tipHeader, "BOTTOMLEFT", 0, -6)
        idCB:SetChecked(DB.showItemIDOnTooltip)
        local idCBText = _G[idCB:GetName() .. "Text"]
        if idCBText then
            idCBText:SetText("Show item ID in tooltip")
            idCBText:SetJustifyH("LEFT")
        end
        idCB:SetScript("OnClick", function()
            DB.showItemIDOnTooltip = idCB:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            -- Tooltips don't re-render themselves while visible, and
            -- EC_AnnotateTooltip's __EC_annotated dedupe flag can keep
            -- an already-drawn tooltip pinned to the pre-toggle state
            -- until the cursor moves off it. Drop the flag and hide
            -- any visible tooltip so the next hover paints fresh -
            -- avoids needing a /reload to see the change take effect.
            if GameTooltip then
                GameTooltip.__EC_annotated = nil
                if GameTooltip:IsShown() then
                    GameTooltip:Hide()
                end
            end
            if ItemRefTooltip then
                ItemRefTooltip.__EC_annotated = nil
            end
        end)
        self.showItemIDCB = idCB

        -- Discoverability hint. The toggle takes effect on the NEXT
        -- tooltip render, not on already-visible ones - tell the user
        -- so they don't assume a /reload is required.
        local idHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        idHint:SetPoint("TOPLEFT", idCB, "BOTTOMLEFT", 4, -2)
        idHint:SetText("|cff888888Move your cursor off and back on to refresh open tooltips.|r")

        -- Single refresh helper that re-syncs every category's swatch
        -- and checkbox state. Called from the REFRESH branch of
        -- initPanel (when the user navigates back to the panel after
        -- a settings-pack import or other external DB mutation).
        self.RefreshSellBorderSwatch = function(panel)
            for _, updater in ipairs(catSwatchUpdaters) do
                updater()
            end
            for _, cat in ipairs(SELL_BORDER_CATEGORIES) do
                local cb = _G["EbonClearanceSellBorderCB_" .. cat.key]
                if cb and cb.SetChecked then
                    cb:SetChecked(DB.sellBorderCategories[cat.key].enabled)
                end
            end
        end

        -- v2.30.x: the "Allowed Characters" list UI was removed when
        -- the per-character allowlist feature was decommissioned. The
        -- panel now ends after the five per-category colour pickers.
        -- The panel isn't scroll-wrapped (~244 px of content, well
        -- under the Interface Options container's natural height) so
        -- no FitScrollContent call is needed.
    end)
end)
