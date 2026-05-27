-- EbonClearance_HelpPanel - in-game FAQ + reference panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Curated three-section reference panel: troubleshooting FAQ, sell-
-- decision gate explanations, and tooltip-label meanings. Entries live
-- in a file-scope EC_HELP_ENTRIES table; section markers in the list
-- drive the build's section grouping + collapsible state.
--
-- Design spec: docs/specs/2026-05-26-help-faq-panel-design.md
--
-- Cross-file dependencies (resolved lazily at call time):
--   * NS.compCache (EC_compCache.initPanel, setPanelWidth, etc.)
--   * NS.DB         (per-character SavedVariables, captured at OnShow)
--   * NS.MakeHeader / NS.MakeLabel (panel-text primitives)
--   * NS.FitScrollContent (scroll-content height fitter)
--   * NS.EC_WrapPanelInScrollFrame (scroll-wrap helper)

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- ---------------------------------------------------------------------------
-- EC_HELP_ENTRIES
-- ---------------------------------------------------------------------------
-- Ordered flat list. Two entry kinds:
--   * Section marker: { section = "<key>", title = "<display>" }
--   * Content entry:  { q = "<question/topic>", a = "<answer>", panel = "<frameName>" }
-- The build callback walks this list; section markers set the current
-- collapse-state group, content entries render between markers.
-- panel field is optional - when present, an `Open <name>` button
-- jumps to that Interface Options panel.
local EC_HELP_ENTRIES = {
    -- ===================================================================
    -- Section 1: Getting started
    -- ===================================================================
    { section = "gettingStarted", title = "Getting started" },

    {
        id = "what-does-ec-do",
        q = "What does EbonClearance do?",
        a = "EbonClearance is a bag manager. When you visit a vendor, it auto-sells your junk and old gear, and protects anything important (gear you're wearing, upgrades, quest items, Project Ebonhold affixes). It can also delete items you don't want, summon the Goblin Merchant when bags fill up, and bulk-disenchant, mill, or prospect a stack of items.",
        panel = nil,
    },
    {
        id = "first-steps",
        q = "I just installed this. What should I do first?",
        a = "Out of the box, EbonClearance auto-sells grey junk every time you visit a vendor. That's it. To go further:\n1) Open Merchant Settings and turn on the rarities you want auto-sold (White / Green / Blue / Epic).\n2) Alt+Right-Click any item you never want sold to put it on your Keep List.\n3) Alt+Right-Click any item you always want sold to put it on your Sell List.\nVisit a merchant and it just works.",
        panel = "EbonClearanceOptionsMerchant",
    },
    {
        id = "what-are-the-lists",
        q = "What are the Sell, Keep, and Delete lists?",
        a = "Three lists that give you fine control over what happens at a vendor. Sell List: items you always want vendored. Keep List: items you never want touched. Delete List: items destroyed at the next merchant visit (with confirmation handled). The Keep List wins over the Sell List, and both win over the automatic quality rules. Add to any list by Alt+Right-Click on a bag item, or by typing the item's name on the relevant panel.",
        panel = nil,
    },
    {
        id = "see-item-decision",
        q = "How do I see what will happen to an item?",
        a = "Hover any bag item with EbonClearance enabled and the tooltip shows what the addon will do: 'Keep', 'Will Sell', 'Will Delete', or 'Won't Sell' with a reason. For a full step-by-step, Alt+Shift+Right-Click the item, or type /ec sellinfo.",
        panel = nil,
    },
    {
        id = "slash-commands",
        q = "What are the slash commands?",
        a = "/ec opens the settings. /ec help prints the full command list. /ec sellinfo explains why a bag item will or won't sell. /ec bugreport opens a diagnostic snapshot. /ec clean finds items appearing on multiple lists. /ecdebug shows a bag scan summary.",
        panel = nil,
    },

    -- ===================================================================
    -- Section 2: Troubleshooting
    -- ===================================================================
    { section = "troubleshooting", title = "Troubleshooting" },

    {
        id = "tshoot-why-not-selling",
        q = "Why isn't this item selling?",
        a = "Alt+Shift+Right-Click the item, or type /ec sellinfo. EbonClearance prints each check and tells you which one is keeping the item. Usually one of the protection toggles is catching it - the panel below has all of them.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "tshoot-equipped-keep",
        q = "EbonClearance keeps adding my equipped gear to the Keep List.",
        a = "By default, EbonClearance protects gear you're currently wearing so you don't accidentally sell it. Untick 'Keep gear you're wearing' in the panel below to turn this off.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "tshoot-upgrade-keep",
        q = "Items keep appearing on the Keep List as 'Keep (upgrade)' that I want to sell.",
        a = "EbonClearance auto-adds items with a higher item level than what you're currently wearing in that slot, so you don't accidentally vendor a useful piece. Old entries (gear you've since replaced) clean up automatically. To turn off the auto-add entirely, untick 'Keep looted upgrades' in the panel below.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "tshoot-affix-rank",
        q = "What does 'Keep (affix rank known)' or 'Keep (affix rank needed)' mean?",
        a = "Project Ebonhold affixes are the special abilities on Rare and Epic gear (like 'of Inner Light III'). EbonClearance protects these items so you can extract the affix at the Anvil. 'Rank known' means you already have that exact rank; 'Rank needed' means you don't yet. Alt+Right-Click an item to allow selling a specific affix you no longer want.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "tshoot-per-char-lists",
        q = "Why are my Sell / Keep / Delete lists different on each character?",
        a = "Each character has its own Sell, Keep, and Delete lists - what you set up on one character won't affect another. For items you want every character to vendor, use the Account Sell List.",
        panel = nil,
    },
    {
        id = "share-sell-list-across-chars",
        q = "How do I share a Sell List across all my characters?",
        a = "Open the Account Sell List panel below. Items added there are shared across every character and combined with each character's own list when you visit a merchant.",
        panel = "EbonClearanceOptionsAccountWhitelist",
    },
    {
        id = "tshoot-goblin-not-summoning",
        q = "The Goblin Merchant isn't being summoned when my bags fill up.",
        a = "Three things must all be on: 'Summon Greedy Scavenger', 'Auto-Loot Cycle', and you need the Greedy Scavenger / Goblin Merchant ability in your spellbook. Check the panel below.",
        panel = "EbonClearanceOptionsScavenger",
    },
    {
        id = "tshoot-bag-borders",
        q = "The bag-slot border colors aren't showing.",
        a = "They're off by default. Tick 'Enable sell-border tints' in the panel below, then turn on the categories you want colored (Delete, Account Sell, Character Sell, Junk, Rule).",
        panel = "EbonClearanceOptionsCharacter",
    },
    {
        id = "tshoot-disable-per-char",
        q = "How do I disable EbonClearance on one specific character?",
        a = "Right-click the minimap button on that character to toggle the addon off, or type /ec and use the toggle on the Main panel. The setting is per-character; other characters stay enabled.",
        panel = nil,
    },
    {
        id = "tshoot-sellinfo",
        q = "How do I see exactly why a bag item will or won't sell?",
        a = "Alt+Shift+Right-Click the item, or type /ec sellinfo. EbonClearance prints the full step-by-step decision in chat.",
        panel = nil,
    },
    {
        id = "tshoot-keep-list-hides-process",
        q = "My herbs / ore aren't showing in Process Bags.",
        a = "Items on the Keep List are intentionally hidden from Process Bags' Disenchant / Mill / Prospect / Pick Locks lists - the Keep List wins over everything, including bulk processing. If you've added a herb or ore to the Keep List (manually or by auto-protect rules), it won't appear here. Open the panel below to remove items from the Keep List and they'll show up in Process Bags again.",
        panel = "EbonClearanceOptionsBlacklist",
    },

    -- ===================================================================
    -- Section 3: Sell decision gates
    -- ===================================================================
    { section = "gates", title = "How sell decisions work" },

    {
        id = "gate-order-of-checks",
        q = "Order of checks",
        a = "When you visit a vendor, EbonClearance walks every bag item through these checks in order:\n1) Has a vendor price?\n2) Grey, on the Sell List, or matches a quality rule?\n3) Currently equipped?\n4) On the Keep List?\n5) Has a protected affix?\n6) Has a 'Chance on hit' proc?\n7) A tome or recipe?\nThe first 'no, keep it' stops the chain; the first 'yes, sell it' queues the item.",
        panel = nil,
    },
    {
        id = "gate-grey-items",
        q = "Grey items always sell",
        a = "Grey items (poor quality junk) always sell at vendors, regardless of any other setting. As long as the item has a vendor price, it goes.",
        panel = nil,
    },
    {
        id = "gate-vendor-price",
        q = "Items must have a vendor price",
        a = "EbonClearance never auto-sells items with no vendor price - the vendor wouldn't pay for them. If you want items like this gone, use the Delete List instead.",
        panel = "EbonClearanceOptionsDeletion",
    },
    {
        id = "gate-quality-rules",
        q = "Quality rules (White / Green / Blue / Epic)",
        a = "Separate auto-sell rules per rarity, in Merchant Settings. Each can be turned on or off independently, with its own item-level threshold to decide which items of that rarity get vendored.",
        panel = "EbonClearanceOptionsMerchant",
    },
    {
        id = "gate-fixed-vs-equipped-ilvl",
        q = "Fixed iLvl cap vs. Use equipped iLvl",
        a = "Two ways to decide which items get auto-sold per rarity. 'Fixed iLvl cap': sells anything at or below the number you set. 'Use equipped iLvl': sells anything lower than what you're currently wearing in that slot. Empty slots are skipped in the second mode, so you won't lose gear meant for an empty slot.",
        panel = "EbonClearanceOptionsMerchant",
    },
    {
        id = "gate-bind-type",
        q = "Bind-type filter",
        a = "An extra restriction per rarity: Any (sells both trade-able and soulbound), BoE only (only sells trade-able items), or BoP only (only sells soulbound). Items without any bind line (consumables, reagents) are only included when set to 'Any'.",
        panel = "EbonClearanceOptionsMerchant",
    },
    {
        id = "gate-equipped-never-sells",
        q = "Currently-equipped items never sell",
        a = "Even when on the Sell List, EbonClearance won't vendor anything you're currently wearing. Unequip first if you want it sold. Turn on 'Keep gear sets' if you also want gear from Blizzard's Equipment Manager protected.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "gate-keep-list-blocks",
        q = "Keep List blocks selling",
        a = "Items on the Keep List are protected from every auto-sell rule. The Keep List always wins - even if the same item is also on the Sell List, the Keep List blocks it. Add items by Alt+Right-Click or via the Keep List panel.",
        panel = "EbonClearanceOptionsBlacklist",
    },
    {
        id = "gate-affix-protection",
        q = "Project Ebonhold affix protection",
        a = "Project Ebonhold affixes are the special abilities on Rare and Epic gear (like 'of Inner Light III'). EbonClearance never auto-sells these so you can extract them at the Anvil. To allow selling them: use Alt+Right-Click 'Allow Sell' on individual items, or turn on 'Allow exact-rank duplicates' for affixes you already own.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "gate-allow-rank-dupes",
        q = "Allow exact-rank duplicates",
        a = "Once you've extracted an affix at a certain rank, duplicates aren't useful. Turn this on and EbonClearance allows selling extras of affixes you already own at that rank. The item still needs a Sell List entry or matching quality rule to actually sell - this just removes the affix protection.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "gate-manual-allow-sell",
        q = "Manual Allow Sell (Alt+Right-Click)",
        a = "Alt+Right-Click an item to mark one specific affix as 'safe to sell'. Every future drop with that exact affix will skip the protection. Works across all your characters. Alt+Right-Click and pick the same option to undo.",
        panel = nil,
    },
    {
        id = "gate-chance-on-hit",
        q = "Chance-on-hit protection",
        a = "Items with a 'Chance on hit:' line have a proc spell you can extract at the Anvil. EbonClearance protects these so you don't sell them by accident. Use Alt+Right-Click 'Allow Sell' to vendor a specific item anyway.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "gate-tome-recipe",
        q = "Tome / recipe protection",
        a = "Plans, Schematics, Patterns, Recipes, class tomes, and mount scrolls are protected from auto-sell so you don't accidentally vendor a learnable spell. Alt+Right-Click 'Allow Sell' to override. 'Protect all tomes / recipes' decides whether already-learned items are also protected (useful for saving spares for the auction house or alts).",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "gate-quest-items",
        q = "Quest item safety net",
        a = "Quest items never auto-sell from a quality rule, even when the rule matches. You can still manually add a quest item to the Sell List if you really want it gone - your direct action overrides the safety net.",
        panel = nil,
    },
    {
        id = "gate-profession-tools",
        q = "Profession tool safety net",
        a = "Fishing poles, mining picks, the Skinning Knife, the Blacksmith Hammer, and the Arclight Spanner are always protected from auto-sell. Add one to the Sell List manually if you have a duplicate to vendor.",
        panel = nil,
    },
    {
        id = "gate-delete-list",
        q = "Delete List path",
        a = "Items on the Delete List are destroyed at your next merchant visit (when 'Enable Deletion' is turned on). The same affix, chance-on-hit, and tome protections apply on the delete path - use Alt+Right-Click 'Allow Sell' to override.",
        panel = "EbonClearanceOptionsDeletion",
    },

    -- ===================================================================
    -- Section 4: Tooltip labels
    -- ===================================================================
    { section = "labels", title = "Tooltip labels" },

    {
        id = "label-keep",
        q = "Keep",
        a = "Plain 'Keep' (no parens) means you manually added this item to your Keep List, either via Alt+Right-Click or the Keep List panel.",
        panel = "EbonClearanceOptionsBlacklist",
    },
    {
        id = "label-keep-equipped",
        q = "Keep (equipped)",
        a = "EbonClearance auto-added this item because you're currently wearing it. The protection lasts as long as it's equipped.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-keep-upgrade",
        q = "Keep (upgrade)",
        a = "EbonClearance auto-added this item because its item level is higher than what you're wearing in that slot. If you replace your gear, old entries clean up automatically.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-keep-gear-set",
        q = "Keep (in gear set)",
        a = "EbonClearance auto-added this item because it's part of a saved gear set in Blizzard's Equipment Manager. Useful for off-spec gear you carry in your bags.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-keep-auto",
        q = "Keep (auto)",
        a = "An older auto-tag from before EbonClearance v2.12.0. Works the same as the more specific 'Keep (equipped/upgrade/gear set)' tags, but the exact origin was lost during an addon upgrade.",
        panel = "EbonClearanceOptionsBlacklist",
    },
    {
        id = "label-keep-quest",
        q = "Keep (quest item)",
        a = "EbonClearance flagged this as a quest item. Quality rules won't auto-sell it. If you really want it gone, add it to the Sell List manually.",
        panel = nil,
    },
    {
        id = "label-keep-prof-tool",
        q = "Keep (profession tool)",
        a = "Profession tool like a fishing pole or mining pick. Always protected. Use Alt+Right-Click 'Allow Sell' to vendor a duplicate.",
        panel = nil,
    },
    {
        id = "label-affix-rank-known",
        q = "Keep (affix rank known)",
        a = "Project Ebonhold affix on the item, and you already own this exact rank. The item is still protected. Turn on 'Allow exact-rank duplicates' in Protection Settings if you want extras to auto-sell.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-affix-rank-needed",
        q = "Keep (affix rank needed)",
        a = "Project Ebonhold affix on the item that you don't yet own at this rank. Protected so you can extract it at the Anvil.",
        panel = nil,
    },
    {
        id = "label-chance-on-hit",
        q = "Keep (chance-on-hit proc)",
        a = "Item has a 'Chance on hit:' proc you can extract at the Anvil. Protected from auto-sell. Use Alt+Right-Click 'Allow Sell' to vendor a specific one anyway.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-new-tome-recipe",
        q = "Keep (new Tome) / Keep (new Recipe)",
        a = "A tome or recipe you haven't learned yet. Protected so you can learn it - just right-click the item. Turn off tome/recipe protection in Protection Settings if you'd rather sell them.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-tome-have",
        q = "Keep (Tome you have) / Keep (Recipe you have)",
        a = "A tome or recipe you've already learned. Only shows up when 'Protect all tomes / recipes' is turned on. Useful if you save spares for the auction house or alts.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-will-sell",
        q = "Will Sell",
        a = "Item is on your Sell List. EbonClearance will vendor it the next time you visit a merchant.",
        panel = "EbonClearanceOptionsWhitelist",
    },
    {
        id = "label-will-sell-account",
        q = "Will Sell (your Account List)",
        a = "Item is on your Account Sell List (shared across all characters). Will vendor at the next merchant visit.",
        panel = "EbonClearanceOptionsAccountWhitelist",
    },
    {
        id = "label-will-sell-char",
        q = "Will Sell (your Character List)",
        a = "Item is on this character's Sell List. Will vendor at the next merchant visit.",
        panel = "EbonClearanceOptionsWhitelist",
    },
    {
        id = "label-will-sell-junk",
        q = "Will Sell (junk)",
        a = "Grey item with a vendor price. Always sells regardless of other settings.",
        panel = nil,
    },
    {
        id = "label-will-sell-quality-rule",
        q = "Will Sell (Blue, lower than equipped), etc.",
        a = "A quality rule matched. The text in parentheses tells you which one. 'Lower than equipped' means the rule is set to compare against your currently-worn iLvl. 'iLvl X, cap N' means a fixed iLvl cap matched.",
        panel = "EbonClearanceOptionsMerchant",
    },
    {
        id = "label-will-sell-affix-dupe",
        q = "Will Sell (you have this affix)",
        a = "You already own this affix at this rank, AND something else (a Sell List entry or quality rule) marks the item for sale. The item will vendor as a duplicate.",
        panel = "EbonClearanceOptionsBlacklistSettings",
    },
    {
        id = "label-will-delete",
        q = "Will Delete",
        a = "Item is on the Delete List, and Deletion is turned on. EbonClearance will destroy it at your next merchant visit (the confirmation popup is handled for you).",
        panel = "EbonClearanceOptionsDeletion",
    },
    {
        id = "label-wont-sell-equipped",
        q = "Won't Sell (equipped)",
        a = "Item is on the Sell List but you're currently wearing it. Unequip first if you want it sold.",
        panel = nil,
    },
    {
        id = "label-wont-sell-no-value",
        q = "Won't Sell (no value)",
        a = "Item is on the Sell List but it has no vendor price. EbonClearance can't sell items vendors won't buy. Try the Delete List if you want it gone.",
        panel = "EbonClearanceOptionsDeletion",
    },
    {
        id = "label-override-no-rule",
        q = "Override on - add to a list to sell",
        a = "You've marked this affix or proc as 'Allow Sell', but the item isn't on any Sell List and no quality rule matches it. The override removes the protection, but you still need a Sell List entry or matching rule to actually vendor it.",
        panel = nil,
    },

    -- ===================================================================
    -- Section 5: Process Bags
    -- ===================================================================
    { section = "processBags", title = "Process Bags" },

    {
        id = "process-bags-overview",
        q = "What does Process Bags do?",
        a = "Process Bags is a bulk processor for materials in your bags. Open it from /ec, pick a mode (Disenchant, Mill, Prospect, or Pick Locks), and EbonClearance arms your cursor with the matching spell or item. Click bag slots in sequence; the addon respects the spell's cooldown and skips items that don't qualify. Useful for turning a stack of green drops into Enchant dust without 30 manual right-clicks. Note: items on your Keep List are intentionally hidden from this panel.",
        panel = "EbonClearanceOptionsProcessBags",
    },
    {
        id = "process-disenchant",
        q = "Disenchant mode",
        a = "Requires the Enchanting profession. Arms Disenchant on your cursor. Click bag slots holding Uncommon (Green) or Rare (Blue) Weapons / Armor to turn them into Enchanting dust, essences, and shards. Items without Enchanting eligibility are skipped.",
        panel = "EbonClearanceOptionsProcessBags",
    },
    {
        id = "process-mill",
        q = "Mill mode",
        a = "Requires the Inscription profession. Arms Milling on your cursor. Click bag slots holding stacks of 5+ herbs to turn them into pigments. Stacks smaller than 5 are skipped.",
        panel = "EbonClearanceOptionsProcessBags",
    },
    {
        id = "process-prospect",
        q = "Prospect mode",
        a = "Requires the Jewelcrafting profession. Arms Prospecting on your cursor. Click bag slots holding stacks of 5+ ore to turn them into gems and rare prospects. Stacks smaller than 5 are skipped.",
        panel = "EbonClearanceOptionsProcessBags",
    },
    {
        id = "process-picklocks",
        q = "Pick Locks mode",
        a = "Requires the Rogue Pick Lock ability. Arms Pick Lock on your cursor. Click bag slots holding lockboxes (Junkboxes, Mageweave Pouches, Heavy Junkboxes, etc.) to open them.",
        panel = "EbonClearanceOptionsProcessBags",
    },

    -- ===================================================================
    -- Section 6: Reporting bugs
    -- ===================================================================
    { section = "discord", title = "Reporting bugs" },

    {
        id = "bug-report-flow",
        q = "Found a bug? Here's how to report it",
        a = "1) Type /ec bugreport. EbonClearance opens a window with a diagnostic snapshot.\n2) Click in the window, press Ctrl+A to select all, then Ctrl+C to copy.\n3) Click the button below to copy the EbonClearance Discord thread link.\n4) Open the link in your browser, paste the report, and tag @serv so I see it.",
        url = "https://discord.com/channels/1429854156444794884/1491764725288009748",
    },
    {
        id = "bug-report-contents",
        q = "What does /ec bugreport include?",
        a = "Your character name, addon version, current Sell / Keep / Delete list sizes, the last few bag-scan results, and your protection settings. No personal info, no full settings dump - just enough context to reproduce the issue.",
        panel = nil,
    },
    {
        id = "bug-dm-vs-thread",
        q = "Direct message vs. the thread",
        a = "Post in the thread - other players hit the same bugs and the public answer helps everyone.",
        panel = nil,
    },
}

