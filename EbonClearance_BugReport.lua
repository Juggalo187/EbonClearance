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
--   * NS.GetVersion              - exposed by EbonClearance_Events.lua
--   * NS.GetFreeBagSlots         - exposed by EbonClearance_Events.lua
--   * NS.EnsureDB                - called once before reading DB fields

local NS = select(2, ...)
local EC_compCache = NS.compCache
local L = NS.L
-- v2.38.3: bound where used so Test 65 (bind-IsInSet invariant) stays
-- satisfied for the /ec processdebug per-slot blacklist gate.
local IsInSet = NS.IsInSet

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
    -- v2.44.5: swap-cycle gate diagnostics. nohsi + Shandrax both hit a
    -- stuck swap (bags full, scavenger still out, cycle never advancing).
    -- These four fields pinpoint which gate of EC_HandleBagFullForCycle is
    -- blocking: vendorRunning stuck true is the leading suspect.
    if NS.GetSwapDiagnostics then
        local d = NS.GetSwapDiagnostics()
        add("Vendor Running: " .. tostring(d.vendorRunning))
        add("Goblin Summon Pending: " .. tostring(d.summonGoblinPending))
        add(string.format("Goblin Summon Timer: %.2fs", tonumber(d.summonGoblinTimer) or 0))
        add("Goblin Retry Count: " .. tostring(d.goblinRetryCount))
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
    add("Allow selling affixes you already have: " .. (DB.affixAllowExactDupes and "yes" or "no"))
    add("Sell affixes below rank: " ..
        ((DB.affixMinSellRank and DB.affixMinSellRank > 0) and tostring(DB.affixMinSellRank) or "off"))
    add("Auto-mark PvP gear (Resilience) for deletion: " .. (DB.autoMarkResilience and "yes" or "no"))
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
    -- v2.44.0: TOOLTIP strata + SetToplevel so the copy frame
    -- floats above the Interface Options window (DIALOG strata).
    -- Pre-v2.44.0 the frame was at DIALOG too, which meant any
    -- caller opening it from a panel button (the new "Current
    -- Rules" button, or /ec rules / bugreport / affixdebug dump
    -- typed while Interface Options was already open) saw the
    -- copy frame land behind the panel - effectively unreachable.
    -- Same pattern the Quickstart panel uses for the same reason.
    f:SetFrameStrata("TOOLTIP")
    f:SetToplevel(true)
    tinsert(UISpecialFrames, "EbonClearanceBugReportFrame")

    local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText(L["EbonClearance Bug Report"])
    f.title = title

    local hint = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -4)
    hint:SetText(L["|cff888888Press Ctrl+A then Ctrl+C to copy this report.|r"])

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
    -- v2.44.0: re-establish TOOLTIP strata + raise above any other
    -- TOOLTIP-strata frame on Show so callers from inside Interface
    -- Options (Current Rules button, /ec rules typed while options
    -- panel is up) actually see the popup in front.
    if f.SetFrameStrata then
        f:SetFrameStrata("TOOLTIP")
    end
    if f.Raise then
        f:Raise()
    end
    f.editBox:HighlightText()
    f.editBox:SetFocus()
    if chatHint then
        NS.PrintNice(chatHint)
    end
end

local function EC_ShowBugReport()
    EC_ShowCopyFrame(
        L["EbonClearance Bug Report"],
        EC_BuildBugReport(),
        L["Bug report generated. Copy the text from the window."]
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
        L["EbonClearance Affix Debug Dump"],
        EC_BuildAffixDebugDump(),
        L["Affix debug dump generated. Copy the text from the window."]
    )
end

