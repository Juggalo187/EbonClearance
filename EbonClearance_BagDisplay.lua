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
--     NS in EbonClearance_Events.lua so the Character Settings panel toggle
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
-- changes are needed in EbonClearance_Events.lua for the cache helpers.
--
-- Cross-file dependencies read inline:
--   * NS.compCache             (Core)
--   * NS.IsSellable            (EbonClearance_Events.lua) - the central sell
--                                predicate; bagSlotWillSell + describeSellability
--                                consult it
--   * NS.PrintNice / PrintNicef (EbonClearance_Events.lua) - chat output for
--                                the sellinfo trace
--   * NS.scanTooltip           (EbonClearance_Events.lua via the frame creation)
--   * NS.DB                    (EbonClearance_Events.lua via EnsureDB) -
--                                captured as `local DB = NS.DB` at the
--                                start of each function that uses it
--   * NS.ADB                   (EbonClearance_Events.lua via EnsureAccountDB)
--                                - same pattern

local NS = select(2, ...)
local EC_compCache = NS.compCache
local L = NS.L

local GetItemInfo = GetItemInfo
local GetContainerItemID = GetContainerItemID
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerItemLink = GetContainerItemLink
local GetContainerNumSlots = GetContainerNumSlots
local IsEquippedItem = IsEquippedItem

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