-- ---------------------------------------------------------------------------
-- Frame creation
-- ---------------------------------------------------------------------------
local HelpPanel = CreateFrame("Frame", "EbonClearanceOptionsHelp", InterfaceOptionsFramePanelContainer)
HelpPanel.name = "Help"
HelpPanel.parent = "EbonClearance"

-- NS.OpenHelpEntry(entryId): deep-link from a settings panel into the
-- Help panel at a specific entry. Settings panels register [?] icons
-- via NS.AddHelpIcon (EbonClearance_PanelWidgets.lua); the icon's
-- OnClick calls this function with the entry's stable id.
--
-- Behaviour:
--   1. Find the section that owns this entry (walk EC_HELP_ENTRIES).
--   2. Set DB.helpSectionsCollapsed[ownerSection] = false so the section
--      auto-expands when the panel renders.
--   3. Stash HelpPanel._pendingScrollEntryId so refreshLayout's
--      post-pass scrolls the entry into view + flashes it.
--   4. Call InterfaceOptionsFrame_OpenToCategory(HelpPanel) twice
--      (the standard 3.3.5a workaround for the open-to-sub-panel bug
--      where the first call sometimes lands on the parent category).
--
-- If entryId is nil or no matching entry exists, the panel still opens
-- (no expand / scroll / flash). Safe failure mode for typos and stale
-- ids during development.
-- Locate the q FontString for a given entry id by walking
-- EC_HELP_ENTRIES (content entries only, in order) and matching
-- against the Nth "q" widget in HelpPanel._helpRenderItems.
-- Returns nil if the panel hasn't been built yet OR the id is unknown.
local function findEntryWidget(entryId)
    if not entryId then
        return nil
    end
    local items = HelpPanel._helpRenderItems
    if not items then
        return nil
    end
    local contentIdx, targetIdx = 0, nil
    for _, entry in ipairs(EC_HELP_ENTRIES) do
        if not entry.section then
            contentIdx = contentIdx + 1
            if entry.id == entryId then
                targetIdx = contentIdx
                break
            end
        end
    end
    if not targetIdx then
        return nil
    end
    local qSeen = 0
    for _, item in ipairs(items) do
        if item.kind == "q" then
            qSeen = qSeen + 1
            if qSeen == targetIdx then
                return item.widget
            end
        end
    end
    return nil
