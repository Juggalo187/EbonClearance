-- EbonClearance_Tooltip - bag-item tooltip annotation system.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8c of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The tooltip annotation surface that decorates every bag item with a
-- coloured line indicating what EC will do (Will Sell / Protected -
-- Random affix / Protected - Chance on hit / Allowed - Account Sell /
-- etc.). Self-contained UI subsystem hooked at addon load against
-- GameTooltip + ItemRefTooltip.
--
-- Moved into this file:
--   * EC_AnnotateTooltip - the per-tooltip body that walks the same
--     decision chain EC_IsSellable runs and produces a humane status
--     line. Mirrors EC_IsSellable rather than calling it (different
--     output: needs to know WHY, not just yes/no). See
--     docs/CODE_REVIEW.md item 6 for the documented parallel-impl
--     tradeoff.
--   * EC_ClearTooltipFlag - resets the per-tooltip dedupe flag
--     (recipe tooltips fire OnTooltipSetItem twice; the flag prevents
--     duplicate annotation lines).
--   * EC_InstallTooltipHookOnce - installs the OnTooltipSetItem +
--     OnTooltipCleared hooks on GameTooltip + ItemRefTooltip. Exposed
--     as NS.InstallTooltipHookOnce.
--
-- Cross-file dependencies read inline:
--   * NS.compCache (Core) - bagSlotAffixData, itemHasChanceOnHit,
--     normaliseAffixDesc, playerHasAffixDescription, isDowngradeVsEquipped,
--     getEquippedILvl, INVTYPE_SLOTS, baselineProtectedIDs, qualityNames
--   * NS.DB / NS.ADB - captured at function entry
--   * NS.IsAddonEnabledForChar (EbonClearance.lua) - early-out gate
--   * Various WoW globals - ITEM_QUALITY_COLORS, GetItemInfo, etc.

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- Set-membership helper. Captures the canonical NS.IsInSet (defined in
-- EbonClearance_Core.lua); per-call cost is one local read.
local IsInSet = NS.IsInSet

-- Allow Sell destination rewrite. Walks the explicit-list precedence
-- chain when a protection (affix / chance-on-hit / tome) has been
-- manually allow-listed and decides what the tooltip should say:
--   * Keep List membership returns currentLine unchanged (the earlier
--     Keep label stays - blacklist wins over Allow Sell).
--   * deleteList -> Will Delete
--   * account whitelist -> Will Sell (your Account List)
--   * character whitelist -> Will Sell (your Character List)
--   * no list claims it -> nil, and the caller picks the fallback
--     ("Override on - add to a list to sell" for Allow Sell prompts,
--     "Will Sell (you have this affix)" for the autoDupe path, etc.).
-- The pre-extraction code duplicated this chain across the affix and
-- tome blocks; centralising removes the drift surface so a future
-- protection rule reuses the same precedence without paired edits.
local function destinationLabel(id, currentLine)
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB then
        return nil
    end
    if IsInSet(DB.blacklist, id) then
        return currentLine
    end
    if IsInSet(DB.deleteList, id) and DB.enableDeletion then
        return "|cff66ccff[EC]|r |cffff4444Will Delete|r"
    end
    if ADB and ADB.whitelist and IsInSet(ADB.whitelist, id) then
        return "|cff66ccff[EC]|r |cffb6ffb6Will Sell (your Account List)|r"
    end
    if IsInSet(DB.whitelist, id) then
        return "|cff66ccff[EC]|r |cffb6ffb6Will Sell (your Character List)|r"
    end
    return nil
end

-- Tooltip annotation. Adds a coloured line indicating whether EbonClearance
-- will sell, protect, or delete the hovered item. Hooked once on addon load
-- against GameTooltip and ItemRefTooltip (chat-linked items use the latter).
--
-- Dedupe: recipe tooltips fire OnTooltipSetItem twice (once for the recipe,
-- once for the embedded result), so we flag the tooltip after adding a line
-- and clear the flag when the tooltip is reset.
local EC_tooltipHooked = false

