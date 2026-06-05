-- EbonClearance_PanelWidgets - panel widget primitives.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ix-c of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- Six widget primitives bundled in one file: MakeHeader, MakeLabel,
-- StyleInputBox, AddCheckbox, AddSlider, ColorTextByQuality. Every
-- Interface Options panel in the addon builds widgets through these
-- helpers. All six are exposed on NS so split panel files can call
-- them (the bare locals would only be visible inside this file).
--
-- Moved into this file:
--   * MakeHeader         (GameFontNormalLarge at TOPLEFT 16, y)
--   * StyleInputBox      (InputBoxTemplate EditBox chrome treatment;
--                         pulls glyph layers to BACKGROUND so the text
--                         renders on top)
--   * MakeLabel          (GameFontHighlight wrapped label; registers
--                         width with EC_compCache.registerWidth so
--                         the wrap re-flows on Interface Options
--                         container resize)
--   * AddCheckbox        (InterfaceOptionsCheckButtonTemplate +
--                         text + click handler)
--   * ColorTextByQuality (ITEM_QUALITY_COLORS-aware text formatter)
--   * AddSlider          (OptionsSliderTemplate + label + value
--                         display + commit on OnValueChanged)
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core)  - EC_compCache.registerWidth (MakeLabel)
--   * NS.GetPanelWidth     - MakeLabel's initial-width snapshot;
--                            8e-ix-b prep exposure
--
-- The list-row factories (EC_compCache.makeListRowFactory +
-- buildList*Row helpers) + CreateListUI + EC_AddScanByQualityRow STAY
-- in EbonClearance.lua for Stage 8e-ix-d.

local NS = select(2, ...)
local EC_compCache = NS.compCache

local function MakeHeader(parent, text, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    return fs
end
NS.MakeHeader = MakeHeader

-- StyleInputBox: applied to every InputBoxTemplate EditBox we use. v2.18.0
-- moved this up from its old position below CreateListUI so the new
-- EC_compCache.buildListHeaderRow / buildListSearchAndSortRow helpers
-- (which call it during their pure-layout build) can see it as an
-- upvalue. Forward-reference discipline: Lua file-scope
-- locals are only visible to code AFTER their declaration; the v2.18.0
-- split inadvertently placed the helpers BEFORE StyleInputBox, which
-- worked at parse time but exploded at first OnShow with
-- "attempt to call global 'StyleInputBox' (a nil value)".
local function StyleInputBox(editBox)
    if not editBox then
        return
    end
    if editBox.SetTextInsets then
        editBox:SetTextInsets(6, 6, 0, 0)
    end

    local fs = editBox.GetFontString and editBox:GetFontString()
    if fs and fs.SetDrawLayer then
        fs:SetDrawLayer("OVERLAY")
    end
    if fs and fs.SetAlpha then
        fs:SetAlpha(1)
    end

    local n = editBox.GetName and editBox:GetName()
    if n then
        local left = _G[n .. "Left"]
        local mid = _G[n .. "Middle"]
        local right = _G[n .. "Right"]
        if left and left.SetDrawLayer then
            left:SetDrawLayer("BACKGROUND")
        end
        if mid and mid.SetDrawLayer then
            mid:SetDrawLayer("BACKGROUND")
        end
        if right and right.SetDrawLayer then
            right:SetDrawLayer("BACKGROUND")
        end
    end
    editBox:SetFrameLevel((editBox:GetParent() and editBox:GetParent():GetFrameLevel() or editBox:GetFrameLevel()) + 2)

    if editBox.GetText and editBox.SetText then
        local t = editBox:GetText() or ""
        editBox:SetText(t)
        if editBox.SetCursorPosition then
            editBox:SetCursorPosition(0)
        end
    end
end
NS.StyleInputBox = StyleInputBox

local function MakeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(NS.GetPanelWidth() - x)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    -- v2.11.0: register the label's width with the reactive layout
    -- registry so it re-wraps when the panel container resizes.
    EC_compCache.registerWidth(fs, x)
    if fs.SetWordWrap then
        fs:SetWordWrap(true)
    end
    fs:SetText(text)
    return fs
end
NS.MakeLabel = MakeLabel

-- MakeHelpIcon: small clickable [?] anchored next to a setting widget.
-- Clicking deep-links into the Help panel via NS.OpenHelpEntry(entryId),
-- which opens Help, expands the section containing the target entry,
-- scrolls the entry to the top of the viewport, and briefly flashes it.
-- See EbonClearance_HelpPanel.lua for NS.OpenHelpEntry.
--
-- Args:
--   parent       - frame to parent the icon to
--   anchorWidget - widget to anchor next to (the setting's label or row)
--   anchorPoint  - anchor point ON the icon (typically "LEFT")
--   relPoint     - anchor point on the target widget (typically "RIGHT")
--   xOff, yOff   - pixel offset (defaults 4, 0 if nil)
--   entryId      - stable id of the Help entry to deep-link to (e.g. "gate-keep-list-blocks")
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

    -- Hover highlight + GameTooltip prompt.
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
        if PlaySound then
            PlaySound("igMainMenuOptionCheckBoxOn")
        end
    end)

    return btn
end
NS.AddHelpIcon = MakeHelpIcon

local function AddCheckbox(parent, name, anchor, labelText, getter, setter, yOff)
    local cb = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -6)
    cb:SetChecked(getter())

    local t = _G[name .. "Text"]
    if t then
        t:SetText(labelText)
        t:SetWidth(420)
        t:SetJustifyH("LEFT")
    end

    cb:SetScript("OnClick", function()
        setter(cb:GetChecked() and true or false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    return cb
end
NS.AddCheckbox = AddCheckbox

local function ColorTextByQuality(quality, text)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    local hex = (c and c.hex) or "|cffffffff"
    return hex .. text .. "|r"
end
NS.ColorTextByQuality = ColorTextByQuality

local function AddSlider(parent, name, anchor, labelText, minVal, maxVal, step, getter, setter, yOff, fmt)
    fmt = fmt or "%.3fs"
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -16)
    s:SetMinMaxValues(minVal, maxVal)
    if s.SetValueStep then
        s:SetValueStep(step)
    end
    if s.SetObeyStepOnDrag then
        s:SetObeyStepOnDrag(true)
    end
    s:SetValue(getter())

    local low = _G[name .. "Low"]
    local high = _G[name .. "High"]
    local text = _G[name .. "Text"]

    if low then
        low:SetText(string.format(fmt, minVal))
    end
    if high then
        high:SetText(string.format(fmt, maxVal))
    end

    local function RefreshText(v)
        if text then
            text:SetText(labelText .. ": " .. string.format(fmt, v))
        end
    end
    RefreshText(getter())

    s:SetScript("OnValueChanged", function(self, value)
        value = tonumber(value) or minVal
        if step and step > 0 then
            value = math.floor((value / step) + 0.5) * step
        end
        if value < minVal then
            value = minVal
        end
        if value > maxVal then
            value = maxVal
        end
        setter(value)
        RefreshText(value)
    end)

    return s
end
NS.AddSlider = AddSlider
