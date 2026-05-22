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

-- Set-membership helper. Local copy of EbonClearance.lua's IsInSet
-- (different upvalue scope; pure function so duplication is cheap and
-- avoids a cross-file lookup on every tooltip refresh). Same pattern
-- as EbonClearance_Vendor.lua and EbonClearance_BagDisplay.lua.
local function IsInSet(setTable, itemID)
    if not itemID or not setTable then
        return false
    end
    local v = setTable[itemID]
    return (v == true) or (v == 1)
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
                statusLine = "|cff66ccff[EC]|r |cffffb84dAuto-Protected (Worn)|r"
            elseif autoTag == "upgrade" then
                statusLine = "|cff66ccff[EC]|r |cffffb84dAuto-Protected (Upgrade)|r"
            elseif autoTag == "set" then
                -- v2.13.0: items from a saved Blizzard Equipment Manager set.
                -- Most likely an off-set / dual-spec piece sitting in bags
                -- between swaps; the tag promotes to "(Worn)" the next time
                -- the user actually equips it (via protectEquipSlot's
                -- existing tag-refresh branch).
                statusLine = "|cff66ccff[EC]|r |cffffb84dAuto-Protected (Set)|r"
            else
                statusLine = "|cff66ccff[EC]|r |cffffb84dAuto-Protected|r"
            end
        else
            statusLine = "|cff66ccff[EC]|r |cffffb84dProtected|r"
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
        local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
        if IsEquippedItem(id) then
            statusLine = "|cff66ccff[EC]|r |cffffb84dWon't Sell - Currently Equipped|r"
        elseif not (sellPrice and sellPrice > 0) then
            statusLine = "|cff66ccff[EC]|r |cffffb84dWon't Sell - No Vendor Price|r"
        else
            statusLine = "|cff66ccff[EC]|r |cffb6ffb6Will Sell|r"
        end
    elseif DB.qualityRules then
        local _, _, quality, ilvl, _, _, _, _, equipLoc, _, sellPrice = GetItemInfo(id)
        -- Grey-quality invariant. EC_IsSellable's "isJunk" branch always
        -- matches a grey item with a positive sell price - independent of
        -- DB.qualityRules, useEquippedILvl, bind filter, or any other
        -- rule setting. Mirror that here so users see why an Item-Level
        -- 47 grey shoulderpad on their level-80 character will vendor.
        -- Reported by an in-game tester via Discord: "I dont see the Will
        -- Sell - Junk".
        if quality == 0 and sellPrice and sellPrice > 0 then
            statusLine = "|cff66ccff[EC]|r |cffb6ffb6Will Sell - Junk|r"
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
                    statusLine = "|cff66ccff[EC]|r |cffffb84dProtected - Quest item|r"
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
                    statusLine = "|cff66ccff[EC]|r |cffffb84dProtected - Profession tool|r"
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
                            "|cff66ccff[EC]|r |cffffb84dProtected - %s rule wants %s only|r",
                            rarityName,
                            fLabel
                        )
                    elseif matchedAgainstEquipped then
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6Will Sell - %s iLvl %d below equipped|r",
                            rarityName,
                            ilvl
                        )
                    elseif cap == 0 then
                        statusLine =
                            string.format("|cff66ccff[EC]|r |cffb6ffb6Will Sell - %s (no iLvl cap)|r", rarityName)
                    else
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6Will Sell - %s iLvl %d (cap %d)|r",
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
                            string.format("|cff66ccff[EC]|r |cffffb84dProtected - %s has no iLvl|r", rarityName)
                    else
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffffb84dProtected - %s iLvl %d (Potential Upgrade)|r",
                            rarityName,
                            ilvl
                        )
                    end
                elseif not hasVisibleILvl then
                    -- Fixed-cap mode; non-equippable has no visible iLvl.
                    statusLine = string.format(
                        "|cff66ccff[EC]|r |cffffb84dProtected - %s has no iLvl (cap %d active)|r",
                        rarityName,
                        cap
                    )
                else
                    -- Fixed-cap mode; equippable item iLvl above cap.
                    statusLine = string.format(
                        "|cff66ccff[EC]|r |cffffb84dProtected - %s above max iLvl (%d > %d)|r",
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
        local _, _, quality = GetItemInfo(id)
        if quality and quality >= 3 then
            local affix = EC_compCache.liveTooltipAffixData(tooltip, id)
            if affix then
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
                local autoDupe = DB.affixAllowExactDupes and EC_compCache.playerHasAffixDescription(affix.description)
                if manualAllow or autoDupe then
                    -- v2.27.0: list-destination label wins over the
                    -- auto-dupe info text. The destination tells the
                    -- user what's going to happen with this item; the
                    -- auto-dupe info only fills in when no list has
                    -- claimed it.
                    if IsInSet(DB.blacklist, id) then
                        -- Keep wins; leave the Protected / Auto-
                        -- Protected label alone.
                    elseif IsInSet(DB.deleteList, id) and DB.enableDeletion then
                        statusLine = "|cff66ccff[EC]|r |cffff4444Allowed - Delete|r"
                    elseif ADB and ADB.whitelist and IsInSet(ADB.whitelist, id) then
                        statusLine = "|cff66ccff[EC]|r |cffb6ffb6Allowed - Account Sell|r"
                    elseif IsInSet(DB.whitelist, id) then
                        statusLine = "|cff66ccff[EC]|r |cffb6ffb6Allowed - Character Sell|r"
                    elseif manualAllow then
                        statusLine = "|cff66ccff[EC]|r |cffffea80Allowed - Choose List|r"
                    else
                        -- autoDupe only, not on any list - keep the
                        -- v2.23.0 informational label.
                        statusLine = string.format(
                            "|cff66ccff[EC]|r |cffb6ffb6Allowed - %s %s already known|r",
                            affix.name or "affix",
                            (affix.rank and ("rank " .. affix.rank)) or ""
                        )
                    end
                else
                    statusLine = "|cff66ccff[EC]|r |cffffb84dProtected - Random affix|r"
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
        if ADB.allowedItems and ADB.allowedItems[id] then
            if IsInSet(DB.blacklist, id) then
                -- Kept wins; leave the earlier Protected / Auto-
                -- Protected label alone.
            elseif IsInSet(DB.deleteList, id) and DB.enableDeletion then
                statusLine = "|cff66ccff[EC]|r |cffff4444Allowed - Delete|r"
            elseif ADB and ADB.whitelist and IsInSet(ADB.whitelist, id) then
                statusLine = "|cff66ccff[EC]|r |cffb6ffb6Allowed - Account Sell|r"
            elseif IsInSet(DB.whitelist, id) then
                statusLine = "|cff66ccff[EC]|r |cffb6ffb6Allowed - Character Sell|r"
            else
                -- Marked allowed but no specific list chosen. "Allowed
                -- - Sell" reads as "this will be auto-sold" which is
                -- misleading - releasing the protection just opens
                -- the item up to the user's decision. The label is a
                -- call to action: pick a list.
                statusLine = "|cff66ccff[EC]|r |cffffea80Allowed - Choose List|r"
            end
        else
            statusLine = "|cff66ccff[EC]|r |cffffb84dProtected - Chance on hit|r"
        end
    end

    if statusLine then
        tooltip:AddLine(statusLine)
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
