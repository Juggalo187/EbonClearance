-- EbonClearance_ListWidget - reusable list-management widget.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ix-d of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The densest remaining cluster: the CreateListUI widget + its five build
-- helpers + the shared "Add from bags by quality" scan row. Every list
-- panel in the addon (Sell List, Account Sell List, Keep List, Delete List)
-- composes its UI through CreateListUI.
--
-- Moved into this file:
--   * EC_compCache.makeListRowFactory       (pooled row + icon + Remove-button + label)
--   * EC_compCache.buildListHeaderRow       ("Add to list": merged ID/name input + Add)
--   * EC_compCache.buildListSearchAndSortRow ("Find in list": Search + Name sort + Clear All + rarity filter)
--   * EC_compCache.buildListScrollArea      (scroll frame + ScrollChild + auto-hide)
--   * CreateListUI                          (assembles the above into one widget,
--                                            wires OnClick / OnTextChanged handlers,
--                                            owns the Refresh closure)
--   * EC_AddScanByQualityRow                (shared "Add from bags: White/Green/Blue"
--                                            scan row used by both Sell List panels)
--
-- NS exposures published from this file (for panel files that call them
-- inside their OnShow bodies):
--   * NS.CreateListUI         - exposed at end of CreateListUI
--   * NS.AddScanByQualityRow  - exposed at end of EC_AddScanByQualityRow
--
-- Cross-file dependencies satisfied by NS / EC_compCache:
--   * NS.compCache             - EC_compCache.refreshLayouts, register*, etc.
--   * NS.GetPanelWidth         - CreateListUI's initial width snapshot;
--                                EC_AddScanByQualityRow's rowFrame width
--   * NS.StyleInputBox         - applied to every InputBoxTemplate EditBox here
--   * NS.HookScrollbarAutoHide - applied to the ScrollFrame here
--   * NS.GetListTable          - core list-table resolver (whitelist /
--                                accountWhitelist / blacklist / deleteList)
--   * NS.AddItemToList         - canonical add-to-list path (conflict guard,
--                                dedupe, panel refresh, future origin tag)
--   * NS.PrintNicef            - chat output formatter
--   * NS.Delay                 - 3.3.5a-compatible setTimeout shim
--   * NS.ADB                   - account DB (for affixedListedItems annotation)
--   * NS.activeIDBox           - shared focus-tracker for shift-click-to-add;
--                                reader lives in EbonClearance.lua's
--                                ChatEdit_InsertLink hook
--
-- Lua 5.1 200-locals-per-main-chunk cap rationale: the five row-factory
-- helpers are hung off EC_compCache (not as file-scope locals) so they
-- don't consume locals slots in this file's main chunk. CreateListUI and
-- EC_AddScanByQualityRow are file-scope locals.

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- v2.41.0: sort-direction arrows. The old up/down triangle glyphs
-- (U+25B2 / U+25BC) are not in the 3.3.5 client font and rendered as a
-- literal "?"; inline button-arrow textures render reliably on every
-- client. SORT_ASC points up (ascending), SORT_DESC points down.
local SORT_ASC = "|TInterface\\Buttons\\Arrow-Up-Up:14:14:0:0|t"
local SORT_DESC = "|TInterface\\Buttons\\Arrow-Down-Up:14:14:0:0|t"

-- v2.41.0: rarity-filter options for the "Show:" dropdown. q == nil means
-- "All" (no filter). Quality numbers map to ITEM_QUALITY_COLORS via
-- NS.ColorTextByQuality for the coloured menu/selection text. Replaces the
-- old "ID" sort button - sorting by an item ID the row no longer shows is
-- no use, but filtering by rarity pairs naturally with the coloured names.
local EC_RARITY_FILTERS = {
    { q = nil, name = "All" },
    { q = 0, name = "Poor" },
    { q = 1, name = "Common" },
    { q = 2, name = "Uncommon" },
    { q = 3, name = "Rare" },
    { q = 4, name = "Epic" },
    { q = 5, name = "Legendary" },
}