end

function NS.OpenHelpEntry(entryId)
    local target = _G["EbonClearanceOptionsHelp"]
    if not target or not InterfaceOptionsFrame_OpenToCategory then
        return
    end

    -- Find the owning section so it's expanded BEFORE the panel renders.
    if entryId and NS.DB then
        local ownerSection = nil
        for _, entry in ipairs(EC_HELP_ENTRIES) do
            if entry.section then
                ownerSection = entry.section
            elseif entry.id == entryId then
                break
            end
        end
        if ownerSection then
            NS.DB.helpSectionsCollapsed = NS.DB.helpSectionsCollapsed or {}
            NS.DB.helpSectionsCollapsed[ownerSection] = false
        end
    end

    -- Open the panel (double-call for the 3.3.5a workaround). This fires
    -- OnShow on HelpPanel, which runs refreshLayout - positions widgets,
    -- fits the chrome + outer scroll content. refreshLayout no longer
    -- handles deep-link scrolling; that all lives here so a single click
    -- produces a single deterministic scroll regardless of how many
    -- OnShow events the double-call triggers.
    InterfaceOptionsFrame_OpenToCategory(target)
    InterfaceOptionsFrame_OpenToCategory(target)

    if not entryId or not NS.Delay then
        return
    end

    -- Generation counter: a subsequent OpenHelpEntry call supersedes
    -- any in-flight scroll from earlier clicks. Each delayed task
    -- checks its captured generation against the current one and
    -- no-ops if it has been superseded. Prevents rapid-click whiplash
    -- (old click's scroll firing AFTER new click's scroll) and stale
    -- scrolls when the user spam-clicks [?] icons.
    HelpPanel._scrollGeneration = (HelpPanel._scrollGeneration or 0) + 1
    local gen = HelpPanel._scrollGeneration

    -- Single deferred scroll + flash. By 0.7s, refreshLayout has run
    -- (immediately on OnShow), both FitScrollContent passes have fired
    -- (0.1s + 0.5s), and the outer scroll content's range is settled.
    -- Earlier scroll attempts (the previous 0.2s/0.6s/0.9s triple-fire
    -- approach) caused visible whiplash because the scroll fired BEFORE
    -- FitScrollContent's later pass resized the content, snapping the
    -- scrollbar back to 0.
    NS.Delay(0.7, function()
        if HelpPanel._scrollGeneration ~= gen then
            return
        end
        local widget = findEntryWidget(entryId)
        if not widget then
            return
        end
        local scrollFrame = _G["EbonClearanceOptionsHelpScroll"]
        if not scrollFrame or not scrollFrame.SetVerticalScroll then
            return
        end
        if not widget.GetTop or not scrollFrame.GetTop then
            return
        end
        local widgetTop = widget:GetTop()
        local scrollTop = scrollFrame:GetTop()
        if not widgetTop or not scrollTop then
            return
        end
        local offset = scrollTop - widgetTop
        if offset < 0 then
            offset = 0
        end
        local range = scrollFrame.GetVerticalScrollRange and scrollFrame:GetVerticalScrollRange() or 0
        if offset > range then
            offset = range
        end
        scrollFrame:SetVerticalScroll(offset)

        -- Flash: yellow tint pulse for ~0.5s, then restore.
        if widget.SetTextColor then
            widget:SetTextColor(1, 1, 0.4)
            NS.Delay(0.5, function()
                if HelpPanel._scrollGeneration == gen and widget.SetTextColor then
                    widget:SetTextColor(1, 1, 1)
                end
            end)
        end
    end)
