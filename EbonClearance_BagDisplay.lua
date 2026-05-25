-- EbonClearance_BagDisplay - bag-slot sell-border tint + sellinfo inspector.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 6 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. This file owns the Release-1 bag-display layer:
--
--   * Sell-border tint helpers (sellBorderButtons weak-keyed registry,
--     applySellBorder, bagSlotWillSell, updateSellBordersForBagFrame,
--     installHostBagBorderHook). The opt-in coloured ring around bag-
--     slot frames whose items would be sold at the next vendor visit.
--     Hooks two surfaces: default ContainerFrame_Update and any host
--     bag UI's per-slot class detected via LibStub at runtime.
--   * NS.RefreshSellBorders body. Forward-declared as a no-op stub on
--     NS in EbonClearance.lua so the Character Settings panel toggle
--     can call it before this file's bag-display hooks install; this
--     file replaces the stub with the real body. Lives on NS (not as
--     a file-scope local) because the stub-and-reassign pattern needs
--     to cross the file boundary.
--   * EC_compCache.qualityNames lookup table used by describeSellability.
--   * Sellability-trace inspector (describeSellability + printSellabilityTrace).
--     Drives /ec sellinfo and Alt+Shift+Right-Click on a bag item.
--     Walks the same decision chain EC_IsSellable runs in the same order
--     and emits a chat-line trace explaining which predicates passed /
--     failed for a given slot.
--   * bagSlotFromButton helper - resolves a host-bag-UI button back to
--     (bag, slot) by walking GetBag/GetID where available with the
--     `button:GetParent():GetID() / button:GetID()` fallback.
--
-- Every helper is attached to EC_compCache (the shared cache table
-- created in EbonClearance_Core.lua), so call sites elsewhere in the
-- addon already resolve via the EC_compCache upvalue. No call-site
-- changes are needed in EbonClearance.lua for the cache helpers.
--
-- Cross-file dependencies read inline:
--   * NS.compCache             (Core)
--   * NS.IsSellable            (EbonClearance.lua) - the central sell
--                                predicate; bagSlotWillSell + describeSellability
--                                consult it
--   * NS.PrintNice / PrintNicef (EbonClearance.lua) - chat output for
--                                the sellinfo trace
--   * NS.scanTooltip           (EbonClearance.lua via the frame creation)
--   * NS.DB                    (EbonClearance.lua via EnsureDB) -
--                                captured as `local DB = NS.DB` at the
--                                start of each function that uses it
--   * NS.ADB                   (EbonClearance.lua via EnsureAccountDB)
--                                - same pattern

local NS = select(2, ...)
local EC_compCache = NS.compCache

local GetItemInfo = GetItemInfo
local GetContainerItemID = GetContainerItemID
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemLink = GetContainerItemLink
local GetContainerNumSlots = GetContainerNumSlots
local IsEquippedItem = IsEquippedItem

-- Set-membership helper. Local copy of EbonClearance.lua's IsInSet
-- (different upvalue scope; pure function so duplication is cheap and
-- avoids a cross-file lookup on every per-slot trace step). Matches
-- the same pattern used in EbonClearance_Vendor.lua.
local function IsInSet(setTable, itemID)
    return setTable and itemID and setTable[itemID] ~= nil
end

-- ===========================================================================
-- Bag display: sell-border tint
-- ===========================================================================
-- Opt-in coloured ring around bag-slot FRAMES whose items the current rule
-- chain would sell at the next vendor visit. The ring texture lives on a
-- frame-overlay sublevel; nothing is drawn on top of the item icon itself,
-- so the slot's quality border + icon stay pristine.
--
-- Three surfaces are decorated:
--   1. The default container frames (`ContainerFrame_Update` hook) - covers
--      the no-extra-bag-UI case and any user who hasn't installed a host
--      bag UI replacement.
--   2. The legacy AceAddon-3.0-registered host bag UI's per-slot class,
--      detected at runtime via LibStub. Re-hooks both the slot's per-call
--      update and its border-only update path so search-fade transitions
--      don't leave a stale ring behind.
--   3. The engine-table-exposure host bag UI's per-slot redraw path,
--      detected at runtime via the framework's global table + module
--      lookup. The slot button is reached through the bag-frame's
--      Bags[bagID][slotID] table.
--
-- Helpers hang off EC_compCache (not module-local) because the main chunk
-- sits near Lua 5.1's 200-local cap; the registry table is a junk drawer
-- specifically for this case. Decorated buttons are tracked in a weak-keyed
-- set so the toggle and colour picker can re-apply (or hide) the ring
-- across all visible bags without an extra event subscription. Recycled
-- / GC'd buttons drop out naturally via the weak-key metatable.

