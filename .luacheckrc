-- Luacheck configuration for EbonClearance (WoW 3.3.5a / WotLK / Lua 5.1)
-- Run:  luacheck *.lua
-- (The addon ships as 32 .lua files after the file split plus the later
-- panel / comms / guild-share / localization additions; the original monolith
-- EbonClearance.lua was renamed to EbonClearance_Events.lua.)
-- See docs/ADDON_GUIDE.md for the rationale behind these settings.

std = "lua51"
max_line_length = 140

-- Ignore:
--   212/self  : unused function argument "self" (WoW script handlers are self-receiving)
--   213       : unused loop variable (common in pairs/ipairs with only values)
--   631       : line is too long (some colour-coded strings are unavoidably long)
ignore = { "212/self", "213", "631" }

-- WoW saved variables and slash-command handles: addon writes to these at the
-- global scope. Everything else in the addon should stay local.
globals = {
    "EbonClearanceDB",
    "EbonClearanceAccountDB",   -- account-wide whitelist store
    "EbonholdStuffDB",          -- legacy, migrated-from
    "SLASH_EBONCLEARANCE1",
    "SLASH_ECDEBUG1",
    "SlashCmdList",
    "EC_IsMerchantAllowed",     -- assigned by module, read by vendor loop
    "ChatEdit_InsertLink",      -- replaced by module to capture shift-click links
    "ContainerFrameItemButton_OnModifiedClick", -- wrapped to add Alt+Right-Click context menu
    -- Keybinding headers / names (read by Blizzard, set by addon)
    "BINDING_HEADER_EBONCLEARANCE",
    "BINDING_NAME_EBONCLEARANCE_TOGGLE_SETTINGS",
    "BINDING_NAME_EBONCLEARANCE_TOGGLE_ENABLED",
    "BINDING_NAME_EBONCLEARANCE_FORCE_SELL",
    -- Globally-exposed handlers called from Bindings.xml
    "EbonClearance_ToggleSettings",
    "EbonClearance_ToggleEnabled",
    "EbonClearance_ForceSell",
    -- Provenance / attribution globals (see LICENSE §2; do not remove).
    "EBONCLEARANCE_IDENT",
    "EBONCLEARANCE_AUTHOR",
    "EBONCLEARANCE_ORIGIN",
    "__EbonClearance_origin",
    "__EbonClearance_author",
    -- _G is writable because one binding name contains a space (standard
    -- Blizzard pattern for SecureActionButton-based keybinds, see
    -- EbonClearanceTargetMerchantButton wiring).
    "_G",
    -- DB and ADB are forward-declared locals at the file scope. Luacheck's
    -- static analysis can't follow forward declarations across the file, so
    -- treat them as writable globals here. They remain `local` in the actual
    -- source.
    "DB",
    "ADB",
    -- StaticPopupDialogs is read-only by Blizzard's API but we register
    -- our own dialog templates onto it (StaticPopupDialogs.EC_CONFIRM_*).
    -- Treating it as writable silences the "setting read-only field" noise
    -- on every dialog registration.
    "StaticPopupDialogs",
}

-- WoW 3.3.5a API surface this addon touches. Grouped loosely by subsystem.
-- If the addon starts using a new API, add it here rather than silencing
-- the whole check.
read_globals = {
    -- Frame/UI
    "CreateFrame", "UIParent", "WorldFrame", "GameTooltip", "ItemRefTooltip", "Minimap",
    "MerchantFrame", "OpenAllBags", "OpenBackpack", "OpenBag", "ContainerFrame1",
    "InterfaceOptionsFramePanelContainer",
    "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory",
    "InterfaceOptionsFrame",
    "PlaySound", "StaticPopup_Show",
    -- StaticPopup1 named globals are auto-created by Blizzard when a
    -- StaticPopup_Show fires; we read them to drive a few input-popup edge
    -- cases (Enter-to-confirm wiring, focus, etc).
    "StaticPopup1", "StaticPopup1EditBox", "StaticPopup1Button1",

    -- Error handler
    "geterrorhandler",

    -- Chat
    "DEFAULT_CHAT_FRAME",
    "ChatFrame_AddMessageEventFilter", "ChatFrame_RemoveMessageEventFilter",
    "ChatTypeInfo",

    -- Items / bags
    "GetItemInfo", "GetItemIcon",
    "GetContainerItemID", "GetContainerItemInfo", "GetContainerItemLink",
    "GetContainerNumSlots", "GetContainerNumFreeSlots",
    "UseContainerItem", "PickupContainerItem",
    "DeleteCursorItem", "ClearCursor",
    "IsEquippedItem",
    "GetItemQualityColor",
    -- Equipped inventory (v2.10.0 auto-protect-equipped path)
    "GetInventoryItemLink",

    -- Merchant
    "GetMerchantNumItems", "GetMerchantItemInfo", "GetMerchantItemLink",
    "BuyMerchantItem",
    "RepairAllItems", "GetRepairAllCost", "CanMerchantRepair",
    "GetMoney",
    -- Guild bank repair (v2.9.0 optional repair-funds path)
    "IsInGuild", "CanGuildBankRepair", "GetGuildBankWithdrawMoney",

    -- Unit / player
    "UnitName", "UnitExists", "UnitAura", "UnitClass",
    "IsMounted", "Dismount",
    "IsAltKeyDown", "IsShiftKeyDown", "IsControlKeyDown", "InCombatLockdown",
    "IsMouseButtonDown", "GetUnitSpeed",

    -- Blizzard constants / static popup buttons
    "YES", "NO", "OKAY",
    -- Locale strings used by the auto-open container tooltip scan
    "ITEM_OPENABLE", "LOCKED",
    -- Cursor positioning for the bag right-click popup
    "GetCursorPosition", "GetCursorInfo",
    -- Escape-key auto-hide for the bag right-click popup
    "UISpecialFrames",
    -- Dropdown menu API (used by Merchant settings dropdowns)
    "UIDropDownMenu_Initialize", "UIDropDownMenu_CreateInfo",
    "UIDropDownMenu_AddButton", "UIDropDownMenu_SetWidth",
    "UIDropDownMenu_SetText", "UIDropDownMenu_SetSelectedValue",
    "UIDropDownMenu_EnableDropDown", "UIDropDownMenu_DisableDropDown",

    -- Keybinding
    "GetBindingKey",

    -- Companions (WotLK critter API)
    "GetNumCompanions", "GetCompanionInfo",
    "CallCompanion", "DismissCompanion",

    -- Addon metadata
    "GetAddOnInfo", "GetAddOnMetadata", "IsAddOnLoaded",

    -- Loot
    "IsFishingLoot",

    -- Misc utilities
    "hooksecurefunc", "wipe", "select", "tinsert",
    "NORMAL_FONT_COLOR", "HIGHLIGHT_FONT_COLOR", "ITEM_QUALITY_COLORS",
    "GetTime", "date", "time",
    "GetRealmName", "GetCurrentRegion",
    -- _G moved to the writable globals block above; we write to _G[...]
    -- for one keybinding name that contains a space.
}
