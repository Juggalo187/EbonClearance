-- EbonClearance_MainPanel - main "EbonClearance" Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ix-a of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The top-level "EbonClearance" panel - the entry point users hit
-- first when opening Interface Options. Hosts the welcome blurb,
-- feature orientation, the Alt+Right-Click tip, and the slash
-- command reference. Stats moved to EbonClearance_StatsPanel.lua
-- in v2.36.x (sub-panel split). The NS.RefreshStats / NS.ResetLifetimeStats
-- helpers still live in this file so Events.lua data-change handlers
-- have a stable namespace entry point; they write to the Stats panel
-- via _G["EbonClearanceOptionsStats"] and no-op until that panel is
-- built.
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

-- ---------------------------------------------------------------------------
-- NS.RefreshStats / NS.ResetLifetimeStats - namespace-exposed helpers.
-- ---------------------------------------------------------------------------
-- Stage 8e-ix-b of the file split: the stats refresh + lifetime-reset
-- logic was a closure local to MainOptions:OnShow. Stats widgets are
-- moving to EbonClearance_StatsPanel.lua (Task 4) and the data-change
-- handlers in EbonClearance_Events.lua need to drive a refresh without
-- knowing which panel owns the FontStrings. Hoisting these to file
-- scope and exposing them on NS gives callers a stable entry point.
-- The stats widgets now hang on _G["EbonClearanceOptionsStats"]; both
-- functions look it up and no-op if the panel isn't built yet.