local function EC_AnnotateTooltip(tooltip)
    local DB = NS.DB
    local ADB = NS.ADB
    if not DB or not tooltip or not tooltip.GetItem then
        return
    end
    -- Honour the addon-enabled toggle and per-character allowlist. If the
    -- addon won't act on the item, don't mislead the user by annotating it.
    if NS.IsAddonEnabledForChar and not NS.IsAddonEnabledForChar() then
        return
    end
    if tooltip.__EC_annotated then
        return
    end
    local _, link = tooltip:GetItem()
    if not link then
        return
    end
    local id = tonumber(link:match("|Hitem:(%d+)"))
    if not id then
        return
    end

    -- Hoisted GetItemInfo: the function used to call it three separate
    -- times (whitelist branch reading sellPrice, qualityRules branch
    -- reading quality/ilvl/equipLoc/sellPrice, affix block reading
    -- quality). All read different subsets of the same cached tuple, so
    -- a single call up here serves every branch below without changing
    -- any per-branch nil-handling. Uncached items still surface as
    -- "Won't Sell (no value)" via the existing sellPrice nil-guards.
    local _, _, itemQuality, itemILvl, _, _, _, _, itemEquipLoc, _, itemSellPrice = GetItemInfo(id)

    local statusLine
    if IsInSet(DB.blacklist, id) then
        -- v2.10.0: distinguish "user manually blacklisted this" from "the
        -- auto-protect-equipped path added it". DB.blacklistAuto is stamped
        -- only by the equipment handler / one-shot sync; manual adds don't
        -- touch it. The suffix is concatenated onto the existing label so
        -- the annotation stays a single line. The suffix tells the user
        -- "this is on Keep because you equipped it, not because you hand-
        -- added it" - useful when they expected an item to vendor and want
        -- to know why the rules are leaving it alone. The override is the
        -- existing Alt+Right-Click context menu's "Remove from Blacklist"
        -- row.
        local autoTag = DB.blacklistAuto and DB.blacklistAuto[id]
        if autoTag then
            -- v2.12.0: origin-aware label. The auto-protect path stamps
            -- one of two string tags so the tooltip can tell the user
            -- WHICH rule kept the item. Legacy boolean-true entries from
            -- v2.10.0 / v2.11.0 fall back to the generic label.
            if autoTag == "equipped" then
                statusLine = "|cff66ccff[EC]|r |cffffb84dKeep (equipped)|r"
            elseif autoTag == "upgrade" then
                statusLine = "|cff66ccff[EC]|r |cffffb84dKeep (upgrade)|r"
            elseif autoTag == "set" then
                -- v2.13.0: items from a saved Blizzard Equipment Manager set.
                -- Most likely an off-set / dual-spec piece sitting in bags
                -- between swaps; the tag promotes to "(equipped)" the next
                -- time the user actually equips it.
                statusLine = "|cff66ccff[EC]|r |cffffb84dKeep (in gear set)|r"
            else
                statusLine = "|cff66ccff[EC]|r |cffffb84dKeep (auto)|r"
            end
        else
            statusLine = "|cff66ccff[EC]|r |cffffb84dKeep|r"
        end
    elseif IsInSet(DB.deleteList, id) and DB.enableDeletion then
        statusLine = "|cff66ccff[EC]|r |cffff4444Will Delete|r"
    elseif IsInSet(DB.whitelist, id) or (ADB and IsInSet(ADB.whitelist, id)) then
        -- Honesty: EC_IsSellable also requires sellPrice > 0 and not currently
        -- equipped. Without these checks the tooltip used to claim "Will Sell"
        -- on items that the merchant cycle correctly refuses (custom items
        -- with no vendor price, or items the player has equipped). Surface
        -- both reasons in warning-yellow so the user sees them at the point
        -- of decision instead of wondering why the cycle skipped them.
        if IsEquippedItem(id) then
            statusLine = "|cff66ccff[EC]|r |cffffb84dWon't Sell (equipped)|r"
        elseif not (itemSellPrice and itemSellPrice > 0) then
            statusLine = "|cff66ccff[EC]|r |cffffb84dWon't Sell (no value)|r"
        else
            statusLine = "|cff66ccff[EC]|r |cffb6ffb6Will Sell|r"
        end
    elseif DB.qualityRules then
        local quality, ilvl, equipLoc, sellPrice = itemQuality, itemILvl, itemEquipLoc, itemSellPrice
        -- Grey-quality invariant. EC_IsSellable's "isJunk" branch always
        -- matches a grey item with a positive sell price - independent of
        -- DB.qualityRules, useEquippedILvl, bind filter, or any other
        -- rule setting. Mirror that here so users see why an Item-Level
        -- 47 grey shoulderpad on their level-80 character will vendor.
        -- Reported by an in-game tester via Discord: "I dont see the Will
        -- Sell - Junk".
        if quality == 0 and sellPrice and sellPrice > 0 then
            statusLine = "|cff66ccff[EC]|r |cffb6ffb6Will Sell (junk)|r"
        elseif quality and quality >= 1 and quality <= 4 and sellPrice and sellPrice > 0 then
            local rule = DB.qualityRules[quality]
            if rule and rule.enabled then
                local rarityName = (quality == 1) and "White"
                    or (quality == 2) and "Green"
                    or (quality == 3) and "Blue"
                    or "Epic"
                local hasVisibleILvl = equipLoc and equipLoc ~= "" and ilvl and ilvl > 0
                -- v2.12.0: split on useEquippedILvl mode. Dynamic-cap mode
                -- mirrors EC_compCache.isDowngradeVsEquipped semantics so
                -- the tooltip is honest about what will / won't sell.
                local matchesILvl = false
                local matchedAgainstEquipped = false
                local cap = rule.maxILvl or 0
                if rule.useEquippedILvl then
                    matchedAgainstEquipped = true
                    if hasVisibleILvl and EC_compCache.isDowngradeVsEquipped(id, ilvl, equipLoc) then
                        matchesILvl = true
                    end
                else
                    matchesILvl = (cap == 0) or (hasVisibleILvl and ilvl <= cap)
                end
                if matchesILvl and EC_compCache.isQuestItem(id) then
                    -- v2.13.x: quest-item safety-net honesty. After the
                    -- v2.13.x narrowing, EC_IsSellable returns false when
                    -- a qualityPass auto-rule would catch a quest-class
                    -- item. Reflect that here so the tooltip doesn't
                    -- claim "Will Sell" when the merchant cycle will
                    -- silently skip. The whitelist match path above is
                    -- unaffected (whitelist overrides safety net).
                    statusLine = "|cff66ccff[EC]|r |cffffb84dKeep (quest item)|r"
                elseif
                    matchesILvl
                    and EC_compCache.baselineProtectedIDs
                    and EC_compCache.baselineProtectedIDs[id]
                    and not (ADB and ADB.allowedItems and ADB.allowedItems[id])
                then
                    -- Baseline profession-tool safety net (Monrad's report).
                    -- Same honesty as the quest-item case: the auto-rule
                    -- sweep would have caught the tool but EC_IsSellable
                    -- vetoes; the tooltip should say so. Allow Sell
                    -- override unsets this annotation (the item flows to
                    -- the normal sell path).
                    statusLine = "|cff66ccff[EC]|r |cffffb84dKeep (profession tool)|r"
                elseif matchesILvl then
                    -- v2.10.0: bind-filter check. EC_IsSellable applies this
                    -- AFTER the iLvl gate; the tooltip annotation has to
                    -- mirror the same chain so users get an accurate read
                    -- of what the rules will do at the next vendor visit.
                    local bindFilter = rule.bindFilter or "any"
                    local bindRejected = false
                    if bindFilter ~= "any" then
                        local bindType = EC_compCache.getBindTypeFromTooltip(tooltip, id)
                        if bindType ~= bindFilter then
                            bindRejected = true
                        end
                    end
                    if bindRejected then
                        local fLabel = (bindFilter == "boe") and "BoE" or "BoP"
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84dKeep (%s rule wants %s only)|r",
                            rarityName,
                            fLabel
                        )
                    elseif matchedAgainstEquipped then
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6Will Sell (%s, lower than equipped)|r",
                            rarityName
                        )
                    elseif cap == 0 then
                        statusLine =
                            string.format("|cff66ccff[EC]|r |cffb6ffb6Will Sell (%s)|r", rarityName)
                    else
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6Will Sell (%s, iLvl %d, cap %d)|r",
                            rarityName,
                            ilvl,
                            cap
                        )
                    end
                elseif matchedAgainstEquipped then
                    -- Dynamic-cap mode and the item didn't qualify. Two
                    -- distinct cases collapse to one user-facing message:
                    --   * "empty_slot": rule short-circuited because at least
                    --     one candidate slot is empty - the looted item could
                    --     fill it (relevant for dual-wielders).
                    --   * "at_or_above": actual iLvl compare happened and the
                    --     looted item met or exceeded the lowest populated
                    --     slot - could be an upgrade for the weakest slot in
                    --     a multi-slot equipLoc, or a same-iLvl sidegrade.
                    -- Both cases mean "kept because this could be useful";
                    -- "Potential Upgrade" is the user-friendly framing.
                    if not hasVisibleILvl then
                        statusLine =
                            string.format("|cff66ccff[EC]|r |cffffb84dKeep (%s, no item level)|r", rarityName)
                    else
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84dKeep (%s, possible upgrade)|r",
                            rarityName
                        )
                    end
                elseif not hasVisibleILvl then
                    -- Fixed-cap mode; non-equippable has no visible iLvl.
                    statusLine = string.format(
                        "|cff66ccff[EC]|r |cffffb84dKeep (%s, no item level)|r",
                        rarityName
                    )
                else
                    -- Fixed-cap mode; equippable item iLvl above cap.
                    statusLine = string.format(
                        "|cff66ccff[EC]|r |cffffb84dKeep (%s, iLvl %d, cap %d)|r",
                        rarityName,
                        ilvl,
                        cap
                    )
                end
            end
        end
    end

    -- v2.19.0: PE roguelite affix protection - tooltip honesty pass.
    -- If the if/elseif chain above resolved to a would-sell or would-
    -- delete verdict but DB.protectAffixedRareItems is on AND the item
    -- is Rare/Epic AND has an affix, override the label to make it
    -- clear that the merchant cycle won't actually act on this
    -- specific bag instance.
    -- v2.20.0: liveTooltipHasAffix now requires the rank-suffix
    -- pattern in the title, narrowing the check so standard
    -- ItemRandomSuffix.dbc entries (`of the Bear`, `of the Sorcerer`)
    -- don't get protected as PE roguelite affixes.
    -- v2.23.0: when the exact-dupe gate releases an affixed item back
    -- to the sell / delete chain, the status line shows "Allowed -
    -- affix already known" instead of "Protected - Random affix". The
    -- match is by description text scraped from the item's @affix@
    -- line vs the descriptions on engraving spells in the player's
    -- spellbook (see EC_compCache.refreshKnownAffixes).
    -- v2.27.0: always surface the affix state when the item has one
    -- (not only when the would-vendor chain produced a label). Mirrors
    -- the v2.26.0 chance-on-hit tooltip pass so Epic items with
    -- affixes also show their state.
    if DB.protectAffixedRareItems then
        local quality = itemQuality
        if quality and quality >= 3 then
            local affix = EC_compCache.liveTooltipAffixData(tooltip, id)
            if affix then
                -- v2.32.x lazy catalog refresh. Pick up any newly-
                -- learned ExtractionService affixes BEFORE the
                -- playerHasAffixDescription lookup so a player who
                -- learned an affix at the Anvil and immediately
                -- hovers a new drop sees the correct verdict on the
                -- FIRST hover (no waiting for the BAG_UPDATE debounce
                -- + spell-event debounce + chunked scan to settle).
                -- The dirty-check is a cheap count comparison that
                -- early-returns when nothing changed; when dirty, the
                -- v2.32.x refactor does an incremental synchronous
                -- merge so the live map reflects the new state by
                -- the time playerHasAffixDescription reads it below.
                if EC_compCache.refreshExtractionIfDirty then
                    EC_compCache.refreshExtractionIfDirty()
                end
                -- v2.27.0: backfill the affix-meta flag for itemIDs
                -- already on a list. Pre-v2.27 entries didn't get
                -- stamped at add time; hovering the item now after
                -- /reload fills in the flag so the panel renders the
                -- (affix-gated) tag.
                local onAnyList = IsInSet(DB.whitelist, id)
                    or (ADB and IsInSet(ADB.whitelist, id))
                    or IsInSet(DB.blacklist, id)
                    or IsInSet(DB.deleteList, id)
                if onAnyList and ADB then
                    ADB.affixedListedItems = ADB.affixedListedItems or {}
                    ADB.affixedListedItems[id] = true
                end
                local affixKey = affix.description and EC_compCache.normaliseAffixDesc(affix.description)
                local manualAllow = affixKey and ADB.allowedAffixes and ADB.allowedAffixes[affixKey]
                -- v2.30.x: compute "does the player know this affix at
                -- this rank" INDEPENDENTLY of affixAllowExactDupes so the
                -- "Protected - Affix known" branch can fire even when the
                -- setting is off. Pre-v2.30 the only way to surface
                -- knowledge was via autoDupe, which silently rolled the
                -- "known" state into a blanket "Random affix" label
                -- whenever the dupe-allow flag was off.
                local playerKnows = affix.description
                    and EC_compCache.playerHasAffixDescription
                    and EC_compCache.playerHasAffixDescription(affix.description)
                    or false
                local autoDupe = DB.affixAllowExactDupes and playerKnows
                if manualAllow or autoDupe then
                    -- Destination-list label wins. destinationLabel walks
                    -- the explicit-list precedence chain (Keep / Delete /
                    -- Account Sell / Character Sell) and returns the
                    -- appropriate label; Keep List leaves the earlier
                    -- Keep label unchanged. Returns nil when no list
                    -- claims it, in which case the manualAllow / autoDupe
                    -- branch picks its own fallback.
                    local newLine = destinationLabel(id, statusLine)
                    if newLine then
                        statusLine = newLine
                    elseif manualAllow then
                        -- Allow Sell is on but no list claims it. An
                        -- existing "Will Sell (...)" verdict from the
                        -- quality-rule sweep already tells the truth;
                        -- otherwise prompt the user to pick a list.
                        if not (statusLine and statusLine:find("Will Sell", 1, true)) then
                            statusLine = "|cff66ccff[EC]|r |cffffea80Override on - add to a list to sell|r"
                        end
                    else
                        -- autoDupe only, not on any list. The dupe-
                        -- allow setting is on, the player already has
                        -- this affix, so future drops can sell.
                        statusLine = "|cff66ccff[EC]|r |cffb6ffb6Will Sell (you have this affix)|r"
                    end
                elseif playerKnows then
                    -- The player has extracted this affix, but the
                    -- dupe-allow setting is off so protection still
                    -- holds. Flipping that setting on (Protection
                    -- Settings) makes drops sell.
                    statusLine = "|cff66ccff[EC]|r |cffffb84dKeep (affix you have)|r"
                else
                    statusLine = "|cff66ccff[EC]|r |cffffb84dKeep (new affix)|r"
                end
            end
        end
    end

    -- v2.20.0: Chance-on-hit protection - tooltip honesty pass.
    -- v2.20.1: narrowed to "Will Sell - <rarity>" verdicts (the
    -- quality-rule sweep labels). Plain "Will Sell" (whitelist match)
    -- and "Will Delete" (Delete List match) stay as-is because they
    -- represent explicit user intent; chance-on-hit protection no
    -- longer overrides those (the user has typically already
    -- extracted the proc and is dumping the base item).
    --
    -- Discriminator: quality-rule labels always have " - " separator
    -- after "Will Sell" (e.g. "Will Sell - Green iLvl 25 (cap 35)").
    -- The plain whitelist label is just "Will Sell" with no separator.
    -- Lua pattern "Will Sell %- " (escaped dash) matches only the
    -- quality-rule variant.
    -- v2.26.0: chance-on-hit state is always surfaced when the item
    -- has the proc, regardless of whether the auto-rule sweep would
    -- fire. Epic items (default quality rule off) still show the
    -- protection state.
    --
    -- Unmarked items always show "Protected - Chance on hit" (the
    -- protection overrides any other status).
    --
    -- Marked items show the actual destination so the user can see
    -- where the item will go: explicit list membership (Account Sell,
    -- Character Sell, Delete) takes the specific label; otherwise
    -- the item will fall through to the quality-rule sweep and the
    -- label is plain "Allowed - Sell". Keep List membership wins
    -- everything else; we don't override the Kept label.
    if DB.protectChanceOnHitItems and EC_compCache.liveTooltipHasChanceOnHit(tooltip, id) then
        -- Explicit user lists override the safety net. The protection
        -- veto in EC_IsSellable only narrows qualityPass; whitelistPass
        -- (explicit Sell List entry) keeps the item sellable. BuildQueue's
        -- delete path also doesn't gate on chance-on-hit (v2.20.1 note).
        -- So if the item is on Sell / Account Sell / Delete / Keep, the
        -- earlier annotation chain produced the correct verdict already;
        -- don't overwrite it.
        local onExplicit = IsInSet(DB.blacklist, id)
            or IsInSet(DB.whitelist, id)
            or (ADB and IsInSet(ADB.whitelist, id))
            or (IsInSet(DB.deleteList, id) and DB.enableDeletion)
        if onExplicit then
            -- Explicit list verdict stands; leave statusLine alone.
        elseif ADB.allowedItems and ADB.allowedItems[id] then
            -- Allow Sell is on. If a quality-rule already produced a
            -- "Will Sell (...)" verdict, leave it alone. Otherwise
            -- prompt the user to pick a list.
            if statusLine and statusLine:find("Will Sell", 1, true) then
                -- Existing verdict stands.
            else
                statusLine = "|cff66ccff[EC]|r |cffffea80Override on - add to a list to sell|r"
            end
        else
            statusLine = "|cff66ccff[EC]|r |cffffb84dKeep (chance-on-hit proc)|r"
        end
    end

    -- Tome protection annotation. Same precedence shape as chance-on-
    -- hit above: a Keep List entry (blacklist) leaves any earlier
    -- Protected / Auto-Protected label alone; an Allow Sell mark
    -- (ADB.allowedItems) rewrites to the destination list; the
    -- unmarked default is "Protected - Tome (unlearned)" or
    -- "Protected - Tome". The aggressive "all tomes" toggle wins over
    -- "unlearned only" - same precedence as EC_IsSellable.
    local tomeProtected = false
    local tomeReason
    if (DB.protectAllTomes or DB.protectUnlearnedTomes)
        and EC_compCache.liveTooltipIsTome(tooltip, id)
    then
        -- Label the protection accurately. GetItemInfo's class is
        -- "Recipe" for BOTH profession crafting items (Plans /
        -- Schematic / Pattern / Formula / Recipe / Design / Manual)
        -- AND generic spell-teaching tomes (class spell books, mount
        -- scrolls, PE Tome of Echo). The distinguishing field is the
        -- subtype - profession recipes carry a profession-name
        -- subtype; everything else falls through to "Tome".
        local kindLabel = (EC_compCache.tomeKind and EC_compCache.tomeKind(id)) or "Tome"
        if DB.protectAllTomes then
            tomeProtected = true
            tomeReason = EC_compCache.liveTooltipPlayerKnowsTome(tooltip, id)
                and ("(" .. kindLabel .. " you have)")
                or ("(new " .. kindLabel .. ")")
        elseif DB.protectUnlearnedTomes
            and not EC_compCache.liveTooltipPlayerKnowsTome(tooltip, id)
        then
            tomeProtected = true
            tomeReason = "(new " .. kindLabel .. ")"
        end
    end
    if tomeProtected then
        -- Tome protection HARD-VETOES in EC_IsSellable regardless of
        -- Sell List membership, so the Keep label is the truth. Keep
        -- List membership stays. Allow Sell override flips to the
        -- destination-list label.
        if IsInSet(DB.blacklist, id) then
            -- Keep List wins; leave the earlier Keep label alone.
        elseif ADB.allowedItems and ADB.allowedItems[id] then
            -- destinationLabel walks the explicit-list precedence chain.
            -- Returns nil when no list claims it; the fallback picks an
            -- existing quality-rule "Will Sell" verdict if there is one,
            -- otherwise prompts the user to pick a list.
            local newLine = destinationLabel(id, statusLine)
            if newLine then
                statusLine = newLine
            elseif not (statusLine and statusLine:find("Will Sell", 1, true)) then
                statusLine = "|cff66ccff[EC]|r |cffffea80Override on - add to a list to sell|r"
            end
        else
            statusLine = "|cff66ccff[EC]|r |cffffb84dKeep " .. tomeReason .. "|r"
        end
    end

    if statusLine then
        tooltip:AddLine(statusLine)
    end
    -- Opt-in item-ID annotation. Surfaces the numeric itemID under the
    -- EC verdict line for users filing bug reports or authoring Keep /
    -- Sell / Delete entries by ID. The id has already been parsed at
    -- the top of this function from the |Hitem:NNNN| link, so this is a
    -- single conditional AddLine - no extra parsing cost.
    if DB.showItemIDOnTooltip then
        tooltip:AddLine(string.format("|cff666666Item ID: %d|r", id))
    end
    -- Discoverability hint for the v2.3.0 right-click context menu. Shown on
    -- every bag/item-link tooltip so users know the action is available.
    tooltip:AddLine("|cff666666Alt+Right-Click for EbonClearance menu|r")
    tooltip.__EC_annotated = true
    tooltip:Show()
end

local function EC_ClearTooltipFlag(tooltip)
    if tooltip then
        tooltip.__EC_annotated = nil
    end
end

local function EC_InstallTooltipHookOnce()
    if EC_tooltipHooked then
        return
    end
    EC_tooltipHooked = true
    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", EC_AnnotateTooltip)
        GameTooltip:HookScript("OnTooltipCleared", EC_ClearTooltipFlag)
    end
    if ItemRefTooltip and ItemRefTooltip.HookScript then
        ItemRefTooltip:HookScript("OnTooltipSetItem", EC_AnnotateTooltip)
        ItemRefTooltip:HookScript("OnTooltipCleared", EC_ClearTooltipFlag)
    end
end

NS.InstallTooltipHookOnce = EC_InstallTooltipHookOnce
