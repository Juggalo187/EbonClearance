-- EbonClearance_BagContextMenu - Alt+Right-Click bag-item quick-action popup.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8d of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The bag-item context menu - a custom popup frame (not a Blizzard
-- DropDownMenu) wired through hooksecurefunc on
-- ContainerFrameItemButton_OnModifiedClick. Alt+Right-Click any bag
-- slot to surface a quick-action list: add to Sell / Keep / Delete
-- list, remove from existing list, allow-sell (chance-on-hit or affix
-- protection override), open the relevant settings panel.
--
-- Moved into this file:
--   * EC_CTX_ROWS - row metadata for the popup
--   * EC_BuildCtxFrame - lazily creates the popup frame on first show
--   * EC_ShowItemContextMenu - per-show: sets row labels, OnClick
--     handlers, anchors at cursor, shows the frame
--   * EC_InstallBagContextHookOnce - the
--     ContainerFrameItemButton_OnModifiedClick hook installer.
--     Exposed as NS.InstallBagContextHookOnce for the ADDON_LOADED
--     branch in EbonClearance.lua.
--
-- Local IsInSet helper carried along (same pattern as Vendor /
-- BagDisplay / Tooltip).
--
-- Cross-file dependencies read inline:
--   * NS.compCache (Core) - bagSlotAffixData, normaliseAffixDesc,
--     playerHasAffixDescription, itemHasChanceOnHit, etc.
--   * NS.DB / NS.ADB - captured at function entry
--   * NS.AddItemToList / NS.RemoveItemFromList / NS.FindAddConflict
--     (EbonClearance.lua) - list-mutation helpers driven by row clicks
--   * NS.PrintNice / PrintNicef (EbonClearance.lua)
--   * NS.compCache.openPanelToList - opens the relevant settings panel
--     via _G[<panel-name>] lookup (panels are named frames)
--   * Various WoW globals - GameTooltip, GetCursorPosition,
--     hooksecurefunc, ContainerFrameItemButton_OnModifiedClick, ...

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- IsInSet binding intentionally not imported here; the bag-context popup
-- doesn't consult set membership directly (the list-mutation helpers it
-- delegates to handle their own checks). If a future row handler needs
-- it, add `local IsInSet = NS.IsInSet` here.

-- Row metadata for the popup. Each "list" row toggles between "Add to ..."
-- (white) and "Remove from ..." (orange) based on the item's live list
-- membership at show time. Special rows ("sellNow", "cancel") get plain text
-- and fixed handlers. EC_ShowItemContextMenu sets per-row text + OnClick on
-- every show; the buttons created in EC_BuildCtxFrame are empty placeholders.
local EC_CTX_ROWS = {
    { kind = "list", setName = "whitelist", label = "Sell List (this character)" },
    { kind = "list", setName = "accountWhitelist", label = "Sell List (account-wide)" },
    { kind = "list", setName = "blacklist", label = "Keep List" },
    { kind = "list", setName = "deleteList", label = "Delete List" },
    { kind = "sellNow" },
    { kind = "cancel" },
}

local EC_ctxFrame