-- Set-membership helper. Captures the canonical NS.IsInSet (defined in
-- EbonClearance_Core.lua); per-call cost is one local read.
local IsInSet = NS.IsInSet

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
    -- v2.37.0: Keep List verdict. Keep-listed items also return false
    -- from EC_IsSellable (that's how the protection works), so the
    -- check has to happen BEFORE the sellable bail. The auto-tag
    -- (DB.blacklistAuto) filter excludes equipped / upgrade / set-
    -- tagged entries; the "keep" tint is for MANUAL Keep List adds
    -- only - the visual-reassurance use case targets explicit user
    -- intent, not addon-driven auto-protections. See
    -- docs/specs/2026-05-28-keep-highlighting-design.md.
    if IsInSet(DB.blacklist, itemID) and not (DB.blacklistAuto and DB.blacklistAuto[itemID]) then
        return "keep"
    end
    -- v2.37.5: random-affix marker. Cached once because we want it to
    -- act as a fallback in two places: (a) when the item is protected
    -- (sellable=false, returned nil before this fix) and (b) when the
    -- item would otherwise fall through to the gold "rule" default.
    -- Explicit user Sell List adds below still take precedence so the
    -- player's deliberate categorisation overrides the at-a-glance
    -- marker.
    local affixCat = DB.sellBorderCategories and DB.sellBorderCategories.affix
    local hasAffixForBorder = affixCat
        and affixCat.enabled
        and EC_compCache.bagSlotAffixData
        and EC_compCache.bagSlotAffixData(bag, slot) ~= nil
    -- Everything below this point requires the item to be sellable per
    -- the normal predicate chain. Filters out protected items,
    -- equipped items, items without a sell price, etc.
    local sellable = NS.IsSellable(bag, slot, false)
    if not sellable then
        if hasAffixForBorder then
            return "affix"
        end
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
    -- v2.37.5: affix overrides the default "rule" tint so the marker
    -- isn't lost on rare/epic affixed items that match a quality rule.
    if hasAffixForBorder then
        return "affix"
    end
    -- Default: the per-rarity rule sweep matched. Gold tint by default
    -- (the v2.29 single-colour default).
    return "rule"
end

function EC_compCache.applySellBorder(button, bag, slot)
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
    -- index when building the global name. applySellBorder resolves the
    -- per-slot verdict internally via bagSlotWillSellCategory, so callers
    -- don't pre-compute it here.
    local apply = EC_compCache.applySellBorder
    for slot = 1, frame.size do
        local button = _G[name .. "Item" .. (frame.size - slot + 1)]
        if button then
            apply(button, bag, slot)
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
                apply(slot)
                return
            end
            local link = slot.GetItem and slot:GetItem()
            if not link then
                apply(slot)
                return
            end
            local bag, id = slot:GetBag(), slot:GetID()
            if not (bag and id) then
                return
            end
            apply(slot, bag, id)
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
            apply(slotButton, bagID, slotID)
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
                            apply(slot, bagID, slotID)
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
    for button in pairs(EC_compCache.sellBorderButtons) do
        local bag, slot = button._ec_sellBag, button._ec_sellSlot
        if bag and slot then
            apply(button, bag, slot)
        end
    end
end

-- ===========================================================================
-- v2.37.0 (Borrow C): item-level text overlay
-- ===========================================================================
-- Quality-coloured "N" text in the bottom-right corner of slot buttons
-- holding equippable gear. Three surfaces, each independently toggled
-- by Item Highlighting: bags (container + bank), paperdoll (character
-- sheet + inspect), merchant (vendor + buyback). The equipLoc
-- whitelist filters consumables / quest items / non-gear so the text
-- only appears where iLvl is meaningful. Master toggle defaults OFF;
-- when first enabled, bags seeds ON and the other two surfaces stay
-- OFF until the player ticks them. See
-- docs/specs/2026-05-28-keep-highlighting-design.md (Borrow C).

local EC_ITEM_LEVEL_EQUIP_LOCS = {
    INVTYPE_HEAD = true,
    INVTYPE_NECK = true,
    INVTYPE_SHOULDER = true,
    INVTYPE_CHEST = true,
    INVTYPE_ROBE = true,
    INVTYPE_WAIST = true,
    INVTYPE_LEGS = true,
    INVTYPE_FEET = true,
    INVTYPE_WRIST = true,
    INVTYPE_HAND = true,
    INVTYPE_FINGER = true,
    INVTYPE_TRINKET = true,
    INVTYPE_CLOAK = true,
    INVTYPE_WEAPON = true,
    INVTYPE_SHIELD = true,
    INVTYPE_2HWEAPON = true,
    INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_HOLDABLE = true,
    INVTYPE_RANGED = true,
    INVTYPE_THROWN = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_RELIC = true,
}

EC_compCache.itemLevelTexts = setmetatable({}, { __mode = "k" })

-- v2.37.0 (Borrow C polish): user-configurable font size for the iLvl
-- text. SetFontObject locks in the Blizzard font, then SetFont rewrites
-- the size to the player's chosen value (clamped 6-20 in EnsureDB).
-- Called from EC_ensureItemLevelText on first paint and from
-- NS.RefreshItemLevelOverlay so the slider change takes effect on
-- already-painted slots.
local function EC_applyItemLevelFont(fs)
    if not fs then
        return
    end
    fs:SetFontObject("NumberFontNormalSmall")
    local fontFile, _, fontFlags = fs:GetFont()
    if not fontFile then
        return
    end
    local DB = NS.DB
    local size = (DB and DB.itemLevelOverlay and DB.itemLevelOverlay.fontSize) or 12
    if size < 6 then
        size = 6
    elseif size > 20 then
        size = 20
    end
    fs:SetFont(fontFile, size, fontFlags or "")
end

local function EC_ensureItemLevelText(button)
    if not button then
        return nil
    end
    local existing = EC_compCache.itemLevelTexts[button]
    if existing then
        return existing
    end
    -- OVERLAY sublevel 7 (max) so the text renders above the host bag
    -- UI's own per-slot overlays (quality borders, stack-count text,
    -- new-item glow). Without an explicit sublevel the default 0 puts
    -- the FontString under those textures on hosts that paint on
    -- OVERLAY too, which read as "the iLvl toggle did nothing" on
    -- the bags surface.
    local fs = button:CreateFontString(nil, "OVERLAY", nil, 7)
    EC_applyItemLevelFont(fs)
    fs:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
    fs:SetJustifyH("RIGHT")
    fs:SetJustifyV("BOTTOM")
    fs:SetShadowColor(0, 0, 0, 0.95)
    fs:SetShadowOffset(1, -1)
    fs:Hide()
    EC_compCache.itemLevelTexts[button] = fs
    return fs