-- v2.41.0: attach a plain-language hover tip to a control. HookScript so
-- it never clobbers an existing OnEnter/OnLeave (the ID input keeps its
-- focus-tracking handlers). Kept brief + new-player friendly.
local function EC_AddControlTip(widget, tipText)
    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tipText, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- v2.18.0: CreateListUI row-factory extraction. Encapsulates the row
-- pool (`rowPool`) and the active-row count (`activeRows`) that the
-- list widget uses to display its rows. Returns a small table with
-- three methods: `getRow(index)` mints or returns a pooled row frame
-- with a Remove button + label FontString, `hideAllRows()` hides every
-- currently active row and resets the count, `setActiveRows(n)` lets
-- the caller (Refresh) report how many rows are now displayed so the
-- next hideAllRows knows the upper bound.
--
-- Why expose setActiveRows: in the inline-CreateListUI version the
-- Refresh closure mutated `activeRows` directly as an upvalue. After
-- extraction the state lives inside the factory's closure, so Refresh
-- needs an explicit setter. Same data flow, just routed through a
-- method call.
--
-- Row layout: 22 px tall, full width via TOPLEFT/TOPRIGHT anchors set
-- by Refresh on each placement. Remove button is right-anchored, label
-- text fills the gap between row's left edge and the button.
function EC_compCache.makeListRowFactory(content, setTableName)
    local rowPool = {}
    local activeRows = 0

    local function getRow(index)
        if rowPool[index] then
            return rowPool[index]
        end
        local row = CreateFrame("Frame", nil, content)
        row:SetHeight(22)
        -- v2.11.0: rows track content width via TOPLEFT/TOPRIGHT anchors
        -- (re-applied at every position update in Refresh below). The text
        -- inside is anchored TOPLEFT/TOPRIGHT relative to row + Remove
        -- button so it auto-stretches; no SetWidth snapshot left to drift.

        local rm = CreateFrame(
            "Button",
            "EbonClearanceListRM_" .. setTableName .. "_" .. index,
            content,
            "UIPanelButtonTemplate"
        )
        rm:SetSize(72, 18)
        rm:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        rm:SetText("Remove")
        -- rm is a sibling of row (both children of content). Enabling
        -- mouse on row below would otherwise make the two compete for
        -- clicks where they overlap; pin rm one level higher so the
        -- Remove button always wins its own footprint.
        rm:SetFrameLevel(row:GetFrameLevel() + 1)

        -- v2.41.0: item icon replaces the old green itemID prefix. 18x18,
        -- left-anchored; SetTexCoord crops the stock icon border so the
        -- square reads cleanly against the dark list backdrop. The texture
        -- itself is set per-row in Refresh from the GetItemInfo call.
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetPoint("LEFT", row, "LEFT", 2, 0)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        text:SetPoint("RIGHT", rm, "LEFT", -8, 0)
        text:SetJustifyH("LEFT")

        -- v2.41.0: hover the row to see the item's tooltip at the cursor.
        -- row.itemID is stamped per-row in Refresh; the handler is wired
        -- once here so the pooled row keeps it across refreshes.
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            if self.itemID then
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetHyperlink("item:" .. self.itemID)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        row.rm = rm
        row.icon = icon
        row.text = text
        rowPool[index] = row
        return row
    end

    local function hideAllRows()
        for i = 1, activeRows do
            if rowPool[i] then
                rowPool[i]:Hide()
                rowPool[i].rm:Hide()
            end
        end
        activeRows = 0
    end

    local function setActiveRows(n)
        activeRows = n
    end

    return {
        getRow = getRow,
        hideAllRows = hideAllRows,
        setActiveRows = setActiveRows,
    }
end

