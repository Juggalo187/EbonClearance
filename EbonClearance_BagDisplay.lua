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
-- Two surfaces are decorated:
--   1. The default container frames (`ContainerFrame_Update` hook) — covers
--      the no-extra-bag-UI case and any user who hasn't installed a host
--      bag UI replacement.
--   2. The host bag UI's per-slot class, when detected at runtime via
--      LibStub. Re-hooks both the slot's per-call update and its
--      border-only update path so search-fade transitions don't leave a
--      stale ring behind.
--
-- Helpers hang off EC_compCache (not module-local) because the main chunk
-- sits near Lua 5.1's 200-local cap; the registry table is a junk drawer
-- specifically for this case. Decorated buttons are tracked in a weak-keyed
-- set so the toggle and colour picker can re-apply (or hide) the ring
-- across all visible bags without an extra event subscription. Recycled
-- / GC'd buttons drop out naturally via the weak-key metatable.

EC_compCache.sellBorderButtons = setmetatable({}, { __mode = "k" })

function EC_compCache.applySellBorder(button, willSell, bag, slot)
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
    -- Track every button we've ever decorated, even when the current verdict
    -- is "won't sell". Without this, a button that first paints with
    -- willSell=false (e.g. bags open with an item not yet on any list) never
    -- enters the registry, and a later list mutation that flips it to
    -- willSell=true can't find it during refresh. The set is weak-keyed so
    -- recycled / freed buttons drop out naturally.
    EC_compCache.sellBorderButtons[button] = true
    if not (willSell and DB and DB.sellBorderEnabled) then
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
        b:SetWidth(67)
        b:SetHeight(67)
        b:SetPoint("CENTER", button)
        button._ec_sellBorder = b
    end
    local c = DB.sellBorderColor
    b:SetVertexColor(c.r, c.g, c.b, c.a or 0.9)
    b:Show()
end

-- Resolve the willSell predicate for one bag slot. Returns false cheaply
-- when the slot is empty, when the toggle is off, or when DB hasn't yet
-- bootstrapped (e.g. an early frame paint before EnsureDB runs).
function EC_compCache.bagSlotWillSell(bag, slot)
    local DB = NS.DB
    if not (DB and DB.sellBorderEnabled) then
        return false
    end
    local link = GetContainerItemLink(bag, slot)
    if not link then
        return false
    end
    return (NS.IsSellable(bag, slot, false)) or false
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

-- Host bag-UI adapter. The hosted slot class exposes :GetBag(), :GetID(),
-- :GetItem(), and :IsCached(); the latter flags cross-character views where
-- our character-scoped rule chain doesn't apply, so the border is hidden
-- regardless of the toggle.
function EC_compCache.installHostBagBorderHook()
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
    local apply = EC_compCache.applySellBorder
    local willSell = EC_compCache.bagSlotWillSell

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
--   * /ec sellinfo [bag] [slot] — defaults to the first non-empty bag slot
--   * Alt+Shift+Right-Click on a bag item — uses the existing
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
        step("locked", false, "slot is locked (mid-pickup) — sell would skip this tick")
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
                        string.format("%s, no visible ilvl (reagent/consumable/etc — protected from cap)", qName)
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
                            .. string.format(" — bindFilter=%s but item is %s", bindFilter, bindType)
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
        step("questSafetyNet", false, "vetoed — quest item; explicit Sell List entry would override this")
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
            "vetoed — baseline-protected profession tool; explicit Sell List entry or Allow Sell override would bypass this"
        )
    end

    local equipped = IsEquippedItem(itemID)
    if equipped then
        step("equippedVeto", false, "VETO — item is currently equipped")
    else
        step("equippedVeto", true, "not currently equipped")
    end

    local blacklisted = DB and IsInSet(DB.blacklist, itemID) or false
    if blacklisted then
        step("keepListVeto", false, "VETO — on Keep List")
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
                step("affixProtection", false, "VETO — Rare/Epic random affix detected")
            end
        else
            step("affixProtection", true, "no random affix on this item")
        end
    else
        step("affixProtection", true, "n/a (quality below Rare or protection off)")
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
            step("chanceOnHitProtection", false, "VETO — chance-on-hit proc detected (downgrades qualityRule veto)")
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
        summary = "|cffffb84dwon't sell — no rule matched|r"
    elseif vetoed then
        summary = "|cffff4444won't sell — protected|r"
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
        NS.PrintNicef("  %s %s — %s", marker, s.name, s.detail)
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