end

-- StaticPopup for copyable URLs (3.3.5a has no clickable browser links
-- in chat; the convention is to pop up a pre-selected EditBox so the
-- player presses Ctrl+C and pastes into a browser themselves). Reusable
-- across entries via the EC_COPY_URL_DATA closure - the URL is set in
-- the closure before StaticPopup_Show fires, then read by OnShow.
local EC_COPY_URL_DATA = { url = "" }
if not StaticPopupDialogs["EC_COPY_URL"] then
    StaticPopupDialogs["EC_COPY_URL"] = {
        text = "Press Ctrl+C to copy the URL, then paste into your browser:",
        button1 = OKAY,
        hasEditBox = true,
        editBoxWidth = 350,
        OnShow = function(self)
            local box = self.editBox or _G[self:GetName() .. "EditBox"]
            if box then
                box:SetText(EC_COPY_URL_DATA.url or "")
                box:HighlightText()
                box:SetFocus()
                box:SetScript("OnEscapePressed", function(eb)
                    eb:GetParent():Hide()
                end)
                box:SetScript("OnEnterPressed", function(eb)
                    eb:GetParent():Hide()
                end)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

-- Apply the v2.32.x list-panel chrome backdrop to a frame. Matches the
-- Sell / Keep / Delete / Process Bags / Profiles scroll-area wrappers:
-- UI-Tooltip-Border edge at edgeSize=12 with the warm brown border tint
-- used by every other chrome-wrapped surface in the addon.
local function applyChromeBackdrop(frame)
    if not frame or not frame.SetBackdrop then
        return
    end
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.6)
    frame:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)