-- GetTopNItems: return up to N {id, count} pairs ordered by count desc.
-- v2.37.0 superset of the old GetMostItem (which returned only the top
-- entry). The Stats panel renders the top 5 most-sold items; passing
-- n=1 reproduces the v2.36.x single-line "Most Sold Item" behaviour.
local function GetTopNItems(countTable, n)
    if type(countTable) ~= "table" then
        return {}
    end
    local entries = {}
    for id, cnt in pairs(countTable) do
        if type(id) == "number" and type(cnt) == "number" and cnt > 0 then
            entries[#entries + 1] = { id = id, count = cnt }
        end
    end
    table.sort(entries, function(a, b)
        if a.count == b.count then
            return a.id < b.id
        end
        return a.count > b.count
    end)
    local top = {}
    for i = 1, math.min(n or 1, #entries) do
        top[i] = entries[i]
    end
    return top
end

-- v2.37.0: quality bucket order + display names + colours. WoW's
-- ITEM_QUALITY_COLORS table exists in 3.3.5a but its colour codes
-- don't always include the leading "ff" alpha pair our format
-- strings expect; hardcoding keeps the rendering stable. Heirloom
-- (7) reuses the Artifact (6) gold tone, matching the legacy
-- in-game tooltip palette.
local QUALITY_NAMES = {
    [0] = "Poor",
    [1] = "Common",
    [2] = "Uncommon",
    [3] = "Rare",
    [4] = "Epic",
    [5] = "Legendary",
    [6] = "Artifact",
    [7] = "Heirloom",
}
local QUALITY_HEX = {
    [0] = "9d9d9d",
    [1] = "ffffff",
    [2] = "1eff00",
    [3] = "0070dd",
    [4] = "a335ee",
    [5] = "ff8000",
    [6] = "e6cc80",
    [7] = "e6cc80",
}

-- ItemLabel: resolve an itemID to a coloured name string, with a
-- cache-warmup deferred re-render for cold-cache cases. The warmup
-- flag hangs on the stats panel itself so a hidden panel doesn't
-- accumulate pending refreshes.
local function ItemLabel(id)
    if not id then
        return "None"
    end
    local name = GetItemInfo(id)
    if name then
        return string.format("|cff24ffb6%s|r", name)
    end
    -- GetItemInfo cold-cache. Post per-character partition (v2.34.0),
    -- each character inherits the snapshot of accumulated counts -
    -- which can include items the current character has never seen
    -- this session, and those items haven't been requested from the
    -- server yet. Trigger a SetHyperlink-driven cache fetch and
    -- schedule one re-render so the name resolves the moment the
    -- client receives the data (typically 100-300 ms). Falls back
    -- to the ItemID string for this paint; the re-render replaces it.
    if NS.scanTooltip and NS.scanTooltip.SetHyperlink then
        NS.scanTooltip:ClearLines()
        NS.scanTooltip:SetHyperlink("item:" .. tostring(id))
    end
    local statsPanel = _G["EbonClearanceOptionsStats"]
    if statsPanel and not statsPanel._statsWarmupPending and NS.Delay then
        statsPanel._statsWarmupPending = true
        NS.Delay(0.6, function()
            statsPanel._statsWarmupPending = nil
            if statsPanel.IsShown and statsPanel:IsShown() and NS.RefreshStats then
                NS.RefreshStats()
            end
        end)
    end
    return "ItemID: " .. tostring(id)
end

function NS.RefreshStats()
    local panel = _G["EbonClearanceOptionsStats"]
    if not panel or not panel.statsMoney then
        return
    end
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB then
        return
    end
    -- v2.38.1: view-aware. Character view reads DB.* (this character's
    -- lifetime). Account view reads ADB.accountStats.* (aggregated
    -- across all characters since v2.38.1 install). Session deltas only
    -- render in Character view - "session" is inherently per-character.
    local view = panel._statsView or "character"
    local src = (view == "account") and (ADB and ADB.accountStats) or DB
    if not src then
        return
    end
    local showSession = (view == "character")
    local function sessionSuffix(n)
        if not showSession then
            return ""
        end
        return string.format("  |cff888888(session +%s)|r", tostring(n or 0))
    end
    local function sessionMoneySuffix(c)
        if not showSession then
            return ""
        end
        return "  |cff888888(session +" .. NS.CopperToColoredText(c or 0) .. "|cff888888)|r"
    end
    panel.statsMoney:SetText(
        "Total Money Made: " .. NS.CopperToColoredText(src.totalCopper or 0) .. sessionMoneySuffix(NS.session.copper)
    )
    panel.statsSold:SetText(
        "Total Items Sold: " .. tostring(src.totalItemsSold or 0) .. sessionSuffix(NS.session.sold)
    )
    panel.statsDeleted:SetText(
        "Total Items Deleted: " .. tostring(src.totalItemsDeleted or 0) .. sessionSuffix(NS.session.deleted)
    )
    panel.statsRepairs:SetText(
        "Total Repairs: " .. tostring(src.totalRepairs or 0) .. sessionSuffix(NS.session.repairs)
    )
    panel.statsRepairCost:SetText(
        "Total Repair Cost: "
            .. NS.CopperToColoredText(src.totalRepairCopper or 0)
            .. sessionMoneySuffix(NS.session.repairCopper)
    )

    -- v2.35.x: Session + Best Gold/Hour. See
    -- docs/specs/2026-05-26-gph-stats-design.md for the design.
    --
    -- The session line shows the live rate (copper/hour) computed
    -- from session.copper / elapsed-seconds, with a 10-second floor
    -- on the elapsed value so sub-second extrapolation doesn't
    -- produce absurd numbers in the moment right after /reload.
    -- The best line shows the per-character record + the zone +
    -- when context. Only updates the best when the session has
    -- run for at least 5 minutes (300s gate) - filters early-
    -- session burst noise.
    local startedAt = NS.session.startedAt or 0
    local now = GetTime()
    local elapsed = (startedAt > 0) and (now - startedAt) or 0
    local function humanDuration(secs)
        secs = math.floor(secs)
        if secs < 60 then
            return string.format("%ds", secs)
        elseif secs < 3600 then
            return string.format("%dm %ds", math.floor(secs / 60), secs % 60)
        end
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        local s = secs % 60
        return string.format("%dh %dm %ds", h, m, s)
    end
    local sessionGPH
    if elapsed >= 10 then
        sessionGPH = math.floor((NS.session.copper / elapsed) * 3600)
    end
    if panel.statsSessionGPH then
        if sessionGPH then
            panel.statsSessionGPH:SetText(
                "Session Gold/Hour: "
                    .. NS.CopperToColoredText(sessionGPH)
                    .. string.format("  |cff888888(%s)|r", humanDuration(elapsed))
            )
        else
            panel.statsSessionGPH:SetText(
                "Session Gold/Hour: |cff888888-  (computing...)|r"
            )
        end
    end

    -- Best-update gate: 5 minutes of session AND new high. Compared
    -- against both records independently so a character-best update
    -- doesn't require an account-best, and vice versa.
    if sessionGPH and elapsed >= 300 then
        local zone = GetRealZoneText()
        local zoneText = (zone and zone ~= "") and zone or "Unknown"
        local now = time()
        if sessionGPH > (DB.bestGPH or 0) then
            DB.bestGPH = sessionGPH
            DB.bestGPHAt = now
            DB.bestGPHZone = zoneText
        end
        -- v2.38.1: account-wide best record. Stamp the character name
        -- so the Account view's ribbon can say "on <CharName>".
        local AS = ADB and ADB.accountStats
        if AS and sessionGPH > (AS.bestGPH or 0) then
            AS.bestGPH = sessionGPH
            AS.bestGPHAt = now
            AS.bestGPHZone = zoneText
            AS.bestGPHChar = (UnitName and UnitName("player")) or ""
        end
    end

    if panel.statsBestGPH then
        local best = src.bestGPH or 0
        if best > 0 then
            local at = src.bestGPHAt or 0
            local zone = src.bestGPHZone
            if not zone or zone == "" then
                zone = "Unknown"
            end
            local when
            if at <= 0 then
                when = "unknown date"
            else
                local secs = time() - at
                if secs < 60 then
                    when = "just now"
                elseif secs < 3600 then
                    local n = math.floor(secs / 60)
                    when = string.format("%d minute%s ago", n, n == 1 and "" or "s")
                elseif secs < 86400 then
                    local n = math.floor(secs / 3600)
                    when = string.format("%d hour%s ago", n, n == 1 and "" or "s")
                elseif secs < 30 * 86400 then
                    local n = math.floor(secs / 86400)
                    when = string.format("%d day%s ago", n, n == 1 and "" or "s")
                else
                    when = date("%Y-%m-%d", at)
                end
            end
            -- v2.38.1: append the character name in Account view so
            -- "Best Gold/Hour: 12345g  in Stranglethorn, 2 hours ago on Bob"
            -- tells the player which character set the account record.
            local charSuffix = ""
            if view == "account" and src.bestGPHChar and src.bestGPHChar ~= "" then
                charSuffix = string.format(" on %s", src.bestGPHChar)
            end
            panel.statsBestGPH:SetText(
                "Best Gold/Hour: "
                    .. NS.CopperToColoredText(best)
                    .. string.format("\n  |cff888888in %s, %s%s|r", zone, when, charSuffix)
            )
        else
            panel.statsBestGPH:SetText("Best Gold/Hour: |cff888888-|r")
        end
    end

    if panel.statsAvgWorth then
        -- inventoryWorthTotal / inventoryWorthCount are per-character
        -- only (no account aggregate). Account view shows a dash for
        -- this row since the average wouldn't be meaningful across
        -- characters with different equip levels.
        if view == "account" then
            panel.statsAvgWorth:SetText("Average Inventory Worth: |cff888888- (per-character only)|r")
        else
            local cnt = DB.inventoryWorthCount or 0
            local total = DB.inventoryWorthTotal or 0
            local avg = 0
            if cnt > 0 then
                avg = math.floor((total / cnt) + 0.5)
            end
            panel.statsAvgWorth:SetText("Average Inventory Worth: " .. NS.CopperToColoredText(avg))
        end
    end

    if panel.statsQualityBreakdown then
        local items = src.soldItemsByQuality or {}
        local copper = src.soldCopperByQuality or {}
        local rows = { "|cffffd200Sold by Quality|r" }
        local any = false
        for q = 0, 7 do
            local cnt = items[q]
            if cnt and cnt > 0 then
                any = true
                -- v2.37.x: x-prefixed grey count + " - " separator
                -- between count and money so two adjacent number groups
                -- don't read as a single long number. Matches the Top 5
                -- row format ("name  x42") for visual consistency.
                rows[#rows + 1] = string.format(
                    "  |cff%s%s|r: |cff888888x%d|r  |cff888888-|r  %s",
                    QUALITY_HEX[q] or "ffffff",
                    QUALITY_NAMES[q] or ("Quality " .. q),
                    cnt,
                    NS.CopperToColoredText(copper[q] or 0)
                )
            end
        end
        if not any then
            rows[#rows + 1] = "  |cff888888None yet|r"
        end
        panel.statsQualityBreakdown:SetText(table.concat(rows, "\n"))
    end

    if panel.statsDeletedByQuality then
        local items = src.deletedItemsByQuality or {}
        local rows = { "|cffffd200Deleted by Quality|r" }
        local any = false
        for q = 0, 7 do
            local cnt = items[q]
            if cnt and cnt > 0 then
                any = true
                rows[#rows + 1] = string.format(
                    "  |cff%s%s|r: |cff888888x%d|r",
                    QUALITY_HEX[q] or "ffffff",
                    QUALITY_NAMES[q] or ("Quality " .. q),
                    cnt
                )
            end
        end
        if not any then
            rows[#rows + 1] = "  |cff888888None yet|r"
        end
        panel.statsDeletedByQuality:SetText(table.concat(rows, "\n"))
    end

    if panel.statsMostSold then
        local top = GetTopNItems(src.soldItemCounts, 5)
        if #top == 0 then
            panel.statsMostSold:SetText("|cffffd200Top 5 Most Sold|r\n  |cff888888None yet|r")
        else
            local rows = { "|cffffd200Top 5 Most Sold|r" }
            for i = 1, #top do
                rows[#rows + 1] = string.format(
                    "  %d. %s  |cff888888x%d|r",
                    i,
                    ItemLabel(top[i].id),
                    top[i].count
                )
            end
            panel.statsMostSold:SetText(table.concat(rows, "\n"))
        end
    end

    if panel.statsMostDeleted then
        local top = GetTopNItems(src.deletedItemCounts, 5)
        if #top == 0 then
            panel.statsMostDeleted:SetText("|cffffd200Top 5 Most Deleted|r\n  |cff888888None yet|r")
        else
            local rows = { "|cffffd200Top 5 Most Deleted|r" }
            for i = 1, #top do
                rows[#rows + 1] = string.format(
                    "  %d. %s  |cff888888x%d|r",
                    i,
                    ItemLabel(top[i].id),
                    top[i].count
                )
            end
            panel.statsMostDeleted:SetText(table.concat(rows, "\n"))
        end
    end

    if panel.statsProcessTotals then
        local counts = src.processCastCounts or {}
        local rows = { "|cffffd200Process Bags Totals|r" }
        local any = false
        -- Fixed display order: Disenchant, Milling, Prospecting, Pick Lock.
        -- Mirrors the Process Bags panel's section order.
        local order = { "Disenchant", "Milling", "Prospecting", "Pick Lock" }
        local labels = {
            Disenchant = "Disenchanted",
            Milling = "Milled",
            Prospecting = "Prospected",
            ["Pick Lock"] = "Lockboxes Picked",
        }
        for _, k in ipairs(order) do
            local n = counts[k] or 0
            if n > 0 then
                any = true
                rows[#rows + 1] = string.format("  %s: %d", labels[k], n)
            end
        end
        if not any then
            rows[#rows + 1] = "  |cff888888None yet|r"
        end
        panel.statsProcessTotals:SetText(table.concat(rows, "\n"))
    end

    if panel.statsTopZones then
        local zones = src.copperByZone or {}
        local entries = {}
        for name, copper in pairs(zones) do
            if type(name) == "string" and type(copper) == "number" and copper > 0 then
                entries[#entries + 1] = { name = name, copper = copper }
            end
        end
        table.sort(entries, function(a, b)
            if a.copper == b.copper then
                return a.name < b.name
            end
            return a.copper > b.copper
        end)
        local rows = { "|cffffd200Top Zones (gold earned)|r" }
        if #entries == 0 then
            rows[#rows + 1] = "  |cff888888None yet|r"
        else
            local cap = math.min(#entries, 5)
            for i = 1, cap do
                rows[#rows + 1] = string.format(
                    "  %d. %s  %s",
                    i,
                    entries[i].name,
                    NS.CopperToColoredText(entries[i].copper)
                )
            end
        end
        panel.statsTopZones:SetText(table.concat(rows, "\n"))
    end
end

-- v2.38.1: view-aware Reset Lifetime. Character view clears this
-- character's DB.* lifetime totals (existing behaviour). Account view
-- clears the ADB.accountStats.* aggregate (every character's
-- contribution since v2.38.1 install). Both wipe the Best GPH triple
-- on their respective side.
function NS.ResetLifetimeStats()
    local panel = _G["EbonClearanceOptionsStats"]
    local view = (panel and panel._statsView) or "character"
    if view == "account" then
        local ADB = NS.ADB
        local AS = ADB and ADB.accountStats
        if not AS then
            return
        end
        AS.totalCopper = 0
        AS.totalItemsSold = 0
        AS.totalItemsDeleted = 0
        AS.totalRepairs = 0
        AS.totalRepairCopper = 0
        if AS.soldItemCounts then
            wipe(AS.soldItemCounts)
        end
        if AS.deletedItemCounts then
            wipe(AS.deletedItemCounts)
        end
        if AS.soldItemsByQuality then
            wipe(AS.soldItemsByQuality)
        end
        if AS.soldCopperByQuality then
            wipe(AS.soldCopperByQuality)
        end
        if AS.deletedItemsByQuality then
            wipe(AS.deletedItemsByQuality)
        end
        if AS.processCastCounts then
            wipe(AS.processCastCounts)
        end
        if AS.copperByZone then
            wipe(AS.copperByZone)
        end
        AS.bestGPH = 0
        AS.bestGPHAt = 0
        AS.bestGPHZone = ""
        AS.bestGPHChar = ""
        AS.startedAt = time()
        return
    end
    -- Character view: clear DB.* (per-character).
    local DB = NS.DB
    if not DB then
        return
    end
    DB.totalCopper = 0
    DB.totalItemsSold = 0
    DB.totalItemsDeleted = 0
    DB.totalRepairs = 0
    DB.totalRepairCopper = 0
    DB.inventoryWorthTotal = 0
    DB.inventoryWorthCount = 0
    wipe(DB.soldItemCounts)
    wipe(DB.deletedItemCounts)
    if DB.soldItemsByQuality then
        wipe(DB.soldItemsByQuality)
    end
    if DB.soldCopperByQuality then
        wipe(DB.soldCopperByQuality)
    end
    if DB.deletedItemsByQuality then
        wipe(DB.deletedItemsByQuality)
    end
    if DB.processCastCounts then
        wipe(DB.processCastCounts)
    end
    if DB.copperByZone then
        wipe(DB.copperByZone)
    end
    -- v2.35.x: Reset Lifetime wipes the GPH best record too.
    -- The user is opting in to a full lifetime reset; per the
    -- spec (docs/specs/2026-05-26-gph-stats-design.md) the
    -- best record is part of lifetime state and goes with it.
    DB.bestGPH = 0
    DB.bestGPHAt = 0
    DB.bestGPHZone = ""
end


local function BuildMainPanel(panel, content)
    -- v2.12.0: widgets are created on `content` (the scroll-frame child)
    -- so vertical overflow is handled by the scroll bar.
    -- v2.36.x: stats widgets + Reset buttons moved to the Stats sub-panel
    -- (EbonClearance_StatsPanel.lua); the `panel` arg is unused here now
    -- but kept in the signature because EC_compCache.initPanel passes it.
    local addonVersion = NS.GetVersion()
    local heading = NS.MakeHeader(content, "EbonClearance " .. addonVersion, -16)
    NS.AddHelpIcon(content, heading, "LEFT", "RIGHT", 8, 0, "what-does-ec-do")

    -- Byline (required by LICENSE; do not remove in derivatives).
    local byline = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    byline:SetPoint("TOPLEFT", 16, -32)
    byline:SetText("|cff888866by " .. NS.ADDON_AUTHOR .. "  \194\183  " .. NS.ADDON_URL .. "|r")

    local welcomeLabel = NS.MakeLabel(
        content,
        "Welcome to |cffb6ffb6EbonClearance|r - bag management for Project Ebonhold.",
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
        "Out of the box it sells your junk and old gear when you visit a merchant, keeps your upgrades, and never touches anything important.\n\n"
            .. "Want more control?\n"
            .. "  |cffb6ffb6Sell List|r - items you want sold every time.\n"
            .. "  |cffb6ffb6Keep List|r - items the addon should never touch.\n"
            .. "  |cffb6ffb6Merchant Settings|r - change what counts as old gear.\n"
            .. "  |cffb6ffb6Process Bags|r - one button to disenchant, mill, prospect, or pick locks."
    )

    -- v2.38.0: Quickstart entry row. Button + one-line nudge so returning
    -- players can find the guided setup wizard any time. Fresh installs
    -- get the wizard opened automatically at PLAYER_LOGIN; this row is the
    -- way back in.
    local quickstartBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    quickstartBtn:SetSize(140, 26)
    quickstartBtn:SetPoint("TOPLEFT", descLabel2, "BOTTOMLEFT", 0, -16)
    quickstartBtn:SetText("Open Quickstart")
    quickstartBtn:SetScript("OnClick", function()
        local qf = _G["EbonClearanceOptionsQuickstart"]
        if qf and qf.Show then
            qf:Show()
        end
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    local quickstartHint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    quickstartHint:SetPoint("LEFT", quickstartBtn, "RIGHT", 10, 0)
    quickstartHint:SetJustifyH("LEFT")
    if quickstartHint.SetWordWrap then
        quickstartHint:SetWordWrap(true)
    end
    EC_compCache.setPanelWidth(quickstartHint, 180)
    quickstartHint:SetText("|cff888888New here? Pick a preset or answer 15 questions for a guided setup.|r")

    -- Tip on its own line, in grey, so it reads as a hint rather than
    -- another sentence in the main description block.
    local mainTip = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    mainTip:SetPoint("TOPLEFT", quickstartBtn, "BOTTOMLEFT", 0, -14)
    EC_compCache.setPanelWidth(mainTip, 16)
    mainTip:SetJustifyH("LEFT")
    mainTip:SetJustifyV("TOP")
    if mainTip.SetWordWrap then
        mainTip:SetWordWrap(true)
    end
    mainTip:SetText("|cff888888Right-click any bag item with Alt held for quick actions.|r")

    -- Update-available nudge toggle. Anchored below mainTip; cmdHeader
    -- re-anchors to this checkbox so the layout chain stays intact.
    local versionAlertCB = NS.AddCheckbox(
        content,
        "EbonClearanceVersionAlertCB",
        mainTip,
        "Tell me when an update is available",
        function()
            -- versionAlerts is an account-level field on the top-level
            -- SavedVariables (not per-character), so read it directly rather
            -- than via a panel DB upvalue this builder does not have.
            return EbonClearanceDB and EbonClearanceDB.versionAlerts
        end,
        function(v)
            if EbonClearanceDB then
                EbonClearanceDB.versionAlerts = v
            end
        end,
        -14
    )

    -- Slash commands reference.
    -- Stats widgets + Reset buttons moved to EbonClearance_StatsPanel.lua
    -- in v2.36.x; this anchor chain now goes mainTip -> versionAlertCB -> cmdHeader.
    local cmdHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    cmdHeader:SetPoint("TOPLEFT", versionAlertCB, "BOTTOMLEFT", 0, -20)
    cmdHeader:SetText("Slash Commands")

    -- v2.37.6: per-row slash command list. Each row gets a [Run] button
    -- when the command works without arguments (or with the safe default
    -- form). Argument-required commands (profile, affixdebug) stay
    -- text-only: a single button can't pick a sub-command for the user.
    -- Labels start at the same x regardless of whether the row has a
    -- button, so the two columns line up.
    local SLASH_ROWS = {
        { label = "|cffffff00/ec|r  Open settings |cffaaaaaa(you are here)|r" },
        { run = "profile list", label = "|cffffff00/ec profile list|r  Show your saved profiles" },
        {
            label = "|cffffff00/ec profile [save|load|delete] <name>|r  Manage profiles by name |cffaaaaaa(or use the Profiles panel)|r",
        },
        {
            run = "clean",
            label = "|cffffff00/ec clean|r  Find items on more than one list |cffaaaaaa(add 'apply' to fix)|r",
        },
        {
            run = "clean upgrades",
            label = "|cffffff00/ec clean upgrades|r  Find old 'Upgrade'-tagged Keep List items |cffaaaaaa(add 'apply' to remove)|r",
        },
        {
            run = "sellinfo",
            label = "|cffffff00/ec sellinfo|r  Explain why an item will or won't sell |cffaaaaaa(or Alt+Shift+Right-Click)|r",
        },
        {
            run = "bugreport",
            label = "|cffffff00/ec bugreport|r  Generate a report to share when something's wrong",
        },
        {
            run = "affixdebug status",
            label = "|cffffff00/ec affixdebug status|r  Show recording state + row count",
        },
        {
            run = "affixdebug on",
            label = "|cffffff00/ec affixdebug on|r  Start recording affix events for a bug report",
        },
        {
            run = "affixdebug off",
            label = "|cffffff00/ec affixdebug off|r  Stop recording",
        },
        {
            run = "affixdebug dump",
            label = "|cffffff00/ec affixdebug dump|r  Open the event-log window",
        },
        {
            run = "affixdebug clear",
            label = "|cffffff00/ec affixdebug clear|r  Wipe recorded rows",
        },
        {
            run = "processdebug",
            label = "|cffffff00/ec processdebug|r  Diagnose missing Disenchant / Mill / Prospect targets",
        },
        {
            run = "processdebug clear",
            label = "|cffffff00/ec processdebug clear|r  Wipe Process Bags cache (force fresh tooltip scans)",
        },
        { run = "perf", label = "|cffffff00/ec perf|r  Show EC's memory, CPU, cache and list sizes" },
    }

    -- Layout strategy: each label is its OWN FontString with setPanelWidth,
    -- so when the panel scales the label re-wraps and its height grows /
    -- shrinks naturally. The Run button anchors to the label's TOPLEFT
    -- (offset to the left of the label column), so a label that wraps to
    -- 2+ lines doesn't push the button down - the button stays aligned
    -- with the first line. The next row anchors to the previous label's
    -- BOTTOMLEFT, so wrapping pushes everything below it down cleanly.
    local LABEL_COL_X = 54 -- button width (48) + 6 px gap; labels start at this x
    local PANEL_RIGHT_PAD = 16 -- same right margin the original cmdText used
    local prevAnchor = cmdHeader
    for i, row in ipairs(SLASH_ROWS) do
        local gap = (i == 1) and -8 or -10
        -- First row indents LABEL_COL_X to clear the button column;
        -- subsequent rows inherit the X position from the previous label
        -- (no further offset, otherwise they'd staircase to the right).
        local xOffset = (i == 1) and LABEL_COL_X or 0

        local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", xOffset, gap)
        fs:SetJustifyH("LEFT")
        if fs.SetWordWrap then
            fs:SetWordWrap(true)
        end
        -- Width = panel width - (left inset for label column) - (right pad).
        -- setPanelWidth subtracts the given xOffset from EC_PANEL_WIDTH and
        -- re-applies on resize, so the wrapped height tracks panel scale.
        EC_compCache.setPanelWidth(fs, LABEL_COL_X + PANEL_RIGHT_PAD)
        fs:SetText(row.label)

        if row.run then
            local btn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
            btn:SetSize(48, 20)
            -- LEFT-to-LEFT vertically-centres the button against the
            -- label's centre line, so single-line labels (the common
            -- case) read as perfectly aligned. The button still sits in
            -- the column to the left of the label via -LABEL_COL_X.
            -- For a wrapped multi-line label, the button centres on the
            -- whole wrapped block, which is acceptable visual drift.
            btn:SetPoint("LEFT", fs, "LEFT", -LABEL_COL_X, 0)
            btn:SetText("Run")
            local runCmd = row.run
            btn:SetScript("OnClick", function()
                local handler = SlashCmdList and SlashCmdList["EBONCLEARANCE"]
                if handler then
                    handler(runCmd)
                end
                PlaySound("igMainMenuOptionCheckBoxOn")
            end)
        end

        prevAnchor = fs
    end

    -- v2.12.0: size the scroll content to fit the bottom-most widget so
    -- the scroll bar engages when the Interface Options frame is too
    -- short to show everything (matches the Scavenger / Merchant /
    -- Profiles / Import-Export panels' pattern).
    NS.FitScrollContent(content, prevAnchor)
end

MainOptions:SetScript("OnShow", function(self)
    -- RefreshStats / ResetLifetimeStats live on NS at file scope (see
    -- top of this file) and write to the Stats sub-panel via
    -- _G["EbonClearanceOptionsStats"]. The Main panel no longer renders
    -- stats itself (v2.36.x split), but we still trigger a refresh on
    -- show so the Stats panel stays up to date when users tab over.
    EC_compCache.initPanel(self, function()
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, function(buildSelf, content)
        -- v2.12.0: scroll-wrap the Main panel so the Slash Commands block
        -- at the bottom doesn't overlap the OK/Cancel button strip when
        -- the Interface Options frame is shorter than the panel content.
        -- Scavenger and Merchant Settings are wrapped the same way.
        BuildMainPanel(buildSelf, content)
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, true)
end)