EC_compCache.sellBorderButtons = setmetatable({}, { __mode = "k" })

-- Set-membership helper. Local copy of EbonClearance.lua's IsInSet (same
-- pattern as the other split files; pure function so duplication is cheap).
local function IsInSet(setTable, itemID)
    if not itemID or not setTable then
        return false
    end
    local v = setTable[itemID]
    return (v == true) or (v == 1)
end

-- Per-category sell-verdict resolver. Returns one of the category string
-- keys defined in EnsureDB's DB.sellBorderCategories ("delete" /
-- "accountSell" / "charSell" / "junk" / "rule"), or nil when the slot
-- shouldn't be tinted at all.
--
-- Priority order matches the tooltip annotation:
--   1. Delete List (red) - highest visibility because deletion is
--      irreversible. Gated on DB.enableDeletion so toggling that flag
--      hides the tint.
--   2. Account Sell List - explicit user intent, account-wide scope.
--   3. Character Sell List - explicit user intent, per-character.
--   4. Junk - quality 0 with sell price. The "always sells" baseline.
--   5. Rule - per-rarity rule match (the v2.29 default tint case).
--
-- Returns nil cheaply when the master toggle is off, when the slot is
-- empty, when DB hasn't bootstrapped yet, or when no verdict applies.
function EC_compCache.bagSlotWillSellCategory(bag, slot)
    local DB = NS.DB
    if not (DB and DB.sellBorderEnabled) then
        return nil
    end
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return nil
    end
    -- Delete List path is separate from EC_IsSellable (which returns
    -- false for delete-listed items because they don't go through the
    -- merchant pipeline). Check it first so the red tint is honoured
    -- even though the item "won't sell" from EC_IsSellable's POV.
    if DB.enableDeletion and IsInSet(DB.deleteList, itemID) then
        return "delete"
    end
    -- Everything below this point requires the item to be sellable per
    -- the normal predicate chain. Filters out protected items,
    -- equipped items, items without a sell price, etc.
    local sellable = NS.IsSellable(bag, slot, false)
    if not sellable then
        return nil
    end
    local ADB = NS.ADB
    if ADB and IsInSet(ADB.whitelist, itemID) then
        return "accountSell"
    end
    if IsInSet(DB.whitelist, itemID) then
        return "charSell"
    end
    -- Junk = grey (quality 0) with positive sell price. EC_IsSellable
    -- returned true so we know it's sellable; the grey discriminator
    -- separates it from per-rarity-rule matches.
    local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
    if quality == 0 and sellPrice and sellPrice > 0 then
        return "junk"
    end
    -- Default: the per-rarity rule sweep matched. Gold tint by default
    -- (the v2.29 single-colour default).
    return "rule"
end

