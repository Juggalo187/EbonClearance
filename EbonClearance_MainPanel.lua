-- EbonClearance_MainPanel - main "EbonClearance" Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ix-a of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The top-level "EbonClearance" panel - the entry point users hit
-- first when opening Interface Options. Hosts the welcome blurb,
-- session stats (gold made / items sold / items deleted / repair
-- spend), lifetime stats, slash command reference, and the master
-- "Enabled" toggle.
--
-- Moved into this file:
--   * local MainOptions = CreateFrame(...) frame creation
--   * BuildMainPanel function (~153 LOC; builds the panel body)
--   * The MainOptions OnShow handler which composes RefreshStats +
--     BuildMainPanel through EC_compCache.initPanel
--
-- The panel-infrastructure helpers (MakeHeader, MakeLabel,
-- AddCheckbox, AddSlider, EC_PANEL_WIDTH, EC_UpdatePanelWidth,
-- EC_compCache.initPanel, registerWidth, setPanelWidth, etc.) all
-- STAY in EbonClearance.lua for now; they're shared across every
-- panel and will move in a later stage.
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth
--   * NS.DB / NS.ADB captured at OnShow + BuildMainPanel entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.FitScrollContent (8e-ii)
--   * NS.CopperToColoredText (Stage 8 era)
--   * NS.GetVersion (Stage 8 era)
--   * NS.ResetSession (8e-ix-a prep) - session-stats reset handler
--     used by the Reset Session button on this panel

local NS = select(2, ...)
local EC_compCache = NS.compCache

local MainOptions = CreateFrame("Frame", "EbonClearanceOptionsMain", InterfaceOptionsFramePanelContainer)
MainOptions.name = "EbonClearance"


