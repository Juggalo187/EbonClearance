-- EbonClearance_PanelInfra - panel-width registry + reactivity layer.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-ix-b of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The panel-infrastructure foundation: every other Interface Options
-- panel in the addon (Main, Merchant, Protection, Scavenger, Item
-- Highlighting, the Sell / Account / Keep / Delete list family,
-- Profiles, Import/Export, Process Bags) builds widgets through
-- these helpers and relies on the reactive layout registry to track
-- Interface Options container resize.
--
-- Moved into this file:
--   * local EC_PANEL_WIDTH (mutable; the container's effective width
--     minus a fixed 40 px margin; default fallback 440)
--   * local function EC_UpdatePanelWidth (refreshes EC_PANEL_WIDTH
--     from InterfaceOptionsFramePanelContainer:GetWidth())
--   * NS.GetPanelWidth (getter closure; captures the upvalue)
--   * EC_compCache.widthRegistry (state: { widgets = {}, scrollFits = {} })
--   * EC_compCache.registerWidth / registerScrollFit / setPanelWidth /
--     refreshLayouts (the 4 reactive-layout helpers)
--   * local function EC_HookScrollbarAutoHide (scroll bar visibility
--     based on content range)
--   * local function EC_WrapPanelInScrollFrame (scroll-wraps a panel;
--     returns the content frame)
--   * local function EC_FitScrollContent (sizes scroll-content to fit
--     the bottom-most widget)
--   * EC_compCache.initPanel (the panel-OnShow preamble extractor)
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - the EC_compCache table shared across files
--   * NS.EnsureDB (Stage 8) - called at the top of initPanel
--   * NS.compCache.registerScrollFit / refreshLayouts read each
--     widget's stored x-offset / padding from internal tables - those
--     tables are only mutated through the helpers in this file so
--     no external API needed
--
-- The widget primitives (MakeHeader, MakeLabel, AddCheckbox, AddSlider,
-- StyleInputBox, ColorTextByQuality) + CreateListUI + the list-row
-- factories STAY in EbonClearance.lua for Stages 8e-ix-c / 8e-ix-d.
-- MakeLabel and CreateListUI reach EC_PANEL_WIDTH through
-- NS.GetPanelWidth() at call time (not via upvalue, because the local
-- now lives in this file's scope).

local NS = select(2, ...)
local EC_compCache = NS.compCache

local EC_PANEL_WIDTH = 440 -- default fallback; updated dynamically in OnShow

local function EC_UpdatePanelWidth()
    local container = InterfaceOptionsFramePanelContainer
    if container and container.GetWidth then
        local w = container:GetWidth()
        if w and w > 100 then
            EC_PANEL_WIDTH = w - 40
        end
    end
end
-- Stage 8e-viii: expose the current panel width to split panel files
-- that need it for build-time SetSize calls. EC_PANEL_WIDTH is a
-- file-scope local that mutates in EC_UpdatePanelWidth, so a static
-- NS value would freeze at first-call time. A getter closure captures
-- the upvalue and returns the live value every call.
NS.GetPanelWidth = function()
    return EC_PANEL_WIDTH
end

-- v2.11.0 reactive layout registry. Pre-v2.11.0 the panel-build pass
-- snapshotted EC_PANEL_WIDTH at first OnShow into every label, every
-- scroll-content, every list internal width - and never touched them
-- again. Dragging the Interface Options frame's resize handle did
-- nothing to the addon's panels because none of those widgets re-read
-- EC_PANEL_WIDTH after their build call. v2.11.0 hooks
-- InterfaceOptionsFramePanelContainer's OnSizeChanged once; widgets
-- whose width snapshots EC_PANEL_WIDTH at construction register
-- themselves on EC_compCache.widthRegistry.widgets, scroll-wrapped
-- panels register their (content, last-widget) pair on
-- EC_compCache.widthRegistry.scrollFits, and the OnSizeChanged callback
-- walks both lists to re-apply widths and re-fit scroll content. No
-- widget rebuilds; pure width refresh.
EC_compCache.widthRegistry = {
    widgets = {},
    scrollFits = {},
}

function EC_compCache.registerWidth(widget, xOffset)
    if not widget then
        return
    end
    local list = EC_compCache.widthRegistry.widgets
    list[#list + 1] = { w = widget, x = xOffset or 0 }
end

function EC_compCache.registerScrollFit(content, last, padding)
    if not content or not last then
        return
    end
    local list = EC_compCache.widthRegistry.scrollFits
    list[#list + 1] = { c = content, l = last, p = padding }
end

-- Convenience: SetWidth + register in one call. Use this at every site
-- that snapshots EC_PANEL_WIDTH into a widget's width so the widget
-- tracks Interface Options frame resizes. Replaces the v2.10.0-and-
-- earlier pattern of "widget:SetWidth(EC_PANEL_WIDTH - X)" - that
-- worked fine on a non-resizable panel but leaves widgets clamped at
-- their snapshot width on resize.
function EC_compCache.setPanelWidth(widget, x)
    if not widget or not widget.SetWidth then
        return
    end
    widget:SetWidth(EC_PANEL_WIDTH - (x or 0))
    EC_compCache.registerWidth(widget, x or 0)
end

function EC_compCache.refreshLayouts()
    EC_UpdatePanelWidth()
    local widgets = EC_compCache.widthRegistry.widgets
    for i = 1, #widgets do
        local d = widgets[i]
        if d.w and d.w.SetWidth then
            d.w:SetWidth(math.max(EC_PANEL_WIDTH - d.x, 100))
        end
    end
    -- After widths are re-applied, the wrapped FontString heights change;
    -- re-fit each scroll content's height to the (now possibly taller)
    -- last-widget extent. Inlined rather than calling EC_FitScrollContent
    -- to avoid re-registering on every resize - the registry pair was
    -- already added at build time.
    local fits = EC_compCache.widthRegistry.scrollFits
    local function compute(f)
        if not f.c or not f.l or not f.l.GetBottom or not f.c.GetTop then
            return
        end
        local top = f.c:GetTop()
        local bottom = f.l:GetBottom()
        if top and bottom and top > bottom then
            f.c:SetHeight(top - bottom + (f.p or 24))
        end
    end
    -- Two-pass identical to EC_FitScrollContent's: first tick catches the
    -- common case, second tick covers FontStrings whose wrapped height
    -- isn't fully settled yet.
    NS.Delay(0.1, function()
        for i = 1, #fits do
            compute(fits[i])
        end
    end)
    NS.Delay(0.5, function()
        for i = 1, #fits do
            compute(fits[i])
        end
    end)
end

-- Auto-hide a UIPanelScrollFrameTemplate's scroll bar (up arrow, thumb,
-- down arrow) when content fits the visible area. Avoids the "orphan icons
-- floating at the right edge" look that lists with few items show.
--
-- Implementation note: a manual GetHeight comparison inside Refresh runs
-- before WoW has laid out the scroll frame on the very first OnShow, so the
-- initial visibility was always wrong. OnScrollRangeChanged is fired by WoW
-- whenever it (re)computes the scroll range, which is exactly the moment the
-- visibility decision is meaningful. The deferred initial update handles the
-- corner case where the script handler is wired after the first range change.
local function EC_HookScrollbarAutoHide(scrollFrame)
    if not scrollFrame or not scrollFrame.GetName then
        return
    end
    local scrollName = scrollFrame:GetName()
    if not scrollName then
        return
    end
    local sb = _G[scrollName .. "ScrollBar"]
    if not sb then
        return
    end
    local function update()
        local yRange = 0
        if scrollFrame.GetVerticalScrollRange then
            yRange = scrollFrame:GetVerticalScrollRange() or 0
        end
        if yRange <= 0 then
            sb:Hide()
        else
            sb:Show()
        end
    end
    scrollFrame:HookScript("OnScrollRangeChanged", update)
    -- Initial check: defer one short tick so layout dimensions are stable.
    NS.Delay(0.1, update)
end
NS.HookScrollbarAutoHide = EC_HookScrollbarAutoHide

-- Wrap a settings panel's body in a vertical scroll frame and return a
-- "content" Frame to use as the widget parent inside that panel's OnShow.
-- Used for panels whose content overflows the Interface Options sub-panel
-- safe area at narrow container widths (Scavenger, Merchant). Width is the
-- panel width minus a 26px scrollbar gutter; the gutter is filled by the
-- scroll bar itself (or empty when EC_HookScrollbarAutoHide hides it).
--
-- After all widgets are placed, the caller should call EC_FitScrollContent
-- to size the content frame to the actual widget extent.
local function EC_WrapPanelInScrollFrame(panel)
    local scrollName = (panel:GetName() or "EbonClearancePanel") .. "Scroll"
    local scroll = CreateFrame("ScrollFrame", scrollName, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    -- v2.10.0: extended the scroll frame down to within 6 px of the panel's
    -- bottom edge (was 30 px). With the v2.4.0 quality threshold + v2.10.0
    -- bind-filter dropdowns, the panel content tall enough for the
    -- scrollbar to be visible all the time, and the previous 30 px reserve
    -- left the down arrow floating above the OK/Cancel button strip with
    -- no visual relationship to the panel frame. EC_FitScrollContent's 24
    -- px padding still keeps the bottom-most widget clear of the OK/Cancel
    -- area; the gap that used to come from the 30 px reserve now comes
    -- from that padding instead.
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(math.max(EC_PANEL_WIDTH - 26, 100))
    content:SetHeight(1) -- expanded by EC_FitScrollContent once widgets are laid out
    scroll:SetScrollChild(content)
    -- v2.11.0: register the scroll content's width with the reactive
    -- layout registry so it tracks Interface Options frame resizes.
    EC_compCache.registerWidth(content, 26)

    -- v2.10.0: nudge the scrollbar's top anchor 4 px further down. The
    -- UIPanelScrollFrameTemplate default insets the bar 16 px from the
    -- ScrollFrame top; the up arrow that lives there ended up sitting
    -- above the panel's content area on Project Ebonhold's Interface
    -- Options layout. Bottom anchor stays at the template default (16 px
    -- inset from ScrollFrame bottom) - the new 6 px outer reserve already
    -- pulls the down arrow down to where it should be.
    local sb = _G[scrollName .. "ScrollBar"]
    if sb then
        sb:ClearAllPoints()
        sb:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -6, -20)
        sb:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -6, 16)
    end

    EC_HookScrollbarAutoHide(scroll)
    return content
end

-- Resize a scroll-wrapped content frame to fit the actual extent of its
-- widgets. Pass the bottom-most widget added during OnShow.
--
-- Two passes: the first at 0.1 s catches the common case quickly; the second
-- at 0.5 s covers FontStrings whose wrapped height isn't fully settled at
-- the first tick (multi-line tips were getting clipped on the Scavenger
-- panel because their wrapped GetBottom hadn't been computed yet).
-- Padding defaults to 24 px so the bottom-most widget always has visible
-- breathing room above the scroll frame's edge.
local function EC_FitScrollContent(content, lastWidget, padding)
    if not content or not lastWidget then
        return
    end
    local pad = padding or 24
    local function compute()
        if not lastWidget.GetBottom or not content.GetTop then
            return
        end
        local top = content:GetTop()
        local bottom = lastWidget:GetBottom()
        if top and bottom and top > bottom then
            content:SetHeight(top - bottom + pad)
        end
    end
    NS.Delay(0.1, compute)
    NS.Delay(0.5, compute)
    -- v2.11.0: register the (content, last) pair so the reactive layout
    -- handler can re-fit when the panel container resizes (label re-wrap
    -- changes lastWidget's GetBottom and the content height needs to
    -- track that). Idempotent re-fits are safe.
    EC_compCache.registerScrollFit(content, lastWidget, pad)
end
NS.FitScrollContent = EC_FitScrollContent

-- v2.17.0: panel OnShow preamble extractor. Replaces the boilerplate
-- (EnsureDB / EC_UpdatePanelWidth / inited guard / refresh-or-build
-- branch / optional scroll-wrap) at the top of every Interface Options
-- panel's OnShow handler. `refresh` is called every OnShow AFTER the
-- first; `build` is called once under the inited guard. `wrapScroll`
-- toggles the EC_WrapPanelInScrollFrame call; when true, `build`
-- receives the scroll-wrap's content frame as its second arg, otherwise
-- it receives the panel `self`. Either callback may be nil. Hung off
-- EC_compCache rather than as a file-scope local to stay under Lua
-- 5.1's 200-locals-per-main-chunk cap (the file is already dense; see
-- CLAUDE.md and ADDON_GUIDE.md for the discipline). Consolidates the
-- duplicated preamble across 11 panels (CODE_REVIEW.md item 4) so
-- future preamble changes - e.g. a UI_SCALE_CHANGED recompute - land
-- in one place instead of 11.
function EC_compCache.initPanel(self, refresh, build, wrapScroll)
    NS.EnsureDB()
    EC_UpdatePanelWidth()
    -- v2.37.3: belt-and-braces hide for the Process Bags panel's
    -- scroll content. When the player is in combat AND switches FROM
    -- Process Bags TO another EC sub-panel, the framework's Hide() on
    -- the Process Bags panel is blocked because it contains a
    -- SecureActionButton ("Process Next"). The block silences the
    -- panel-level Hide() entirely, so neither the framework's hide
    -- propagation NOR our OnHide handler fires - the scroll content
    -- stays visible and the rows bleed through behind whichever panel
    -- shows next. Detection from the OTHER side: whenever any non-
    -- Process-Bags EC panel's OnShow runs through initPanel, walk
    -- across to Process Bags and Hide() its scroll background frame
    -- (which is NOT a secure descendant - just a regular Frame holding
    -- the row ScrollFrame, so the Hide() is unblocked even in combat).
    -- The matching Show() inside Process Bags' OnShow handler restores
    -- visibility when the player returns to that panel.
    local pbp = _G["EbonClearanceOptionsProcessBags"]
    if pbp and pbp ~= self and pbp.processScrollBg then
        pbp.processScrollBg:Hide()
    end
    if self.inited then
        if refresh then
            refresh(self)
        end
        return
    end
    self.inited = true
    local content = self
    if wrapScroll then
        content = EC_WrapPanelInScrollFrame(self)
    end
    if build then
        build(self, content)
    end
end
