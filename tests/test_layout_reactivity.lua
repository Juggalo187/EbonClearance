#!/usr/bin/env lua
-- Layout-reactivity regression tests for EbonClearance.
--
-- Run from repo root:    lua tests/test_layout_reactivity.lua
--
-- v2.11.0 made the Interface Options panels reactive to the user
-- resizing the container frame (previously every label / list / scroll
-- snapshotted EC_PANEL_WIDTH at first OnShow and never re-flowed).
-- The plumbing is small but easy to bypass: a contributor adding a new
-- panel widget can write `:SetWidth(EC_PANEL_WIDTH - X)` directly and
-- the widget silently freezes at its build-time width.
--
-- These tests are static-pattern checks against the source. They do NOT
-- run the addon - the WoW API is not mockable - but they catch the four
-- structural mistakes that caused the original v2.11.0 regression report:
--
--   1. Bare :SetWidth(EC_PANEL_WIDTH - X) outside the registered helpers.
--   2. CreateListUI / CreateNameListUI missing the box:OnSizeChanged hook.
--   3. Panels using CreateListUI without the ClearAllPoints + BOTTOMRIGHT
--      anchor follow-up (so list rows can stretch with the parent).
--   4. List row text using SetWidth instead of TOPLEFT + TOPRIGHT anchors.
--
-- Add new tests below as new structural invariants emerge. Keep them
-- pattern-matching only - this file must run under stock lua5.1 with no
-- external dependencies so it works in CI without a luarocks step.

local SOURCE_PATH = "EbonClearance.lua"

local f, err = io.open(SOURCE_PATH, "r")
if not f then
    io.stderr:write("FAIL: cannot open " .. SOURCE_PATH .. ": " .. tostring(err) .. "\n")
    os.exit(1)
end
local src = f:read("*a")
f:close()

local fails = 0

local function check(name, ok, message)
    if ok then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name)
        if message then
            print("      " .. message)
        end
        fails = fails + 1
    end
end