function EC_compCache.applySellBorder(button, _, bag, slot)
    local DB = NS.DB
    if not button then
        return
    end
    -- Stash (bag, slot) on the button so the refresh helper (called from
    -- the Character Settings toggle / colour picker / list mutation) can
    -- re-evaluate the predicate without re-walking the bag tree to figure
    -- out which slot this button currently represents.
    if bag and slot then
        button._ec_sellBag = bag
        button._ec_sellSlot = slot
    end
    -- Track every button we've ever decorated, even when the current
    -- verdict is "won't sell". Without this, a button that first paints
    -- with no tint (e.g. bags open with an item not yet on any list)
    -- never enters the registry, and a later list mutation that flips it
    -- to tinted can't find it during refresh. The set is weak-keyed so
    -- recycled / freed buttons drop out naturally.
    EC_compCache.sellBorderButtons[button] = true

    -- Master gate: feature disabled OR DB not yet bootstrapped.
    if not (DB and DB.sellBorderEnabled) then
        if button._ec_sellBorder then
            button._ec_sellBorder:Hide()
        end
        return
    end

    local category = (bag and slot) and EC_compCache.bagSlotWillSellCategory(bag, slot) or nil
    if not category then
        if button._ec_sellBorder then
            button._ec_sellBorder:Hide()
        end
        return
    end

    -- Per-category enable + colour lookup. A category with enabled =
    -- false (user opted out of that one tint) hides the border just
    -- like a no-verdict slot.
    local catSettings = DB.sellBorderCategories and DB.sellBorderCategories[category]
    if not (catSettings and catSettings.enabled and catSettings.color) then
        if button._ec_sellBorder then
            button._ec_sellBorder:Hide()
        end
        return
    end

    local b = button._ec_sellBorder
    if not b then
        -- OVERLAY sublevel 6 sits above the quality border at default
        -- sublevel; the ADD blend composes additively so a coloured ring
        -- reads on top of the quality colour without flattening it.
        b = button:CreateTexture(nil, "OVERLAY", nil, 6)
        b:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        b:SetBlendMode("ADD")
        b:SetPoint("CENTER", button)
        button._ec_sellBorder = b
    end
    -- Size the ring relative to the button each call so the visible
    -- glow hugs the slot edge consistently across host bag UIs with
    -- different button sizes. The 67/37 ratio matches Blizzard's
    -- default container slot (37 px button -> 67 px texture, glow at
    -- slot edge); smaller / larger host slots scale proportionally
    -- to preserve the same tight visual. Per-call (not per-create)
    -- so dynamic resizes by the host adapter still track.
    local sw = button:GetWidth()
    if not sw or sw <= 0 then
        sw = 37
    end
    local textureSize = math.floor(sw * 67 / 37 + 0.5)
    b:SetWidth(textureSize)
    b:SetHeight(textureSize)
    local c = catSettings.color
    b:SetVertexColor(c.r, c.g, c.b, c.a or 0.9)
    b:Show()
end

-- Boolean wrapper that returns whether the slot would tint under the
-- current settings. Preserved as a public predicate (callers expect a
-- bool); delegates to the category resolver. Returns true when the
-- master toggle is off only if a category WOULD have matched - kept
-- backwards compatible: any path that previously gated on
-- bagSlotWillSell still gates correctly.
function EC_compCache.bagSlotWillSell(bag, slot)
    return EC_compCache.bagSlotWillSellCategory(bag, slot) ~= nil
end

function EC_compCache.updateSellBordersForBagFrame(frame)
    if not (frame and frame.size) then
        return
    end
    local name = frame:GetName()
    if not name then
        return
    end
    local bag = frame:GetID()
    if not bag then
        return
    end
    -- Slot buttons are reverse-indexed in the frame's name: button "Item1"
    -- maps to the LAST slot visually, so iterate the size and reverse the
    -- index when building the global name.
    local apply = EC_compCache.applySellBorder
    local willSell = EC_compCache.bagSlotWillSell
    for slot = 1, frame.size do
        local button = _G[name .. "Item" .. (frame.size - slot + 1)]
        if button then
            apply(button, willSell(bag, slot), bag, slot)
        end
    end
end

if _G.ContainerFrame_Update then
    hooksecurefunc("ContainerFrame_Update", EC_compCache.updateSellBordersForBagFrame)
end

