-- EbonClearance_Vendor - vendor cycle infrastructure.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 5 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. Stage 5 is deliberately scoped narrowly because the full vendor
-- cycle (EC_IsSellable, BuildQueue, DoNextAction, worker, StartRun,
-- EC_manualSell) has dense cross-file dependencies that warrant their
-- own future stages. This stage establishes the file with two pieces:
--
--   * The vendor-cycle state-machine constants and runtime state, which
--     were promoted onto EC_compCache during Stage 5 prep:
--       - EC_compCache.vendorRunning  (was file-scope local `running`)
--       - EC_compCache.pendingDelete  (was file-scope local of same name)
--     These initialise in EbonClearance_Core.lua's table literal. No code
--     lives in this file for them; they're documented here as the canonical
--     home for vendor-cycle state going forward.
--
--   * The deletion-confirmation popup hook (HookDeletePopupOnce). Self-
--     contained ~75 LOC subsystem with minimal cross-file dependencies.
--     The hook OnUpdate watches StaticPopup1 for DELETE_* variants and
--     auto-confirms when the queued deletion (EC_compCache.pendingDelete)
--     names an item on DB.deleteList. Exposed as NS.HookDeletePopupOnce
--     so EbonClearance.lua's ADDON_LOADED branch can install it once.
--
-- Cross-file dependencies (read at call time):
--   * EC_compCache.pendingDelete - shared cache field, promoted Stage 5 prep
--   * NS.DB                      - SavedVariables, captured at function entry
--   * StaticPopup1{,Button1,EditBox}, MerchantFrame, etc. - WoW globals
--
-- DOES NOT include (future stage targets):
--   * EC_IsSellable, BuildQueue, FinishRun, DoNextAction, worker, StartRun,
--     EC_PreviewSellable, EC_IsMerchantAllowed (the merchant cycle itself)
--   * EC_manualSell (manual-sell attribution via hooksecurefunc)
--   * EC_compCache.isQuestItem helper
-- All of those stay in EbonClearance.lua for now and will be extracted
-- in future stages when the cross-file plumbing for the helpers they
-- depend on (PrintNice, EC_Delay, EC_session, EC_lootCycleState, STATE,
-- EC_GetItemPrice, EC_IsAddonEnabledForChar, EC_RecordInventoryWorthSample,
-- EC_SummonGreedyWithDelay, EC_EffectiveMaxItemsPerRun,
-- EC_EffectiveVendorInterval, CopperToColoredText, EC_addonDismissed,
-- EC_RefreshSellBorders, ...) can be done deliberately.

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- File-scope state for the deletion-popup hook. `deletePopupHooked` gates
-- the one-shot install (CreateFrame + SetScript at install time creates
-- a long-lived OnUpdate ticker; re-installing would duplicate it).
local deletePopupHooked = false

-- Set-membership helper. Captures the canonical NS.IsInSet (defined in
-- EbonClearance_Core.lua); per-call cost is one local read.
local IsInSet = NS.IsInSet

-- Watches StaticPopup1 for DELETE_* variants and auto-confirms when the
-- queued deletion (EC_compCache.pendingDelete) names an item still on
-- DB.deleteList. Self-detaches when no deletion is queued (the OnUpdate
-- body's early-return is the gate). Installed once at ADDON_LOADED via
-- NS.HookDeletePopupOnce.
local function HookDeletePopupOnce()
    if deletePopupHooked then
        return
    end
    deletePopupHooked = true

    local f = CreateFrame("Frame")
    local popupElapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        -- Skip entirely unless a deletion is queued. Without this gate the
        -- handler would tick ~60 times/s for the life of the session.
        if not EC_compCache.pendingDelete then
            popupElapsed = 0
            return
        end
        popupElapsed = popupElapsed + (elapsed or 0)
        if popupElapsed < 0.1 then
            return
        end
        popupElapsed = 0

        -- v2.13.8: accept all four DELETE_* popup variants, not just the
        -- simple yes/no DELETE_ITEM. Soulbound rare/epic items (e.g.
        -- Tabard of Conquest itemID 49054 - BoP + Blue) trigger
        -- DELETE_GOOD_ITEM which requires typing "DELETE" into a
        -- confirmation edit box; the edit-box population already lived
        -- in the handler body, but the outer gate was checking for the
        -- wrong popup.which. The startswith check covers DELETE_ITEM,
        -- DELETE_GOOD_ITEM, DELETE_QUEST_ITEM, DELETE_GOOD_QUEST_ITEM
        -- in one expression and would accept any future Blizzard-added
        -- DELETE_* variant.
        local popup = StaticPopup1
        local which = popup and popup.which
        local isDeletePopup = which and which:find("^DELETE_") ~= nil
        if popup and popup:IsShown() and isDeletePopup then
            local DB = NS.DB
            local id = EC_compCache.pendingDelete.itemID
            if id and DB and IsInSet(DB.deleteList, id) then
                local editBox = StaticPopup1EditBox
                if editBox then
                    editBox:SetText("DELETE")
                    editBox:HighlightText()
                end
                local button1 = StaticPopup1Button1
                if button1 and button1:IsEnabled() then
                    button1:Click()
                    EC_compCache.pendingDelete = nil
                end
            else
                EC_compCache.pendingDelete = nil
            end
        end
    end)
end
NS.HookDeletePopupOnce = HookDeletePopupOnce
