-- EbonClearance_Minimap - minimap button, LDB launcher, combat-vendor button.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8b of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- Three self-contained UI buttons that live outside the Interface Options
-- panel hierarchy:
--
--   * EC_UpdateMinimapPos  - positions the minimap button using stored
--                             angle (DB.minimapAngle, default placement).
--   * EC_CreateMinimapButton - draggable minimap button with left/middle/
--                              right-click bindings (options / Process /
--                              toggle) and a hover tooltip showing free
--                              bag slots, sellable count, est. value.
--   * EC_CreateTargetMerchantButton - hidden SecureActionButton that the
--                              "Target Goblin Merchant" key binding
--                              dispatches through (combat-lockdown safe).
--   * EC_CreateLDBLauncher - LibDataBroker plugin so users with Bazooka,
--                            ChocolateBar, etc. get the same launcher in
--                            their preferred frame.
--
-- These are wired from EbonClearance.lua's ADDON_LOADED branch via the
-- existing names (still file-scope locals in EbonClearance.lua that we
-- expose on NS below). Existing call sites in EbonClearance.lua
-- (PLAYER_LOGIN, slash command "/ec minimap") read NS-qualified names.
--
-- Cross-file dependencies read inline:
--   * NS.compCache               (Core)
--   * NS.DB / NS.ADB             - captured at function entry
--   * NS.PreviewSellable         (Vendor) - tooltip "Sellable now: N"
--   * NS.CopperToColoredText     (EbonClearance.lua) - tooltip est. value
--   * NS.GetFreeBagSlots         (EbonClearance.lua) - tooltip free slots
--   * NS.PrintNice / PrintNicef  (EbonClearance.lua)
--   * NS.TARGET_NAME             (EbonClearance.lua, refreshed by EnsureDB)
--   * _G["EbonClearanceOptionsMain"]      - main settings panel (named frame)
--   * _G["EbonClearanceOptionsProcessBags"] - Process Bags panel (named frame)
--   * EbonClearance_ToggleSettings / ToggleEnabled / ForceSell - WoW
--     globals from the keybinding handler block in EbonClearance.lua

local NS = select(2, ...)
local EC_compCache = NS.compCache

local function EC_UpdateMinimapPos()
    local DB = NS.DB
    local btn = _G["EbonClearanceMinimapButton"]
    if not btn then
        return
    end
    local angle = math.rad(DB and DB.minimapButtonAngle or 220)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function EC_CreateMinimapButton()
    local DB = NS.DB
    if not DB then
        return
    end
    if _G["EbonClearanceMinimapButton"] then
        return
    end -- only create once

    local btn = CreateFrame("Button", "EbonClearanceMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- Circular background
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Background")
    bg:SetSize(53, 53)
    bg:SetPoint("CENTER", btn, "CENTER", -1, 1)

    -- Icon
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.icon = icon

    -- Border ring
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("CENTER", btn, "CENTER", 10, -10)

    EC_UpdateMinimapPos()

    local dragging = false

    btn:SetScript("OnDragStart", function(self)
        dragging = true
    end)

    btn:SetScript("OnDragStop", function(self)
        dragging = false
        EC_UpdateMinimapPos()
    end)

    btn:SetScript("OnUpdate", function(self)
        if not dragging then
            return
        end
        if not IsMouseButtonDown("LeftButton") then
            dragging = false
            return
        end
        local mx, my = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        cx = cx / scale
        cy = cy / scale
        local angle = math.deg(math.atan2(cy - my, cx - mx))
        if DB then
            DB.minimapButtonAngle = angle
        end
        EC_UpdateMinimapPos()
    end)

    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            -- Combat lockdown blocks the InterfaceOptions panel-swap path;
            -- queue the open so it fires the moment combat ends. The user
            -- gets a one-line note so silent no-op doesn't look broken.
            if InCombatLockdown and InCombatLockdown() then
                EC_compCache.pendingOpenAfterCombat = "main"
                NS.PrintNice("|cffffb84dSettings will open when combat ends.|r")
                return
            end
            NS.OpenOptionsPanel("EbonClearanceOptionsMain")
        elseif button == "MiddleButton" then
            if InCombatLockdown and InCombatLockdown() then
                EC_compCache.pendingOpenAfterCombat = "process"
                NS.PrintNice("|cffffb84dProcess Bags will open when combat ends.|r")
                return
            end
            NS.OpenOptionsPanel("EbonClearanceOptionsProcessBags")
        elseif button == "RightButton" then
            if not DB then
                return
            end
            DB.enabled = not DB.enabled
            local state = DB.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
            NS.PrintNice("Addon " .. state)
            if self.icon then
                self.icon:SetDesaturated(not DB.enabled)
            end
        end
    end)

    -- Apply initial desaturation if disabled
    if DB and DB.enabled == false then
        icon:SetDesaturated(true)
    end

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("EbonClearance")
        GameTooltip:AddLine("Left: Options  |  Middle: Process Bags  |  Right: Toggle Addon", 1, 1, 1)
        local stateStr = (DB and DB.enabled ~= false) and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
        GameTooltip:AddLine("Status: " .. stateStr)
        local freeSlots = NS.GetFreeBagSlots()
        local slotColor = freeSlots >= 10 and "|cff00ff00" or (freeSlots >= 5 and "|cffffff00" or "|cffff4444")
        GameTooltip:AddLine("Free bag slots: " .. slotColor .. freeSlots .. "|r")

        local sellCount, sellCopper = NS.PreviewSellable()
        GameTooltip:AddLine(string.format("Sellable now: |cffffff00%d|r items", sellCount))
        if sellCopper > 0 then
            GameTooltip:AddLine("Est. value: " .. NS.CopperToColoredText(sellCopper))
        end
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
end