end

-- Returns iLvl iff the link points to equippable gear via the equipLoc
-- whitelist. Shirts (INVTYPE_BODY) and tabards (INVTYPE_TABARD) are
-- deliberately excluded because their iLvl is cosmetic / meaningless.
function EC_compCache.getGearItemLevel(itemLink)
    if not itemLink then
        return nil
    end
    local _, _, _, itemLevel, _, _, _, _, equipLoc = GetItemInfo(itemLink)
    if not itemLevel or itemLevel <= 0 then
        return nil
    end
    if not equipLoc or not EC_ITEM_LEVEL_EQUIP_LOCS[equipLoc] then
        return nil
    end
    return itemLevel
end

function EC_compCache.getGearQualityRGB(itemLink, fallbackQuality)
    local quality = fallbackQuality
    if not quality and itemLink then
        local _, _, q = GetItemInfo(itemLink)
        quality = q
    end
    if quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
        local c = ITEM_QUALITY_COLORS[quality]
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

local function EC_itemLevelSurfaceEnabled(surface)
    local DB = NS.DB
    if not (DB and DB.itemLevelOverlay and DB.itemLevelOverlay.enabled) then
        return false
    end
    return DB.itemLevelOverlay[surface] and true or false
end

function EC_compCache.applyItemLevelOverlay(button, itemLink, fallbackQuality, surface)
    if not button then
        return
    end
    button._ec_iLvlSurface = surface
    local fs = EC_ensureItemLevelText(button)
    if not fs then
        return
    end
    if not EC_itemLevelSurfaceEnabled(surface) then
        fs:Hide()
        return
    end
    local iLvl = EC_compCache.getGearItemLevel(itemLink)
    if not iLvl then
        fs:Hide()
        return
    end
    local r, g, b = EC_compCache.getGearQualityRGB(itemLink, fallbackQuality)
    fs:SetText(tostring(iLvl))
    fs:SetTextColor(r, g, b)
    fs:Show()
end

local function EC_applyContainerItemLevel(frame)
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
    for slot = 1, frame.size do
        local button = _G[name .. "Item" .. (frame.size - slot + 1)]
        if button then
            local link = GetContainerItemLink(bag, slot)
            local _, _, _, q = GetContainerItemInfo(bag, slot)
            EC_compCache.applyItemLevelOverlay(button, link, q, "bags")
        end
    end
end
if _G.ContainerFrame_Update then
    hooksecurefunc("ContainerFrame_Update", EC_applyContainerItemLevel)
end

-- v2.37.0 (Borrow C polish): host bag-UI adapter for the item-level
-- overlay. Mirrors EC_compCache.installHostBagBorderHook above - same
-- two host patterns (legacy AceAddon-3.0 host with ItemSlot class;
-- engine-table-exposure host with Bags module), same idempotent
-- install flags, same one-shot repaint of already-visible bag frames.
-- Without this, players running with a host bag UI installed see iLvl
-- text only on character sheet + merchant; the bags surface paints
-- nothing because the default ContainerFrame_Update hook never fires
-- (the host replaced the underlying bag display).
function EC_compCache.installHostBagItemLevelHook()
    local apply = EC_compCache.applyItemLevelOverlay

    local function tryLegacyHost()
        if EC_compCache._hostBagItemLevelHookInstalled then
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
            local bag, id = slot:GetBag(), slot:GetID()
            if not (bag and id) then
                return
            end
            local link
            if slot.GetItem then
                link = slot:GetItem()
            end
            if not link then
                link = GetContainerItemLink(bag, id)
            end
            local _, _, _, q = GetContainerItemInfo(bag, id)
            apply(slot, link, q, "bags")
        end
        hooksecurefunc(ItemSlot, "Update", refresh)
        if ItemSlot.UpdateBorder then
            hooksecurefunc(ItemSlot, "UpdateBorder", refresh)
        end
        EC_compCache._hostBagItemLevelHookInstalled = true
        if host.frames then
            for _, frame in pairs(host.frames) do
                if frame and frame.UpdateEverything and frame.IsVisible and frame:IsVisible() then
                    pcall(frame.UpdateEverything, frame)
                end
            end
        end
    end

    local function tryEngineHost()
        if EC_compCache._engineBagItemLevelHookInstalled then
            return
        end
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
            local link = GetContainerItemLink(bagID, slotID)
            local _, _, _, q = GetContainerItemInfo(bagID, slotID)
            apply(slotButton, link, q, "bags")
        end)
        EC_compCache._engineBagItemLevelHookInstalled = true
        if B.UpdateAllBagSlots then
            pcall(B.UpdateAllBagSlots, B)
        end
    end

    tryLegacyHost()
    tryEngineHost()
