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
--   * EC_compCache.makeListRowFactory       (pooled row + Remove-button + label)
--   * EC_compCache.buildListHeaderRow       (title + ID input + Add + Clear All)
--   * EC_compCache.buildListSearchAndSortRow (search input + ID/Name sort buttons)
--   * EC_compCache.buildListMatchRow        ("Add matching in bags" input + button)
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

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 2, 0)
        text:SetPoint("RIGHT", rm, "LEFT", -8, 0)
        text:SetJustifyH("LEFT")

        row.rm = rm
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

-- v2.18.0: CreateListUI header-row extraction. Builds the title
-- FontString + ID-input EditBox + Add Button + Clear All Button.
-- Also wires the input's focus-tracking handlers (NS.activeIDBox is the
-- shift-click-to-add target) and the drag-to-receive handler that
-- populates the input with an itemID when a bag item is dropped onto
-- it - these are pure layout (don't depend on Refresh), so they live
-- here. Add and Clear All button OnClick handlers stay in CreateListUI
-- because they call Refresh. Returns (input, addBtn, clearAllBtn).
function EC_compCache.buildListHeaderRow(box, titleText, setTableName)
    local title = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(titleText)

    local input = CreateFrame("EditBox", "EbonClearanceIDInput_" .. setTableName, box, "InputBoxTemplate")
    input:SetAutoFocus(false)
    input:SetSize(140, 20)
    input:SetPoint("TOPLEFT", 0, -24)
    input:SetNumeric(true)
    input:SetMaxLetters(10)
    input:SetText("")
    NS.StyleInputBox(input)

    local addBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 20)
    addBtn:SetPoint("LEFT", input, "RIGHT", 8, 0)
    addBtn:SetText("Add")

    -- "Clear All" button on the input row, anchored hard-right and visually
    -- separated from the Add flow. Wipes every entry in the list with a
    -- confirmation popup. OnClick wired by caller (needs Refresh).
    local clearAllBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    clearAllBtn:SetSize(80, 20)
    clearAllBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -24)
    clearAllBtn:SetText("Clear All")

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

    return input, addBtn, clearAllBtn
end

-- v2.18.0: CreateListUI search-and-sort-row extraction. Builds the
-- "Search:" label + search input + sort-by-ID button + sort-by-Name button,
-- all on one line at y=-52 within the box. Pure layout - no OnClick
-- wiring; caller attaches handlers after Refresh exists. Returns
-- (search, sortIDBtn, sortNameBtn). The sort buttons use right-pointing
-- triangle glyphs ("\226\150\178") by default; the OnClick handlers in
-- CreateListUI swap to down-pointing ("\226\150\188") to indicate
-- descending order.
function EC_compCache.buildListSearchAndSortRow(box, setTableName)
    local searchLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", 0, -52)
    searchLabel:SetText("Search:")

    -- v2.32.x: sort buttons anchored 4 px higher than the label's
    -- TOPLEFT Y so their top edge lines up with the search input
    -- field's top edge. The search input centres on the LABEL's
    -- vertical centre (LEFT to label.RIGHT anchor), which sits ~4 px
    -- below the label's TOPLEFT Y because the small font height
    -- centres around that point. Without the -4 offset, buttons
    -- visibly sit lower than the input field next to them.
    local sortNameBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    sortNameBtn:SetSize(62, 20)
    sortNameBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -48)
    sortNameBtn:SetText("Name \226\150\178")

    local sortIDBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    sortIDBtn:SetSize(50, 20)
    sortIDBtn:SetPoint("RIGHT", sortNameBtn, "LEFT", -4, 0)
    sortIDBtn:SetText("ID \226\150\178")

    local search = CreateFrame("EditBox", "EbonClearanceSearchInput_" .. setTableName, box, "InputBoxTemplate")
    search:SetAutoFocus(false)
    search:SetHeight(20)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetPoint("RIGHT", sortIDBtn, "LEFT", -8, 0)
    search:SetMaxLetters(40)
    search:SetText("")
    NS.StyleInputBox(search)

    return search, sortIDBtn, sortNameBtn
end