-- Hidden SecureActionButton that registers a keybinding to /target the Goblin
-- Merchant. The button is never shown; its only job is to sink the keybind
-- registered via BINDING_HEADER_EBONCLEARANCE near the slash commands. The
-- macrotext attribute is set at creation so it remains functional inside
-- InCombatLockdown() (secure click from a player hardware event).
local function EC_CreateTargetMerchantButton()
    if _G.EbonClearanceTargetMerchantButton then
        return
    end
    local btn = CreateFrame("Button", "EbonClearanceTargetMerchantButton", UIParent, "SecureActionButtonTemplate")
    btn:RegisterForClicks("AnyUp")
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", "/target " .. NS.TARGET_NAME)
    btn:Hide()
end

-- Optional LibDataBroker-1.0 launcher. No-op if LibStub or LDB is not present,
-- so users on Titan Panel / Bazooka / ChocolateBar / etc. get an entry in
-- their display addon without us taking a hard dependency on anything.
local function EC_CreateLDBLauncher()
    local DB = NS.DB
    if not _G.LibStub then
        return
    end
    local LDB = _G.LibStub("LibDataBroker-1.0", true)
    if not LDB then
        return
    end
    if LDB.GetDataObjectByName and LDB:GetDataObjectByName("EbonClearance") then
        return
    end

    LDB:NewDataObject("EbonClearance", {
        type = "launcher",
        label = "EbonClearance",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        OnClick = function(_, button)
            local DB = NS.DB
            if button == "RightButton" then
                if not DB then
                    return
                end
                DB.enabled = not DB.enabled
                NS.PrintNice("Addon " .. (DB.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"))
            else
                NS.OpenOptionsPanel("EbonClearanceOptionsMain")
            end
        end,
        OnTooltipShow = function(tt)
            local DB = NS.DB
            tt:AddLine("EbonClearance")
            tt:AddLine("Left-click: Options  |  Right-click: Toggle", 1, 1, 1)
            local stateStr = (DB and DB.enabled ~= false) and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
            tt:AddLine("Status: " .. stateStr)
            local freeSlots = NS.GetFreeBagSlots()
            local slotColor = freeSlots >= 10 and "|cff00ff00" or (freeSlots >= 5 and "|cffffff00" or "|cffff4444")
            tt:AddLine("Free bag slots: " .. slotColor .. freeSlots .. "|r")
            local count, copper = NS.PreviewSellable()
            tt:AddLine(string.format("Sellable now: |cffffff00%d|r items", count))
            if copper > 0 then
                tt:AddLine("Est. value: " .. NS.CopperToColoredText(copper))
            end
        end,
    })
end

NS.UpdateMinimapPos = EC_UpdateMinimapPos
NS.CreateMinimapButton = EC_CreateMinimapButton
NS.CreateTargetMerchantButton = EC_CreateTargetMerchantButton
NS.CreateLDBLauncher = EC_CreateLDBLauncher