end

local function EC_applyBankItemLevel()
    if not (BankFrame and BankFrame:IsShown()) then
        return
    end
    local numSlots = NUM_BANKGENERIC_SLOTS or 28
    for index = 1, numSlots do
        local button = _G["BankFrameItem" .. index]
        if button then
            local link = GetContainerItemLink(-1, index)
            local _, _, _, q = GetContainerItemInfo(-1, index)
            EC_compCache.applyItemLevelOverlay(button, link, q, "bags")
        end
    end
end
if BankFrame and BankFrame.HookScript then
    BankFrame:HookScript("OnShow", EC_applyBankItemLevel)
end

local function EC_applyPaperDollItemLevel(button)
    if not button then
        return
    end
    local slotID = button:GetID()
    if not slotID or slotID == 0 then
        return
    end
    local link = GetInventoryItemLink("player", slotID)
    -- v2.37.x audit fix: GetInventoryItemQuality doesn't exist in
    -- 3.3.5a (Cataclysm+ API), so the previous defensive call always
    -- short-circuited to nil. Derive quality from the link instead;
    -- getGearQualityRGB does the same fallback internally but reading
    -- it once here keeps the call uniform with the bags surface.
    local quality = link and select(3, GetItemInfo(link)) or nil
    EC_compCache.applyItemLevelOverlay(button, link, quality, "paperdoll")
end
if _G.PaperDollItemSlotButton_Update then
    hooksecurefunc("PaperDollItemSlotButton_Update", EC_applyPaperDollItemLevel)
end

local function EC_applyInspectItemLevel(button)
    if not button then
        return
    end
    local slotID = button:GetID()
    if not slotID or slotID == 0 then
        return
    end
    local unit = (InspectFrame and InspectFrame.unit) or (UnitExists("target") and "target") or nil
    if not unit then
        return
    end
    local link = GetInventoryItemLink(unit, slotID)
    -- v2.37.x audit fix: same as the paperdoll path above - derive
    -- quality from the link rather than via the Cataclysm-only API.
    local quality = link and select(3, GetItemInfo(link)) or nil
    EC_compCache.applyItemLevelOverlay(button, link, quality, "paperdoll")
end
if _G.InspectPaperDollItemSlotButton_Update then
    hooksecurefunc("InspectPaperDollItemSlotButton_Update", EC_applyInspectItemLevel)
end

local function EC_applyMerchantItemLevel()
    if not (MerchantFrame and MerchantFrame:IsShown()) then
        return
    end
    local page = MerchantFrame.page or 1
    local isBuyback = MerchantFrame.selectedTab == 2
    local perPage = isBuyback and (BUYBACK_ITEMS_PER_PAGE or 12) or (MERCHANT_ITEMS_PER_PAGE or 10)
    for index = 1, perPage do
        local button = _G["MerchantItem" .. index .. "ItemButton"]
        if button then
            local itemIndex = ((page - 1) * perPage) + index
            local link
            if isBuyback and GetBuybackItemLink then
                link = GetBuybackItemLink(itemIndex)
            elseif GetMerchantItemLink then
                link = GetMerchantItemLink(itemIndex)
            end
            EC_compCache.applyItemLevelOverlay(button, link, nil, "merchant")
        end
    end
end
if _G.MerchantFrame_Update then
    hooksecurefunc("MerchantFrame_Update", EC_applyMerchantItemLevel)