-- ---------------------------------------------------------------------------
-- Test 1: no bare :SetWidth(EC_PANEL_WIDTH - N) outside the two known helpers.
-- ---------------------------------------------------------------------------
-- Two patterns are allowed:
--   * Inside EC_compCache.setPanelWidth: "widget:SetWidth(EC_PANEL_WIDTH - (x or 0))"
--   * Inside MakeLabel:                    "fs:SetWidth(EC_PANEL_WIDTH - x)"
-- Plus comment lines (the helper's own docstring references the pattern).
-- Any other ":SetWidth(EC_PANEL_WIDTH" is a regression - the widget will
-- not track resize. Use EC_compCache.setPanelWidth instead.
do
    local violators = {}
    for line in src:gmatch("([^\n]+)") do
        if line:find(":SetWidth%(EC_PANEL_WIDTH") then
            local stripped = line:gsub("^%s+", "")
            local isHelperBody = stripped:find("^widget:SetWidth%(EC_PANEL_WIDTH %- %(x or 0%)%)")
            local isMakeLabel = stripped:find("^fs:SetWidth%(EC_PANEL_WIDTH %- x%)")
            local isComment = stripped:find("^%-%-")
            if not (isHelperBody or isMakeLabel or isComment) then
                violators[#violators + 1] = line
            end
        end
    end
    local detail
    if #violators > 0 then
        local list = {}
        for i = 1, #violators do
            list[i] = "    " .. violators[i]
        end
        detail = "found " .. #violators .. " bare snapshot(s); use EC_compCache.setPanelWidth instead:\n" ..
                 table.concat(list, "\n")
    end
    check("no bare SetWidth(EC_PANEL_WIDTH-X) outside helpers", #violators == 0, detail)
end

-- ---------------------------------------------------------------------------
-- Test 2: CreateListUI and CreateNameListUI must each install an
-- OnSizeChanged hook on their `box` so the ScrollChild content (and
-- therefore the rows anchored to it) tracks parent resize.
-- ---------------------------------------------------------------------------
do
    local function hasOnSizeChanged(funcName)
        local body = src:match("local function " .. funcName .. ".-end\n$")
        if not body then
            -- Fallback: take everything from the function definition to the
            -- next "local function " (or end of file) - good enough for the
            -- structural check and avoids needing a real Lua parser.
            local startIdx = src:find("local function " .. funcName)
            if not startIdx then
                return nil, "function " .. funcName .. " not found"
            end
            local nextIdx = src:find("\nlocal function ", startIdx + 1) or #src
            body = src:sub(startIdx, nextIdx)
        end
        return body:find('box:SetScript%("OnSizeChanged"') ~= nil, body
    end

    local ok1 = hasOnSizeChanged("CreateListUI")
    check("CreateListUI installs box:OnSizeChanged", ok1,
        "missing - rows inside CreateListUI will not stretch with the panel on resize")

    local ok2 = hasOnSizeChanged("CreateNameListUI")
    check("CreateNameListUI installs box:OnSizeChanged", ok2,
        "missing - rows inside CreateNameListUI will not stretch with the panel on resize")
end

-- ---------------------------------------------------------------------------
-- Test 3: every panel that uses CreateListUI / CreateNameListUI must
-- follow up with ClearAllPoints + BOTTOMRIGHT anchor so the list box
-- itself tracks the panel size. Without this the box stays at its
-- build-time width and the OnSizeChanged inside the helper is never
-- triggered with a new size.
-- ---------------------------------------------------------------------------
do
    local panelsMissingAnchor = {}
    -- Capture each "self.listUI = CreateListUI/CreateNameListUI(..." line plus
    -- the next ~6 lines of context. If "ClearAllPoints" and "BOTTOMRIGHT"
    -- aren't both present in that block, the panel doesn't anchor properly.
    for callLine in src:gmatch("(self%.listUI = Create[N]?a?m?e?ListUI%([^\n]*)") do
        local startIdx = src:find(callLine, 1, true)
        if startIdx then
            local block = src:sub(startIdx, startIdx + 600) -- ~10-15 lines
            -- Stop the block at "self.listUI:Refresh()" or "end)" - whichever
            -- comes first - so we don't leak into the next panel.
            local stopAt = block:find("self%.listUI:Refresh%(%)") or block:find("\nend%)")
            if stopAt then
                block = block:sub(1, stopAt)
            end
            if not (block:find("ClearAllPoints") and block:find("BOTTOMRIGHT")) then
                panelsMissingAnchor[#panelsMissingAnchor + 1] = callLine
            end
        end
    end
    local detail
    if #panelsMissingAnchor > 0 then
        local list = {}
        for i = 1, #panelsMissingAnchor do
            list[i] = "    " .. panelsMissingAnchor[i]
        end
        detail = "found " .. #panelsMissingAnchor .. " call(s) without ClearAllPoints + BOTTOMRIGHT setup:\n" ..
                 table.concat(list, "\n")
    end
    check("every CreateListUI/CreateNameListUI call anchors BOTTOMRIGHT",
          #panelsMissingAnchor == 0, detail)
end

-- ---------------------------------------------------------------------------
-- Test 4: list row text must use SetPoint("RIGHT", ...) anchoring, not
-- SetWidth(w - N). The latter snapshots width at construction; the
-- former auto-stretches with the parent row.
-- ---------------------------------------------------------------------------
do
    -- Look for the GetRow-style construction of the row text. The
    -- regression pattern was: text:SetWidth(w - 106). The fix replaces
    -- it with: text:SetPoint("RIGHT", rm, "LEFT", -8, 0)
    local rowTextSnapshots = 0
    for line in src:gmatch("([^\n]+)") do
        if line:find("text:SetWidth%(w %- %d") then
            rowTextSnapshots = rowTextSnapshots + 1
        end
    end
    check("list row text uses anchors not SetWidth(w-N)",
        rowTextSnapshots == 0,
        "found " .. rowTextSnapshots ..
        " row text snapshot(s); use text:SetPoint(\"RIGHT\", rm, \"LEFT\", ...) instead")
end

-- ---------------------------------------------------------------------------
-- Test 5: the reactive layout machinery itself must be wired up. If any
-- of these go missing the whole system silently degrades to v2.10.0
-- behaviour (snapshotted everything).
-- ---------------------------------------------------------------------------
do
    check("widthRegistry is defined on EC_compCache",
        src:find("EC_compCache%.widthRegistry%s*=%s*{") ~= nil,
        "EC_compCache.widthRegistry table missing - registerWidth has nothing to push to")

    check("EC_compCache.refreshLayouts is defined",
        src:find("function EC_compCache%.refreshLayouts%(%)") ~= nil,
        "refresh entrypoint missing - the OnSizeChanged hook will fail")

    check("InterfaceOptionsFramePanelContainer:OnSizeChanged hook is wired",
        src:find('InterfaceOptionsFramePanelContainer:HookScript%("OnSizeChanged"') ~= nil,
        "the container OnSizeChanged hook is gone - panels will not refresh on resize")
end

-- ---------------------------------------------------------------------------
-- Test 6: panels with meaningful vertical content must be scroll-wrapped
-- via EC_WrapPanelInScrollFrame so a short Interface Options frame
-- doesn't bury the bottom widgets behind the OK/Cancel button strip.
-- The Main panel was originally not wrapped; v2.12.0 fixed that after
-- the user reported the Slash Commands block overlapping the buttons
-- on a narrow window. List-style panels (Whitelist*, Blacklist,
-- Deletion, Character Settings) self-stretch via list anchoring and
-- don't need scroll wrap.
--
-- v2.17.0 extracted the panel OnShow boilerplate into
-- `EC_compCache.initPanel(self, refresh, build, wrapScroll)`. Panels
-- that previously called `EC_WrapPanelInScrollFrame` inline now pass
-- `true` as the wrapScroll arg and the helper does the call internally.
-- The test accepts either form: literal `EC_WrapPanelInScrollFrame(`
-- (old style or build-callback style) OR the `end, true)` closer that
-- marks an initPanel call with wrapScroll=true. The `end, true)`
-- pattern is specific enough not to match SetWordWrap(true) or other
-- bare `true)` occurrences inside callback bodies.
-- ---------------------------------------------------------------------------
do
    local panelsNeedingWrap = {
        { name = "MainOptions",      onShowMarker = "MainOptions:SetScript%(\"OnShow\"" },
        { name = "ScavengerPanel",   onShowMarker = "ScavengerPanel:SetScript%(\"OnShow\"" },
        { name = "MerchantPanel",    onShowMarker = "MerchantPanel:SetScript%(\"OnShow\"" },
    }
    local missing = {}
    for _, p in ipairs(panelsNeedingWrap) do
        local startIdx = src:find(p.onShowMarker)
        if not startIdx then
            missing[#missing + 1] = p.name .. " (OnShow handler not found)"
        else
            -- Block boundary: from this OnShow to the start of the next
            -- panel's OnShow (or the registration block, whichever comes
            -- first). This keeps each panel's check scoped to its own body
            -- rather than leaking into adjacent panels.
            local nextOnShow = src:find("[A-Za-z_]+:SetScript%(\"OnShow\"", startIdx + #p.onShowMarker)
            local nextRegister = src:find("\nInterfaceOptions_AddCategory", startIdx + 1)
            local endIdx = nextOnShow or nextRegister or (startIdx + 15000)
            if nextOnShow and nextRegister then
                endIdx = math.min(nextOnShow, nextRegister)
            end
            local block = src:sub(startIdx, endIdx)
            local hasOldWrap = block:find("EC_WrapPanelInScrollFrame")
            local hasNewWrap = block:find("end, true%)")
            if not (hasOldWrap or hasNewWrap) then
                missing[#missing + 1] = p.name
            end
        end
    end
    local detail
    if #missing > 0 then
        detail = "missing scroll wrap on: " .. table.concat(missing, ", ")
    end
    check("major content panels are scroll-wrapped via EC_WrapPanelInScrollFrame",
        #missing == 0, detail)
end

-- ---------------------------------------------------------------------------
-- Test 7: ADDON_VERSION lua constant matches the .toc Version field.
-- ---------------------------------------------------------------------------
-- The lua constant is what EC_GetVersion returns (and therefore what the
-- panel header / /ec bugreport display). The .toc Version field is what
-- Blizzard's AddOn list shows. Drift between the two means EC says one
-- version while WoW says another.
--
-- Pre-v2.13.2, the release workflow only updated the .toc and silently
-- failed to update the lua constant, leaving in-game version displays
-- stuck at v2.12.0 across the v2.13.0 and v2.13.1 releases. This test
-- locks the invariant so any future release that updates one but not
-- the other fails CI before it can ship.
do
    local tocPath = "EbonClearance.toc"
    local f, err = io.open(tocPath, "r")
    if not f then
        check("ADDON_VERSION matches .toc Version field", false,
            "cannot open " .. tocPath .. ": " .. tostring(err))
    else
        local tocContent = f:read("*a")
        f:close()
        local tocVersion = tocContent:match("##%s*Version:%s*(v[%d%.]+)")
        local luaVersion = src:match("local ADDON_VERSION%s*=%s*\"(v[%d%.]+)\"")
        local message
        if not tocVersion then
            message = "no '## Version: vX.Y.Z' line found in " .. tocPath
        elseif not luaVersion then
            message = "no 'local ADDON_VERSION = \"vX.Y.Z\"' line found in " .. SOURCE_PATH
        elseif tocVersion ~= luaVersion then
            message = string.format(
                "version drift: %s says %s but %s says %s",
                tocPath, tocVersion, SOURCE_PATH, luaVersion
            )
        end
        check("ADDON_VERSION matches .toc Version field", message == nil, message)
    end
end

-- ---------------------------------------------------------------------------
-- Result.
-- ---------------------------------------------------------------------------
print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