local function EC_BuildCtxFrame()
    if EC_ctxFrame then
        return EC_ctxFrame
    end
    local rowCount = #EC_CTX_ROWS
    -- Layout: 8 top pad + 22 title + 6 gap + rows*22 + 8 bottom pad
    local frameHeight = 8 + 22 + 6 + (rowCount * 22) + 8
    local frame = CreateFrame("Frame", "EbonClearanceCtxFrame", UIParent)
    -- 3.3.5a strata layering: host bag UI replacements commonly run
    -- their bag frames at DIALOG strata with a very high internal
    -- frame level, so a popup at plain DIALOG can render BEHIND the
    -- bag frame and become invisible. Same class of bug already
    -- handled for the colour picker in
    -- EbonClearance_ItemHighlightingPanel.lua; same fix applied here -
    -- bump one strata up to FULLSCREEN_DIALOG + Raise() on every show
    -- so the menu always wins the layering contest regardless of
    -- which host bag UI is loaded.
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetSize(240, frameHeight)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:EnableMouse(true)
    frame:Hide()

    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetPoint("TOPRIGHT", -10, -8)
    title:SetJustifyH("LEFT")
    if title.SetWordWrap then
        title:SetWordWrap(false)
    end
    frame.title = title

    frame.buttons = {}
    for i = 1, #EC_CTX_ROWS do
        local btn = CreateFrame("Button", nil, frame)
        btn:SetSize(220, 20)
        btn:SetPoint("TOPLEFT", 10, -(8 + 22 + 6) - (i - 1) * 22)
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetHighlightFontObject("GameFontGreenSmall")
        btn:SetDisabledFontObject("GameFontDisableSmall")
        local fs = btn:GetFontString()
        if fs then
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", btn, "LEFT", 4, 0)
            fs:SetJustifyH("LEFT")
        end
        -- Highlight texture so hover gives feedback.
        local hl = btn:CreateTexture(nil, "BACKGROUND")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAllPoints(btn)
        hl:SetAlpha(0)
        btn:SetScript("OnEnter", function()
            hl:SetAlpha(0.4)
        end)
        btn:SetScript("OnLeave", function()
            hl:SetAlpha(0)
        end)
        -- Text + OnClick are populated per-show by EC_ShowItemContextMenu
        -- so the row labels reflect the item's live list membership.
        frame.buttons[i] = btn
    end

    -- Escape closes the popup. Standard Blizzard pattern: anything in the
    -- UISpecialFrames table is auto-hidden on Escape. Avoids the previous
    -- fullscreen-overlay approach which could intercept bag clicks if it ever
    -- got stuck shown after a disable/enable cycle.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "EbonClearanceCtxFrame")
    end
    frame:SetScript("OnHide", function()
        frame.bag = nil
        frame.slot = nil
    end)

    EC_ctxFrame = frame
    return frame
end

