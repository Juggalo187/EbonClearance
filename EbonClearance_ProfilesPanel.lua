-- EbonClearance_ProfilesPanel - Profiles + Import/Export Interface Options panels.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-viii of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- Two related panels bundled into one file:
--   * ProfilesPanel       - named-profile management (save / load /
--                           rename / delete)
--   * ImportExportPanel   - profile pack + settings pack export and
--                           import; also hosts the file-scope helpers
--                           EC_GetWhitelistForScope / EC_ExportWhitelist
--                           / EC_ImportWhitelist + EC_EXPORT_PREFIX
--                           constant (all used only by this panel)
--   * EC_compCache.exportFullPack / importFullPack (full settings
--     pack serialiser + deserialiser; previously inline in this
--     region, now moves with it)
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth
--   * NS.DB / NS.ADB captured at each OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.StyleInputBox (8e-ii)
--   * NS.HookScrollbarAutoHide (8e-viii prep) - scrollbar auto-hide
--     hook used by the profile list and the import textarea
--   * NS.SaveProfile / NS.LoadProfile / NS.DeleteProfile /
--     NS.RenameProfile (8e-viii prep) - profile-mutation helpers
--     whose bodies stay in EbonClearance.lua (slash commands also
--     resolve them through the same NS entries)
--   * NS.CountItems (Stage 8 prep) - item-count utility

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- ============================================================
local ProfilesPanel = CreateFrame("Frame", "EbonClearanceOptionsProfiles", InterfaceOptionsFramePanelContainer)
ProfilesPanel.name = "Profiles"
ProfilesPanel.parent = "EbonClearance"

ProfilesPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.RefreshProfileList then
            self:RefreshProfileList()
        end
    end, function(self)
        NS.MakeHeader(self, "Profiles", -16)
        local descLabel = NS.MakeLabel(
            self,
            "Profiles save and restore your |cffb6ffb6Sell List|r and |cffb6ffb6Keep List|r as a named pair. Switching profiles overwrites the live character lists with the saved snapshot. Handy for swapping between farming spots.",
            16,
            -44
        )
        -- Cascade-anchored to descLabel so the layout adapts to whatever number of
        -- lines the description wraps to (fixed-y caused overlap on narrower panels).
        local clarifyLabel = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        clarifyLabel:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -8)
        EC_compCache.setPanelWidth(clarifyLabel, 32)
        clarifyLabel:SetJustifyH("LEFT")
        clarifyLabel:SetJustifyV("TOP")
        if clarifyLabel.SetWordWrap then
            clarifyLabel:SetWordWrap(true)
        end
        clarifyLabel:SetText(
            "|cffaaaaaaProfiles do NOT touch the |cffb6ffb6Account Sell List|r|cffaaaaaa (which is shared across every alt and never replaced). The |cffb6ffb6Default|r|cffaaaaaa profile is permanently empty - give your profile a real name before saving.|r"
        )

        -- Active profile indicator
        local activeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        activeLabel:SetPoint("TOPLEFT", clarifyLabel, "BOTTOMLEFT", 0, -16)
        EC_compCache.setPanelWidth(activeLabel, 16)
        activeLabel:SetJustifyH("LEFT")
        self.activeLabel = activeLabel

        -- Save row: input + Save button (relative to activeLabel so it follows
        -- whatever the wrap above ends up at).
        local saveLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        saveLabel:SetPoint("TOPLEFT", activeLabel, "BOTTOMLEFT", 0, -10)
        saveLabel:SetText("Profile name:")

        local saveInput = CreateFrame("EditBox", "EbonClearanceProfileSaveInput", self, "InputBoxTemplate")
        saveInput:SetAutoFocus(false)
        saveInput:SetSize(180, 20)
        saveInput:SetPoint("LEFT", saveLabel, "RIGHT", 8, 0)
        saveInput:SetMaxLetters(30)
        saveInput:SetText(DB.activeProfileName or "Default")
        NS.StyleInputBox(saveInput)

        local saveBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        saveBtn:SetSize(80, 22)
        saveBtn:SetPoint("LEFT", saveInput, "RIGHT", 8, 0)
        saveBtn:SetText("Save")

        -- Status text (relative to the save row above it).
        local statusFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        statusFS:SetPoint("TOPLEFT", saveLabel, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(statusFS, 16)
        statusFS:SetJustifyH("LEFT")
        statusFS:SetText("")
        self.statusFS = statusFS

        -- Profile list scroll area
        local listLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        listLabel:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -8)
        listLabel:SetText("Saved Profiles")

        -- v2.32.x: backdrop chrome wrapper around the profile scroll list,
        -- matching the Import/Export panel pattern and the list-widget
        -- treatment in EbonClearance_ListWidget.lua. Same dark tooltip-
        -- style frame so the Saved Profiles list reads as a contained
        -- "where you look" surface instead of a transparent void.
        local scrollBg = CreateFrame("Frame", nil, self)
        scrollBg:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -4)
        scrollBg:SetSize(NS.GetPanelWidth() - 42, 160)
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
        EC_compCache.registerWidth(scrollBg, 42)

        local scroll = CreateFrame("ScrollFrame", "EbonClearanceProfileListScroll", scrollBg, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -28, 6)

        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(NS.GetPanelWidth() - 76, 1)
        EC_compCache.registerWidth(content, 76)
        scroll:SetScrollChild(content)
        -- Auto-hide the scroll bar (arrows + thumb) when content fits the visible
        -- area. Wired once here; OnScrollRangeChanged fires on every Refresh that
        -- changes content height, so visibility tracks the list automatically.
        NS.HookScrollbarAutoHide(scroll)

        local rowPool = {}
        local activeRows = 0

        local function GetRow(index)
            if rowPool[index] then
                return rowPool[index]
            end
            local row = CreateFrame("Frame", nil, content)
            row:SetHeight(22)

            local delBtn = CreateFrame("Button", "EbonClearanceProfileDel_" .. index, content, "UIPanelButtonTemplate")
            delBtn:SetSize(58, 18)
            delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            delBtn:SetText("Delete")

            local clearBtn =
                CreateFrame("Button", "EbonClearanceProfileClear_" .. index, content, "UIPanelButtonTemplate")
            clearBtn:SetSize(52, 18)
            clearBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
            clearBtn:SetText("Clear")

            local loadBtn =
                CreateFrame("Button", "EbonClearanceProfileLoad_" .. index, content, "UIPanelButtonTemplate")
            loadBtn:SetSize(52, 18)
            loadBtn:SetPoint("RIGHT", clearBtn, "LEFT", -4, 0)
            loadBtn:SetText("Load")

            local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            text:SetPoint("LEFT", row, "LEFT", 2, 0)
            text:SetPoint("RIGHT", loadBtn, "LEFT", -4, 0)
            text:SetJustifyH("LEFT")

            row.text = text
            row.loadBtn = loadBtn
            row.clearBtn = clearBtn
            row.delBtn = delBtn
            rowPool[index] = row
            return row
        end

        local function HideAllRows()
            for i = 1, activeRows do
                if rowPool[i] then
                    rowPool[i]:Hide()
                    rowPool[i].loadBtn:Hide()
                    rowPool[i].clearBtn:Hide()
                    rowPool[i].delBtn:Hide()
                end
            end
            activeRows = 0
        end

        -- Rename row
        local renameLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        renameLabel:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -12)
        renameLabel:SetText("Rename active profile:")

        local renameInput = CreateFrame("EditBox", "EbonClearanceProfileRenameInput", self, "InputBoxTemplate")
        renameInput:SetAutoFocus(false)
        renameInput:SetSize(150, 20)
        renameInput:SetPoint("LEFT", renameLabel, "RIGHT", 8, 0)
        renameInput:SetMaxLetters(30)
        renameInput:SetText("")
        NS.StyleInputBox(renameInput)

        local renameBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        renameBtn:SetSize(70, 22)
        renameBtn:SetPoint("LEFT", renameInput, "RIGHT", 8, 0)
        renameBtn:SetText("Rename")

        -- Use field-assignment form rather than colon-method definition so the
        -- function closes over the outer `self` (the panel) rather than receiving
        -- a fresh `self` parameter that would shadow it. Body still references
        -- self.activeLabel etc via that captured upvalue.
        self.RefreshProfileList = function()
            HideAllRows()

            -- Update active indicator
            local activeName = DB.activeProfileName or "Default"
            activeLabel:SetText("Active profile: |cff00ff00" .. activeName .. "|r")
            saveInput:SetText(activeName)
            renameInput:SetText(activeName)

            -- Collect and sort profile names
            local names = {}
            for name in pairs(DB.whitelistProfiles) do
                if type(name) == "string" then
                    names[#names + 1] = name
                end
            end
            table.sort(names, function(a, b)
                return a:lower() < b:lower()
            end)

            local shown = 0
            local rowY = -4
            for i = 1, #names do
                local pName = names[i]
                shown = shown + 1
                local row = GetRow(shown)
                row:ClearAllPoints()
                -- v2.11.0: anchor TOPLEFT + TOPRIGHT so the row stretches.
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, rowY)
                row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, rowY)

                local isActive = (pName == DB.activeProfileName)
                local wlCount = NS.CountItems(DB.whitelistProfiles[pName])
                local blCount = DB.blacklistProfiles[pName] and NS.CountItems(DB.blacklistProfiles[pName]) or 0
                -- Use compact "wl/bl" labels: row text shares horizontal space
                -- with up to three buttons (Load/Clear/Delete), so longer phrasing
                -- gets truncated at narrow Interface Options widths.
                local label = isActive
                        and string.format("|cff00ff00%s|r  |cff888888(%d wl, %d bl, active)|r", pName, wlCount, blCount)
                    or string.format("|cffffff00%s|r  |cff888888(%d wl, %d bl)|r", pName, wlCount, blCount)
                row.text:SetText(label)

                row.loadBtn:SetScript("OnClick", function()
                    local ok, msg = NS.LoadProfile(pName)
                    statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
                    if ok then
                        NS.PrintNice(msg)
                        PlaySound("igMainMenuOptionCheckBoxOn")
                    end
                    self:RefreshProfileList()
                end)

                row.delBtn:SetScript("OnClick", function()
                    local dialog = StaticPopup_Show("EC_CONFIRM_DELETE_PROFILE", pName)
                    if dialog then
                        dialog.data = function()
                            local ok, msg = NS.DeleteProfile(pName)
                            statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
                            if ok then
                                NS.PrintNice(msg)
                                PlaySound("igMainMenuOptionCheckBoxOn")
                            end
                            self:RefreshProfileList()
                        end
                    end
                end)

                row.clearBtn:SetScript("OnClick", function()
                    local dialog = StaticPopup_Show("EC_CONFIRM_CLEAR_PROFILE", pName)
                    if dialog then
                        dialog.data = function()
                            if DB.whitelistProfiles[pName] then
                                wipe(DB.whitelistProfiles[pName])
                                if pName == DB.activeProfileName then
                                    wipe(DB.whitelist)
                                    local wp = _G["EbonClearanceOptionsWhitelist"]
                                    if wp and wp.listUI then
                                        wp.listUI:Refresh()
                                    end
                                end
                                statusFS:SetText('|cff00ff00Cleared profile "|cffffff00' .. pName .. '|r|cff00ff00".|r')
                                NS.PrintNicef('Cleared profile "|cffffff00%s|r".', pName)
                                PlaySound("igMainMenuOptionCheckBoxOn")
                            end
                            self:RefreshProfileList()
                        end
                    end
                end)

                local isDefault = (pName == "Default")
                row:Show()
                row.loadBtn:Show()
                if isDefault then
                    row.clearBtn:Hide()
                    row.delBtn:Hide()
                else
                    row.clearBtn:Show()
                    row.delBtn:Show()
                end
                rowY = rowY - 22
            end

            activeRows = shown
            content:SetHeight(math.max(1, (shown * 22) + 8))
            -- Scroll-bar visibility handled by the OnScrollRangeChanged hook.
        end

        saveBtn:SetScript("OnClick", function()
            local name = saveInput:GetText()
            local ok, msg = NS.SaveProfile(name)
            statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
            if ok then
                NS.PrintNice(msg)
                PlaySound("igMainMenuOptionCheckBoxOn")
                self:RefreshProfileList()
            else
                PlaySound("igMainMenuOptionCheckBoxOff")
            end
        end)

        saveInput:SetScript("OnEnterPressed", function()
            saveBtn:Click()
            saveInput:ClearFocus()
        end)

        renameBtn:SetScript("OnClick", function()
            local newName = renameInput:GetText()
            local ok, msg = NS.RenameProfile(DB.activeProfileName, newName)
            statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
            if ok then
                NS.PrintNice(msg)
                PlaySound("igMainMenuOptionCheckBoxOn")
                self:RefreshProfileList()
            else
                PlaySound("igMainMenuOptionCheckBoxOff")
            end
        end)

        renameInput:SetScript("OnEnterPressed", function()
            renameBtn:Click()
            renameInput:ClearFocus()
        end)

        self:RefreshProfileList()
    end)
