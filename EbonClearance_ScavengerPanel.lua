-- EbonClearance_ScavengerPanel - Scavenger Settings Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-iii of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Scavenger Settings UI panel: companion automation toggles
-- (summon Greedy / dismiss in combat / mute chat / bubble killer /
-- auto-loot cycle / bag-full threshold / auto-open containers / fast
-- loot driver) and the summon-delay slider.
--
-- Moved into this file:
--   * local ScavengerPanel = CreateFrame(...) frame creation
--   * The ScavengerPanel OnShow handler (the panel-build body that
--     constructs all the toggles + slider + description blocks)
--
-- Cross-file dependencies satisfied by NS (all NS-exposed in earlier
-- stages; zero new prep needed for this extraction):
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth,
--     refreshLayouts
--   * NS.DB captured at OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.AddCheckbox / NS.AddSlider / NS.FitScrollContent (8e-ii)
--   * Various WoW globals - CreateFrame, PlaySound, etc.

local NS = select(2, ...)
local EC_compCache = NS.compCache

local ScavengerPanel = CreateFrame("Frame", "EbonClearanceOptionsScavenger", InterfaceOptionsFramePanelContainer)

ScavengerPanel.name = "Scavenger Settings"
ScavengerPanel.parent = "EbonClearance"

ScavengerPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.sumCB then
            self.sumCB:SetChecked(DB.summonGreedy)
        end
        if self.delaySlider then
            self.delaySlider:SetValue(DB.summonDelay or 1.6)
        end
        if self.muteCB then
            self.muteCB:SetChecked(DB.muteGreedy)
        end
        if self.chatCB then
            self.chatCB:SetChecked(DB.hideGreedyChat)
        end
        if self.bubCB then
            self.bubCB:SetChecked(DB.hideGreedyBubbles)
        end
        if self.cycleCB then
            self.cycleCB:SetChecked(DB.autoLootCycle)
        end
        if self.threshSlider then
            self.threshSlider:SetValue(DB.bagFullThreshold or 2)
        end
        if self.autoOpenCB then
            self.autoOpenCB:SetChecked(DB.autoOpenContainers)
        end
        if self.fastLootCB then
            self.fastLootCB:SetChecked(DB.fastLoot)
        end
    end, function(self, content)
        NS.MakeHeader(content, "Scavenger Settings", -16)
        NS.MakeLabel(
            content,
            "Controls summoning and muting of |cffff7f7fGreedy Scavenger|r. The auto-loot cycle will continuously loot and sell while your bags fill up.",
            16,
            -44
        )

        local sumCB =
            CreateFrame("CheckButton", "EbonClearanceSummonGreedyCB", content, "InterfaceOptionsCheckButtonTemplate")
        sumCB:SetPoint("TOPLEFT", 16, -96)
        sumCB:SetChecked(DB.summonGreedy)
        local st = _G[sumCB:GetName() .. "Text"]
        if st then
            st:SetText("Summon |cffff7f7fGreedy Scavenger|r after vendoring")
            st:SetWidth(420)
            st:SetJustifyH("LEFT")
        end
        sumCB:SetScript("OnClick", function()
            DB.summonGreedy = sumCB:GetChecked() and true or false
            if not DB.summonGreedy and DB.autoLootCycle then
                DB.autoLootCycle = false
                if self.cycleCB then
                    self.cycleCB:SetChecked(false)
                end
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        self.sumCB = sumCB

        local combatOnlyCB = NS.AddCheckbox(
            content,
            "EbonClearanceSummonOnlyOutOfCombatCB",
            sumCB,
            "Only summon |cffff7f7fGreedy Scavenger|r when out of combat",
            function()
                return DB.summonOnlyOutOfCombat
            end,
            function(v)
                DB.summonOnlyOutOfCombat = v
            end,
            -8
        )
        self.combatOnlyCB = combatOnlyCB

        local chatCB = NS.AddCheckbox(
            content,
            "EbonClearanceHideGreedyChatCB",
            combatOnlyCB,
            "Hide |cffff7f7fGreedy Scavenger|r's chat messages",
            function()
                return DB.hideGreedyChat
            end,
            function(v)
                DB.hideGreedyChat = v
                NS.ApplyGreedyChatFilter()
            end,
            -8
        )
        self.chatCB = chatCB

        local bubCB = NS.AddCheckbox(
            content,
            "EbonClearanceHideGreedyBubblesCB",
            chatCB,
            "Hide |cffff7f7fGreedy Scavenger|r's chat bubbles",
            function()
                return DB.hideGreedyBubbles
            end,
            function(v)
                DB.hideGreedyBubbles = v
            end,
            -8
        )
        self.bubCB = bubCB

        local delaySlider = NS.AddSlider(
            content,
            "EbonClearanceSummonDelaySlider",
            bubCB,
            "Summon delay",
            0.0,
            3.0,
            0.1,
            function()
                return DB.summonDelay or 1.6
            end,
            function(v)
                DB.summonDelay = v
            end,
            -16,
            "%.1fs"
        )
        self.delaySlider = delaySlider
        delaySlider:SetWidth(200)

        local cycleCB = NS.AddCheckbox(
            content,
            "EbonClearanceAutoLootCycleCB",
            delaySlider,
            "Enable auto-loot cycle (loot, sell, repeat)",
            function()
                return DB.autoLootCycle
            end,
            function(v)
                DB.autoLootCycle = v
                if v then
                    DB.summonGreedy = true
                    if self.sumCB then
                        self.sumCB:SetChecked(true)
                    end
                end
            end,
            -16
        )
        self.cycleCB = cycleCB

        local cycleNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        cycleNote:SetPoint("TOPLEFT", cycleCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(cycleNote, 60)
        cycleNote:SetJustifyH("LEFT")
        cycleNote:SetText(
            "|cff888888At threshold: Greedy is dismissed and the Goblin Merchant is summoned. Right-click it to sell; Greedy re-summons automatically.|r"
        )

        local threshSlider = NS.AddSlider(
            content,
            "EbonClearanceBagThresholdSlider",
            cycleNote,
            "Bag slots remaining before selling",
            0,
            10,
            1,
            function()
                return DB.bagFullThreshold or 2
            end,
            function(v)
                DB.bagFullThreshold = v
            end,
            -16,
            "%d"
        )
        self.threshSlider = threshSlider
        threshSlider:SetWidth(200)

        local autoOpenCB = NS.AddCheckbox(
            content,
            "EbonClearanceAutoOpenCB",
            threshSlider,
            "Auto-open lootable containers from your bags",
            function()
                return DB.autoOpenContainers
            end,
            function(v)
                DB.autoOpenContainers = v
            end,
            -16
        )
        self.autoOpenCB = autoOpenCB

        local autoOpenNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        autoOpenNote:SetPoint("TOPLEFT", autoOpenCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(autoOpenNote, 60)
        autoOpenNote:SetJustifyH("LEFT")
        if autoOpenNote.SetWordWrap then
            autoOpenNote:SetWordWrap(true)
        end
        autoOpenNote:SetText("|cff888888Lockboxes that need a key or lockpick are skipped. Combat-paused.|r")

        -- v2.16.0: Fast Loot. When on AND Blizzard's auto-loot CVar is
        -- effectively enabled (autoLootDefault XOR'd with the
        -- AUTOLOOTTOGGLE modifier), EC drains every slot in the loot
        -- window the moment LOOT_READY fires - the loot frame flashes
        -- briefly or skips entirely, and BoP-bind popups are auto-
        -- confirmed for items that would otherwise interrupt the drain.
        -- Pairs well with the auto-loot cycle for fast farming.
        local fastLootCB = NS.AddCheckbox(
            content,
            "EbonClearanceFastLootCB",
            autoOpenNote,
            "Fast Loot (instant corpse looting)",
            function()
                return DB.fastLoot
            end,
            function(v)
                DB.fastLoot = v
            end,
            -10
        )
        -- AddCheckbox anchors at (0, yOff) from its anchor's BOTTOMLEFT, and
        -- our anchor (autoOpenNote) is itself indented +26 to align with the
        -- auto-open checkbox label. Back-shift the x by -26 to put fastLootCB
        -- on the panel's left margin, level with autoOpenCB above. Same trick
        -- the Protection Settings panel uses to keep its toggle stack
        -- left-aligned beneath each toggle's wrapped explanatory note.
        fastLootCB:ClearAllPoints()
        fastLootCB:SetPoint("TOPLEFT", autoOpenNote, "BOTTOMLEFT", -26, -10)
        self.fastLootCB = fastLootCB

        local fastLootNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fastLootNote:SetPoint("TOPLEFT", fastLootCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(fastLootNote, 60)
        fastLootNote:SetJustifyH("LEFT")
        if fastLootNote.SetWordWrap then
            fastLootNote:SetWordWrap(true)
        end
        fastLootNote:SetText(
            "|cff888888Speeds up manual looting (corpses, fishing, gift bags, dungeon/raid loot, mailbox). Honours Blizzard's |cffffff00Auto Loot|r|cff888888 setting. |cffff7f7fGreedy Scavenger|r|cff888888 looting is already instant and isn't affected.|r"
        )

        -- v2.10.0: the v2.9.0 editable companion-name input boxes were removed
        -- from this panel after in-game testing showed the click-to-focus path
        -- was unreliable on PE-ElvUI; users could see the inputs but typing did
        -- not update DB.scavengerName / DB.merchantName consistently. The
        -- underlying mechanism (DB fields, EC_compCache.refreshNames, the
        -- EnsureDB defaults, and the spellID 600126 cold-cache fallback in
        -- FindGoblinMerchantIndex) all stay - they are still the source of
        -- truth for companion lookup and a future re-enable can drop the UI
        -- back in without touching the runtime path. For now if a user needs
        -- to override either name they can edit DB.scavengerName /
        -- DB.merchantName directly via /run on a single character.

        -- Discoverability hint for the right-click context menu. Lives on this
        -- panel because both v2.3.0 bag-action features cluster here.
        local rightClickHint = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        rightClickHint:SetPoint("TOPLEFT", fastLootNote, "BOTTOMLEFT", 0, -16)
        EC_compCache.setPanelWidth(rightClickHint, 60)
        rightClickHint:SetJustifyH("LEFT")
        if rightClickHint.SetWordWrap then
            rightClickHint:SetWordWrap(true)
        end
        rightClickHint:SetText(
            "|cffffb84dTip:|r |cff888888Alt+Right-Click any item in your bags for a quick-action menu (Sell, Keep, Delete, Sell Now).|r"
        )

        -- Size the scroll content to fit the bottom-most widget so the scrollbar
        -- range matches actual content (no excess empty space at the bottom).
        NS.FitScrollContent(content, rightClickHint)
    end, true)
end)