end

local EC_PAPERDOLL_SLOTS = {
    "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot",
    "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot",
    "Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot",
    "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

-- v2.37.0 polish: per-button repaint helper for the bags surface.
-- Used by NS.RefreshItemLevelOverlay to re-paint every bag slot in the
-- registry without relying on the host bag-UI's broad-repaint method
-- fanning out to every slot's Update. Some host bag UIs redraw the
-- frame layout on a broad-repaint call but do not re-fire the per-slot
-- Update method on slots whose inventory data hasn't changed, so a
-- master-toggle OFF -> ON cycle could leave the FontStrings hidden
-- until the slots got their next live update (which only fires on
-- bag-content change, not on a settings toggle). Direct re-derive
-- sidesteps that.
local function EC_repaintBagButton(button)
    if not button then
        return
    end
    local bag, slot
    if button.GetBag and button.GetID then
        -- Host bag-UI slot class: the slot resolves its own identity
        -- via methods on the slot object. Standard ContainerFrame slot
        -- buttons have GetID but no GetBag, so this branch is for
        -- third-party bag-UI replacements only.
        local ok, b = pcall(button.GetBag, button)
        if ok then
            bag = b
        end
        local ok2, s = pcall(button.GetID, button)
        if ok2 then
            slot = s
        end
    end
    if not bag then
        -- Standard ContainerFrame slot: button:GetID() is the slot
        -- index; parent:GetID() is the bag index. Reverse the slot
        -- index because ContainerFrame numbers buttons right-to-left.
        local parent = button.GetParent and button:GetParent()
        local parentBag = parent and parent.GetID and parent:GetID()
        local rawSlot = button.GetID and button:GetID()
        if parentBag and rawSlot then
            bag = parentBag
            slot = rawSlot
        end
    end
    if bag and slot then
        local link = GetContainerItemLink(bag, slot)
        local _, _, _, q = GetContainerItemInfo(bag, slot)
        EC_compCache.applyItemLevelOverlay(button, link, q, "bags")
    end
end

-- v2.37.0 (Borrow C): repaint every registered button. Called from the
-- Item Highlighting panel toggles so changes take effect immediately
-- without waiting for the next BAG_UPDATE / paperdoll event. Iterates
-- the weak-keyed registry to clear stale text on disabled surfaces,
-- then re-fires the per-surface walker for whichever surfaces are
-- currently enabled.
NS.RefreshItemLevelOverlay = function()
    -- Re-apply the font first so a slider change rewrites the size on
    -- every existing FontString (including ones that won't be repainted
    -- below because their surface is now disabled - we still want the
    -- next time they show to use the right size).
    for _, fs in pairs(EC_compCache.itemLevelTexts) do
        EC_applyItemLevelFont(fs)
    end
    for button, fs in pairs(EC_compCache.itemLevelTexts) do
        if fs and not EC_itemLevelSurfaceEnabled(button._ec_iLvlSurface or "bags") then
            fs:Hide()
        end
    end
    if EC_itemLevelSurfaceEnabled("bags") then
        -- Walk the standard ContainerFrame stack first (covers slots
        -- visible under the default Blizzard bag UI).
        for i = 1, (NUM_CONTAINER_FRAMES or 13) do
            local frame = _G["ContainerFrame" .. i]
            if frame and frame:IsShown() then
                EC_applyContainerItemLevel(frame)
            end
        end
        EC_applyBankItemLevel()
        -- Then re-paint every registered bag-surface button directly.
        -- This catches host-bag-UI slots that were painted earlier
        -- whose host doesn't re-fire its per-slot Update on a settings
        -- toggle (broad-repaint methods skip slots with unchanged data).
        for button in pairs(EC_compCache.itemLevelTexts) do
            if button._ec_iLvlSurface == "bags" then
                EC_repaintBagButton(button)
            end
        end
    end
    if EC_itemLevelSurfaceEnabled("paperdoll") then
        if CharacterFrame and CharacterFrame:IsShown() then
            for _, slotName in ipairs(EC_PAPERDOLL_SLOTS) do
                local button = _G["Character" .. slotName]
                if button then
                    EC_applyPaperDollItemLevel(button)
                end
            end
        end
    end
    if EC_itemLevelSurfaceEnabled("merchant") then
        EC_applyMerchantItemLevel()
    end
    -- v2.37.0 polish: nudge the host bag-UI frameworks to repaint so a
    -- player who just ticked the "On bags" sub-toggle doesn't have to
    -- open + close their bags to see iLvl text appear on the visible
    -- slots. The host's per-slot Update method (which our hook
    -- intercepts) only fires when the host decides to refresh - usually
    -- on bag-open / inventory-change events. Calling the host's
    -- broad-repaint method here forces a refresh now.
    if EC_itemLevelSurfaceEnabled("bags") then
        local LibStub = _G.LibStub
        if LibStub then
            local ok, ace = pcall(LibStub, "AceAddon-3.0", true)
            if ok and ace and ace.GetAddon then
                local ok2, host = pcall(ace.GetAddon, ace, "Bagnon")
                if ok2 and host and host.frames then
                    for _, frame in pairs(host.frames) do
                        if frame and frame.UpdateEverything and frame.IsVisible and frame:IsVisible() then
                            pcall(frame.UpdateEverything, frame)
                        end
                    end
                end
            end
        end
        local hostTable = _G.ElvUI
        if type(hostTable) == "table" then
            local ok, engine = pcall(unpack, hostTable)
            if ok and type(engine) == "table" and type(engine.GetModule) == "function" then
                local ok2, B = pcall(engine.GetModule, engine, "Bags")
                if ok2 and type(B) == "table" and B.UpdateAllBagSlots then
                    pcall(B.UpdateAllBagSlots, B)
                end
            end
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
    { [0] = L["Junk"], [1] = L["Common"], [2] = L["Uncommon"], [3] = L["Rare"], [4] = L["Epic"], [5] = L["Legendary"] }

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
            steps = { { name = "slot", passed = false, detail = L["empty"] } },
            wouldSell = false,
            summary = L["Empty slot"],
        }
    end

    local _, itemCount, locked = GetContainerItemInfo(bag, slot)
    if not itemCount or itemCount <= 0 then
        step("count", false, L["no items in slot"])
        return { steps = steps, wouldSell = false, summary = L["Empty slot"] }
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
        step("locked", false, L["slot is locked (mid-pickup) - sell would skip this tick"])
    end

    local hasSellPrice = sellPrice and sellPrice > 0
    step("hasSellPrice", hasSellPrice, hasSellPrice and L["yes"] or L["no (item cannot be vendored)"])

    -- Delete List wins over every sell signal (v2.37.0). Check it first
    -- so the trace agrees with the bag tint + tooltip annotation, and
    -- with BuildQueue's per-slot dispatch which now checks Delete List
    -- before the sell branch. When the item is on the Delete List + the
    -- Enable Deletion master toggle is on, the cycle queues this slot
    -- as `type = "delete"` and ignores any sell signal further down.
    local onDeleteList = DB and IsInSet(DB.deleteList, itemID) or false
    local deletionEnabled = DB and DB.enableDeletion == true
    local willDelete = onDeleteList and deletionEnabled
    if willDelete then
        step("deleteListVerdict", true, L["WILL DELETE - on Delete List, Enable Deletion is on"])
    elseif onDeleteList then
        step(
            "deleteListVerdict",
            true,
            L["on Delete List but Enable Deletion is OFF - falling through to sell rules"]
        )
    else
        step("deleteListVerdict", true, L["not on Delete List"])
    end

    local isJunk = (quality == 0) and hasSellPrice
    step("greyAutoSell", isJunk, isJunk and L["yes (grey with sell price)"] or L["n/a"])

    local onCharSell = DB and IsInSet(DB.whitelist, itemID) or false
    local onAcctSell = ADB and IsInSet(ADB.whitelist, itemID) or false
    local whitelistPass = hasSellPrice and (onCharSell or onAcctSell)
    local sellListDetail
    if onCharSell and onAcctSell then
        sellListDetail = L["yes (Character + Account Sell List)"]
    elseif onCharSell then
        sellListDetail = L["yes (Character Sell List)"]
    elseif onAcctSell then
        sellListDetail = L["yes (Account Sell List)"]
    else
        sellListDetail = L["no"]
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
        qualityDetail = L["no rule applies (no sell price OR quality outside Common..Epic)"]
    end
    step("qualityRule", qualityPass, qualityDetail)

    -- v2.44.0: affix-rank floor + "Allow selling affixes you already
    -- have" are both standalone sell rules now (hoisted into
    -- EC_IsSellable's positive-signal check). Mirror them here so
    -- /ec sellinfo agrees with the merchant cycle's verdict.
    local affixDataForTrace = (quality and quality >= 3) and EC_compCache.bagSlotAffixData(bag, slot) or nil
    local affixRankPass = DB and DB.affixMinSellRank
        and DB.affixMinSellRank > 0
        and affixDataForTrace
        and affixDataForTrace.rank
        and affixDataForTrace.rank < DB.affixMinSellRank
        or false
    if affixRankPass then
        step("affixRankRule", true, string.format(
            "rank %d is below your 'Sell affixes below rank %d' setting",
            affixDataForTrace.rank,
            DB.affixMinSellRank
        ))
    elseif DB and DB.affixMinSellRank and DB.affixMinSellRank > 0 then
        if affixDataForTrace and affixDataForTrace.rank then
            step("affixRankRule", false, string.format(
                "rank %d - kept (your setting only sells ranks below %d)",
                affixDataForTrace.rank,
                DB.affixMinSellRank
            ))
        else
            step("affixRankRule", false, L["n/a (item has no random affix)"])
        end
    end
    local autoDupePass = false
    if DB and DB.affixAllowExactDupes and affixDataForTrace then
        local descKnown = affixDataForTrace.description
            and EC_compCache.playerHasAffixDescription
            and EC_compCache.playerHasAffixDescription(affixDataForTrace.description)
        local rankKnown = (not descKnown)
            and affixDataForTrace.name
            and affixDataForTrace.rank
            and EC_compCache.playerHasAffixRank
            and EC_compCache.playerHasAffixRank(affixDataForTrace.name, affixDataForTrace.rank)
        autoDupePass = (descKnown or rankKnown) and true or false
        if autoDupePass then
            step(
                "alreadyHaveAffixRule",
                true,
                descKnown and "you have this exact affix (description match)"
                    or "you have this affix family at this rank"
            )
        end
    end

    if qualityPass and EC_compCache.isQuestItem and EC_compCache.isQuestItem(itemID) then
        qualityPass = false
        step("questSafetyNet", false, L["vetoed - quest item; explicit Sell List entry would override this"])
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
            L["vetoed - baseline-protected profession tool; explicit Sell List entry or Allow Sell override would bypass this"]
        )
    end

    local equipped = IsEquippedItem(itemID)
    if equipped then
        step("equippedVeto", false, L["VETO - item is currently equipped"])
    else
        step("equippedVeto", true, L["not currently equipped"])
    end

    local blacklisted = DB and IsInSet(DB.blacklist, itemID) or false
    if blacklisted then
        step("keepListVeto", false, L["VETO - on Keep List"])
    else
        step("keepListVeto", true, L["not on Keep List"])
    end

    local affixProtected = false
    if (whitelistPass or qualityPass) and DB and DB.protectAffixedRareItems and quality and quality >= 3 then
        local affix = EC_compCache.bagSlotAffixData and EC_compCache.bagSlotAffixData(bag, slot)
        if affix then
            local affixKey = affix.description
                and EC_compCache.normaliseAffixDesc
                and EC_compCache.normaliseAffixDesc(affix.description)
            local manualAllow = affixKey and ADB and ADB.allowedAffixes and ADB.allowedAffixes[affixKey]
            -- v2.35.1: autoDupe widened to release on description match
            -- OR (family, rank) match. Mirrors the same widening in
            -- EC_IsSellable + EC_AnnotateTooltip so /ec sellinfo
            -- agrees with the merchant cycle and the tooltip on the
            -- same item.
            local descKnown = affix.description
                and EC_compCache.playerHasAffixDescription
                and EC_compCache.playerHasAffixDescription(affix.description)
                or false
            local rankKnown = (not descKnown)
                and affix.name
                and affix.rank
                and EC_compCache.playerHasAffixRank
                and EC_compCache.playerHasAffixRank(affix.name, affix.rank)
                or false
            local autoDupe = DB.affixAllowExactDupes and (descKnown or rankKnown)
            -- v2.44.0: rank-floor opt-out. Match the sell-path veto
            -- so /ec sellinfo reflects the same verdict the merchant
            -- cycle would produce.
            local rankBelow = DB.affixMinSellRank
                and DB.affixMinSellRank > 0
                and affix.rank
                and affix.rank < DB.affixMinSellRank
            if manualAllow then
                step("affixProtection", true, L["affix present, manually allow-listed via Alt+Right-Click"])
            elseif autoDupe then
                local how = descKnown
                    and L["you already have this affix"]
                    or L["you already have this affix family at this rank"]
                step("affixProtection", true, "affix present, selling allowed (" .. how .. ")")
            elseif rankBelow then
                step("affixProtection", true, string.format(
                    "affix present, selling allowed (rank %s below your floor of %d)",
                    tostring(affix.rank or "?"),
                    DB.affixMinSellRank
                ))
            else
                affixProtected = true
                step("affixProtection", false, L["VETO - Rare/Epic random affix detected"])
            end
        else
            step("affixProtection", true, L["no random affix on this item"])
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
            step("affixProtection", true, L["n/a (affix protection toggle off)"])
        elseif not quality or quality < 3 then
            step("affixProtection", true, L["n/a (quality below Rare)"])
        else
            step("affixProtection", true, L["n/a (no positive sell signal - affix gate only fires for items the sell rules would otherwise touch; delete-list path is checked separately)"])
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
            step("chanceOnHitProtection", true, L["chance-on-hit proc, but item allow-listed"])
        else
            procProtected = true
            qualityPass = false
            step("chanceOnHitProtection", false, L["VETO - chance-on-hit proc detected (downgrades qualityRule veto)"])
        end
    else
        step("chanceOnHitProtection", true, L["n/a"])
    end

    local positiveSignal = isJunk or qualityPass or whitelistPass or affixRankPass or autoDupePass
    local vetoed = equipped or blacklisted or affixProtected
    local wouldSell = positiveSignal and not vetoed and not locked

    local summary
    if willDelete then
        -- Delete-List path wins over every sell verdict. The cycle queues
        -- this slot as a delete regardless of any sell signal further
        -- down. Steps above still run for educational value (the player
        -- can see what WOULD have happened if the item weren't on the
        -- Delete List), but the summary reflects the actual outcome.
        summary = L["|cffff4444WILL DELETE at the next vendor visit|r"]
    elseif wouldSell then
        summary = L["|cff00ff00WILL SELL at the next vendor visit|r"]
    elseif not positiveSignal then
        summary = L["|cffffb84dwon't sell - no rule matched|r"]
    elseif vetoed then
        summary = L["|cffff4444won't sell - protected|r"]
    else
        summary = L["|cffff4444won't sell|r"]
    end

    return { steps = steps, wouldSell = wouldSell, willDelete = willDelete, summary = summary }
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
        NS.PrintNice(L["|cffff4444No items in any bag to inspect.|r"])
        return
    end

    local r = EC_compCache.describeSellability(bag, slot)
    NS.PrintNicef(L["|cffffff00=== Sellability trace: bag %d slot %d ===|r"], bag, slot)
    for _, s in ipairs(r.steps) do
        local marker = s.passed and "|cff00ff00+|r" or "|cffff4444-|r"
        NS.PrintNicef("  %s %s - %s", marker, s.name, s.detail)
    end
    NS.PrintNicef(L["Result: %s"], r.summary)
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