-- v2.18.0: CreateListUI match-row extraction. Builds the
-- "Add matching in bags:" label + match-input EditBox + Add Match button
-- (anchored at y=-76 within the box, with the input filling the gap
-- between label and button). Pure layout - no OnClick wiring; caller
-- attaches handlers after Refresh exists. Returns (matchInput, matchBtn).
function EC_compCache.buildListMatchRow(box, setTableName)
    local matchLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    matchLabel:SetPoint("TOPLEFT", 0, -76)
    matchLabel:SetText("Add matching in bags:")

    -- v2.32.x: same +4 px lift as the sort buttons in the search row,
    -- for the same reason. The match input centres on matchLabel.RIGHT
    -- which sits below the label's TOPLEFT Y, so the button needs to
    -- shift up to align with the input's top edge.
    local matchBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    matchBtn:SetSize(80, 20)
    matchBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -72)
    matchBtn:SetText("Add Match")

    local matchInput = CreateFrame("EditBox", "EbonClearanceMatchInput_" .. setTableName, box, "InputBoxTemplate")
    matchInput:SetAutoFocus(false)
    matchInput:SetHeight(20)
    matchInput:SetPoint("LEFT", matchLabel, "RIGHT", 8, 0)
    matchInput:SetPoint("RIGHT", matchBtn, "LEFT", -8, 0)
    matchInput:SetMaxLetters(40)
    matchInput:SetText("")
    NS.StyleInputBox(matchInput)

    return matchInput, matchBtn
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
    scrollBg:SetPoint("TOPLEFT", 0, -102)
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

    local input, addBtn, clearAllBtn = EC_compCache.buildListHeaderRow(box, titleText, setTableName)

    local sortMode = "id_asc" -- default: sort by ID ascending

    -- Search row: Search box then ID, Name sort buttons all on one line
    local search, sortIDBtn, sortNameBtn = EC_compCache.buildListSearchAndSortRow(box, setTableName)

    -- Bag-scan "Add matching" row: scan bags for items whose name contains the
    -- typed substring and add each match to this list.
    local matchInput, matchBtn = EC_compCache.buildListMatchRow(box, setTableName)

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
        -- v2.28.0: name-sort comparator previously called GetItemInfo
        -- per pair-compare = ~20k lookups for a 1000-item sort. Build
        -- a one-pass {id -> lowercase name} map first; comparator
        -- becomes an O(1) table read.
        if sortMode == "id_desc" then
            table.sort(keys, function(a, b)
                return a > b
            end)
        elseif sortMode == "name_asc" or sortMode == "name_desc" then
            local nameByID = {}
            for i = 1, #keys do
                nameByID[keys[i]] = (GetItemInfo(keys[i]) or ""):lower()
            end
            if sortMode == "name_asc" then
                table.sort(keys, function(a, b)
                    return nameByID[a] < nameByID[b]
                end)
            else
                table.sort(keys, function(a, b)
                    return nameByID[a] > nameByID[b]
                end)
            end
        else
            table.sort(keys) -- id_asc (default)
        end

        -- v2.28.0: hoist the affix-set reference once per Refresh
        -- instead of dereferencing ADB.affixedListedItems three times
        -- per visible row.
        local affixSet = (ADB and ADB.affixedListedItems) or nil

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
            local name = GetItemInfo(id)
            if not name then
                hasUncached = true
                if canPrime then
                    primeFrame:SetHyperlink("item:" .. id .. ":0:0:0:0:0:0:0")
                end
                name = "ItemID: " .. id
            end

            if MatchesSearch(id, name, searchText) then
                shown = shown + 1
                local row = rowFactory.getRow(shown)
                row:ClearAllPoints()
                -- v2.11.0: anchor both TOPLEFT and TOPRIGHT so the row
                -- stretches with the (resizable) content frame.
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, rowY)
                row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, rowY)
                -- v2.27.0: append "(affix-gated)" tag when the entry
                -- was added because the item carries a random affix.
                local affixTag = (affixSet and affixSet[id]) and " |cffaaaaaa(affix-gated)|r" or ""
                row.text:SetText(string.format("|cffb6ffb6%d|r  %s%s", id, name, affixTag))
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

    addBtn:SetScript("OnClick", function()
        local v = tonumber(input:GetText() or "")
        if not v or v <= 0 then
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        -- v2.13.4: route through EC_AddItemToList for canonical add
        -- semantics (cross-list conflict guard, dedupe check, panel
        -- refresh, future origin-tag support). The previous inline
        -- code reimplemented the conflict guard + write, bypassing
        -- the canonical path and missing any future improvements to
        -- it. EC_AddItemToList prints its own conflict / dedupe /
        -- success chat lines using item names rather than raw IDs,
        -- which is a slight upgrade over the previous "Item NNN is
        -- already on..." format.
        NS.AddItemToList(setTableName, v, titleText)
        input:SetText("")
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    input:SetScript("OnEnterPressed", function()
        addBtn:Click()
        input:ClearFocus()
    end)

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
                local target = NS.GetListTable(setTableName)
                if target then
                    wipe(target)
                end
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

    matchBtn:SetScript("OnClick", function()
        local txt = (matchInput:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if txt == "" then
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        local added, skipped = AddMatchingFromBags(txt)
        NS.PrintNicef("Scanned bags: added |cffffff00%d|r matching item(s) (substring: |cffffff00%s|r).", added, txt)
        if skipped and skipped > 0 then
            NS.PrintNicef("Skipped |cffffff00%d|r already on another list.", skipped)
        end
        matchInput:SetText("")
        Refresh()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    matchInput:SetScript("OnEnterPressed", function()
        matchBtn:Click()
        matchInput:ClearFocus()
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

    sortIDBtn:SetScript("OnClick", function()
        if sortMode == "id_asc" then
            sortMode = "id_desc"
        else
            sortMode = "id_asc"
        end
        sortIDBtn:SetText(sortMode == "id_asc" and "ID \226\150\178" or "ID \226\150\188")
        sortNameBtn:SetText("Name \226\150\178")
        Refresh()
    end)
    sortNameBtn:SetScript("OnClick", function()
        if sortMode == "name_asc" then
            sortMode = "name_desc"
        else
            sortMode = "name_asc"
        end
        sortNameBtn:SetText(sortMode == "name_asc" and "Name \226\150\178" or "Name \226\150\188")
        sortIDBtn:SetText("ID \226\150\178")
        Refresh()
    end)

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