-- Host bag-UI adapter. Two surfaces are recognised, each with its own
-- install-once flag so the presence (or absence) of one host doesn't
-- block the other from installing:
--
--   1. Legacy AceAddon-3.0 host: per-slot class with :GetBag() /
--      :GetID() / :GetItem() / :IsCached() methods. Hook the slot
--      class's Update + UpdateBorder methods; force-repaint via the
--      host's per-frame UpdateEverything.
--   2. UI-replacement framework with an "engine table → module" exposure
--      pattern (table at _G, unpack to engine, engine:GetModule("Bags")).
--      The bags module exposes per-slot UpdateSlot(frame, bagID, slotID)
--      and the slot button lives at frame.Bags[bagID][slotID]. Hook the
--      method; force-repaint via the module's UpdateAllBagSlots.
--
-- `installHostBagBorderHook` is called from two sites in the event hub
-- (ADDON_LOADED and PLAYER_LOGIN + 2 s fallback); each attempt below is
-- idempotent through its own install flag.
function EC_compCache.installHostBagBorderHook()
    local apply = EC_compCache.applySellBorder
    local willSell = EC_compCache.bagSlotWillSell

    -- Attempt 1: legacy AceAddon-3.0-registered host. The slot class
    -- carries its own :GetBag()/:GetID()/:GetItem()/:IsCached() helpers
    -- so we resolve identity per-slot rather than via a container frame.
    local function tryLegacyHost()
        if EC_compCache._hostBagBorderHookInstalled then
            return
        end
        local LibStub = _G.LibStub
        if not LibStub then
            return
        end
        local ok, ace = pcall(LibStub, "AceAddon-3.0", true)
        if not ok or not ace or not ace.GetAddon then
            return
        end
        local ok2, host = pcall(ace.GetAddon, ace, "Bagnon")
        if not ok2 or not host or not host.ItemSlot then
            return
        end

        local ItemSlot = host.ItemSlot

        local function refresh(slot)
            if not (slot and slot.GetBag and slot.GetID) then
                return
            end
            if slot.IsCached and slot:IsCached() then
                apply(slot, false)
                return
            end
            local link = slot.GetItem and slot:GetItem()
            if not link then
                apply(slot, false)
                return
            end
            local bag, id = slot:GetBag(), slot:GetID()
            if not (bag and id) then
                return
            end
            apply(slot, willSell(bag, id), bag, id)
        end

        hooksecurefunc(ItemSlot, "Update", refresh)
        if ItemSlot.UpdateBorder then
            hooksecurefunc(ItemSlot, "UpdateBorder", refresh)
        end
        EC_compCache._hostBagBorderHookInstalled = true

        -- Force a one-shot repaint of any already-visible host bag frames.
        -- Without this, slots painted by the host BEFORE our hook installed
        -- sit with no border until the player triggers another host refresh
        -- (open bag, visit bank, move an item). The hook only fires forward.
        if host.frames then
            for _, frame in pairs(host.frames) do
                if frame and frame.UpdateEverything and frame.IsVisible and frame:IsVisible() then
                    pcall(frame.UpdateEverything, frame)
                end
            end
        end
    end

    -- Attempt 2: UI-replacement framework with the engine-table exposure
    -- pattern. The framework table is a global; unpack(table) yields
    -- (Engine, Locales, PrivateDB, ProfileDB, GlobalDB); Engine:GetModule
    -- ("Bags") returns the bag module B which exposes
    -- B:UpdateSlot(frame, bagID, slotID) as the per-slot redraw path.
    -- The slot button is reachable as frame.Bags[bagID][slotID].
    local function tryEngineHost()
        if EC_compCache._engineBagBorderHookInstalled then
            return
        end
        -- Detection code names the framework global directly because we
        -- have to know what to read off _G; the comment frames it
        -- neutrally per the project's third-party-naming rule. The
        -- exact global identifier is necessary for runtime resolution.
        local hostTable = _G.ElvUI
        if type(hostTable) ~= "table" then
            return
        end
        local ok, engine = pcall(unpack, hostTable)
        if not ok or type(engine) ~= "table" or type(engine.GetModule) ~= "function" then
            return
        end
        local ok2, B = pcall(engine.GetModule, engine, "Bags")
        if not ok2 or type(B) ~= "table" or type(B.UpdateSlot) ~= "function" then
            return
        end

        hooksecurefunc(B, "UpdateSlot", function(_self, frame, bagID, slotID)
            if not frame or type(frame.Bags) ~= "table" then
                return
            end
            local bag = frame.Bags[bagID]
            if not bag then
                return
            end
            local slotButton = bag[slotID]
            if not slotButton then
                return
            end
            apply(slotButton, willSell(bagID, slotID), bagID, slotID)
        end)

        EC_compCache._engineBagBorderHookInstalled = true

        -- Force a one-shot repaint of any already-visible bag frames.
        -- Same rationale as the legacy attempt above; slots painted
        -- before the hook installed otherwise sit with no border until
        -- the next host-driven slot refresh.
        if B.UpdateAllBagSlots then
            pcall(B.UpdateAllBagSlots, B)
        end

        -- Belt-and-braces direct paint by predictable global frame
        -- name. The host's Layout path creates slot buttons named
        -- "<bagFrameName>Bag<bagID>Slot<slotID>", and the bag frames
        -- the host builds eagerly during its module init are named
        -- ElvUI_ContainerFrame (main) and ElvUI_BankContainerFrame
        -- (bank, lazy). This loop runs even when B.UpdateAllBagSlots
        -- bailed (e.g. B.BagFrames not yet populated, or the host's
        -- bags feature disabled) so the first paint after EC install
        -- doesn't depend on a subsequent host-driven update firing.
        -- The names are needed for runtime lookup; comments stay
        -- neutral per the project's third-party-naming rule.
        local function paintByName(framePrefix, bagRange)
            for _, bagID in ipairs(bagRange) do
                local numSlots = GetContainerNumSlots(bagID)
                if numSlots and numSlots > 0 then
                    for slotID = 1, numSlots do
                        local name = framePrefix .. "Bag" .. bagID .. "Slot" .. slotID
                        local slot = _G[name]
                        if slot then
                            apply(slot, willSell(bagID, slotID), bagID, slotID)
                        end
                    end
                end
            end
        end
        paintByName("ElvUI_ContainerFrame", { 0, 1, 2, 3, 4 })
        if _G.ElvUI_BankContainerFrame then
            paintByName("ElvUI_BankContainerFrame", { -1, 5, 6, 7, 8, 9, 10 })
        end
    end

    tryLegacyHost()
    tryEngineHost()