end)

-- ============================================================
-- Whitelist Import / Export Panel
-- ============================================================
local ImportExportPanel = CreateFrame("Frame", "EbonClearanceOptionsImportExport", InterfaceOptionsFramePanelContainer)
ImportExportPanel.name = "Import/Export"
ImportExportPanel.parent = "EbonClearance"

local EC_EXPORT_PREFIX = "EC:"

-- Resolve the export/import target table. scope is "character" (default) or
-- "account"; the latter touches the account-wide whitelist (ADB).
local function EC_GetWhitelistForScope(scope)
    local DB = NS.DB
    local ADB = NS.ADB
    if scope == "account" then
        return ADB and ADB.whitelist
    end
    return DB and DB.whitelist
end

local function EC_ExportWhitelist(listName, scope)
    local source = EC_GetWhitelistForScope(scope)
    if not source then
        return ""
    end
    local ids = {}
    for k, v in pairs(source) do
        if type(k) == "number" and (v == true or v == 1) then
            ids[#ids + 1] = k
        end
    end
    table.sort(ids)
    local name = (listName and listName ~= "") and listName or "Unnamed"
    name = name:gsub("[:|]", "_")
    local payload = EC_EXPORT_PREFIX .. name .. ":" .. table.concat(ids, ",")
    -- Fingerprint suffix flags this export as EbonClearance-produced.
    -- Helper lives in EbonClearance_Core.lua, exposed as NS.Fingerprint.
    return payload .. ";fp=" .. NS.Fingerprint(payload)
end

-- Full settings pack: serialises qualityRules + Sell / Keep / Delete lists +
-- account Sell List into one shareable string. Extends the existing single-
-- list export model so a user can paste a friend's complete config in one
-- go. Format kept human-readable (line per record, comma-separated IDs);
-- the prefix below is checked first so the importer can route the right
-- parser. Pack strings are fingerprinted using the same helper the
-- single-list export uses, so a recipient can verify provenance the same
-- way.
EC_compCache.PACK_PREFIX = "EC_PACK_V1"

function EC_compCache.exportFullPack()
    local DB = NS.DB
    local ADB = NS.ADB
    -- Inner locals don't count against the main-chunk locals cap, so keep
    -- the formatting helpers inside the function body.
    local function formatRule(q)
        local r = DB and DB.qualityRules and DB.qualityRules[q]
        if not r then
            return string.format("QR:%d:0:0:any:0", q)
        end
        local en = r.enabled and 1 or 0
        local ilvl = tonumber(r.maxILvl) or 0
        local bf = r.bindFilter or "any"
        if bf ~= "boe" and bf ~= "bop" then
            bf = "any"
        end
        local eq = r.useEquippedILvl and 1 or 0
        return string.format("QR:%d:%d:%d:%s:%d", q, en, ilvl, bf, eq)
    end

    local function formatIDs(prefix, t)
        local ids = {}
        if t then
            for k, v in pairs(t) do
                if type(k) == "number" and (v == true or v == 1) then
                    ids[#ids + 1] = k
                end
            end
        end
        table.sort(ids)
        return prefix .. ":" .. table.concat(ids, ",")
    end

    local lines = { EC_compCache.PACK_PREFIX }
    for q = 1, 4 do
        lines[#lines + 1] = formatRule(q)
    end
    lines[#lines + 1] = formatIDs("SL", DB and DB.whitelist)
    lines[#lines + 1] = formatIDs("SLA", ADB and ADB.whitelist)
    lines[#lines + 1] = formatIDs("KL", DB and DB.blacklist)
    lines[#lines + 1] = formatIDs("DL", DB and DB.deleteList)
    local payload = table.concat(lines, "\n")
    return payload .. "\n;fp=" .. NS.Fingerprint(payload)
end

function EC_compCache.importFullPack(str, mode)
    local DB = NS.DB
    local ADB = NS.ADB
    if type(str) ~= "string" or str == "" then
        return false, "Empty string."
    end
    -- Normalise line endings + strip trailing fingerprint and whitespace.
    str = (str:gsub("\r\n", "\n"))
    str = (str:gsub(";fp=[0-9a-f]+%s*$", ""))
    str = (str:gsub("%s+$", ""))

    local lines = {}
    for line in str:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    if #lines == 0 or lines[1]:sub(1, #EC_compCache.PACK_PREFIX) ~= EC_compCache.PACK_PREFIX then
        return false, "Not a full settings pack. Use the single-list importer below."
    end

    -- Parse-then-apply: build the full snapshot first so a single malformed
    -- line doesn't half-apply the import.
    local sell, sellAcct, keep, del = {}, {}, {}, {}
    local rules = {}

    for i = 2, #lines do
        local line = lines[i]
        if line:sub(1, 3) == "QR:" then
            local q, en, ilvl, bf, eq = line:match("^QR:(%d+):(%d+):(%d+):(%w+):(%d+)$")
            q = tonumber(q)
            if q and q >= 1 and q <= 4 then
                rules[q] = {
                    enabled = (en == "1"),
                    maxILvl = tonumber(ilvl) or 0,
                    bindFilter = (bf == "boe" or bf == "bop") and bf or "any",
                    useEquippedILvl = (eq == "1"),
                }
            end
        else
            local prefix, payload = line:match("^([A-Z]+):(.*)$")
            local target
            if prefix == "SL" then
                target = sell
            elseif prefix == "SLA" then
                target = sellAcct
            elseif prefix == "KL" then
                target = keep
            elseif prefix == "DL" then
                target = del
            end
            if target and payload and payload ~= "" then
                for token in payload:gmatch("[^,]+") do
                    local n = tonumber(token:match("^%s*(%d+)%s*$"))
                    if n and n > 0 then
                        target[n] = true
                    end
                end
            end
        end
    end

    local function applyList(dst, parsed)
        if not dst then
            return
        end
        if mode == "replace" then
            wipe(dst)
        end
        for id in pairs(parsed) do
            dst[id] = true
        end
    end

    local sellAdded, keepAdded, delAdded, acctAdded = 0, 0, 0, 0
    local function countNew(dst, parsed)
        if not dst then
            return 0
        end
        local n = 0
        for id in pairs(parsed) do
            if not dst[id] then
                n = n + 1
            end
        end
        return n
    end

    if DB then
        sellAdded = countNew(DB.whitelist, sell)
        keepAdded = countNew(DB.blacklist, keep)
        delAdded = countNew(DB.deleteList, del)
        applyList(DB.whitelist, sell)
        applyList(DB.blacklist, keep)
        applyList(DB.deleteList, del)
        DB.qualityRules = DB.qualityRules or {}
        for q = 1, 4 do
            if rules[q] then
                DB.qualityRules[q] = DB.qualityRules[q] or {}
                local t = DB.qualityRules[q]
                t.enabled = rules[q].enabled
                t.maxILvl = rules[q].maxILvl
                t.bindFilter = rules[q].bindFilter
                t.useEquippedILvl = rules[q].useEquippedILvl
            end
        end
    end
    if ADB and ADB.whitelist then
        acctAdded = countNew(ADB.whitelist, sellAcct)
        applyList(ADB.whitelist, sellAcct)
    end

    if NS.RefreshSellBorders then
        NS.RefreshSellBorders()
    end

    -- Refresh any open list panels so the new contents render immediately.
    for _, panelName in ipairs({
        "EbonClearanceOptionsWhitelist",
        "EbonClearanceOptionsAccountWhitelist",
        "EbonClearanceOptionsBlacklist",
        "EbonClearanceOptionsDeletion",
        "EbonClearanceOptionsMerchant",
    }) do
        local p = _G[panelName]
        if p and p.listUI then
            p.listUI:Refresh()
        end
    end

    local modeLabel = (mode == "replace") and "replaced" or "merged"
    return true,
        string.format(
            "Imported settings pack (%s). Quality rules updated; Sell +%d, Keep +%d, Delete +%d, Account Sell +%d.",
            modeLabel,
            sellAdded,
            keepAdded,
            delAdded,
            acctAdded
        )
end

local function EC_ImportWhitelist(str, mode, scope)
    local DB = NS.DB
    local ADB = NS.ADB
    if type(str) ~= "string" or str == "" then
        return false, "Empty string."
    end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    -- Strip a trailing ";fp=<hex>" fingerprint suffix before format
    -- validation so pre-fingerprint and hand-edited strings still parse.
    -- The fingerprint marks our exports going OUT; imports tolerate both
    -- fingerprinted and unfingerprinted strings without warning.
    str = (str:gsub(";fp=[0-9a-f]+%s*$", ""))
    if str:sub(1, #EC_EXPORT_PREFIX) ~= EC_EXPORT_PREFIX then
        return false, "Invalid format. String must start with EC:"
    end
    local body = str:sub(#EC_EXPORT_PREFIX + 1)
    local name, idStr = body:match("^([^:]*):(.+)$")
    if not idStr or idStr == "" then
        return false, "No item IDs found after the list name."
    end
    local ids = {}
    for token in idStr:gmatch("([^,]+)") do
        local n = tonumber(token:match("^%s*(%d+)%s*$"))
        if n and n > 0 then
            ids[#ids + 1] = n
        end
    end
    if #ids == 0 then
        return false, "No valid item IDs found."
    end
    local target = EC_GetWhitelistForScope(scope)
    if not target then
        return false, "Target list unavailable."
    end
    if mode == "replace" then
        wipe(target)
    end
    local added = 0
    for i = 1, #ids do
        if not target[ids[i]] then
            added = added + 1
        end
        target[ids[i]] = true
    end
    local scopeLabel = (scope == "account") and "account whitelist" or "character whitelist"
    return true,
        string.format(
            'Imported |cffffff00%d|r items from "%s" into the %s (%d new).',
            #ids,
            name or "Unnamed",
            scopeLabel,
            added
        )
end

ImportExportPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, nil, function(self)
        NS.MakeHeader(self, "Import / Export", -16)

        -- === EXPORT SECTION ===
        -- Each section owns its own scope radio so it's obvious which list a
        -- click reads from (Source list) versus writes to (Target list).
        NS.MakeLabel(
            self,
            "Export a whitelist to a string you can share. Pick which list to read from, then give the export a name.",
            16,
            -44
        )

        local exportScope = "character"

        local exportScopeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        exportScopeLabel:SetPoint("TOPLEFT", 16, -72)
        exportScopeLabel:SetText("Source list:")

        local exportCharCB =
            CreateFrame("CheckButton", "EbonClearanceExportSourceCharCB", self, "UIRadioButtonTemplate")
        exportCharCB:SetPoint("LEFT", exportScopeLabel, "RIGHT", 8, 0)
        exportCharCB:SetChecked(true)
        local exportCharLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        exportCharLbl:SetPoint("LEFT", exportCharCB, "RIGHT", 2, 1)
        exportCharLbl:SetText("Character")

        local exportAcctCB =
            CreateFrame("CheckButton", "EbonClearanceExportSourceAcctCB", self, "UIRadioButtonTemplate")
        exportAcctCB:SetPoint("LEFT", exportCharLbl, "RIGHT", 12, -1)
        exportAcctCB:SetChecked(false)
        local exportAcctLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        exportAcctLbl:SetPoint("LEFT", exportAcctCB, "RIGHT", 2, 1)
        exportAcctLbl:SetText("Account")

        exportCharCB:SetScript("OnClick", function()
            exportScope = "character"
            exportCharCB:SetChecked(true)
            exportAcctCB:SetChecked(false)
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        exportAcctCB:SetScript("OnClick", function()
            exportScope = "account"
            exportAcctCB:SetChecked(true)
            exportCharCB:SetChecked(false)
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)

        local exportNameLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        exportNameLabel:SetPoint("TOPLEFT", 16, -100)
        exportNameLabel:SetText("List name:")

        local exportNameBox = CreateFrame("EditBox", "EbonClearanceExportNameBox", self, "InputBoxTemplate")
        exportNameBox:SetAutoFocus(false)
        exportNameBox:SetSize(200, 20)
        exportNameBox:SetPoint("LEFT", exportNameLabel, "RIGHT", 8, 0)
        exportNameBox:SetMaxLetters(40)
        exportNameBox:SetText("My Sell List")
        NS.StyleInputBox(exportNameBox)

        local exportBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        exportBtn:SetSize(80, 22)
        exportBtn:SetPoint("LEFT", exportNameBox, "RIGHT", 8, 0)
        exportBtn:SetText("Export")

        -- Optional checkbox: when ticked, the Export button emits a full
        -- settings pack instead of the current single-list payload. Toggling
        -- it greys out the scope and name inputs since the pack covers every
        -- list and carries no name field. Off by default; existing exports
        -- remain unchanged.
        --
        -- Lives on its OWN row below the name input so the export controls
        -- never overflow on a narrow panel; the previous side-by-side layout
        -- pushed the checkbox off the right edge on smaller widths.
        local fullPackCB = CreateFrame("CheckButton", "EbonClearanceExportFullPackCB", self, "UICheckButtonTemplate")
        fullPackCB:SetPoint("TOPLEFT", exportNameLabel, "BOTTOMLEFT", 0, -8)
        fullPackCB:SetSize(22, 22)
        local fullPackLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fullPackLbl:SetPoint("LEFT", fullPackCB, "RIGHT", 2, 1)
        fullPackLbl:SetText("Full settings pack (rules + Sell / Keep / Delete + Account Sell)")
        fullPackCB:SetChecked(false)

        local function refreshExportInputsForPackMode(packMode)
            -- EditBox on 3.3.5a doesn't expose Enable/Disable like Button does;
            -- toggle mouse + keyboard interaction and drop focus instead. The
            -- alpha shift makes the disabled state visually obvious.
            if packMode then
                exportNameBox:ClearFocus()
                exportNameBox:EnableMouse(false)
                exportNameBox:EnableKeyboard(false)
                exportNameBox:SetTextColor(0.5, 0.5, 0.5)
            else
                exportNameBox:EnableMouse(true)
                exportNameBox:EnableKeyboard(true)
                exportNameBox:SetTextColor(1, 1, 1)
            end
            -- CheckButton derives from Button so Enable/Disable do exist here,
            -- but for symmetry with the EditBox path we drive both via alpha
            -- plus EnableMouse so the visual state stays consistent.
            for _, cb in ipairs({ exportCharCB, exportAcctCB }) do
                cb:EnableMouse(not packMode)
                cb:SetAlpha(packMode and 0.5 or 1)
            end
            exportNameLabel:SetAlpha(packMode and 0.5 or 1)
            exportScopeLabel:SetAlpha(packMode and 0.5 or 1)
            exportCharLbl:SetAlpha(packMode and 0.5 or 1)
            exportAcctLbl:SetAlpha(packMode and 0.5 or 1)
        end

        fullPackCB:SetScript("OnClick", function(self_)
            refreshExportInputsForPackMode(self_:GetChecked())
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        fullPackCB:SetScript("OnEnter", function(self_)
            GameTooltip:SetOwner(self_, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Full settings pack")
            GameTooltip:AddLine(
                "When ticked, Export produces one string covering quality rules, the Sell List, the Keep List, the Delete List, and the Account Sell List together. Off by default.",
                1,
                1,
                1,
                true
            )
            GameTooltip:Show()
        end)
        fullPackCB:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        -- Wrap the scroll frame in a thin backdrop frame so the input area is
        -- visually distinct. The raw ScrollFrame template doesn't carry any
        -- backdrop, so an empty box renders as a transparent void with no
        -- visual cue for where to click. The wrapper supplies the chrome;
        -- the scroll frame inside still owns scrolling behaviour.
        local exportBoxBg = CreateFrame("Frame", nil, self)
        exportBoxBg:SetPoint("TOPLEFT", fullPackCB, "BOTTOMLEFT", 0, -8)
        exportBoxBg:SetSize(NS.GetPanelWidth() - 36, 50)
        exportBoxBg:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        exportBoxBg:SetBackdropColor(0, 0, 0, 0.6)
        exportBoxBg:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)
        -- Track the wrapper's width on panel resize so the input area follows
        -- the Interface Options frame resize handle.
        EC_compCache.registerWidth(exportBoxBg, 36)

        local exportScroll =
            CreateFrame("ScrollFrame", "EbonClearanceExportScroll", exportBoxBg, "UIPanelScrollFrameTemplate")
        exportScroll:SetPoint("TOPLEFT", 6, -6)
        exportScroll:SetPoint("BOTTOMRIGHT", -28, 6)

        local exportBox = CreateFrame("EditBox", "EbonClearanceExportBox", exportScroll)
        exportBox:SetAutoFocus(false)
        exportBox:SetMultiLine(true)
        exportBox:SetFontObject("GameFontHighlightSmall")
        -- Size the EditBox explicitly. Without SetHeight, an empty multiline
        -- EditBox has zero clickable area, so users can't focus it to paste.
        exportBox:SetSize(560, 50)
        exportBox:SetText("")
        exportBox:SetScript("OnEscapePressed", function(s)
            s:ClearFocus()
        end)
        exportScroll:SetScrollChild(exportBox)
        -- Clicking anywhere in the backdrop area focuses the EditBox so the
        -- user doesn't have to land precisely on the (often empty) text
        -- glyphs to start typing or to highlight an existing export.
        exportBoxBg:EnableMouse(true)
        exportBoxBg:SetScript("OnMouseDown", function()
            exportBox:SetFocus()
        end)

        exportBtn:SetScript("OnClick", function()
            local str
            if fullPackCB:GetChecked() and EC_compCache.exportFullPack then
                str = EC_compCache.exportFullPack()
                exportBox:SetText(str)
                exportBox:HighlightText()
                exportBox:SetFocus()
                PlaySound("igMainMenuOptionCheckBoxOn")
                NS.PrintNice(
                    "Exported full settings pack (rules + Sell / Keep / Delete + Account Sell). Copy the text above."
                )
            else
                str = EC_ExportWhitelist(exportNameBox:GetText(), exportScope)
                exportBox:SetText(str)
                exportBox:HighlightText()
                exportBox:SetFocus()
                PlaySound("igMainMenuOptionCheckBoxOn")
                local source = EC_GetWhitelistForScope(exportScope) or {}
                local count = 0
                for _, v in pairs(source) do
                    if v == true or v == 1 then
                        count = count + 1
                    end
                end
                local scopeName = (exportScope == "account") and "account" or "character"
                NS.PrintNicef("Exported |cffffff00%d|r %s whitelist items. Copy the text above.", count, scopeName)
            end
        end)

        -- === IMPORT SECTION ===
        NS.MakeLabel(self, "Paste a Sell List string and pick which list it imports into.", 16, -228)

        local importScope = "character"

        local importScopeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        importScopeLabel:SetPoint("TOPLEFT", 16, -256)
        importScopeLabel:SetText("Target list:")

        local importCharCB =
            CreateFrame("CheckButton", "EbonClearanceImportTargetCharCB", self, "UIRadioButtonTemplate")
        importCharCB:SetPoint("LEFT", importScopeLabel, "RIGHT", 8, 0)
        importCharCB:SetChecked(true)
        local importCharLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        importCharLbl:SetPoint("LEFT", importCharCB, "RIGHT", 2, 1)
        importCharLbl:SetText("Character")

        local importAcctCB =
            CreateFrame("CheckButton", "EbonClearanceImportTargetAcctCB", self, "UIRadioButtonTemplate")
        importAcctCB:SetPoint("LEFT", importCharLbl, "RIGHT", 12, -1)
        importAcctCB:SetChecked(false)
        local importAcctLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        importAcctLbl:SetPoint("LEFT", importAcctCB, "RIGHT", 2, 1)
        importAcctLbl:SetText("Account")

        importCharCB:SetScript("OnClick", function()
            importScope = "character"
            importCharCB:SetChecked(true)
            importAcctCB:SetChecked(false)
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        importAcctCB:SetScript("OnClick", function()
            importScope = "account"
            importAcctCB:SetChecked(true)
            importCharCB:SetChecked(false)
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)

        -- Wrap in a backdrop frame for the same reason as the export box:
        -- the raw ScrollFrame is transparent until typed into, leaving the
        -- user with no visual target for paste. Wrapper supplies chrome;
        -- ScrollFrame inside owns scrolling.
        local importBoxBg = CreateFrame("Frame", nil, self)
        importBoxBg:SetPoint("TOPLEFT", 16, -284)
        importBoxBg:SetSize(NS.GetPanelWidth() - 36, 50)
        importBoxBg:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        importBoxBg:SetBackdropColor(0, 0, 0, 0.6)
        importBoxBg:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)
        EC_compCache.registerWidth(importBoxBg, 36)

        local importScroll =
            CreateFrame("ScrollFrame", "EbonClearanceImportScroll", importBoxBg, "UIPanelScrollFrameTemplate")
        importScroll:SetPoint("TOPLEFT", 6, -6)
        importScroll:SetPoint("BOTTOMRIGHT", -28, 6)

        local importBox = CreateFrame("EditBox", "EbonClearanceImportBox", importScroll)
        importBox:SetAutoFocus(false)
        importBox:SetMultiLine(true)
        importBox:SetFontObject("GameFontHighlightSmall")
        -- Explicit size required so an empty EditBox still has a clickable area
        -- for paste. Without SetHeight, multiline EditBoxes collapse to zero.
        importBox:SetSize(560, 50)
        importBox:SetText("")
        importBox:SetScript("OnEscapePressed", function(s)
            s:ClearFocus()
        end)
        importScroll:SetScrollChild(importBox)
        -- Clicking anywhere in the wrapper focuses the EditBox so users can
        -- paste without having to land on the (empty) glyph row inside the
        -- scroll frame.
        importBoxBg:EnableMouse(true)
        importBoxBg:SetScript("OnMouseDown", function()
            importBox:SetFocus()
        end)

        local importMergeBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        importMergeBtn:SetSize(120, 22)
        importMergeBtn:SetPoint("TOPLEFT", 16, -342)
        importMergeBtn:SetText("Import (Merge)")

        local importReplaceBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        importReplaceBtn:SetSize(120, 22)
        importReplaceBtn:SetPoint("LEFT", importMergeBtn, "RIGHT", 8, 0)
        importReplaceBtn:SetText("Import (Replace)")

        local statusFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        statusFS:SetPoint("TOPLEFT", 16, -370)
        EC_compCache.setPanelWidth(statusFS, 16)
        statusFS:SetJustifyH("LEFT")
        statusFS:SetText("")

        local function runImport(mode)
            local raw = importBox:GetText() or ""
            -- Auto-detect: full settings packs start with the EC_PACK_V1 marker
            -- on their first line. Anything else falls through to the existing
            -- single-list import, which honours the Target scope radio above.
            local firstLine = raw:match("^%s*([^\r\n]+)")
            local isPack = firstLine and firstLine:sub(1, #EC_compCache.PACK_PREFIX) == EC_compCache.PACK_PREFIX
            local ok, msg
            if isPack and EC_compCache.importFullPack then
                ok, msg = EC_compCache.importFullPack(raw, mode)
            else
                ok, msg = EC_ImportWhitelist(raw, mode, importScope)
            end
            statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
            if ok then
                PlaySound("igMainMenuOptionCheckBoxOn")
                NS.PrintNice(msg)
                if isPack then
                -- The pack importer already refreshed every relevant panel,
                -- so nothing extra to do here.
                else
                    local panelName = (importScope == "account") and "EbonClearanceOptionsAccountWhitelist"
                        or "EbonClearanceOptionsWhitelist"
                    local wp = _G[panelName]
                    if wp and wp.listUI then
                        wp.listUI:Refresh()
                    end
                end
            else
                PlaySound("igMainMenuOptionCheckBoxOff")
            end
        end
        importMergeBtn:SetScript("OnClick", function()
            runImport("merge")
        end)
        importReplaceBtn:SetScript("OnClick", function()
            runImport("replace")
        end)

        -- Grey explanation is anchored to the status line so it naturally flows
        -- below, even when the status wraps to two lines (e.g. long error).
        local importNote = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        importNote:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -8)
        EC_compCache.setPanelWidth(importNote, 16)
        importNote:SetJustifyH("LEFT")
        importNote:SetJustifyV("TOP")
        if importNote.SetWordWrap then
            importNote:SetWordWrap(true)
        end
        importNote:SetText(
            "|cffaaaaaa'Merge' adds imported items to the target list. "
                .. "'Replace' clears the target list first, then adds the imported items.|r"
        )
    end)
end)