end

HelpPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    if not DB then
        return
    end

    -- Per-character collapse state. Default: troubleshooting expanded,
    -- gates + labels collapsed so a first-time visitor doesn't see a
    -- wall of reference content. Stored under PER_CHAR_FIELDS so the
    -- v2.34.0 partition migrates it correctly (matches the
    -- processCollapsedModes precedent).
    if type(DB.helpSectionsCollapsed) ~= "table" then
        DB.helpSectionsCollapsed = {
            gettingStarted = true,
            troubleshooting = true,
            gates = true,
            labels = true,
            processBags = true,
            discord = true,
        }
    end
    -- Defensive defaults for individual keys (handles partial saves).
    -- Default: every section starts collapsed. The visitor sees the
    -- list of section headers and clicks the one they're interested in,
    -- rather than scrolling past a wall of expanded content. Existing
    -- per-character collapse toggles are preserved (only keys missing
    -- from the saved table get the collapsed default).
    for _, key in ipairs({ "gettingStarted", "troubleshooting", "gates", "labels", "processBags", "discord" }) do
        if type(DB.helpSectionsCollapsed[key]) ~= "boolean" then
            DB.helpSectionsCollapsed[key] = true
        end
    end

    -- ---------------------------------------------------------------
    -- refreshLayout: re-applies anchors + visibility based on the
    -- current collapse state. Walks the prebuilt renderItems list once.
    -- Called after section-header clicks (toggle) and during initial
    -- build (initial layout).
    -- ---------------------------------------------------------------
    local function refreshLayout(panel)
        local items = panel._helpRenderItems
        local chrome = panel._helpChromeContent
        if not items or not chrome then
            return
        end
        local DB2 = NS.DB
        if not DB2 then
            return
        end
        local collapsed = DB2.helpSectionsCollapsed or {}

        -- Layout uses TOPLEFT + TOPRIGHT anchors exclusively (corner
        -- anchors don't imply vertical-center alignment, unlike LEFT/RIGHT
        -- which would over-constrain frames whose TOP is also set and
        -- silently stretch them to satisfy all three constraints).
        --
        -- prevFull tracks the most recent FULL-WIDTH widget (section,
        -- q, a, sep). Buttons are fixed-width + right-aligned and do NOT
        -- become prevFull - if a button could become prevFull, the next
        -- full-width row's TOPLEFT would land at the button's left edge
        -- (the right-third of the panel). yCursor accumulates the vertical
        -- distance from prevFull's bottom through any intervening button
        -- so the next full-width row anchors to the correct Y.
        local prevFull = nil
        local yCursor = 0
        local currentSection = nil
        local currentSectionCollapsed = false
        local SECTION_GAP = 16
        local Q_GAP = 14
        local A_GAP = 4
        local BUTTON_GAP = 6
        local BUTTON_HEIGHT = 22
        local SEP_GAP = 8
        for _, it in ipairs(items) do
            if it.kind == "section" then
                -- Section header (Button frame). TOPLEFT + TOPRIGHT
                -- anchors span the full chrome width - Buttons don't
                -- need SetWordWrap so the anchor pair is safe here.
                currentSection = it.section
                currentSectionCollapsed = collapsed[currentSection] == true
                local glyph = currentSectionCollapsed and "[+]" or "[-]"
                it.widget:SetText(string.format("|cffffff00%s %s|r", glyph, it.title))
                it.widget:ClearAllPoints()
                if prevFull then
                    it.widget:SetPoint("TOPLEFT", prevFull, "BOTTOMLEFT", 0, -(SECTION_GAP + yCursor))
                    it.widget:SetPoint("TOPRIGHT", prevFull, "BOTTOMRIGHT", 0, -(SECTION_GAP + yCursor))
                else
                    it.widget:SetPoint("TOPLEFT", chrome, "TOPLEFT", 0, -4)
                    it.widget:SetPoint("TOPRIGHT", chrome, "TOPRIGHT", 0, -4)
                end
                it.widget:Show()
                prevFull = it.widget
                yCursor = 0
            else
                if currentSectionCollapsed then
                    it.widget:Hide()
                else
                    it.widget:ClearAllPoints()
                    if it.kind == "button" then
                        it.widget:SetPoint("TOPRIGHT", prevFull, "BOTTOMRIGHT", 0, -(BUTTON_GAP + yCursor))
                        it.widget:Show()
                        yCursor = yCursor + BUTTON_GAP + BUTTON_HEIGHT
                    elseif it.kind == "sep" then
                        -- Separator Texture. Textures use anchors for
                        -- their visible bounds (no wrap concept), so
                        -- TOPLEFT + TOPRIGHT spans the full chrome.
                        it.widget:SetPoint("TOPLEFT", prevFull, "BOTTOMLEFT", 0, -(SEP_GAP + yCursor))
                        it.widget:SetPoint("TOPRIGHT", prevFull, "BOTTOMRIGHT", 0, -(SEP_GAP + yCursor))
                        it.widget:Show()
                        prevFull = it.widget
                        yCursor = 0
                    else
                        -- FontString (q or a). TOPLEFT only - width is
                        -- driven by SetWidth (from setPanelWidth in the
                        -- build callback), which is what engages the
                        -- word-wrap codepath in WoW 3.3.5a FontStrings.
                        -- Adding TOPRIGHT here would set the visual
                        -- frame bounds but NOT engage wrap, producing
                        -- single-line "..." truncation.
                        local gap = (it.kind == "q") and Q_GAP or A_GAP
                        it.widget:SetPoint("TOPLEFT", prevFull, "BOTTOMLEFT", 0, -(gap + yCursor))
                        it.widget:Show()
                        prevFull = it.widget
                        yCursor = 0
                    end
                end
            end
        end
        if prevFull and NS.FitScrollContent then
            -- Two-stage fit: (1) size chromeOuter to fit the last rendered
            -- widget, then (2) size the OUTER scroll content (chromeOuter's
            -- parent, returned by initPanel's wrapScroll) to fit chromeOuter.
            -- Without step (2), the outer scroll content stays at the
            -- SetHeight(1) it gets in EC_WrapPanelInScrollFrame, so
            -- GetVerticalScrollRange returns 0 and SetVerticalScroll can't
            -- actually move the scroll - which silently broke deep-link
            -- scroll-to-entry from settings panels' [?] icons.
            local chromeOuter = chrome:GetParent()
            local scrollContent = chromeOuter and chromeOuter:GetParent()
            NS.FitScrollContent(chromeOuter, prevFull)
            if scrollContent then
                NS.FitScrollContent(scrollContent, chromeOuter)
            end
        end
        -- Deep-link scroll-to-entry + flash all live in NS.OpenHelpEntry
        -- now, gated by a generation counter so rapid [?] clicks supersede
        -- cleanly. refreshLayout is intentionally responsible only for
        -- positioning + sizing, not for consuming any pending-scroll state.
    end

    EC_compCache.initPanel(self, function()
        refreshLayout(self)
    end, function(s, content)
        -- Heading. Y offset -16 matches the Keep List / Sell List /
        -- Delete List heading pattern (MakeHeader anchors at TOPLEFT
        -- 16,y - the y passed in is the gap from the panel's top
        -- edge). Without a y arg, the heading butts right against the
        -- panel's top edge and the whole stack reads as misaligned
        -- relative to the other Interface Options sub-panels.
        local heading = NS.MakeHeader and NS.MakeHeader(content, "Help / Troubleshooting", -16)
            or content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        if not NS.MakeHeader then
            heading:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -16)
            heading:SetText("Help / Troubleshooting")
        end

        local intro = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        intro:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -6)
        EC_compCache.setPanelWidth(intro, 16)
        intro:SetJustifyH("LEFT")
        if intro.SetWordWrap then
            intro:SetWordWrap(true)
        end
        intro:SetText(
            "|cff888888Common issues, sell-decision gates, and tooltip label meanings. Click a section header to expand / collapse.|r"
        )

        -- Chrome-wrapped content area for the FAQ entries. Uses Keep
        -- List's two-anchor pattern (TOPLEFT to prev widget's BOTTOMLEFT,
        -- TOPRIGHT to extend out to the panel's standard 16px right
        -- margin) so the chrome sits symmetrically inside the menu
        -- frame instead of having a small left margin and a large
        -- right margin. intro is setPanelWidth(intro, 16) so its right
        -- edge is at EC_PANEL_WIDTH - 16; +24 on the TOPRIGHT offset
        -- pushes chromeOuter's right out to EC_PANEL_WIDTH + 8 (= 16
        -- from panel.right), matching Keep List's listUI extent.
        -- chromeOuter doesn't need its own setPanelWidth because the
        -- anchors trace back to intro, which IS registered for resize.
        local chromeOuter = CreateFrame("Frame", nil, content)
        chromeOuter:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -12)
        chromeOuter:SetPoint("TOPRIGHT", intro, "BOTTOMRIGHT", 24, -12)
        chromeOuter:SetHeight(400) -- temporary; refreshLayout's FitScrollContent recomputes
        applyChromeBackdrop(chromeOuter)

        -- v2.36.x scroll viewport extension + scrollbar relocation.
        --
        -- The problem: EC_WrapPanelInScrollFrame anchors the scroll frame
        -- at BOTTOMRIGHT (-26, 6), so its viewport ends at panel.right - 26.
        -- WoW's ScrollFrame scissor-clips its scroll child to that viewport,
        -- which means chromeOuter (extending to panel.right - 16, matching
        -- Keep List's listUI extent) has its rightmost 10px CLIPPED OFF.
        -- The brown border on the right side never renders.
        --
        -- The fix: extend this panel's scroll frame to BOTTOMRIGHT (-4, 6)
        -- so the viewport ends at panel.right - 4. chromeOuter at
        -- panel.right - 16 is now fully inside the viewport (no clip).
        -- Then re-anchor the scrollbar so its left edge sits at the
        -- chrome's right edge, occupying the strip between the chrome
        -- and panel.right.
        --
        -- Other scroll-wrapped panels (MainPanel, MerchantPanel, etc.)
        -- don't need this because their content widgets sit at most at
        -- panel.right - 40 (via setPanelWidth(widget, 16)), well inside
        -- the default viewport - the Help panel is unusual in extending
        -- its chrome to Keep List's panel.right - 16 extent.
        local scrollName = (s:GetName() or "EbonClearanceOptionsHelp") .. "Scroll"
        local scrollFrame = _G[scrollName]
        local scrollBar = _G[scrollName .. "ScrollBar"]
        if scrollFrame and scrollBar then
            scrollFrame:ClearAllPoints()
            scrollFrame:SetPoint("TOPLEFT", 0, 0)
            scrollFrame:SetPoint("BOTTOMRIGHT", -4, 6)

            -- Scrollbar: anchor so sb.left sits at chrome.right (= panel.right
            -- - 16). With scroll.right at panel.right - 4, an offset of +2
            -- on TOPRIGHT puts sb.right at panel.right - 2 (small inset from
            -- panel edge) and sb.left at panel.right - 18 (2px to the right
            -- of chrome.right).
            scrollBar:ClearAllPoints()
            scrollBar:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", 2, -20)
            scrollBar:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", 2, 16)
        end

        -- Inner padding frame for the actual widgets so the chrome
        -- backdrop edges aren't directly against the FontStrings. 6px
        -- inset matches Process Bags' inner ScrollFrame pattern (small
        -- gap inside the brown UI-Tooltip-Border, not a deep margin).
        local chrome = CreateFrame("Frame", nil, chromeOuter)
        chrome:SetPoint("TOPLEFT", chromeOuter, "TOPLEFT", 6, -6)
        chrome:SetPoint("BOTTOMRIGHT", chromeOuter, "BOTTOMRIGHT", -6, 6)
        s._helpChromeContent = chrome

        -- Build a prebuilt renderItems list. Every widget exists from
        -- the start; visibility + anchors are set per-section by the
        -- refreshLayout pass below (and on every collapse toggle).
        local renderItems = {}
        local currentSection = nil
        for _, entry in ipairs(EC_HELP_ENTRIES) do
            if entry.section then
                local hdr = CreateFrame("Button", nil, chrome)
                hdr:SetHeight(22)
                hdr:RegisterForClicks("LeftButtonUp")
                local fs = hdr:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
                fs:SetPoint("LEFT", hdr, "LEFT", 0, 0)
                fs:SetPoint("RIGHT", hdr, "RIGHT", 0, 0)
                fs:SetJustifyH("LEFT")
                hdr:SetFontString(fs)
                hdr:SetText("")
                hdr.SetTextProxy = function(self2, txt)
                    fs:SetText(txt)
                end
                -- Hover highlight via vertex tint on the FontString.
                hdr:SetScript("OnEnter", function()
                    fs:SetTextColor(1, 1, 0.6)
                end)
                hdr:SetScript("OnLeave", function()
                    fs:SetTextColor(1, 1, 1)
                end)
                local sectionKey = entry.section
                hdr:SetScript("OnClick", function()
                    local db = NS.DB
                    if not db then
                        return
                    end
                    db.helpSectionsCollapsed = db.helpSectionsCollapsed or {}
                    db.helpSectionsCollapsed[sectionKey] =
                        not (db.helpSectionsCollapsed[sectionKey] == true)
                    refreshLayout(s)
                    PlaySound("igMainMenuOptionCheckBoxOn")
                end)
                renderItems[#renderItems + 1] = {
                    kind = "section",
                    widget = hdr,
                    section = sectionKey,
                    title = entry.title,
                }
                currentSection = sectionKey
            else
                -- Content entry: q FontString, a FontString, optional
                -- button, separator. WoW 3.3.5a FontStrings need an
                -- explicit SetWidth() call to engage word-wrap mode;
                -- anchor-derived width alone keeps the FontString in
                -- single-line mode and produces "..." truncation when
                -- the text overflows. setPanelWidth handles both: it
                -- calls SetWidth (enabling wrap) AND registers the
                -- widget for reactive resize. Value 4 matches the
                -- chrome inner width: chromeOuter uses two anchors that
                -- span panel - 32 (matching Keep List's listUI extent),
                -- inner chrome is inset 6px each side so chrome.width
                -- = panel - 44 = EC_PANEL_WIDTH - 4.
                local qfs = chrome:CreateFontString(nil, "ARTWORK", "GameFontNormal")
                EC_compCache.setPanelWidth(qfs, 4)
                qfs:SetJustifyH("LEFT")
                if qfs.SetWordWrap then
                    qfs:SetWordWrap(true)
                end
                qfs:SetText(string.format("|cffffff00%s|r", entry.q))

                local afs = chrome:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                EC_compCache.setPanelWidth(afs, 4)
                afs:SetJustifyH("LEFT")
                if afs.SetWordWrap then
                    afs:SetWordWrap(true)
                end
                afs:SetText(entry.a)

                renderItems[#renderItems + 1] = { kind = "q", widget = qfs, section = currentSection }
                renderItems[#renderItems + 1] = { kind = "a", widget = afs, section = currentSection }

                if entry.url then
                    -- Copyable URL button. Clicking pops up the EC_COPY_URL
                    -- StaticPopup pre-selected with the URL so the player
                    -- can Ctrl+C and paste into their browser.
                    local urlValue = entry.url
                    local btn = CreateFrame("Button", nil, chrome, "UIPanelButtonTemplate")
                    btn:SetSize(180, 22)
                    btn:SetText("Copy Discord URL")
                    btn:SetScript("OnClick", function()
                        EC_COPY_URL_DATA.url = urlValue
                        StaticPopup_Show("EC_COPY_URL")
                    end)
                    renderItems[#renderItems + 1] = { kind = "button", widget = btn, section = currentSection }
                elseif entry.panel then
                    local panelKey = entry.panel
                    -- Button label is resolved at OnClick time so panel
                    -- renames don't require updating the help table.
                    local btn = CreateFrame("Button", nil, chrome, "UIPanelButtonTemplate")
                    btn:SetSize(180, 22)
                    btn:SetText("Open Settings")
                    btn:SetScript("OnEnter", function()
                        local target = _G[panelKey]
                        if target and target.name then
                            btn:SetText("Open " .. target.name)
                        end
                    end)
                    btn:SetScript("OnLeave", function()
                        local target = _G[panelKey]
                        if target and target.name then
                            btn:SetText("Open " .. target.name)
                        end
                    end)
                    -- Resolve the label immediately on build so it
                    -- isn't generic until the first hover.
                    do
                        local target = _G[panelKey]
                        if target and target.name then
                            btn:SetText("Open " .. target.name)
                        end
                    end
                    btn:SetScript("OnClick", function()
                        local target = _G[panelKey]
                        if target and InterfaceOptionsFrame_OpenToCategory then
                            InterfaceOptionsFrame_OpenToCategory(target)
                            InterfaceOptionsFrame_OpenToCategory(target)
                        end
                    end)
                    renderItems[#renderItems + 1] = { kind = "button", widget = btn, section = currentSection }
                end

                -- Separator texture.
                local sep = chrome:CreateTexture(nil, "ARTWORK")
                sep:SetTexture(0.3, 0.3, 0.3, 0.6)
                sep:SetHeight(1)
                renderItems[#renderItems + 1] = { kind = "sep", widget = sep, section = currentSection }
            end
        end
        s._helpRenderItems = renderItems

        refreshLayout(s)
    end, true)
end)

InterfaceOptions_AddCategory(_G["EbonClearanceOptionsHelp"])