-- v2.44.0: rule summary in plain English. Triggered by /ec rules.
-- Surfaces the actual order of operations EbonClearance uses to
-- decide DELETE vs SELL vs KEEP for each bag item, alongside the
-- player's currently active toggles. Asked for by ch (the addon
-- author) as a one-stop reference for understanding why a specific
-- item went the way it did - complements /ec sellinfo's per-item
-- trace by showing the whole rule book at a glance.
local function EC_BuildRuleSummary()
    local DB = NS.DB
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end
    local function onoff(v)
        return v and "|cff00ff00ON|r" or "|cffff4444OFF|r"
    end
    local function yesno(v, yesLabel, noLabel)
        if v then
            return "|cff00ff00" .. (yesLabel or "yes") .. "|r"
        else
            return "|cffff4444" .. (noLabel or "no") .. "|r"
        end
    end

    add("=== EbonClearance Rule Summary ===")
    add("Generated: " .. (date and date("%Y-%m-%d %H:%M:%S") or "?"))
    add("Player: " .. (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?"))
    add("Addon: " .. (NS.GetVersion and NS.GetVersion() or "?"))
    add("")
    add("Master switch: " .. onoff(DB and DB.enabled ~= false))

    -- v2.44.0: surface non-obvious rule conflicts at the top of the
    -- summary so a player who set the rank slider in one session and
    -- enabled "Keep blue/purple items with affixes" in another doesn't
    -- wonder why affixed items are still selling. The slider's positive-
    -- signal semantics correctly override the parent's keep intent, but
    -- it's easy to forget the slider value when "keep" is what's freshest
    -- in mind. Real player report (Serv) drove this addition.
    local rankFloor = DB.affixMinSellRank or 0
    local bothOn = (rankFloor > 0) and DB.affixAllowExactDupes
    if bothOn and DB.protectAffixedRareItems then
        add("")
        add("|cffffea80NOTE: 'Sell affixes below rank' (currently "
            .. rankFloor
            .. ") and 'Allow selling affixes you already have' are BOTH on.")
        add("  They are independent rules - each can release the affix protection on its own.")
        add("    - Slider rule sells affixed items at rank 1 through "
            .. (rankFloor - 1)
            .. " (any rank, extracted or not).")
        add("    - 'Already have' rule sells any rank you've already extracted (any rank,")
        add("      regardless of the slider).")
        add("  Result: an extracted rank "
            .. rankFloor
            .. "+ item still sells because the 'already have' rule fires for it.")
        add("  To make ONLY the slider govern: turn 'Allow selling affixes you already have' off.")
        add("  To make ONLY the 'already have' rule govern: set the slider to 0 (Off).|r")
    elseif rankFloor > 0 and DB.protectAffixedRareItems then
        add("")
        add("|cffffea80NOTE: 'Sell affixes below rank' is set to "
            .. rankFloor
            .. " - affixed items at rank 1 through "
            .. (rankFloor - 1)
            .. " WILL sell even though 'Keep blue/purple items with affixes' is on. "
            .. "Set the slider to 0 (Off) if you want to keep all affixed items.|r")
    elseif DB.affixAllowExactDupes and DB.protectAffixedRareItems then
        add("")
        add("|cffffea80NOTE: 'Allow selling affixes you already have' is on - "
            .. "affixed items at ranks you've already extracted WILL sell, regardless of "
            .. "'Keep blue/purple items with affixes'. Turn it off to keep all of them.|r")
    end

    add("")
    add("--- How EbonClearance handles each item in your bags ---")
    add("")
    add("Step 1: Should I DELETE this?")
    add("  Yes, if ALL of these apply:")
    add("    - The item is on your Delete List, AND")
    add("    - 'Allow items to be deleted' is on (currently " .. onoff(DB.enableDeletion) .. "), AND")
    add("    - It isn't held back by affix protection")
    add("      (or you've allowed selling that affix)")
    add("")
    add("  Extras:")
    add("    - 'Auto-delete on pickup' (" .. onoff(DB.autoDeleteOnPickup) .. ") destroys Delete List")
    add("      items the moment they enter your bags, no vendor needed.")
    add("    - 'Auto-mark PvP gear (Resilience)' (" .. onoff(DB.autoMarkResilience) .. ") adds items")
    add("      with Resilience to your Delete List automatically.")
    add("")
    add("Step 2: Should I SELL this?")
    add("  Yes, if ANY ONE of the reasons below matches (the rules don't")
    add("  cancel each other - each one independently triggers a sell):")
    add("    - It's grey junk with a vendor price")
    add("    - It's on your Sell List or Account Sell List")
    add("    - It matches a quality rule:")
    if DB and DB.qualityRules then
        local qNames = { "White", "Green", "Blue", "Purple" }
        for q = 1, 4 do
            local r = DB.qualityRules[q]
            local enabled = r and r.enabled
            local mode
            if r and r.useEquippedILvl then
                mode = "equipped iLvl"
            elseif r and r.maxILvl and r.maxILvl > 0 then
                mode = "max iLvl " .. tostring(r.maxILvl)
            else
                mode = "no cap"
            end
            local bind = (r and r.bindType) or "any"
            add(string.format(
                "        %s: %s  (%s, bind: %s)",
                qNames[q],
                yesno(enabled, "ON", "OFF"),
                mode,
                bind
            ))
        end
    end
    add("    - 'Allow selling affixes you already have' (" .. onoff(DB.affixAllowExactDupes) .. ")")
    add("      and you've already extracted this exact affix at this rank")
    add(string.format(
        "    - 'Sell affixes below rank' (currently %s) and this rank is below it",
        (DB.affixMinSellRank and DB.affixMinSellRank > 0) and tostring(DB.affixMinSellRank) or "off"
    ))
    add("")
    add("  ...AND NOTHING blocks it:")
    add("    - You're currently wearing it -> keep")
    add("    - It's on your Keep List -> keep")
    add("    - It's a quest item (auto-rule sweep only) -> keep")
    add("    - It belongs to a saved equipment set ("
        .. onoff(DB.autoProtectEquipmentSets) .. ") -> keep")
    add("    - It has an affix you haven't extracted, and")
    add("      'Keep blue/purple items with affixes' is " .. onoff(DB.protectAffixedRareItems) .. " -> keep")
    add("    - It has a 'Chance on hit:' proc, and")
    add("      'Keep items with chance-on-hit procs' is " .. onoff(DB.protectChanceOnHitItems) .. " -> keep")
    add("      (unless you've Alt+Right-Clicked 'Allow Sell' on that itemID)")
    add("    - It's an unlearned tome / recipe, and")
    add("      'Keep unlearned tomes and recipes' is " .. onoff(DB.protectUnlearnedTomes) .. " -> keep")
    add("")
    add("Step 3: Otherwise, keep it (default).")
    add("")
    add("--- Your current settings at a glance ---")
    add("  Master switch:                            " .. onoff(DB and DB.enabled ~= false))
    add("  Allow deletion at vendor:                 " .. onoff(DB.enableDeletion))
    add("  Auto-delete on pickup:                    " .. onoff(DB.autoDeleteOnPickup))
    add("  Auto-mark PvP gear (Resilience):          " .. onoff(DB.autoMarkResilience))
    add("  Keep gear you're wearing:                 " .. onoff(DB.autoAddEquipped))
    add("  Keep upgrades found in bags:              " .. onoff(DB.autoProtectUpgrades))
    add("  Keep items in saved equipment sets:       " .. onoff(DB.autoProtectEquipmentSets))
    add("  Keep blue/purple items with affixes:      " .. onoff(DB.protectAffixedRareItems))
    add("  Allow selling affixes you already have:   " .. onoff(DB.affixAllowExactDupes))
    add(string.format(
        "  Sell affixes below rank:                  %s",
        (DB.affixMinSellRank and DB.affixMinSellRank > 0) and tostring(DB.affixMinSellRank) or "|cffff4444off|r"
    ))
    add("  Keep items with chance-on-hit procs:      " .. onoff(DB.protectChanceOnHitItems))
    add("  Keep unlearned tomes and recipes:         " .. onoff(DB.protectUnlearnedTomes))
    add("  Keep all tomes (even learned):            " .. onoff(DB.protectAllTomes))
    local sellCount = 0
    if DB.whitelist then
        for _ in pairs(DB.whitelist) do
            sellCount = sellCount + 1
        end
    end
    local keepCount = 0
    if DB.blacklist then
        for _ in pairs(DB.blacklist) do
            keepCount = keepCount + 1
        end
    end
    local delCount = 0
    if DB.deleteList then
        for _ in pairs(DB.deleteList) do
            delCount = delCount + 1
        end
    end
    local acctSellCount = 0
    if NS.ADB and NS.ADB.whitelist then
        for _ in pairs(NS.ADB.whitelist) do
            acctSellCount = acctSellCount + 1
        end
    end
    add("")
    add(string.format("  Sell List entries:           %d", sellCount))
    add(string.format("  Account Sell List entries:   %d", acctSellCount))
    add(string.format("  Keep List entries:           %d", keepCount))
    add(string.format("  Delete List entries:         %d", delCount))
    add("")
    add("--- See more ---")
    add("  /ec sellinfo  - per-item trace (or Alt+Shift+Right-Click on a bag item)")
    add("  /ec bugreport - full diagnostic dump")

    return table.concat(lines, "\n")
end

local function EC_ShowRuleSummary()
    EC_ShowCopyFrame(
        L["EbonClearance Rule Summary"],
        EC_BuildRuleSummary(),
        L["Rule summary generated. Copy the text from the window."]
    )
end

-- v2.38.3: one-shot diagnostic for the Process Bags engine. Triggered
-- by /ec processdebug. Surfaces every gate that decides whether an
-- item shows up in the Disenchant / Mill / Prospect / Lockpick list,
-- so a player whose herbs/ores don't appear can paste the dump and
-- we can pinpoint which layer is failing on their setup (custom
-- profession spell IDs, tooltip-marker variance, IsSpellKnown
-- behaviour on private-server cores, etc.). Mirrors /ec affixdebug
-- dump's pattern: pure plain-text, copy-paste-friendly, single
-- generate-and-show call (no recording over time).
local function EC_BuildProcessDebugDump()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end
    add("=== EbonClearance Process Bags Debug Dump ===")
    add("Generated: " .. (date and date("%Y-%m-%d %H:%M:%S") or "?"))
    add("Player: " .. (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?"))
    add("Class: " .. (UnitClass and (UnitClass("player")) or "?") .. " / Level " .. tostring(UnitLevel and UnitLevel("player") or "?"))
    add("Locale: " .. (GetLocale and GetLocale() or "?"))
    add("Addon: " .. (NS.GetVersion and NS.GetVersion() or "?"))
    add("")

    local cc = NS.compCache
    if not cc then
        add("ERROR: NS.compCache is nil; addon not fully loaded.")
        return table.concat(lines, "\n")
    end

    add("--- Spell knowledge gates ---")
    local function spellRow(label, id)
        local name = (GetSpellInfo and GetSpellInfo(id)) or "<GetSpellInfo nil>"
        local known = (IsSpellKnown and IsSpellKnown(id)) and "yes" or "no"
        add(string.format("  %-12s id=%-6d  IsSpellKnown=%s  GetSpellInfo='%s'", label, id, known, name))
    end
    spellRow("Disenchant", cc.SPELL_DISENCHANT or 13262)
    spellRow("Milling", cc.SPELL_MILLING or 51005)
    spellRow("Prospecting", cc.SPELL_PROSPECTING or 31252)
    spellRow("Pick Lock", cc.SPELL_PICK_LOCK or 1804)
    add("")

    add("--- Tooltip marker globals ---")
    add(string.format("  ITEM_MILLABLE     = '%s'", tostring(ITEM_MILLABLE)))
    add(string.format("  ITEM_PROSPECTABLE = '%s'", tostring(ITEM_PROSPECTABLE)))
    add(string.format("  ITEM_SOULBOUND    = '%s'", tostring(ITEM_SOULBOUND)))
    add(string.format("  LOCKED            = '%s'", tostring(LOCKED)))
    add("")

    local DB = NS.DB
    local ADB = NS.ADB
    if not DB then
        add("ERROR: NS.DB is nil; cannot evaluate per-slot gates.")
        return table.concat(lines, "\n")
    end
    local ignored = DB.processIgnored or {}
    local protectCOH = DB.protectChanceOnHitItems
    local maxQ = DB.processMaxDEQuality or 4
    add(string.format("--- Settings ---"))
    add(string.format("  processMaxDEQuality   = %d", maxQ))
    add(string.format("  processIncludeSoulbound = %s", tostring(DB.processIncludeSoulbound == true)))
    add(string.format("  protectChanceOnHitItems = %s", tostring(protectCOH)))
    add(string.format("  lockpickEnabled         = %s", tostring(DB.lockpickEnabled == true)))
    local ignCount = 0
    for _ in pairs(ignored) do
        ignCount = ignCount + 1
    end
    add(string.format("  processIgnored entries  = %d", ignCount))
    add("")

    -- v2.38.3: processCache state. If a stack-of-5 Prospectable item is
    -- in bags but the panel shows no Prospect section, the cache having
    -- "none" for that itemID is the smoking gun for a tooltip-not-ready
    -- race that wrote a poisoned entry during early /reload scan.
    add("--- processCache state (per-itemID classification cache) ---")
    if cc.processCache then
        local entries = {}
        for id, v in pairs(cc.processCache) do
            entries[#entries + 1] = string.format("    id=%-6d -> '%s'", id, tostring(v))
        end
        table.sort(entries)
        if #entries == 0 then
            add("  (empty)")
        else
            add(string.format("  %d entry/entries:", #entries))
            for _, line in ipairs(entries) do
                add(line)
            end
        end
    else
        add("  (cc.processCache is nil)")
    end
    add("")

    add("--- Bag walk (every non-empty slot) ---")
    local rowCount, herbOrOreShown = 0, 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            local link = GetContainerItemLink(bag, slot)
            -- v2.38.3: direct call (NOT `(API and API(args))`) so the
            -- multi-return texture/count/locked/quality/... reaches
            -- us. The parenthesised guard form discarded everything
            -- past the first return value, so count was always nil
            -- and the filter rejected every slot.
            local _, count = GetContainerItemInfo(bag, slot)
            if itemID and link and count and count > 0 then
                rowCount = rowCount + 1
                local itemString = link:match("item[%-?%d:]+") or "?"
                -- v2.38.3: direct call (no parens) so the multi-return
                -- (name, link, quality, ...) doesn't collapse to a single
                -- value. The original `(API and API(args))` form silently
                -- discarded everything past the first return so quality
                -- was always nil and the dump always showed q=?. Same
                -- class of bug as the count variant fixed above.
                local _, _, quality = GetItemInfo(itemID)
                local equippable = (IsEquippableItem and IsEquippableItem(itemID)) and "Y" or "N"
                local equipped = (IsEquippedItem and IsEquippedItem(itemID)) and "Y" or "N"
                local ignoredHit = ignored[itemString] and "Y" or "N"
                local blacklisted = (IsInSet and DB.blacklist and IsInSet(DB.blacklist, itemID)) and "Y" or "N"
                local cohGated = "N"
                if protectCOH and cc.itemHasChanceOnHit and cc.itemHasChanceOnHit(bag, slot, itemID) then
                    cohGated = (ADB and ADB.allowedItems and ADB.allowedItems[itemID]) and "allowed" or "Y"
                end
                local ttResult = cc.processTooltipHasLine and cc.processTooltipHasLine(bag, slot, itemID) or "?"
                local canDE = cc.canDisenchant and cc.canDisenchant(itemID) and "Y" or "N"
                local canM = cc.canMill and cc.canMill(bag, slot, itemID) and "Y" or "N"
                local canP = cc.canProspect and cc.canProspect(bag, slot, itemID) and "Y" or "N"
                add(string.format(
                    "  b%d s%-2d id=%-6d q=%s ct=%-3d ttScan=%-8s DE=%s M=%s P=%s | ign=%s bl=%s eq=%s coh=%s | %s",
                    bag, slot, itemID, tostring(quality or "?"), count, ttResult, canDE, canM, canP,
                    ignoredHit, blacklisted, equipped, cohGated, link
                ))
                -- v2.38.3: dump tooltip lines for the most suspicious
                -- slots, capped at 3 dumps to keep output short:
                --   (a) any slot where ttScan returned Mill or Prospect
                --       - confirms what PE's actual tooltip line says
                --   (b) any non-equippable, low-quality, stack>=5 slot
                --       where ttScan returned 'none' - that's the
                --       cache-poisoning candidate (herbs/ores that
                --       the engine thinks aren't processable)
                local interesting = (ttResult == "Mill" or ttResult == "Prospect")
                    or (
                        ttResult == "none"
                        and equippable == "N"
                        and (quality or 0) <= 1
                        and count >= 5
                    )
                if interesting and herbOrOreShown < 3 then
                    herbOrOreShown = herbOrOreShown + 1
                    add(string.format("    -- tooltip dump for b%d s%d (%s, ttScan=%s):", bag, slot, link, ttResult))
                    if cc.scanBagItem and NS.scanTooltip then
                        -- v2.38.3: route through the shared helper that
                        -- enforces SetOwner before SetBagItem. The bug
                        -- this diagnostic surfaced (silent zero-line
                        -- SetBagItem when ownership was lost) is now
                        -- fixed structurally - the helper re-establishes
                        -- ownership every call.
                        cc.scanBagItem(bag, slot)
                        local numLines = NS.scanTooltip.NumLines and NS.scanTooltip:NumLines() or -1
                        add(string.format("       NumLines() = %d", numLines))
                        for i = 1, 30 do
                            local lineFS = _G["EbonClearanceScanTooltipTextLeft" .. i]
                            if not lineFS then
                                add(string.format("       L%-2d: <FontString not registered>", i))
                                break
                            end
                            local txt = lineFS:GetText()
                            if txt == nil then
                                add(string.format("       L%-2d: <nil>", i))
                            elseif txt == "" then
                                add(string.format("       L%-2d: <empty string>", i))
                            else
                                add(string.format("       L%-2d: '%s'", i, txt))
                            end
                            if i >= numLines and numLines > 0 then
                                break
                            end
                        end
                    else
                        add("       (NS.scanTooltip is nil)")
                    end
                end
            end
        end
    end
    if rowCount == 0 then
        add("  (no items in bags)")
    end
    add("")
    add(string.format("--- Summary ---"))
    if cc.buildProcessSummary then
        local results = cc.buildProcessSummary() or {}
        local byMode = {}
        for _, e in ipairs(results) do
            byMode[e.mode] = (byMode[e.mode] or 0) + 1
        end
        add(string.format("  buildProcessSummary entries: %d", #results))
        for mode, n in pairs(byMode) do
            add(string.format("    %s: %d", mode, n))
        end
    else
        add("  ERROR: buildProcessSummary helper missing")
    end
    return table.concat(lines, "\n")
end

local function EC_ShowProcessDebugDump()
    EC_ShowCopyFrame(
        L["EbonClearance Process Bags Debug Dump"],
        EC_BuildProcessDebugDump(),
        L["Process debug dump generated. Copy the text from the window."]
    )
end

NS.ShowBugReport = EC_ShowBugReport
NS.ShowAffixDebugDump = EC_ShowAffixDebugDump
NS.ShowProcessDebugDump = EC_ShowProcessDebugDump
NS.ShowRuleSummary = EC_ShowRuleSummary