-- v2.37.4 (audit issue #4): Clear All wipes a list table directly, which
-- bypasses EC_RemoveItemFromList's per-id side-meta prune. Snapshot the
-- itemIDs before wipe so each one can be prune-checked individually
-- (each call no-ops cheaply when the itemID is still on another list scope).
local function EC_ClearListWithPrune(t)
    if not t then
        return
    end
    if not NS.PruneSideMetaForItem then
        wipe(t)
        return
    end
    local cleared = {}
    for id in pairs(t) do
        cleared[#cleared + 1] = id
    end
    wipe(t)
    for i = 1, #cleared do
        NS.PruneSideMetaForItem(cleared[i])
    end
end

-- v2.41.0: the box no longer draws the list's name as an in-box title -
-- the panel heading + description above the box already identify the list.
-- This row is the "Add to list" group: a section header + one merged input
-- + Add. The input takes an item ID OR a name (the add logic lives in
-- CreateListUI's DoAdd). Clear All moved to the Find group (it is a
-- whole-list action, not an add action). Returns (input, addBtn).
function EC_compCache.buildListHeaderRow(box, setTableName)
    local secAdd = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    secAdd:SetPoint("TOPLEFT", 0, 0)
    secAdd:SetText("Add to list")

    local addLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    addLabel:SetPoint("TOPLEFT", 4, -24)
    addLabel:SetWidth(64)
    addLabel:SetJustifyH("LEFT")
    addLabel:SetText("Add item:")

    local addBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 20)
    -- -20 (not -24): the input anchors to the label's vertical centre, which
    -- sits ~4px below the row top, so the button is lifted 4px to line up
    -- with the field's centre (same trick as the v2.32.x sort buttons).
    addBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -20)
    addBtn:SetText("Add")

    -- Not numeric: the input accepts an ID or an item name. shift-click /
    -- drag still fill in the numeric ID via the handlers below.
    local input = CreateFrame("EditBox", "EbonClearanceIDInput_" .. setTableName, box, "InputBoxTemplate")
    input:SetAutoFocus(false)
    input:SetHeight(20)
    input:SetPoint("LEFT", addLabel, "RIGHT", 6, 0)
    input:SetPoint("RIGHT", addBtn, "LEFT", -8, 0)
    input:SetMaxLetters(100)
    input:SetText("")
    NS.StyleInputBox(input)

    input:SetScript("OnEditFocusGained", function(self)
        NS.activeIDBox = self
    end)
    input:SetScript("OnEditFocusLost", function(self)
        if NS.activeIDBox == self then
            NS.activeIDBox = nil
        end
    end)
    input:SetScript("OnReceiveDrag", function(self)
        local ctype, cid = GetCursorInfo()
        if ctype == "item" and cid then
            self:SetText(tostring(cid))
            self:HighlightText()
            ClearCursor()
        end
    end)

    EC_AddControlTip(
        input,
        "Type an item ID, or an item name (exact, or part of a name to add matching items from your bags). "
            .. "Shift-click or drag a bag item to fill in its ID."
    )
    EC_AddControlTip(addBtn, "Add the typed item ID or name to the list.")

    return input, addBtn
end