end

-- Settings-flip refresh body. The forward-declared name was stubbed to a
-- no-op at file head; here we replace it with the real implementation so
-- toggling the checkbox or changing the colour repaints every decorated
-- slot button immediately, without waiting for the next bag event.
NS.RefreshSellBorders = function()
    local apply = EC_compCache.applySellBorder
    local willSell = EC_compCache.bagSlotWillSell
    for button in pairs(EC_compCache.sellBorderButtons) do
        local bag, slot = button._ec_sellBag, button._ec_sellSlot
        if bag and slot then
            apply(button, willSell(bag, slot), bag, slot)
        end
    end
end

-- ===========================================================================
-- Sellability trace: per-item predicate inspector
-- ===========================================================================
-- Walks the same decision chain EC_IsSellable runs, in the same order, and
-- emits a chat-line trace explaining which predicates passed / failed for a
-- given bag slot. Surfaced two ways:
--   * /ec sellinfo [bag] [slot] - defaults to the first non-empty bag slot
--   * Alt+Shift+Right-Click on a bag item - uses the existing
--     ContainerFrameItemButton_OnModifiedClick override path
--
-- The trace mirrors EC_IsSellable's logic deliberately rather than calling
-- into it because the goal is a per-step explanation, not the final boolean.
-- Both paths read the same DB fields and EC_compCache helpers so the trace
-- can't disagree with the live decision unless one falls out of sync; if you
-- touch EC_IsSellable, update this helper alongside.

