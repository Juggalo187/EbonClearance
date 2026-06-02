-- EbonClearance_GuildPanel - Guild sharing sub-panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Interface Options sub-panel for guild-share: opt-in toggle,
-- best farming zones aggregate, guild totals, and a manual refresh
-- button. Registered with InterfaceOptions_AddCategory from
-- EbonClearance_Events.lua (separate task) so sort order is
-- controlled at one place.
--
-- Dependencies satisfied by NS:
--   * NS.compCache (Core)           - initPanel, setPanelWidth
--   * NS.MakeHeader / NS.MakeLabel  - panel text primitives
--   * NS.AddCheckbox                - opt-in toggle
--   * NS.FitScrollContent           - scroll height sizing
--   * NS.CopperToColoredText        - coloured gold strings
--   * NS.GuildShare                 - GetAggregate, RequestNow
--   * NS.Delay                      - deferred repaint after request

local NS = select(2, ...)
local EC_compCache = NS.compCache

local GuildPanel = CreateFrame(
    "Frame",
    "EbonClearanceOptionsGuild",
    InterfaceOptionsFramePanelContainer
)
GuildPanel.name = "Guild"
GuildPanel.parent = "EbonClearance"

-- repaintGuildPanel: shared repaint body used by both the OnShow
-- refresh callback and NS.RefreshGuildPanel. Forward-declared so the
-- OnShow closure and the NS exposure both capture the same upvalue.
local repaintGuildPanel