local function EC_ShowItemContextMenu(button)
    local DB = NS.DB
    local ADB = NS.ADB
    local frame = EC_BuildCtxFrame()
    local bag = button:GetParent():GetID()
    local slot = button:GetID()
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return
    end
    frame.bag = bag
    frame.slot = slot

    -- Pull sellPrice alongside the name so the smart-row filter below can
    -- decide which actions are meaningful for this item.
    local name, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
    local itemName = name or ("ItemID:" .. itemID)
    frame.title:SetText("|cff66ccffEbonClearance|r: " .. itemName)

    -- Smart-row filter. When we know the item has no vendor value (sellPrice
    -- 0 or nil from a cache hit) the only useful "Add to X" action is the
    -- Deletion List - the auto-rules already ignore unsellable items so
    -- whitelisting/blacklisting them is no-op, and Sell Now is meaningless
    -- because no vendor will buy it. Existing list memberships still expose
    -- a "Remove from X" row so users can clean up stale entries (e.g. an
    -- item that was added to the whitelist before its sellPrice was known).
    -- The cross-list conflict greying remains unchanged: an unsellable item
    -- already on the Whitelist still shows the Deletion List row as a
    -- greyed "Add to Deletion List" so the user knows they need to remove
    -- it from Whitelist first - same UX rule the panel-side adds enforce,
    -- which is why the tooltip annotation also stays as the canonical
    -- "why is this item being treated this way?" indicator.
    --
    -- The cache-miss path (name == nil) falls back to showing every row;
    -- we don't know yet whether the item is unsellable. Reopen the menu
    -- after a moment to let GetItemInfo populate.
    local cacheKnown = (name ~= nil)
    local noVendorValue = cacheKnown and (not sellPrice or sellPrice == 0)

    -- v2.26.0 / v2.27.0: protected items (chance-on-hit OR
    -- random-affix) show a single "Allow Sell" option in place of
    -- Sell Now while unmarked. Picking it releases the v2.20.0 /
    -- v2.23.0 safety net - future drops auto-sell via the normal
    -- quality rules and the item becomes available to Process Bags.
    -- While unmarked, the Sell List / Keep List / Delete List rows
    -- are hidden so the user must consciously acknowledge the
    -- protection before adding it to a sell rule. Once marked, the
    -- full menu opens up and the sellNow row shows "Remove from
    -- Allow List" as the toggle.
    local hasProc = EC_compCache.itemHasChanceOnHit(bag, slot, itemID)
    -- For random-affix items the identity-bearing field is the affix
    -- description, NOT the base itemID. Capture both the protection
    -- flag and the normalised description so the Allow Sell row can
    -- mark by affix when relevant.
    local affixData
    if DB.protectAffixedRareItems then
        local _, _, q = GetItemInfo(itemID)
        if q and q >= 3 and EC_compCache.bagSlotAffixData then
            affixData = EC_compCache.bagSlotAffixData(bag, slot)
        end
    end
    local hasAffix = affixData ~= nil
    local affixKey = affixData
        and affixData.description
        and EC_compCache.normaliseAffixDesc
        and EC_compCache.normaliseAffixDesc(affixData.description)
    -- Tome protection: same per-itemID storage as chance-on-hit
    -- (ADB.allowedItems[itemID]), so the Allow Sell / Remove from
    -- Allow List flow shares those branches. The unlearned-only mode
    -- gates on playerKnowsTomeSpell; protectAllTomes is unconditional.
    local hasTome = false
    if (DB.protectAllTomes or DB.protectUnlearnedTomes)
        and EC_compCache.itemIsTome
        and EC_compCache.itemIsTome(bag, slot, itemID)
    then
        if DB.protectAllTomes then
            hasTome = true
        elseif DB.protectUnlearnedTomes
            and EC_compCache.playerKnowsTomeSpell
            and not EC_compCache.playerKnowsTomeSpell(bag, slot, itemID)
        then
            hasTome = true
        end
    end
    local hasProtection = hasProc or hasAffix or hasTome
    -- Allowance has four sources:
    --   1. Manual itemID mark for chance-on-hit (allowedItems).
    --   2. Manual affix-description mark for random affix
    --      (allowedAffixes).
    --   3. Auto-dupe gate for random affix: when
    --      DB.affixAllowExactDupes is ON, an affix the player has
    --      already extracted is implicitly allowed - no manual mark
    --      needed. This is the "if exact-rank dupes is enabled then
    --      Allow Sell isn't required" rule from the user spec.
    --   4. Manual itemID mark for tome (allowedItems, shared with
    --      chance-on-hit since both protections are per-itemID).
    local procAllowed = hasProc and ADB.allowedItems and ADB.allowedItems[itemID] == true
    local tomeAllowed = hasTome and ADB.allowedItems and ADB.allowedItems[itemID] == true
    local affixManualAllowed = hasAffix and affixKey and ADB.allowedAffixes and ADB.allowedAffixes[affixKey] == true
    local affixAutoAllowed = hasAffix
        and affixData
        and affixData.description
        and DB.affixAllowExactDupes
        and EC_compCache.playerHasAffixDescription
        and EC_compCache.playerHasAffixDescription(affixData.description)
    local affixAllowed = affixManualAllowed or affixAutoAllowed
    local itemAllowed = procAllowed or affixAllowed or tomeAllowed
    local procProtected = hasProtection and not itemAllowed

    local merchantOpen = MerchantFrame and MerchantFrame:IsShown()
    local visibleSlot = 0
    for i, row in ipairs(EC_CTX_ROWS) do
        local btn = frame.buttons[i]
        local rowHidden = false
        if row.kind == "list" and procProtected then
            -- v2.26.0: hide all list rows while protected. User must
            -- click "Allow Sell" first to unlock the normal
            -- Sell/Keep/Delete actions on this item.
            rowHidden = true
        elseif row.kind == "list" then
            local t = NS.GetListTable(row.setName)
            local onList = t and t[itemID] == true
            if onList then
                -- Orange "Remove from ..." when the item is already on this
                -- list. Clicking removes it. Always shown - this is how
                -- users clean up stale entries, including for unsellable
                -- items that may have been added before their price was
                -- known.
                btn:SetText("|cffff8000Remove from " .. row.label .. "|r")
                btn:SetScript("OnClick", function()
                    NS.RemoveItemFromList(row.setName, itemID, row.label)
                    frame:Hide()
                end)
                btn:Enable()
            elseif noVendorValue and row.setName ~= "deleteList" then
                -- Hide whitelist/account-whitelist/blacklist Add rows for
                -- items the auto-rules can't act on anyway. The Delete
                -- List row stays visible because that's the actually-
                -- useful action.
                rowHidden = true
            else
                -- v2.26.0: dropped the "Add to" prefix on add rows -
                -- the label alone is self-evident and orange
                -- "Remove from" rows provide the contrast.
                local conflictName = NS.FindAddConflict(itemID, row.setName)
                if conflictName then
                    btn:SetText(row.label)
                    btn:SetScript("OnClick", function() end)
                    btn:Disable()
                else
                    btn:SetText(row.label)
                    btn:SetScript("OnClick", function()
                        NS.AddItemToList(row.setName, itemID, row.label)
                        -- v2.27.0: stamp the affix-meta flag so the
                        -- list panel renders "(affix-gated)" on this
                        -- entry. Reminds the user that the affix
                        -- protection still filters per-drop even
                        -- though the base itemID is on the list.
                        if hasAffix then
                            ADB.affixedListedItems = ADB.affixedListedItems or {}
                            ADB.affixedListedItems[itemID] = true
                        end
                        frame:Hide()
                    end)
                    btn:Enable()
                end
            end
        elseif row.kind == "sellNow" then
            -- v2.26.0 / v2.27.0: unified "Allow Sell" toggle for any
            -- protected item (chance-on-hit or random affix). Marks
            -- the right list automatically: itemID for chance-on-hit
            -- (proc carried by the item), affix description for
            -- random affix (so all future drops with the same affix
            -- pass, not just the same base item).
            --
            -- When the affix auto-dupe gate is allowing the item
            -- (DB.affixAllowExactDupes is ON and the affix is one the
            -- player has extracted), there's no manual mark to
            -- toggle - hide the row. The full list menu is already
            -- visible because itemAllowed is true.
            local hasManualMark = procAllowed or affixManualAllowed or tomeAllowed
            if hasManualMark then
                btn:SetText("|cffff8000Remove from Allow List|r")
                btn:SetScript("OnClick", function()
                    -- procAllowed and tomeAllowed share the same
                    -- ADB.allowedItems[itemID] flag; clearing once
                    -- restores both protections.
                    if (procAllowed or tomeAllowed) and ADB.allowedItems then
                        ADB.allowedItems[itemID] = nil
                    end
                    if affixManualAllowed and affixKey and ADB.allowedAffixes then
                        ADB.allowedAffixes[affixKey] = nil
                    end
                    frame:Hide()
                    NS.PrintNicef("Removed %s from Allow List.", itemName)
                    -- Cascade: removing Allow Sell expresses the user intent
                    -- "re-protect this proc / affix item from auto-selling".
                    -- If the item is also on a Sell List, the protection
                    -- only narrows back to the auto-rule sweep (per the
                    -- v2.20.1 "explicit user intent overrides safety net"
                    -- design) - the item would STILL vendor via the
                    -- whitelist path. Clearing the Sell List entries here
                    -- matches the menu-driven workflow most users follow
                    -- (Allow Sell + Add to Sell + later Remove from Allow
                    -- List = full undo). Keep List and Delete List are NOT
                    -- cascaded: those are different intents (Keep = never
                    -- sell, Delete = destroy) that the protection toggle
                    -- doesn't logically conflict with. NS.RemoveItemFromList
                    -- no-ops when the item isn't on the list, prints its
                    -- own "Removed X from <list>" line when it does, and
                    -- handles panel refresh + border repaint.
                    NS.RemoveItemFromList("whitelist", itemID, "Character Sell List")
                    NS.RemoveItemFromList("accountWhitelist", itemID, "Account Sell List")
                    -- Border repaint covers the case where neither sell
                    -- list contained the item (so RemoveItemFromList no-
                    -- op'd and didn't trigger its own repaint). Same
                    -- rationale as before the cascade: the Allow List
                    -- mutation can flip a slot's would-sell verdict.
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end)
                btn:Enable()
            elseif itemAllowed then
                -- Auto-allowed (affix dupe gate); no manual state.
                rowHidden = true
            elseif hasProtection then
                btn:SetText("Allow Sell")
                btn:SetScript("OnClick", function()
                    -- Mark each protection layer that applies. In the
                    -- common case only one of (affix, proc, tome) is
                    -- true; mixed cases (e.g. a chance-on-hit tome -
                    -- rare) mark both flags so a single Allow Sell
                    -- click lifts everything.
                    local marked = false
                    if hasAffix and affixKey then
                        ADB.allowedAffixes = ADB.allowedAffixes or {}
                        ADB.allowedAffixes[affixKey] = true
                        NS.PrintNicef(
                            "Marked affix %s as allowed. Future drops with this affix will auto-sell.",
                            tostring(affixData.name or affixKey)
                        )
                        marked = true
                    end
                    if hasProc or hasTome then
                        ADB.allowedItems = ADB.allowedItems or {}
                        ADB.allowedItems[itemID] = true
                        if not marked then
                            NS.PrintNicef(
                                "Marked %s as allowed. Future drops will auto-sell.",
                                itemName
                            )
                        end
                    end
                    frame:Hide()
                    -- Same reasoning as the remove-from-allow path: this
                    -- mutation can flip a slot from "protected" to "will
                    -- sell" so the border should track immediately.
                    if NS.RefreshSellBorders then
                        NS.RefreshSellBorders()
                    end
                end)
                btn:Enable()
            else
                rowHidden = true
            end
        elseif row.kind == "cancel" then
            btn:SetText("Cancel")
            btn:SetScript("OnClick", function()
                frame:Hide()
            end)
            btn:Enable()
        end

        if rowHidden then
            btn:Hide()
        else
            -- Pack visible rows contiguously starting at slot 0; the frame
            -- height below resizes to match the count so the trailing
            -- padding is consistent regardless of how many rows are shown.
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", 10, -(8 + 22 + 6) - visibleSlot * 22)
            btn:Show()
            visibleSlot = visibleSlot + 1
        end
    end

    -- Resize the frame to match the visible row count. Same layout formula
    -- the build path uses; visibleSlot is the count of rows we just laid
    -- out (it ended at last_index + 1).
    frame:SetHeight(8 + 22 + 6 + (visibleSlot * 22) + 8)

    -- Position at the cursor. WoW's GetCursorPosition returns screen pixels;
    -- divide by UIParent's effective scale to get UIParent-local coords.
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    frame:Show()
    -- Belt-and-braces: even at FULLSCREEN_DIALOG strata, a host bag UI
    -- replacement might have raised one of its own frames to the top
    -- of the same strata. Calling Raise() on every show guarantees the
    -- menu sits at the highest frame level within FULLSCREEN_DIALOG,
    -- so it lands above whatever the host bag UI is doing.
    if frame.Raise then
        frame:Raise()
    end