EC_compCache.qualityNames =
    { [0] = "Junk", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary" }

function EC_compCache.describeSellability(bag, slot)
    local DB = NS.DB
    local ADB = NS.ADB
    local steps = {}
    local function step(name, passed, detail)
        steps[#steps + 1] = { name = name, passed = passed, detail = detail or "" }
    end

    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return {
            steps = { { name = "slot", passed = false, detail = "empty" } },
            wouldSell = false,
            summary = "Empty slot",
        }
    end

    local _, itemCount, locked = GetContainerItemInfo(bag, slot)
    if not itemCount or itemCount <= 0 then
        step("count", false, "no items in slot")
        return { steps = steps, wouldSell = false, summary = "Empty slot" }
    end

    local name, link, quality, ilvl, _, _, _, _, equipLoc, _, sellPrice = GetItemInfo(itemID)
    local qName = EC_compCache.qualityNames[quality or -1] or tostring(quality)
    step(
        "item",
        true,
        string.format(
            "%s |cffaaaaaa[id=%d, quality=%s, ilvl=%s, sellPrice=%s]|r",
            link or name or "?",
            itemID,
            qName,
            tostring(ilvl or 0),
            tostring(sellPrice or 0)
        )
    )

    if locked then
        step("locked", false, "slot is locked (mid-pickup) - sell would skip this tick")
    end

    local hasSellPrice = sellPrice and sellPrice > 0
    step("hasSellPrice", hasSellPrice, hasSellPrice and "yes" or "no (item cannot be vendored)")

    local isJunk = (quality == 0) and hasSellPrice
    step("greyAutoSell", isJunk, isJunk and "yes (grey with sell price)" or "n/a")

    local onCharSell = DB and IsInSet(DB.whitelist, itemID) or false
    local onAcctSell = ADB and IsInSet(ADB.whitelist, itemID) or false
    local whitelistPass = hasSellPrice and (onCharSell or onAcctSell)
    local sellListDetail
    if onCharSell and onAcctSell then
        sellListDetail = "yes (Character + Account Sell List)"
    elseif onCharSell then
        sellListDetail = "yes (Character Sell List)"
    elseif onAcctSell then
        sellListDetail = "yes (Account Sell List)"
    else
        sellListDetail = "no"
    end
    step("onSellList", whitelistPass, sellListDetail)

    local qualityPass = false
    local qualityDetail
    if hasSellPrice and quality and quality >= 1 and quality <= 4 and DB and DB.qualityRules then
        local rule = DB.qualityRules[quality]
        if rule and rule.enabled then
            if rule.useEquippedILvl then
                if
                    EC_compCache.isDowngradeVsEquipped
                    and EC_compCache.isDowngradeVsEquipped(itemID, ilvl, equipLoc)
                then
                    qualityPass = true
                    qualityDetail = string.format("%s, ilvl=%s below equipped slot", qName, tostring(ilvl))
                else
                    qualityDetail = string.format("%s, ilvl=%s not below equipped slot", qName, tostring(ilvl))
                end
            else
                local cap = rule.maxILvl or 0
                local hasVisibleILvl = equipLoc and equipLoc ~= "" and ilvl and ilvl > 0
                if cap == 0 then
                    qualityPass = true
                    qualityDetail = string.format("%s rule enabled, no ilvl cap", qName)
                elseif hasVisibleILvl and ilvl <= cap then
                    qualityPass = true
                    qualityDetail = string.format("%s, ilvl=%d <= cap=%d", qName, ilvl, cap)
                elseif not hasVisibleILvl then
                    qualityDetail =
                        string.format("%s, no visible ilvl (reagent/consumable/etc - protected from cap)", qName)
                else
                    qualityDetail = string.format("%s, ilvl=%d > cap=%d", qName, ilvl, cap)
                end
            end
            if qualityPass then
                local bindFilter = rule.bindFilter or "any"
                if bindFilter ~= "any" then
                    local bindType = EC_compCache.getBindType and EC_compCache.getBindType(bag, slot) or "any"
                    if bindFilter ~= bindType then
                        qualityPass = false
                        qualityDetail = qualityDetail
                            .. string.format(" - bindFilter=%s but item is %s", bindFilter, bindType)
                    else
                        qualityDetail = qualityDetail .. string.format(", bindFilter=%s match", bindFilter)
                    end
                end
            end
        else
            qualityDetail = string.format("%s rule disabled", qName)
        end
    else
        qualityDetail = "no rule applies (no sell price OR quality outside Common..Epic)"
    end
    step("qualityRule", qualityPass, qualityDetail)

    if qualityPass and EC_compCache.isQuestItem and EC_compCache.isQuestItem(itemID) then
        qualityPass = false
        step("questSafetyNet", false, "vetoed - quest item; explicit Sell List entry would override this")
    end

    if
        qualityPass
        and EC_compCache.baselineProtectedIDs
        and EC_compCache.baselineProtectedIDs[itemID]
        and not (ADB and ADB.allowedItems and ADB.allowedItems[itemID])
    then
        qualityPass = false
        step(
            "professionToolSafetyNet",
            false,
            "vetoed - baseline-protected profession tool; explicit Sell List entry or Allow Sell override would bypass this"
        )
    end

    local equipped = IsEquippedItem(itemID)
    if equipped then
        step("equippedVeto", false, "VETO - item is currently equipped")
    else
        step("equippedVeto", true, "not currently equipped")
    end

    local blacklisted = DB and IsInSet(DB.blacklist, itemID) or false
    if blacklisted then
        step("keepListVeto", false, "VETO - on Keep List")
    else
        step("keepListVeto", true, "not on Keep List")
    end

    local affixProtected = false
    if (whitelistPass or qualityPass) and DB and DB.protectAffixedRareItems and quality and quality >= 3 then
        local affix = EC_compCache.bagSlotAffixData and EC_compCache.bagSlotAffixData(bag, slot)
        if affix then
            local affixKey = affix.description
                and EC_compCache.normaliseAffixDesc
                and EC_compCache.normaliseAffixDesc(affix.description)
            local manualAllow = affixKey and ADB and ADB.allowedAffixes and ADB.allowedAffixes[affixKey]
            local autoDupe = DB.affixAllowExactDupes
                and EC_compCache.playerHasAffixDescription
                and EC_compCache.playerHasAffixDescription(affix.description)
            if manualAllow then
                step("affixProtection", true, "affix present but allow-listed (manual)")
            elseif autoDupe then
                step("affixProtection", true, "affix present but allow-listed (rank dupe)")
            else
                affixProtected = true
                step("affixProtection", false, "VETO - Rare/Epic random affix detected")
            end
        else
            step("affixProtection", true, "no random affix on this item")
        end
    else
        -- v2.32.x: split the catch-all "n/a" message into the actual
        -- gate that failed. The earlier blanket "quality below Rare or
        -- protection off" was misleading on items that ARE Rare/Epic
        -- with protection ON but where the sell-side gate doesn't fire
        -- because the item has no positive sell signal (no Sell List
        -- entry, no per-rarity rule match). The delete-side affix gate
        -- in BuildQueue is a separate path; see `/ec sellinfo` is sell-
        -- only by design.
        if not DB or not DB.protectAffixedRareItems then
            step("affixProtection", true, "n/a (affix protection toggle off)")
        elseif not quality or quality < 3 then
            step("affixProtection", true, "n/a (quality below Rare)")
        else
            step("affixProtection", true, "n/a (no positive sell signal - affix gate only fires for items the sell rules would otherwise touch; delete-list path is checked separately)")
        end
    end

    local procProtected = false
    if
        qualityPass
        and DB
        and DB.protectChanceOnHitItems
        and EC_compCache.itemHasChanceOnHit
        and EC_compCache.itemHasChanceOnHit(bag, slot, itemID)
    then
        if ADB and ADB.allowedItems and ADB.allowedItems[itemID] then
            step("chanceOnHitProtection", true, "chance-on-hit proc, but item allow-listed")
        else
            procProtected = true
            qualityPass = false
            step("chanceOnHitProtection", false, "VETO - chance-on-hit proc detected (downgrades qualityRule veto)")
        end
    else
        step("chanceOnHitProtection", true, "n/a")
    end

    local positiveSignal = isJunk or qualityPass or whitelistPass
    local vetoed = equipped or blacklisted or affixProtected
    local wouldSell = positiveSignal and not vetoed and not locked

    local summary
    if wouldSell then
        summary = "|cff00ff00WILL SELL at the next vendor visit|r"
    elseif not positiveSignal then
        summary = "|cffffb84dwon't sell - no rule matched|r"
    elseif vetoed then
        summary = "|cffff4444won't sell - protected|r"
    else
        summary = "|cffff4444won't sell|r"
    end

    return { steps = steps, wouldSell = wouldSell, summary = summary }
end

function EC_compCache.printSellabilityTrace(bag, slot)
    if not (bag and slot) then
        for b = 0, 4 do
            local n = GetContainerNumSlots(b) or 0
            for s = 1, n do
                if GetContainerItemID(b, s) then
                    bag, slot = b, s
                    break
                end
            end
            if bag then
                break
            end
        end
    end
    if not (bag and slot) then
        NS.PrintNice("|cffff4444No items in any bag to inspect.|r")
        return
    end

    local r = EC_compCache.describeSellability(bag, slot)
    NS.PrintNicef("|cffffff00=== Sellability trace: bag %d slot %d ===|r", bag, slot)
    for _, s in ipairs(r.steps) do
        local marker = s.passed and "|cff00ff00+|r" or "|cffff4444-|r"
        NS.PrintNicef("  %s %s - %s", marker, s.name, s.detail)
    end
    NS.PrintNice("Result: " .. r.summary)
end

-- Look up a bag-slot button's (bag, slot) from a hover. Works for both the
-- default container buttons (parent frame's GetID + button's GetID under
-- the reverse-index naming convention) and host bag-UI slot instances that
-- expose GetBag/GetID methods directly.
function EC_compCache.bagSlotFromButton(button)
    if not button then
        return nil
    end
    if button.GetBag and button.GetID then
        local ok1, b = pcall(button.GetBag, button)
        local ok2, s = pcall(button.GetID, button)
        if ok1 and ok2 and b and s then
            return b, s
        end
    end
    local parent = button.GetParent and button:GetParent()
    if parent and parent.GetID then
        local pid = parent:GetID()
        local sid = button.GetID and button:GetID()
        if pid and sid then
            return pid, sid
        end
    end
    return nil
end