repaintGuildPanel = function()
    local panel = GuildPanel
    if not panel._guildZonesFS or not panel._guildTotalsFS then
        return
    end
    if not (NS.GuildShare and NS.GuildShare.GetAggregate) then
        return
    end
    local agg = NS.GuildShare.GetAggregate()

    -- Best Zones block.
    if panel._guildZonesFS then
        if agg.zones and next(agg.zones) then
            -- Collect entries and sort copper descending.
            local entries = {}
            for name, z in pairs(agg.zones) do
                entries[#entries + 1] = {
                    name = name,
                    copper = z.copper or 0,
                    contributors = z.contributors or 0,
                }
            end
            table.sort(entries, function(a, b)
                if a.copper == b.copper then
                    return a.name < b.name
                end
                return a.copper > b.copper
            end)
            local rows = {}
            local limit = math.min(5, #entries)
            for i = 1, limit do
                local e = entries[i]
                local copperStr = NS.CopperToColoredText
                    and NS.CopperToColoredText(e.copper)
                    or tostring(e.copper)
                rows[i] = e.name
                    .. " - "
                    .. copperStr
                    .. " (from "
                    .. e.contributors
                    .. ")"
            end
            panel._guildZonesFS:SetText(table.concat(rows, "\n"))
        else
            panel._guildZonesFS:SetText("No zones shared yet.")
        end
    end

    -- Guild Totals block.
    if panel._guildTotalsFS then
        if agg.memberCount and agg.memberCount > 0 then
            local copperStr = NS.CopperToColoredText
                and NS.CopperToColoredText(agg.totalCopper or 0)
                or tostring(agg.totalCopper or 0)
            panel._guildTotalsFS:SetText(
                "Members shared: " .. (agg.memberCount or 0) .. "\n"
                .. "Combined gold: " .. copperStr .. "\n"
                .. "Combined items sold: " .. (agg.totalItems or 0)
            )
        else
            panel._guildTotalsFS:SetText(
                "Open with guildmates online, or click Refresh."
                .. " Needs at least one other member sharing."
            )
        end
    end
end

GuildPanel:SetScript("OnShow", function(self)
    EC_compCache.initPanel(self, function(refreshSelf)
        -- Refresh pass: repaint data rows on subsequent OnShow.
        repaintGuildPanel()
    end, function(buildSelf, content)
        -- Build pass: runs once on the first OnShow.

        local heading = NS.MakeHeader(content, "Guild", -16)

        local descLabel = NS.MakeLabel(
            content,
            "See your guild's best farming zones."
                .. " Everything here is anonymous and guild/group only.",
            16,
            -44
        )

        -- Opt-in checkbox. Reads/writes the top-level SavedVariables field
        -- directly (no DB proxy upvalue), matching the version-alert toggle
        -- on the Main panel.
        local optInCB = NS.AddCheckbox(
            content,
            "EbonClearanceGuildShareCB",
            descLabel,
            "Share my farming data with my guild (anonymous)",
            function()
                return EbonClearanceDB and EbonClearanceDB.shareGuildData
            end,
            function(v)
                if EbonClearanceDB then
                    EbonClearanceDB.shareGuildData = v
                end
            end,
            -10
        )

        -- "Guild's Best Farming Zones" sub-header + data FontString.
        local zonesHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        zonesHeader:SetPoint("TOPLEFT", optInCB, "BOTTOMLEFT", 0, -16)
        zonesHeader:SetText("Guild's Best Farming Zones")

        local zonesFS = content:CreateFontString(
            nil, "ARTWORK", "GameFontHighlight"
        )
        zonesFS:SetPoint("TOPLEFT", zonesHeader, "BOTTOMLEFT", 0, -8)
        EC_compCache.setPanelWidth(zonesFS, 16)
        zonesFS:SetJustifyH("LEFT")
        zonesFS:SetJustifyV("TOP")
        if zonesFS.SetWordWrap then
            zonesFS:SetWordWrap(true)
        end
        zonesFS:SetText("No zones shared yet.")
        buildSelf._guildZonesFS = zonesFS

        -- "Guild Totals" sub-header + data FontString.
        local totalsHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        totalsHeader:SetPoint("TOPLEFT", zonesFS, "BOTTOMLEFT", 0, -16)
        totalsHeader:SetText("Guild Totals")

        local totalsFS = content:CreateFontString(
            nil, "ARTWORK", "GameFontHighlight"
        )
        totalsFS:SetPoint("TOPLEFT", totalsHeader, "BOTTOMLEFT", 0, -8)
        EC_compCache.setPanelWidth(totalsFS, 16)
        totalsFS:SetJustifyH("LEFT")
        totalsFS:SetJustifyV("TOP")
        if totalsFS.SetWordWrap then
            totalsFS:SetWordWrap(true)
        end
        totalsFS:SetText(
            "Open with guildmates online, or click Refresh."
            .. " Needs at least one other member sharing."
        )
        buildSelf._guildTotalsFS = totalsFS

        -- Refresh button. Fires a broadcast request then plays the
        -- standard checkbox click sound.
        local refreshBtn = CreateFrame(
            "Button", nil, content, "UIPanelButtonTemplate"
        )
        refreshBtn:SetSize(110, 24)
        refreshBtn:SetPoint("TOPLEFT", totalsFS, "BOTTOMLEFT", 0, -12)
        refreshBtn:SetText("Refresh")
        refreshBtn:SetScript("OnClick", function()
            if NS.GuildShare and NS.GuildShare.RequestNow then
                NS.GuildShare.RequestNow()
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)

        -- Populate whatever the aggregate already holds at build time
        -- (may have data from earlier in the session).
        repaintGuildPanel()

        -- Size the scroll content to fit the last widget.
        if NS.FitScrollContent then
            NS.FitScrollContent(content, refreshBtn)
        end
    end, true)

    -- On every show (first and subsequent), broadcast a request and
    -- schedule a repaint so replies have time to arrive before display.
    if NS.GuildShare and NS.GuildShare.RequestNow then
        NS.GuildShare.RequestNow()
    end
    if NS.Delay then
        NS.Delay(3, function()
            if NS.RefreshGuildPanel then
                NS.RefreshGuildPanel()
            end
        end)
    end
end)

-- NS.RefreshGuildPanel: repaint the panel if it has been built.
-- Called by the GDAT handler in EbonClearance_GuildShare.lua so
-- the displayed data updates live as replies land.
NS.RefreshGuildPanel = function()
    local panel = _G["EbonClearanceOptionsGuild"]
    if not panel or not panel.inited then
        return
    end
    repaintGuildPanel()
end

-- v2.39.x: registered with InterfaceOptions_AddCategory from
-- EbonClearance_Events.lua so the sub-panel sort order is controlled
-- at one place.
