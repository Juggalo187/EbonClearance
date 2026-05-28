-- EbonClearance_StatsPanel - dedicated stats sub-panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Holds every stat widget (statsMoney, statsSold, statsDeleted, statsRepairs,
-- statsRepairCost, statsSessionGPH, statsBestGPH + zone/when sub-line,
-- statsAvgWorth, statsMostSold, statsNote, EbonClearanceResetStatsBtn).
-- These used to live on the Main panel; v2.36.x split them out so the Main
-- panel can read as a welcome page and Stats can grow.
--
-- RefreshStats (defined in EbonClearance_MainPanel.lua pre-split; re-homed
-- here post-split) writes to the panel.statsX attachments below. The
-- attachments are the public contract with the rest of the addon:
-- EbonClearance_Events.lua's data-change handlers call RefreshStats; this
-- file owns the panel object that holds the FontStrings.

local NS = select(2, ...)
local EC_compCache = NS.compCache

local StatsPanel = CreateFrame("Frame", "EbonClearanceOptionsStats", InterfaceOptionsFramePanelContainer)
StatsPanel.name = "Stats"
StatsPanel.parent = "EbonClearance"

StatsPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(refreshSelf)
        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end, function(buildSelf, content)
        -- Alias buildSelf as `panel` so the explicit panel.statsX = fs
        -- assignments below stay literal. The test suite scans for
        -- `panel.statsMoney`, `panel.statsSessionGPH`, `panel.statsBestGPH`
        -- as the public contract with RefreshStats - keep the literals.
        local panel = buildSelf
        -- Heading. Same -16 y offset as Keep List / Sell List etc.
        local heading = NS.MakeHeader(content, "Stats", -16)
        NS.AddHelpIcon(content, heading, "LEFT", "RIGHT", 8, 0, "stats-overview")

        -- Lifetime + session stats. Each panel.statsX is the contract
        -- with RefreshStats (called from EbonClearance_Events.lua's data
        -- handlers). Order matches the old MainPanel layout for visual
        -- continuity. The explicit panel.statsX = fs assignments below
        -- are the contract the test suite scans for - keep them literal
        -- (no table-driven indirection) so the static-pattern check can
        -- find them.
        local function makeStatRow(yOffset, anchorPrev)
            local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            if anchorPrev == content then
                fs:SetPoint("TOPLEFT", content, "TOPLEFT", 16, yOffset)
            else
                fs:SetPoint("TOPLEFT", anchorPrev, "BOTTOMLEFT", 0, yOffset)
            end
            EC_compCache.setPanelWidth(fs, 16)
            fs:SetJustifyH("LEFT")
            return fs
        end

        local money = makeStatRow(-44, content)
        panel.statsMoney = money
        local sold = makeStatRow(-6, money)
        panel.statsSold = sold
        local deleted = makeStatRow(-6, sold)
        panel.statsDeleted = deleted
        local repairs = makeStatRow(-6, deleted)
        panel.statsRepairs = repairs
        local repairCost = makeStatRow(-6, repairs)
        panel.statsRepairCost = repairCost
        local sessionGPH = makeStatRow(-6, repairCost)
        panel.statsSessionGPH = sessionGPH
        local bestGPH = makeStatRow(-6, sessionGPH)
        panel.statsBestGPH = bestGPH
        local avgWorth = makeStatRow(-6, bestGPH)
        panel.statsAvgWorth = avgWorth
        -- v2.37.0: Sold-by-Quality breakdown. Multi-line FontString; the
        -- row height grows with the number of quality buckets that have
        -- nonzero counts (RefreshStats emits 1-8 indented rows). Width
        -- is registered via setPanelWidth so live panel-resize keeps
        -- the text flush. SetWordWrap stays at the default TRUE so the
        -- \n line breaks RefreshStats emits actually render as multiple
        -- lines (SetWordWrap(false) would collapse them to a single
        -- truncated line ending in "...").
        local qualityBreakdown = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        qualityBreakdown:SetPoint("TOPLEFT", avgWorth, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(qualityBreakdown, 16)
        qualityBreakdown:SetJustifyH("LEFT")
        qualityBreakdown:SetJustifyV("TOP")
        panel.statsQualityBreakdown = qualityBreakdown
        -- v2.37.x: "Deleted by Quality" mirrors "Sold by Quality" -
        -- per-rarity counts only (no copper, deletion produces no
        -- money). Rendered when DB.deletedItemsByQuality has any
        -- non-zero entry; reads "None yet" otherwise.
        local deletedByQuality = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        deletedByQuality:SetPoint("TOPLEFT", qualityBreakdown, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(deletedByQuality, 16)
        deletedByQuality:SetJustifyH("LEFT")
        deletedByQuality:SetJustifyV("TOP")
        panel.statsDeletedByQuality = deletedByQuality
        -- v2.37.0: panel.statsMostSold is now a multi-line "Top 5 Most
        -- Sold" widget. The name is preserved because Test 80 docs
        -- reference it as a contract surface; the format changed from
        -- single-line "Most Sold Item: ..." to a heading + up to five
        -- ranked rows. RefreshStats writes the full block via
        -- table.concat with "\n" so it grows row by row.
        local mostSold = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        mostSold:SetPoint("TOPLEFT", deletedByQuality, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(mostSold, 16)
        mostSold:SetJustifyH("LEFT")
        mostSold:SetJustifyV("TOP")
        panel.statsMostSold = mostSold
        -- v2.37.x: Top 5 Most Deleted mirrors Top 5 Most Sold.
        -- Reuses GetTopNItems over DB.deletedItemCounts.
        local mostDeleted = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        mostDeleted:SetPoint("TOPLEFT", mostSold, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(mostDeleted, 16)
        mostDeleted:SetJustifyH("LEFT")
        mostDeleted:SetJustifyV("TOP")
        panel.statsMostDeleted = mostDeleted

        -- v2.37.0: Process Bags lifetime totals (Disenchant / Mill /
        -- Prospect / Pick Lock). Multi-line; RefreshStats emits a
        -- header plus one row per nonzero counter.
        local processTotals = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        processTotals:SetPoint("TOPLEFT", mostDeleted, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(processTotals, 16)
        processTotals:SetJustifyH("LEFT")
        processTotals:SetJustifyV("TOP")
        panel.statsProcessTotals = processTotals

        -- v2.37.0: Top zones by lifetime gold earned. RefreshStats emits
        -- a header plus up to five ranked zone rows (gold-desc) so the
        -- player can see where they've grossed the most.
        local topZones = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        topZones:SetPoint("TOPLEFT", processTotals, "BOTTOMLEFT", 0, -10)
        EC_compCache.setPanelWidth(topZones, 16)
        topZones:SetJustifyH("LEFT")
        topZones:SetJustifyV("TOP")
        panel.statsTopZones = topZones

        -- Footnote about buyback exclusion.
        local statsNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        statsNote:SetPoint("TOPLEFT", topZones, "BOTTOMLEFT", 0, -4)
        EC_compCache.setPanelWidth(statsNote, 16)
        statsNote:SetJustifyH("LEFT")
        statsNote:SetText("|cff888888Stats don't account for items bought back from a merchant.|r")
        panel.statsNote = statsNote

        -- Reset Session button. Clears the in-memory session deltas (the
        -- "session +X" suffixes next to each stat) without touching the
        -- lifetime totals. NS.ResetSession lives in EbonClearance_Events.lua.
        local resetSessionBtn = CreateFrame("Button", "EbonClearanceResetSessionBtn", content, "UIPanelButtonTemplate")
        resetSessionBtn:SetSize(170, 22)
        resetSessionBtn:SetPoint("TOPLEFT", statsNote, "BOTTOMLEFT", 0, -10)
        resetSessionBtn:SetText("Reset Session Stats")
        resetSessionBtn:SetScript("OnClick", function()
            if NS.ResetSession then
                NS.ResetSession()
            end
            if NS.RefreshStats then
                NS.RefreshStats()
            end
        end)

        -- Reset Lifetime button (same global name + behaviour as before).
        -- Anchored next to Reset Session so both buttons sit on the same row.
        local resetBtn = CreateFrame("Button", "EbonClearanceResetStatsBtn", content, "UIPanelButtonTemplate")
        resetBtn:SetSize(170, 22)
        resetBtn:SetPoint("LEFT", resetSessionBtn, "RIGHT", 8, 0)
        resetBtn:SetText("Reset Lifetime Stats")
        resetBtn:SetScript("OnClick", function()
            local dialog = StaticPopup_Show("EC_CONFIRM_RESET_LIFETIME")
            if dialog then
                dialog.data = function()
                    if NS.ResetLifetimeStats then
                        NS.ResetLifetimeStats()
                    end
                    if NS.RefreshStats then
                        NS.RefreshStats()
                    end
                end
            end
        end)

        if NS.RefreshStats then
            NS.RefreshStats()
        end
    end)
end)

-- v2.36.x: registered with InterfaceOptions_AddCategory from
-- EbonClearance_Events.lua (right after the Main panel) so the sub-panel
-- sort order (Main / Stats / Merchant / ...) is controlled at one place.
