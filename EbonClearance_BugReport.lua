-- EbonClearance_BugReport - diagnostic snapshot builder + display frame.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. Smallest self-contained UI cluster: ~430 LOC of pure formatting
-- code with one external call site (the bug-report button on the main
-- settings panel) and read-only access to a handful of DB / cache fields.
--
-- Exposed as NS.ShowBugReport for the button to call.
--
-- Cross-file dependencies read inline:
--   * NS.compCache (state)       - lootCycleState, lastScavengerOut,
--                                   addonDismissed (promoted in Stage 8 prep)
--   * NS.DB / NS.ADB             - captured at function entry
--   * NS.PrintNice / PrintNicef  - chat output
--   * NS.GetVersion              - exposed by EbonClearance.lua
--   * NS.GetFreeBagSlots         - exposed by EbonClearance.lua
--   * NS.EnsureDB                - called once before reading DB fields

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- Bug report diagnostic snapshot
local function EC_CopperToPlainText(copper)
    if not copper or copper <= 0 then
        return "0"
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100
    if gold > 0 then
        return string.format("%dg %ds %dc", gold, silver, cop)
    elseif silver > 0 then
        return string.format("%ds %dc", silver, cop)
    else
        return string.format("%dc", cop)
    end
end

local function EC_BuildBugReport()
    local DB = NS.DB
    local ADB = NS.ADB
    NS.EnsureDB()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end

    local version = NS.GetVersion()
    local player = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    local dateStr = date("%Y-%m-%d %H:%M")
    local className = UnitClass and UnitClass("player") or "Unknown"
    local level = UnitLevel and UnitLevel("player") or 0
    local locale = GetLocale and GetLocale() or "Unknown"

    add("=== EbonClearance Bug Report ===")
    add("Version: " .. version)
    -- Watermark: deterministic hash of `EbonClearance@<version>`. Matches
    -- _G.__EbonClearance_watermark; surfaced here so a report can be tied
    -- back to a specific build, and so a modified / repackaged copy is
    -- visible (the hash would not match the canonical value for that
    -- version). See docs/ADDON_GUIDE.md "Fingerprint and watermark".
    add("Watermark: " .. tostring(_G.__EbonClearance_watermark or "(missing)"))
    add("Character: " .. player .. " - " .. realm)
    add("Class / Level: " .. className .. " / " .. tostring(level))
    add("Locale: " .. tostring(locale))
    add("Date: " .. dateStr)
    add("")

    -- v2.13.1 Live State section. Captures the runtime context at the
    -- exact moment of report. Useful for diagnosing merchant-mode
    -- target-vs-npc mismatches, combat-deferral cases, and "addon not
    -- doing anything" reports where the cause is a live unit / frame
    -- state the static settings can't show.
    add("--- Live State ---")
    add("In Combat: " .. tostring(InCombatLockdown and InCombatLockdown() or false))
    add("Mounted: " .. tostring(IsMounted and IsMounted() or false))
    local targetExists = UnitExists and UnitExists("target")
    add("Target: " .. ((targetExists and UnitName("target")) or "(none)"))
    local npcExists = UnitExists and UnitExists("npc")
    add("NPC (interact): " .. ((npcExists and UnitName("npc")) or "(none)"))
    local merchantOpen = MerchantFrame and MerchantFrame:IsShown() or false
    add("Merchant Open: " .. tostring(merchantOpen))
    local totalBagSlots = 0
    for bag = 0, 4 do
        totalBagSlots = totalBagSlots + (GetContainerNumSlots(bag) or 0)
    end
    add("Free Bags: " .. tostring(NS.GetFreeBagSlots()) .. " / " .. tostring(totalBagSlots))
    add("")

    add("--- Settings ---")
    add("Enabled: " .. tostring(DB.enabled))
    add("Merchant Mode: " .. tostring(DB.merchantMode))
    add("Repair Gear: " .. tostring(DB.repairGear))
    add("Repair via Guild Bank: " .. tostring(DB.repairUseGuildBank))
    add("Keep Bags Open: " .. tostring(DB.keepBagsOpen))
    add("Enable Deletion: " .. tostring(DB.enableDeletion))
    add("Vendor Interval: " .. tostring(DB.vendorInterval))
    add("Max Items Per Run: " .. tostring(DB.maxItemsPerRun))
    add("Fast Mode: " .. tostring(DB.fastMode))
    add("Turbo Mode: " .. tostring(DB.turboMode))
    -- v2.10.0 / v2.11.0 / v2.13.0 auto-protect family - omitting these
    -- left a blind spot in earlier reports for "why is X being kept?"
    -- diagnostics where the auto-protect path was the answer.
    add("Auto-Add Equipped: " .. tostring(DB.autoAddEquipped))
    add("Auto-Protect Upgrades: " .. tostring(DB.autoProtectUpgrades))
    add("Auto-Protect Equipment Sets: " .. tostring(DB.autoProtectEquipmentSets))
    add("Protect Affixed Rare Items: " .. tostring(DB.protectAffixedRareItems))
    add("Protect Chance-on-Hit Items: " .. tostring(DB.protectChanceOnHitItems))
    add("Protect Unlearned Tomes: " .. tostring(DB.protectUnlearnedTomes))
    add("Protect All Tomes: " .. tostring(DB.protectAllTomes))
    -- v2.30.x: the per-character allowlist feature was decommissioned;
    -- DB.enableOnlyListedChars is force-disabled in EnsureDB and the
    -- bug report no longer surfaces the legacy fields.
    add("")

    add("--- Scavenger ---")
    add("Summon Greedy: " .. tostring(DB.summonGreedy))
    add("Summon Delay: " .. tostring(DB.summonDelay))
    add("Summon Only Out Of Combat: " .. tostring(DB.summonOnlyOutOfCombat))
    add("Mute Greedy: " .. tostring(DB.muteGreedy))
    add("Auto-Loot Cycle: " .. tostring(DB.autoLootCycle))
    add("Bag Full Threshold: " .. tostring(DB.bagFullThreshold))
    add("Auto-Open Containers: " .. tostring(DB.autoOpenContainers))
    add("Fast Loot: " .. tostring(DB.fastLoot))
    -- Companion-name overrides. Most users leave these as defaults; when a
    -- user has customised one and then reports a "addon doesn't recognise
    -- my Goblin Merchant" / "Scavenger isn't being detected" issue, the
    -- override is usually the cause.
    -- v2.13.3: dropped the DB.petName branch (field had no setter, copy-
    -- paste artifact of the v2.9.0 scavengerName rename); the real pet
    -- field is DB.scavengerName.
    -- v2.13.5: only show these lines when the value actually differs
    -- from the default that EnsureDB seeds. The previous "non-empty"
    -- check matched every install because EnsureDB always seeds these
    -- fields with default strings, so the "(override)" label was
    -- displayed even when no override was set. Also added the scavenger
    -- field which had a comment claiming it was "exposed elsewhere"
    -- but in fact wasn't surfaced in the report at all.
    if DB.merchantName and DB.merchantName ~= "" and DB.merchantName ~= "Goblin Merchant" then
        add("Merchant Name (override): " .. tostring(DB.merchantName))
    end
    if DB.scavengerName and DB.scavengerName ~= "" and DB.scavengerName ~= "Greedy scavenger" then
        add("Scavenger Name (override): " .. tostring(DB.scavengerName))
    end
    add("")

    -- v2.13.1 Runtime State section. Snapshots the in-flight loot-cycle
    -- and stuck-detection signals so a Discord report can pinpoint
    -- "why isn't the cycle progressing" cases without requiring a /reload
    -- or chat-log scrape.
    add("--- Runtime State ---")
    add("Loot Cycle State: " .. tostring(EC_compCache.lootCycleState or "?"))
    add("Scavenger Out: " .. tostring(EC_compCache.lastScavengerOut))
    add("Addon-Dismissed: " .. tostring(EC_compCache.addonDismissed))
    add("Scav Speech Heard This Session: " .. tostring(EC_compCache.scavSpeechEverHeard))
    if EC_compCache.bagFullSince and EC_compCache.bagFullSince > 0 then
        local elapsed = (GetTime and GetTime() or 0) - EC_compCache.bagFullSince
        add(string.format("Bag-Full Threshold Hit: %.1fs ago", elapsed))
    else
        add("Bag-Full Threshold Hit: -")
    end
    add("")

    add("--- Sell Rules ---")
    add("Quality Rules:")
    for q = 1, 4 do
        local r = DB.qualityRules and DB.qualityRules[q] or {}
        local rarityName = (q == 1) and "White" or (q == 2) and "Green" or (q == 3) and "Blue" or "Epic"
        local capStr = (r.maxILvl and r.maxILvl > 0) and tostring(r.maxILvl) or "no cap"
        local bindStr = tostring(r.bindFilter or "any")
        add(
            string.format(
                "  %s: enabled=%s, max iLvl=%s, useEquipped=%s, bind=%s",
                rarityName,
                tostring(r.enabled),
                capStr,
                tostring(r.useEquippedILvl),
                bindStr
            )
        )
    end
    add("Active Profile: " .. tostring(DB.activeProfileName))
    add("Sell List Items: " .. tostring(NS.CountItems(DB.whitelist)))
    add("Account Sell List Items: " .. tostring(ADB and NS.CountItems(ADB.whitelist) or 0))
    add("Keep List Items: " .. tostring(NS.CountItems(DB.blacklist)))
    add("Delete List Items: " .. tostring(NS.CountItems(DB.deleteList)))
    add("")

    -- v2.13.1 Auto-Protected Breakdown. Walks DB.blacklistAuto and groups
    -- entries by origin tag so a user reporting "my Keep list is huge,
    -- why?" can see at a glance which auto-protect path is responsible.
    -- Legacy entries (v2.10.0 / v2.11.0 stamped a boolean true rather
    -- than a string tag) bucket separately so they're visible for the
    -- /ec clean upgrades workflow.
    if type(DB.blacklistAuto) == "table" then
        local cWorn, cUpgrade, cSet, cLegacy = 0, 0, 0, 0
        for _, tag in pairs(DB.blacklistAuto) do
            if tag == "equipped" then
                cWorn = cWorn + 1
            elseif tag == "upgrade" then
                cUpgrade = cUpgrade + 1
            elseif tag == "set" then
                cSet = cSet + 1
            elseif tag == true then
                cLegacy = cLegacy + 1
            end
        end
        local total = cWorn + cUpgrade + cSet + cLegacy
        if total > 0 then
            add("--- Auto-Protected Breakdown ---")
            add("Equipped (Worn): " .. cWorn)
            add("Upgrade: " .. cUpgrade)
            add("Set: " .. cSet)
            if cLegacy > 0 then
                add("Legacy (untagged): " .. cLegacy)
            end
            add("Total auto-tagged: " .. total)
            add("")
        end
    end

    add("--- Profiles ---")
    local names = {}
    for name in pairs(DB.whitelistProfiles) do
        if type(name) == "string" then
            names[#names + 1] = name
        end
    end
    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)
    for i = 1, #names do
        local wlCount = NS.CountItems(DB.whitelistProfiles[names[i]])
        local blCount = DB.blacklistProfiles[names[i]] and NS.CountItems(DB.blacklistProfiles[names[i]]) or 0
        local tag = (names[i] == DB.activeProfileName) and " (active)" or ""
        add(names[i] .. " (" .. wlCount .. " sell, " .. blCount .. " keep)" .. tag)
    end
    add("")

    add("--- Stats ---")
    add("Total Money Made: " .. EC_CopperToPlainText(DB.totalCopper or 0))
    add("Total Items Sold: " .. tostring(DB.totalItemsSold or 0))
    add("Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0))
    add("Total Repairs: " .. tostring(DB.totalRepairs or 0))
    add("Total Repair Cost: " .. EC_CopperToPlainText(DB.totalRepairCopper or 0))
    add("")

    -- Capability flags. The bag-rendering layer and auction-pricing source
    -- can interact (or fail to interact) with EC's hooks and integrations;
    -- capturing which capabilities are present disambiguates "bag
    -- decoration missing" / "tooltip overlaps" reports without a
    -- follow-up. Generic flags so the report doesn't depend on specific
    -- third-party addon names.
    add("--- Environment Capabilities ---")
    local hostBagUI = (_G.Bagnon ~= nil) or (_G.BagnonFrame ~= nil) or (_G.ArkInventory ~= nil) or (_G.ElvUI ~= nil)
    add("Host bag UI detected: " .. (hostBagUI and "yes" or "no"))
    add(
        "Host bag-UI category API: "
            .. ((_G.LibStub and pcall(_G.LibStub, "AceAddon-3.0", true)) and "available" or "absent")
    )
    add("LibItemSearch: " .. (_G.LibStub and _G.LibStub("LibItemSearch-1.0", true) and "yes" or "no"))
    add(
        "Auction pricing source: "
            .. ((_G.Atr_GetAuctionBuyout ~= nil or _G.Auctionator ~= nil) and "detected" or "absent")
    )
    add(
        "Project Ebonhold extraction catalog: "
            .. ((_G.ExtractionService and _G.ExtractionService.learnedAffixes) and "exposed" or "absent")
    )

    add("")
    add("--- Bag Display ---")
    add("Sell-border tint enabled: " .. (DB.sellBorderEnabled and "yes" or "no"))
    if DB.sellBorderCategories then
        -- v2.30.x: per-category sell-border colours replaced the
        -- single DB.sellBorderColor. Dump each category's enable +
        -- colour so bug reports surface user-customised tint state.
        local catOrder = { "delete", "accountSell", "charSell", "junk", "rule" }
        for _, key in ipairs(catOrder) do
            local entry = DB.sellBorderCategories[key]
            if entry and entry.color then
                local c = entry.color
                add(
                    string.format(
                        "  %-12s enabled=%s  r=%.2f g=%.2f b=%.2f a=%.2f",
                        key,
                        entry.enabled and "yes" or "no ",
                        c.r or 0,
                        c.g or 0,
                        c.b or 0,
                        c.a or 0
                    )
                )
            end
        end
    end
    local decoratedCount = 0
    if EC_compCache.sellBorderButtons then
        for _ in pairs(EC_compCache.sellBorderButtons) do
            decoratedCount = decoratedCount + 1
        end
    end
    add("Decorated slot buttons (this session): " .. tostring(decoratedCount))
    add("Host bag-UI border hook installed: " .. (EC_compCache._hostBagBorderHookInstalled and "yes" or "no"))

    add("")
    add("--- Allow Lists ---")
    local allowedItemCount = 0
    if ADB and ADB.allowedItems then
        for _ in pairs(ADB.allowedItems) do
            allowedItemCount = allowedItemCount + 1
        end
    end
    local allowedAffixCount = 0
    if ADB and ADB.allowedAffixes then
        for _ in pairs(ADB.allowedAffixes) do
            allowedAffixCount = allowedAffixCount + 1
        end
    end
    local knownAffixCount = 0
    if EC_compCache.knownAffixDescriptions then
        for _ in pairs(EC_compCache.knownAffixDescriptions) do
            knownAffixCount = knownAffixCount + 1
        end
    end
    add("Chance-on-hit allow list (per-itemID): " .. tostring(allowedItemCount))
    add("Random-affix allow list (per-description): " .. tostring(allowedAffixCount))
    add("Known affix descriptions in session set: " .. tostring(knownAffixCount))
    add("Allow exact-rank duplicates: " .. (DB.affixAllowExactDupes and "yes" or "no"))
    -- v2.37.0 (Borrow A): surface the affix debug log status. When the
    -- log has rows, prompt the reporter to also include /ec affixdebug
    -- dump so the maintainer gets the structured event trail.
    local affixDebugRows = (ADB and ADB.affixDebug and type(ADB.affixDebug.rows) == "table") and #ADB.affixDebug.rows or 0
    add("Affix debug log: "
        .. ((ADB and ADB.affixDebugEnabled) and "ON" or "off")
        .. ", "
        .. tostring(affixDebugRows)
        .. " row(s) recorded"
        .. (affixDebugRows > 0 and " - run /ec affixdebug dump and include that output too" or "")
    )

    add("")
    add("--- Bags ---")
    add("Free Slots: " .. tostring(NS.GetFreeBagSlots()))

    -- v2.37.0: installed addons section. Walks GetNumAddOns() and
    -- lists every LOADED addon by title + version. Maintainer can
    -- spot bag-management / vendor / loot addons that may race with
    -- EC's hooks, which makes "the addon isn't doing X" reports
    -- diagnosable from the first read rather than after a back-and-
    -- forth about the user's setup. Disabled addons are excluded -
    -- they're not running and can't conflict.
    add("")
    add("--- Loaded Addons ---")
    local n = GetNumAddOns and GetNumAddOns() or 0
    if n == 0 then
        add("(GetNumAddOns unavailable)")
    else
        local entries = {}
        for i = 1, n do
            local name, title, _, _, _, reason, _ = GetAddOnInfo(i)
            local loaded = IsAddOnLoaded and IsAddOnLoaded(i)
            if loaded then
                local meta = GetAddOnMetadata and GetAddOnMetadata(i, "Version") or nil
                local rawTitle = (title and title ~= "") and title or (name or "?")
                -- Strip Blizzard's colour escapes so the report stays
                -- pasteable into plain-text contexts.
                local cleanTitle = rawTitle:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                entries[#entries + 1] = {
                    name = name or "?",
                    title = cleanTitle,
                    version = meta or "",
                }
            end
        end
        table.sort(entries, function(a, b) return a.name < b.name end)
        if #entries == 0 then
            add("(no addons reported as loaded)")
        else
            add("Loaded: " .. tostring(#entries))
            for _, e in ipairs(entries) do
                if e.version ~= "" then
                    add("  " .. e.name .. " (" .. e.title .. ") v" .. e.version)
                else
                    add("  " .. e.name .. " (" .. e.title .. ")")
                end
            end
        end
    end

    return table.concat(lines, "\n")
end

local EC_bugReportFrame = nil

-- v2.37.0: the BugReport display frame is now shared between the
-- /ec bugreport snapshot path and the new /ec affixdebug dump path.
-- Title FontString is hoisted to the frame so callers can swap the
-- header text; the rest of the frame chrome (size, scroll, edit box,
-- close button, drag) is identical between both call sites.
local function EC_EnsureCopyFrame()
    if EC_bugReportFrame then
        return EC_bugReportFrame
    end
    local f = CreateFrame("Frame", "EbonClearanceBugReportFrame", UIParent)
    f:SetSize(460, 360)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    tinsert(UISpecialFrames, "EbonClearanceBugReportFrame")

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText("EbonClearance Bug Report")
    f.title = title

    local hint = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -4)
    hint:SetText("|cff888888Press Ctrl+A then Ctrl+C to copy this report.|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)

    local scroll = CreateFrame("ScrollFrame", "EbonClearanceBugReportScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -50)
    scroll:SetPoint("BOTTOMRIGHT", -32, 16)

    local editBox = CreateFrame("EditBox", "EbonClearanceBugReportBox", scroll)
    editBox:SetAutoFocus(false)
    editBox:SetMultiLine(true)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetWidth(400)
    editBox:SetText("")
    editBox:SetScript("OnEscapePressed", function(s)
        s:ClearFocus()
    end)
    scroll:SetScrollChild(editBox)

    f.editBox = editBox
    EC_bugReportFrame = f
    return f
end

local function EC_ShowCopyFrame(titleText, bodyText, chatHint)
    local f = EC_EnsureCopyFrame()
    if f.title and titleText then
        f.title:SetText(titleText)
    end
    f.editBox:SetText(bodyText or "")
    f:Show()
    f.editBox:HighlightText()
    f.editBox:SetFocus()
    if chatHint then
        NS.PrintNice(chatHint)
    end
end

local function EC_ShowBugReport()
    EC_ShowCopyFrame(
        "EbonClearance Bug Report",
        EC_BuildBugReport(),
        "Bug report generated. Copy the text from the window."
    )
end

-- v2.37.0 (Borrow A): serialise ADB.affixDebug to a human-readable
-- dump. Rows are emitted one per line in chronological order with
-- their kind, timestamp, and key/value pairs from the data table.
-- Output is plain text (not JSON) so it pastes cleanly into Discord
-- threads / GitHub issues without code-fence escaping headaches.
local function EC_BuildAffixDebugDump()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end
    add("=== EbonClearance Affix Debug Dump ===")
    add("Generated: " .. (date and date("%Y-%m-%d %H:%M:%S") or "?"))
    add("Player: " .. (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?"))
    add("Addon: " .. (NS.GetVersion and NS.GetVersion() or "?"))

    local ADB = NS.ADB
    local dump = ADB and ADB.affixDebug
    if not dump or type(dump.rows) ~= "table" or #dump.rows == 0 then
        add("")
        add("No rows recorded. Enable with |cffffff00/ec affixdebug on|r, reproduce, then re-run dump.")
        return table.concat(lines, "\n")
    end
    add("Enabled: " .. (ADB.affixDebugEnabled and "yes" or "no (still showing previously recorded rows)"))
    add("Rows: " .. tostring(#dump.rows))
    add("Sequence high: " .. tostring(dump.sequence or 0))
    add("")
    for _, row in ipairs(dump.rows) do
        local stamp = row.date or string.format("t+%.2f", row.time or 0)
        local parts = {}
        if type(row.data) == "table" then
            for k, v in pairs(row.data) do
                parts[#parts + 1] = string.format("%s=%s", tostring(k), tostring(v))
            end
            table.sort(parts)
        end
        add(string.format(
            "#%-5d [%s] %s | %s",
            row.n or 0,
            stamp,
            row.kind or "?",
            table.concat(parts, ", ")
        ))
    end
    return table.concat(lines, "\n")
end

local function EC_ShowAffixDebugDump()
    EC_ShowCopyFrame(
        "EbonClearance Affix Debug Dump",
        EC_BuildAffixDebugDump(),
        "Affix debug dump generated. Copy the text from the window."
    )
end

NS.ShowBugReport = EC_ShowBugReport
NS.ShowAffixDebugDump = EC_ShowAffixDebugDump