local function BuildMainPanel(panel, content, refreshStats)
    local DB = NS.DB
    -- v2.12.0: widgets are created on `content` (the scroll-frame child)
    -- so vertical overflow is handled by the scroll bar. Stat refs are
    -- still stored on `panel` (the outer Interface Options panel) so
    -- RefreshStats's self.statsX reads keep working across re-OnShows.
    local addonVersion = NS.GetVersion()
    NS.MakeHeader(content, "EbonClearance " .. addonVersion, -16)

    -- Byline (required by LICENSE; do not remove in derivatives).
    local byline = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    byline:SetPoint("TOPLEFT", 16, -32)
    byline:SetText("|cff888866by " .. NS.ADDON_AUTHOR .. "  \194\183  " .. NS.ADDON_URL .. "|r")

    local welcomeLabel = NS.MakeLabel(
        content,
        "Welcome to |cffb6ffb6EbonClearance|r! Bag management for Project Ebonhold: vendoring, deletion, looting, protection rules, and profession processing.",
        16,
        -52
    )
    local descLabel2 = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    descLabel2:SetPoint("TOPLEFT", welcomeLabel, "BOTTOMLEFT", 0, -4)
    EC_compCache.setPanelWidth(descLabel2, 16)
    descLabel2:SetJustifyH("LEFT")
    descLabel2:SetJustifyV("TOP")
    if descLabel2.SetWordWrap then
        descLabel2:SetWordWrap(true)
    end
    descLabel2:SetText(
        "Greys auto-sell. Whites and greens below your equipped iLvl auto-sell too, and looted upgrades are auto-protected.\n\n"
            .. "Use |cffb6ffb6Sell List|r (per-character or account-wide) to mark specific items for sale, "
            .. "|cffb6ffb6Keep List|r to permanently protect items, "
            .. "|cffb6ffb6Merchant Settings|r to tune the auto-sell rules per rarity, "
            .. "and |cffb6ffb6Process Bags|r to disenchant, mill, prospect, or pick lock from one button."
    )
    -- Tip on its own line, in grey, so it reads as a hint rather than
    -- another sentence in the main description block.
    local mainTip = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    mainTip:SetPoint("TOPLEFT", descLabel2, "BOTTOMLEFT", 0, -10)
    EC_compCache.setPanelWidth(mainTip, 16)
    mainTip:SetJustifyH("LEFT")
    mainTip:SetJustifyV("TOP")
    if mainTip.SetWordWrap then
        mainTip:SetWordWrap(true)
    end
    mainTip:SetText("|cff888888Tip: Alt+Right-Click any bag item for a quick-action menu.|r")

    -- Stats fontstrings. Stacked vertically; each attaches its ref to `panel`
    -- so RefreshStats can find them across subsequent OnShow calls.
    local money = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    money:SetPoint("TOPLEFT", mainTip, "BOTTOMLEFT", 0, -16)
    panel.statsMoney = money

    local sold = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sold:SetPoint("TOPLEFT", money, "BOTTOMLEFT", 0, -6)
    panel.statsSold = sold

    local deleted = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    deleted:SetPoint("TOPLEFT", sold, "BOTTOMLEFT", 0, -6)
    panel.statsDeleted = deleted

    local repairs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairs:SetPoint("TOPLEFT", deleted, "BOTTOMLEFT", 0, -6)
    panel.statsRepairs = repairs

    local repairCost = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairCost:SetPoint("TOPLEFT", repairs, "BOTTOMLEFT", 0, -6)
    panel.statsRepairCost = repairCost

    local avgWorth = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    avgWorth:SetPoint("TOPLEFT", repairCost, "BOTTOMLEFT", 0, -6)
    panel.statsAvgWorth = avgWorth

    local mostSold = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    mostSold:SetPoint("TOPLEFT", avgWorth, "BOTTOMLEFT", 0, -6)
    EC_compCache.setPanelWidth(mostSold, 16)
    mostSold:SetJustifyH("LEFT")
    panel.statsMostSold = mostSold

    local statsNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statsNote:SetPoint("TOPLEFT", mostSold, "BOTTOMLEFT", 0, -4)
    EC_compCache.setPanelWidth(statsNote, 16)
    statsNote:SetJustifyH("LEFT")
    statsNote:SetText("|cff888888Stats don't account for items bought back from a merchant.|r")

    local resetBtn = CreateFrame("Button", "EbonClearanceResetStatsBtn", content, "UIPanelButtonTemplate")
    resetBtn:SetSize(170, 22)
    resetBtn:SetPoint("TOPLEFT", statsNote, "BOTTOMLEFT", 0, -8)
    resetBtn:SetText("Reset Lifetime Stats")
    resetBtn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("EC_CONFIRM_RESET_LIFETIME")
        if dialog then
            dialog.data = function()
                DB.totalCopper = 0
                DB.totalItemsSold = 0
                DB.totalItemsDeleted = 0
                DB.totalRepairs = 0
                DB.totalRepairCopper = 0
                DB.inventoryWorthTotal = 0
                DB.inventoryWorthCount = 0
                wipe(DB.soldItemCounts)
                wipe(DB.deletedItemCounts)
                refreshStats()
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    -- Session delta is inlined into each lifetime stat line by RefreshStats (NS.session).
    -- The Reset Session button sits side-by-side with Reset Lifetime to avoid adding vertical space.
    local resetSessionBtn = CreateFrame("Button", "EbonClearanceResetSessionBtn", content, "UIPanelButtonTemplate")
    resetSessionBtn:SetSize(170, 22)
    resetSessionBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
    resetSessionBtn:SetText("Reset Session Stats")
    resetSessionBtn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("EC_CONFIRM_RESET_SESSION")
        if dialog then
            dialog.data = function()
                NS.ResetSession()
                refreshStats()
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    -- Slash commands reference.
    local cmdHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    cmdHeader:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -16)
    cmdHeader:SetText("Slash Commands")

    local cmdText = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cmdText:SetPoint("TOPLEFT", cmdHeader, "BOTTOMLEFT", 0, -6)
    EC_compCache.setPanelWidth(cmdText, 16)
    cmdText:SetJustifyH("LEFT")
    if cmdText.SetWordWrap then
        cmdText:SetWordWrap(true)
    end
    cmdText:SetText(
        "|cffffff00/ec|r  Open settings\n"
            .. "|cffffff00/ec profile [list|save|load|delete <name>]|r  Manage saved profiles\n"
            .. "|cffffff00/ec clean [apply]|r  Find and resolve list conflicts\n"
            .. "|cffffff00/ec clean upgrades [apply]|r  Clean stale 'Upgrade'-tagged Keep List entries\n"
            .. "|cffffff00/ec sellinfo [bag slot]|r  Trace why a bag item will/won't sell |cffaaaaaa(or Alt+Shift+Right-Click)|r\n"
            .. "|cffffff00/ec bugreport|r  Generate a diagnostic report\n"
            .. "|cffffff00/ec help|r  Print full slash-command reference in chat\n"
            .. "|cffffff00/ecdebug|r  Show debug info and bag scan"
    )

    -- v2.12.0: size the scroll content to fit the bottom-most widget so
    -- the scroll bar engages when the Interface Options frame is too
    -- short to show everything (matches the Scavenger / Merchant /
    -- Profiles / Import-Export panels' pattern).
    NS.FitScrollContent(content, cmdText)
end

MainOptions:SetScript("OnShow", function(self)
    local DB = NS.DB
    local ADB = NS.ADB
    -- Stats helpers stay inside OnShow because RefreshStats captures `self`
    -- via closure and gets passed in two slots (the EC_compCache.initPanel
    -- refresh callback, and as the refresh fn handed to BuildMainPanel so
    -- the stat fields update after the merchant cycle). Re-declaring on
    -- each OnShow is cheap; the closures are reclaimed once initPanel
    -- returns.
    local function GetMostItem(countTable)
        local bestID, bestCount = nil, 0
        if type(countTable) ~= "table" then
            return nil, 0
        end
        for id, cnt in pairs(countTable) do
            if type(id) == "number" and type(cnt) == "number" and cnt > bestCount then
                bestID, bestCount = id, cnt
            end
        end
        return bestID, bestCount
    end

    local function ItemLabel(id)
        if not id then
            return "None"
        end
        local name = GetItemInfo(id)
        if name then
            return string.format("|cff24ffb6%s|r", name)
        end
        return "ItemID: " .. tostring(id)
    end

    local function RefreshStats()
        if not self.statsMoney then
            return
        end
        local function sessionSuffix(n)
            return string.format("  |cff888888(session +%s)|r", tostring(n or 0))
        end
        local function sessionMoneySuffix(c)
            return "  |cff888888(session +" .. NS.CopperToColoredText(c or 0) .. "|cff888888)|r"
        end
        self.statsMoney:SetText(
            "Total Money Made: " .. NS.CopperToColoredText(DB.totalCopper or 0) .. sessionMoneySuffix(NS.session.copper)
        )
        self.statsSold:SetText(
            "Total Items Sold: " .. tostring(DB.totalItemsSold or 0) .. sessionSuffix(NS.session.sold)
        )
        self.statsDeleted:SetText(
            "Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0) .. sessionSuffix(NS.session.deleted)
        )
        self.statsRepairs:SetText(
            "Total Repairs: " .. tostring(DB.totalRepairs or 0) .. sessionSuffix(NS.session.repairs)
        )
        self.statsRepairCost:SetText(
            "Total Repair Cost: "
                .. NS.CopperToColoredText(DB.totalRepairCopper or 0)
                .. sessionMoneySuffix(NS.session.repairCopper)
        )
        if self.statsAvgWorth then
            local cnt = DB.inventoryWorthCount or 0
            local total = DB.inventoryWorthTotal or 0
            local avg = 0
            if cnt > 0 then
                avg = math.floor((total / cnt) + 0.5)
            end
            self.statsAvgWorth:SetText("Average Inventory Worth: " .. NS.CopperToColoredText(avg))
        end

        local mostID, mostCount = GetMostItem(DB.soldItemCounts)
        if mostID then
            self.statsMostSold:SetText("Most Sold Item: " .. ItemLabel(mostID) .. " (x" .. tostring(mostCount) .. ")")
        else
            self.statsMostSold:SetText("Most Sold Item: None")
        end
    end

    EC_compCache.initPanel(self, RefreshStats, function(self, content)
        -- v2.12.0: scroll-wrap the Main panel so the Slash Commands block
        -- at the bottom doesn't overlap the OK/Cancel button strip when
        -- the Interface Options frame is shorter than the panel content.
        -- Scavenger and Merchant Settings are wrapped the same way.
        BuildMainPanel(self, content, RefreshStats)
        RefreshStats()
    end, true)
end)