-- v2.41.0: the "Find in list" group. A thin divider separates it from the
-- "Add to list" group above. The header line carries the Sort label + the
-- Name sort button + Clear All (hard-right); the Search input + the "Show:"
-- rarity filter sit on the line below (the search input stretches to the
-- rarity dropdown and stays reactive on panel resize). Returns
-- (search, sortNameBtn, clearAllBtn, rarityDD).
function EC_compCache.buildListSearchAndSortRow(box, setTableName)
    local divider = box:CreateTexture(nil, "ARTWORK")
    divider:SetTexture(0.4, 0.35, 0.25, 0.8)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 0, -50)
    divider:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -50)

    local secFind = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    secFind:SetPoint("TOPLEFT", 0, -60)
    secFind:SetText("Find in list")

    -- Clear All wipes the whole list; lives on the Find header line, hard-right.
    local clearAllBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    clearAllBtn:SetSize(80, 20)
    clearAllBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -58)
    clearAllBtn:SetText("Clear All")

    local sortNameBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    sortNameBtn:SetSize(74, 20)
    sortNameBtn:SetPoint("RIGHT", clearAllBtn, "LEFT", -8, 0)
    sortNameBtn:SetText("Name " .. SORT_ASC)

    local sortLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    sortLabel:SetPoint("RIGHT", sortNameBtn, "LEFT", -6, 0)
    sortLabel:SetText("Sort:")

    -- Search line: Search input on the left, the "Show:" rarity filter on
    -- the right (both narrow what's visible, so they group together). The
    -- dropdown's Initialize + selection handler are wired in CreateListUI
    -- (they need the Refresh closure + the filter state).
    local rarityDD = CreateFrame("Frame", "EbonClearanceRarityDD_" .. setTableName, box, "UIDropDownMenuTemplate")
    rarityDD:SetPoint("TOPRIGHT", box, "TOPRIGHT", 12, -78)
    UIDropDownMenu_SetWidth(rarityDD, 84)

    local rarityLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    rarityLabel:SetPoint("RIGHT", rarityDD, "LEFT", 14, 2)
    rarityLabel:SetText("Show:")

    local searchLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", 0, -84)
    searchLabel:SetText("Search:")

    local search = CreateFrame("EditBox", "EbonClearanceSearchInput_" .. setTableName, box, "InputBoxTemplate")
    search:SetAutoFocus(false)
    search:SetHeight(20)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetPoint("RIGHT", rarityLabel, "LEFT", -8, 0)
    search:SetMaxLetters(40)
    search:SetText("")
    NS.StyleInputBox(search)

    EC_AddControlTip(clearAllBtn, "Remove every item from this list.")
    EC_AddControlTip(sortNameBtn, "Sort the list by item name. Click again to reverse.")
    EC_AddControlTip(search, "Show only rows whose name contains this text.")

    return search, sortNameBtn, clearAllBtn, rarityDD
end

-- v2.18.0: CreateListUI scroll-area extraction. Builds the scroll frame +
-- ScrollChild content + the auto-hide scrollbar hook + the OnSizeChanged
-- reactive-width hook that keeps the ScrollChild's width in step with the
-- box on Interface Options frame resize. Returns (scroll, content). Hung
-- off EC_compCache rather than as a file-scope local to stay under Lua
-- 5.1's 200-locals-per-main-chunk cap (CLAUDE.md discipline). Part of the
-- CODE_REVIEW.md item 2 split of CreateListUI.
function EC_compCache.buildListScrollArea(box, w, setTableName)
    -- v2.32.x: backdrop chrome wrapper around the scroll area, matching
    -- the Import/Export panel's text-box look. The wrapper inherits the
    -- old scroll's external footprint, the scroll re-anchors 6 px inside
    -- it on three sides and 28 px on the right (6 px chrome margin +
    -- 22 px scrollbar gutter). Numbers borrowed from the I/E pattern in
    -- EbonClearance_ProfilesPanel.lua so all five "scrollable list"
    -- surfaces (Sell / Account Sell / Keep / Delete / Profiles) read
    -- with the same visual containment.
    local scrollBg = CreateFrame("Frame", nil, box)
    -- v2.41.0: -108 to clear the grouped header (Add to list single-input
    -- row + divider + Find in list row + Search/rarity row).
    scrollBg:SetPoint("TOPLEFT", 0, -108)
    scrollBg:SetPoint("BOTTOMRIGHT", 0, 8)
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

    local scroll =
        CreateFrame("ScrollFrame", "EbonClearanceListScroll_" .. setTableName, scrollBg, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -28, 6)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(w - 34, 1)
    scroll:SetScrollChild(content)
    -- Auto-hide the scroll bar (arrows + thumb) when content fits the visible
    -- area. Wired once here; OnScrollRangeChanged fires on every Refresh that
    -- changes content height, so visibility tracks the list automatically.
    NS.HookScrollbarAutoHide(scroll)

    -- v2.11.0: when the panel resizes the box stretches via its
    -- BOTTOMRIGHT anchor (set externally), scrollBg stretches with the
    -- box, scroll stretches with scrollBg, but content (a ScrollChild)
    -- needs explicit SetWidth - ScrollChild doesn't auto-track parent.
    -- Hook OnSizeChanged on box to keep content width in step. Rows
    -- inside the content already track via TOPLEFT/TOPRIGHT anchors so
    -- they stretch with content automatically. The -34 accounts for
    -- 6 px chrome inset on left + 22 px scrollbar gutter + 6 px right
    -- chrome margin.
    box:SetScript("OnSizeChanged", function(self, width)
        if not width or width <= 0 then
            return
        end
        if content and content.SetWidth then
            content:SetWidth(width - 34)
        end
    end)

    return scroll, content
end

local function CreateListUI(parent, titleText, setTableName, x, y)
    local ADB = NS.ADB
    local w = NS.GetPanelWidth() - x
    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", x, y)
    -- Height chosen to keep the whole box inside a standard InterfaceOptions
    -- sub-panel. Callers may override via listUI:SetHeight(n) if they need more
    -- or less room (e.g. WhitelistPanel has extra controls above it).
    box:SetSize(w, 280)

    -- v2.41.0: "Add to list" group (one merged ID/name input + Add).
    local input, addBtn = EC_compCache.buildListHeaderRow(box, setTableName)

    -- v2.41.0: default to alphabetical (Name) order - the item ID is no
    -- longer shown, so an ID order the user can't read is no use.
    local sortMode = "name_asc"
    -- nil = show all rarities; otherwise a quality number (set by the
    -- "Show:" rarity dropdown wired below).
    local rarityFilter = nil

    -- "Find in list" group: divider + Sort button + Clear All (returned
    -- here now) + the Search input and rarity dropdown on the line below.
    local search, sortNameBtn, clearAllBtn, rarityDD = EC_compCache.buildListSearchAndSortRow(box, setTableName)

    local scroll, content = EC_compCache.buildListScrollArea(box, w, setTableName)

    local rowFactory = EC_compCache.makeListRowFactory(content, setTableName)

    local function MatchesSearch(id, name, searchText)
        if not searchText or searchText == "" then
            return true
        end
        local idStr = tostring(id or "")
        if idStr:find(searchText, 1, true) then
            return true
        end
        local nameStr = tostring(name or ""):lower()
        if nameStr:find(searchText, 1, true) then
            return true
        end
        return false
    end

    local pendingRetry = false

    local function Refresh()
        rowFactory.hideAllRows()

        local searchText = ""
        if search and search.GetText then
            searchText = (search:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        end

        local setTable = NS.GetListTable(setTableName)
        if type(setTable) ~= "table" then
            return
        end
        local keys = {}
        for k in pairs(setTable) do
            if type(k) == "number" then
                keys[#keys + 1] = k
            end
        end
        -- v2.41.0: ID sort was removed (the row no longer shows the ID), so
        -- the list is always name-sorted. v2.28.0 perf note still applies:
        -- the comparator previously called GetItemInfo per pair-compare
        -- (~20k lookups for a 1000-item sort). Build a one-pass {id ->
        -- lowercase name} map first; the comparator is then an O(1) read.
        local nameByID = {}
        for i = 1, #keys do
            nameByID[keys[i]] = (GetItemInfo(keys[i]) or ""):lower()
        end
        if sortMode == "name_desc" then
            table.sort(keys, function(a, b)
                return nameByID[a] > nameByID[b]
            end)
        else
            table.sort(keys, function(a, b)
                return nameByID[a] < nameByID[b]
            end)
        end

        -- v2.28.0: hoist the affix-set reference once per Refresh
        -- instead of dereferencing ADB.affixedListedItems three times
        -- per visible row.
        local affixSet = (ADB and ADB.affixedListedItems) or nil
        -- v2.37.0: parallel set for the "(Hit-proc)" annotation.
        -- Stamped by the menu's add-to-list flow + the tooltip
        -- backfill, then read once here per Refresh.
        local procSet = (ADB and ADB.chanceOnHitListedItems) or nil

        -- Tooltip-prime helper. SetHyperlink for an uncached item
        -- queues an async server request; the response populates the
        -- item cache and the existing pendingRetry chain re-paints
        -- once names are available. SetOwner is called once outside
        -- the loop body since the same owner serves every prime.
        local primeFrame = GameTooltip
        local canPrime = primeFrame and primeFrame.SetHyperlink
        if canPrime then
            primeFrame:SetOwner(UIParent, "ANCHOR_NONE")
        end

        local shown = 0
        local rowY = -4
        local hasUncached = false
        for i = 1, #keys do
            local id = keys[i]
            -- v2.41.0: capture quality (3rd) + icon texture (10th) from the
            -- same lookup the name already costs - no extra GetItemInfo call.
            local name, _, quality, _, _, _, _, _, _, itemTexture = GetItemInfo(id)
            if not name then
                hasUncached = true
                if canPrime then
                    primeFrame:SetHyperlink("item:" .. id .. ":0:0:0:0:0:0:0")
                end
                name = "ItemID: " .. id
            end

            -- v2.41.0: rarity filter stacks with the search filter. An
            -- uncached item has unknown quality, so under a specific rarity
            -- it stays hidden until it caches (the prime above requeues a
            -- Refresh), then appears if it matches.
            local passesRarity = (rarityFilter == nil) or (quality == rarityFilter)
            if passesRarity and MatchesSearch(id, name, searchText) then
                shown = shown + 1
                local row = rowFactory.getRow(shown)
                row:ClearAllPoints()
                -- v2.11.0: anchor both TOPLEFT and TOPRIGHT so the row
                -- stretches with the (resizable) content frame.
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, rowY)
                row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, rowY)
                -- v2.27.0: append "(affix-gated)" tag when the entry
                -- was added because the item carries a random affix.
                -- v2.37.0: append "(Hit-proc)" tag when the entry's
                -- base itemID carries a chance-on-hit proc. Same
                -- per-drop semantics as affix-gated: the chance-on-hit
                -- protection still filters per-drop even though the
                -- itemID is on a list. Both tags can render on the
                -- same row when an item has both signals.
                local affixTag = (affixSet and affixSet[id]) and " |cffaaaaaa(affix-gated)|r" or ""
                local procTag = (procSet and procSet[id]) and " |cffaaaaaa(Hit-proc)|r" or ""
                -- v2.41.0: icon replaces the old green itemID prefix; the
                -- name is quality-colored. itemID powers the row hover
                -- tooltip wired in the row factory. Uncached items show the
                -- question-mark icon (quality nil -> white name) until the
                -- pendingRetry pass below repaints with real data.
                row.icon:SetTexture(itemTexture or "Interface\\Icons\\INV_Misc_QuestionMark")
                row.itemID = id
                row.text:SetText(string.format("%s%s%s", NS.ColorTextByQuality(quality, name), affixTag, procTag))
                row.rm:SetScript("OnClick", function()
                    local t = NS.GetListTable(setTableName)
                    if t then
                        t[id] = nil
                    end
                    Refresh()
                end)
                row:Show()
                row.rm:Show()
                rowY = rowY - 22
            end
        end

        -- One Hide() after the prime loop instead of one per uncached
        -- item. SetOwner(ANCHOR_NONE) keeps the tooltip offscreen
        -- while we prime, then we hide it once at the end.
        if canPrime then
            primeFrame:Hide()
        end

        rowFactory.setActiveRows(shown)
        content:SetHeight(math.max(1, (shown * 22) + 8))
        -- Scroll-bar visibility auto-updates via the OnScrollRangeChanged hook
        -- wired in EC_HookScrollbarAutoHide(scroll) below; SetHeight here
        -- triggers that hook, no manual call needed.

        -- If any items were uncached, retry after a delay to pick up server responses
        if hasUncached and not pendingRetry then
            pendingRetry = true
            NS.Delay(1.5, function()
                pendingRetry = false
                Refresh()
            end)
        end
    end

    -- v2.41.0: the Add button + input OnEnterPressed are wired below, after
    -- AddMatchingFromBags (the merged add handler DoAdd uses it).

    clearAllBtn:SetScript("OnClick", function()
        local t = NS.GetListTable(setTableName)
        if not t or not next(t) then
            NS.PrintNicef("|cff888888%s is already empty.|r", titleText)
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        local dialog = StaticPopup_Show("EC_CONFIRM_CLEAR_LIST", titleText)
        if dialog then
            dialog.data = function()
                EC_ClearListWithPrune(NS.GetListTable(setTableName))
                Refresh()
                NS.PrintNicef('Cleared every item from "|cffffff00%s|r".', titleText)
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    local function AddMatchingFromBags(substr)
        local t = NS.GetListTable(setTableName)
        if not t or not substr or substr == "" then
            return 0, 0
        end
        local needle = substr:lower()
        local added, skipped = 0, 0
        -- v2.13.4: route adds through EC_AddItemToList(quiet=true) so
        -- this bulk path picks up the canonical conflict guard, dedupe,
        -- and any future origin-tag support. The pre-check on `t[itemID]`
        -- preserves the existing semantic where already-present items
        -- silently do not increment either counter; only cross-list
        -- conflicts count as skipped.
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID and not t[itemID] then
                    local name = GetItemInfo(itemID)
                    if name and name:lower():find(needle, 1, true) then
                        if NS.AddItemToList(setTableName, itemID, titleText, true) then
                            added = added + 1
                        else
                            skipped = skipped + 1
                        end
                    end
                end
            end
        end
        return added, skipped
    end

    -- v2.41.0: one merged "Add" handler. A numeric entry is added as an
    -- item ID directly (works for items you don't own; shift-click / drag
    -- also fill in the ID). Text is resolved two ways - an exact match from
    -- the client item cache, plus every bag item whose name contains the
    -- text. 3.3.5a has no full item-database name search, so a name the
    -- client has never cached can't be found; the empty result says so.
    local function DoAdd()
        local raw = (input:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if raw == "" then
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        local id = tonumber(raw)
        if id and id > 0 and math.floor(id) == id then
            -- v2.13.4: route through NS.AddItemToList for canonical add
            -- semantics (cross-list conflict guard, dedupe, panel refresh).
            -- It prints its own success / conflict chat lines.
            NS.AddItemToList(setTableName, id, titleText)
            input:SetText("")
            PlaySound("igMainMenuOptionCheckBoxOn")
            return
        end
        -- Name path: exact cached-name hit + bag substring scan.
        local added, skipped = 0, 0
        local _, link = GetItemInfo(raw)
        if link then
            local exactID = tonumber(link:match("item:(%d+)"))
            if exactID and NS.AddItemToList(setTableName, exactID, titleText, true) then
                added = added + 1
            end
        end
        local bagAdded, bagSkipped = AddMatchingFromBags(raw)
        added = added + bagAdded
        skipped = skipped + bagSkipped
        if added > 0 then
            NS.PrintNicef("Added |cffffff00%d|r item(s) matching |cffffff00%s|r.", added, raw)
        else
            NS.PrintNicef(
                "|cff888888No item found for |r|cffffff00%s|r|cff888888 in your bags or item cache. "
                    .. "Tip: you can paste an item ID.|r",
                raw
            )
        end
        if skipped > 0 then
            NS.PrintNicef("Skipped |cffffff00%d|r already on another list.", skipped)
        end
        input:SetText("")
        Refresh()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
    addBtn:SetScript("OnClick", DoAdd)
    input:SetScript("OnEnterPressed", function()
        DoAdd()
        input:ClearFocus()
    end)

    -- v2.28.0: debounce search refreshes. Each keystroke previously
    -- fired a full O(N) Refresh which on a 1000-item list walked the
    -- table, called GetItemInfo per entry, and rebuilt the visible
    -- rows. Typing "bloodpike" = 9 of those passes. Coalesce via a
    -- per-CreateListUI OnUpdate frame; first keystroke arms a 250 ms
    -- countdown, subsequent keystrokes reset it, idle window fires
    -- one Refresh.
    local searchDebounce = CreateFrame("Frame")
    searchDebounce:Hide()
    searchDebounce.elapsed = 0
    searchDebounce:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed >= 0.25 then
            self:Hide()
            Refresh()
        end
    end)
    search:SetScript("OnTextChanged", function()
        searchDebounce.elapsed = 0
        searchDebounce:Show()
    end)

    sortNameBtn:SetScript("OnClick", function()
        if sortMode == "name_asc" then
            sortMode = "name_desc"
        else
            sortMode = "name_asc"
        end
        sortNameBtn:SetText(sortMode == "name_asc" and ("Name " .. SORT_ASC) or ("Name " .. SORT_DESC))
        Refresh()
    end)

    -- v2.41.0: wire the "Show:" rarity dropdown. Selecting a rarity sets
    -- rarityFilter and repaints; "All" clears it. Menu + selection text are
    -- quality-colored via NS.ColorTextByQuality.
    local function setRarity(q)
        rarityFilter = q
        local opt
        for i = 1, #EC_RARITY_FILTERS do
            if EC_RARITY_FILTERS[i].q == q then
                opt = EC_RARITY_FILTERS[i]
                break
            end
        end
        UIDropDownMenu_SetText(rarityDD, NS.ColorTextByQuality(q, (opt and opt.name) or "All"))
        CloseDropDownMenus()
        Refresh()
    end
    UIDropDownMenu_Initialize(rarityDD, function()
        for i = 1, #EC_RARITY_FILTERS do
            local entry = EC_RARITY_FILTERS[i]
            local info = UIDropDownMenu_CreateInfo()
            info.text = NS.ColorTextByQuality(entry.q, entry.name)
            info.value = entry.q
            info.func = function()
                setRarity(entry.q)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetText(rarityDD, NS.ColorTextByQuality(nil, "All"))

    box.Refresh = Refresh
    return box
end
NS.CreateListUI = CreateListUI

-- Shared "Add from bags" scan row used by both whitelist panels.
-- setTableName resolves to the underlying list via NS.GetListTable, so the same
-- helper drives the per-character whitelist and the account whitelist.
-- Build the "Add from bags: [White] [Green] [Blue]" scan row. Returns a
-- container Frame whose BOTTOMLEFT is the natural anchor for the next
-- downstream widget (typically the list UI). Callers pass an anchorFrame
-- (usually the panel description) so the row cascades when the description
-- wraps to more lines on narrow Interface Options containers, instead of
-- using a brittle hardcoded y-offset.
local function EC_AddScanByQualityRow(parent, anchorFrame, setTableName, listLabel, refreshFn, xOff, yOff)
    local function ScanBagsForQuality(quality)
        local t = NS.GetListTable(setTableName)
        if not t then
            return 0, 0
        end
        local added, skipped = 0, 0
        -- v2.13.4: route adds through EC_AddItemToList(quiet=true) so
        -- this bulk path picks up the canonical conflict guard, dedupe,
        -- and any future origin-tag support. The pre-check on `t[itemID]`
        -- preserves the existing semantic where already-present items
        -- silently do not increment either counter; only cross-list
        -- conflicts count as skipped.
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID then
                    local _, _, q, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
                    if q == quality and sellPrice and sellPrice > 0 and not t[itemID] then
                        if NS.AddItemToList(setTableName, itemID, listLabel, true) then
                            added = added + 1
                        else
                            skipped = skipped + 1
                        end
                    end
                end
            end
        end
        return added, skipped
    end

    -- Wrap the row in a container Frame so callers can anchor the next widget
    -- to rowFrame:BOTTOMLEFT cleanly without having to know about button
    -- heights vs the (shorter) text label.
    local rowFrame = CreateFrame("Frame", nil, parent)
    rowFrame:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", xOff or 0, yOff or -10)
    rowFrame:SetSize(NS.GetPanelWidth(), 22)

    local scanLabel = rowFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    scanLabel:SetPoint("LEFT", rowFrame, "LEFT", 0, 0)
    scanLabel:SetText("Add from bags:")

    local function MakeBtn(prevAnchor, leftPad, label, qualityNum, colorWord)
        local b = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
        b:SetSize(55, 20)
        b:SetPoint("LEFT", prevAnchor, "RIGHT", leftPad, 0)
        b:SetText(label)
        b:SetScript("OnClick", function()
            local added, skipped = ScanBagsForQuality(qualityNum)
            NS.PrintNicef("Scanned bags: added |cffffff00%d|r %s items to %s.", added, colorWord, listLabel)
            if skipped and skipped > 0 then
                NS.PrintNicef("Skipped |cffffff00%d|r already on another list.", skipped)
            end
            if refreshFn then
                refreshFn()
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        return b
    end

    local btnWhite = MakeBtn(scanLabel, 8, "|cffffffffWhite|r", 1, "white")
    local btnGreen = MakeBtn(btnWhite, 4, "|cff1eff00Green|r", 2, "green")
    MakeBtn(btnGreen, 4, "|cff0070ddBlue|r", 3, "blue")

    return rowFrame
end
NS.AddScanByQualityRow = EC_AddScanByQualityRow