end

local EC_bagContextHookInstalled = false

-- 3.3.5a routes any modifier+click on a bag item through
-- ContainerFrameItemButton_OnModifiedClick (NOT _OnClick). _OnModifiedClick
-- has Shift/Ctrl handlers, then falls through to _OnClick for the unhandled
-- modifiers. We intercept pure Alt+RightClick (no Shift, no Ctrl) before that
-- fall-through. Replace rather than hooksecurefunc because we need to suppress
-- the fall-through, not just append.
local function EC_InstallBagContextHookOnce()
    if EC_bagContextHookInstalled then
        return
    end
    if type(ContainerFrameItemButton_OnModifiedClick) ~= "function" then
        return
    end
    EC_bagContextHookInstalled = true
    local orig = ContainerFrameItemButton_OnModifiedClick
    ContainerFrameItemButton_OnModifiedClick = function(self, button)
        if button == "RightButton" and IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown() then
            EC_ShowItemContextMenu(self)
            return
        end
        -- Alt+Shift+Right-Click on a bag item: print the per-predicate
        -- sellability trace for that slot. Lower-priority than the Alt-only
        -- branch above; falls through to the original handler when the
        -- click can't be resolved to a (bag, slot) pair.
        if button == "RightButton" and IsAltKeyDown() and IsShiftKeyDown() and not IsControlKeyDown() then
            if EC_compCache.bagSlotFromButton and EC_compCache.printSellabilityTrace then
                local bag, slot = EC_compCache.bagSlotFromButton(self)
                if bag and slot then
                    EC_compCache.printSellabilityTrace(bag, slot)
                    return
                end
            end
        end
        return orig(self, button)
    end
end

NS.InstallBagContextHookOnce = EC_InstallBagContextHookOnce
