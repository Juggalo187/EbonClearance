-- EbonClearance_Protection - PE roguelite affix + chance-on-hit detection.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 4 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. This file owns the protection-detection cluster previously in
-- EbonClearance.lua at lines ~1817-2477:
--
--   * v2.19.0+ PE random-affix detection (linkHasAffix, romanToInt,
--     parseAffixFromTitle, scanTooltipForAffixDesc, normaliseAffixDesc,
--     bagSlotAffixData, bagSlotHasAffix, liveTooltipAffixData,
--     liveTooltipHasAffix).
--   * v2.23.0+ PE engraving / affix-catalog integration
--     (knownAffixDescriptions table, peDetected, refreshKnownAffixes,
--     refreshExtractionIfDirty, playerHasAffixDescription, the
--     procIdToDescription cache, knownExtractionVersion counter).
--   * v2.20.0+ PE chance-on-hit detection (lineLooksLikeChanceProc,
--     itemHasChanceOnHit, liveTooltipHasChanceOnHit, chanceOnHitCache).
--   * v2.26.0 PE Anvil bridge (findLearnedAffixForItem,
--     itemAffixLookupCache).
--
-- Every helper is attached to EC_compCache (= NS.compCache, created in
-- EbonClearance_Core.lua). Call sites elsewhere in the addon already
-- resolve through the EC_compCache upvalue, so no call-site changes
-- were needed for the move.
--
-- Cross-file API surface this file relies on:
--   * NS.compCache              (Core)  - target table for all helpers
--   * NS.scanTooltip            (EbonClearance.lua) - the private named
--                                 GameTooltip used by every scan call.
--                                 We bind it lazily via NS.scanTooltip
--                                 inside function bodies, NOT as a
--                                 file-load upvalue, because the frame
--                                 is created by EbonClearance.lua's
--                                 main chunk which runs AFTER this
--                                 file loads. By the time any of these
--                                 functions is first called (BAG_UPDATE,
--                                 vendor run, tooltip annotation), the
--                                 frame exists.
--
-- Naming: the file-scope upvalue `EC_scanTooltip` is restored at the top
-- of this file by reading NS.scanTooltip... but NS.scanTooltip is nil at
-- our file-load time. The TextLeft FontStrings are looked up by the
-- absolute name "EbonClearanceScanTooltipTextLeft<N>" via _G, which is
-- only resolved at call time, so they keep working. The `EC_scanTooltip`
-- identifier inside method bodies is rewritten to NS.scanTooltip inline
-- when called (closures capture the NS table, not the field, and the
-- field is dereferenced at call time).

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- Read-through accessor so each call resolves NS.scanTooltip fresh.
-- EbonClearance.lua creates the frame and writes NS.scanTooltip during
-- its main chunk; this file loads first, so any file-load attempt to
-- capture the frame as an upvalue would store nil. Wrap in a function
-- and call it inside each method body.
local function scanTip()
    return NS.scanTooltip
end

-- ---------------------------------------------------------------------------
-- v2.19.0: PE roguelite affix detection
-- ---------------------------------------------------------------------------
-- Project Ebonhold randomly applies suffix-style affixes to items (e.g.
-- `Thorbia's Gauntlets of Fortified by Pain IV` shares the base itemID
-- with the plain `Thorbia's Gauntlets` but adds a random " of X" suffix
-- and a proc effect). EC needs to detect affixed instances so the
-- Sell-List / Delete-List itemID match doesn't accidentally dump them.
--
-- Two-layer detection:
--   1. linkHasAffix(link)         - parses the 7th field of the item
--      link (suffix-DBC ID). Non-zero means the standard 3.3.5a random
--      property/suffix system fired on this instance. Cheap; one regex.
--   2. bagSlotHasAffix / liveTooltipHasAffix - fallback that compares
--      the live tooltip's title (TextLeft1) to GetItemInfo's base name.
--      If they differ, the title has extra text appended - affix
--      detected. Covers the case where PE uses a custom mechanism that
--      doesn't touch the link's suffix slot. Slightly more expensive
--      (tooltip scan) but only fires when Layer 1 returned false.
function EC_compCache.linkHasAffix(link)
    if not link then
        return false
    end
    -- 3.3.5a item link format:
    -- |cQUALITY|Hitem:ID:enchant:gem1:gem2:gem3:gem4:suffix:uniqueID:level|h[Name]|h|r
    -- The 7th numeric field is the suffix-DBC ID. Positive =
    -- ItemRandomProperties.dbc, negative = ItemRandomSuffix.dbc, zero
    -- = no random property. We only care about non-zero.
    local suffix = link:match("item:%-?%d+:%-?%d+:%-?%d+:%-?%d+:%-?%d+:%-?%d+:(%-?%d+):")
    local n = suffix and tonumber(suffix)
    return n ~= nil and n ~= 0
end

-- v2.20.0: narrowed affix detection. The previous v2.19.0 logic
-- returned true on ANY non-zero suffix-DBC field (Layer 1) OR any
-- tooltip-title that differed from GetItemInfo's base name (Layer 2),
-- which conflated PE roguelite affixes with standard 3.3.5a random
-- suffixes (`of the Bear`, `of the Sorcerer`, etc.). Bug: standard
-- random-suffix items were being protected as if they were PE
-- roguelite affixes, blocking legitimate vendor sales.
--
-- Discriminator: PE roguelite affixes always end with a roman-numeral
-- rank (I, II, III, IV, ...). Standard ItemRandomSuffix.dbc entries
-- don't. So both checks now require BOTH "tooltip title differs from
-- base name" AND "tooltip title ends with a roman-numeral rank".
--
-- linkHasAffix is retained as a diagnostic helper (it still correctly
-- reports whether the suffix-DBC field is non-zero) but is no longer
-- consulted in the protection decision.
-- v2.23.0: roman-numeral parser used by parseAffixFromTitle. Covers
-- I-V which is sufficient for PE (current cap is rank IV). Returns
-- the integer rank or nil if the input doesn't look like roman. The
-- value table lives on EC_compCache instead of as a file-scope local
-- to stay under Lua 5.1's 200-locals-per-main-chunk cap.
EC_compCache.ROMAN_VALUES = { I = 1, V = 5, X = 10, L = 50, C = 100, D = 500, M = 1000 }
function EC_compCache.romanToInt(s)
    if not s or s == "" then
        return nil
    end
    local total = 0
    local prev = 0
    for i = #s, 1, -1 do
        local ch = s:sub(i, i)
        local v = EC_compCache.ROMAN_VALUES[ch]
        if not v then
            return nil
        end
        if v < prev then
            total = total - v
        else
            total = total + v
        end
        prev = v
    end
    return total > 0 and total or nil
end

-- v2.23.0: pull the affix name + rank out of a tooltip title.
-- Returns { name = "of Inner Light", rank = 2 } for a title like
-- "Helm of Inner Light II" against baseName "Helm". Returns nil for
-- anything that doesn't match the PE rank-suffix discriminator.
function EC_compCache.parseAffixFromTitle(liveName, baseName)
    if not liveName or liveName == "" or not baseName then
        return nil
    end
    if liveName == baseName then
        return nil
    end
    -- The roman-numeral rank-suffix discriminator (see v2.20.0 fix in
    -- bagSlotHasAffix above).
    local rankStr = liveName:match(" ([IVXLCDM]+)$")
    if not rankStr then
        return nil
    end
    local rank = EC_compCache.romanToInt(rankStr)
    if not rank then
        return nil
    end
    -- Strip the baseName prefix + the trailing " <rank>". What's left
    -- is the affix name as it appears in tooltip / PerkService.
    -- e.g. "Helm of Inner Light II" - "Helm " - " II" -> "of Inner Light"
    if liveName:sub(1, #baseName + 1) ~= (baseName .. " ") then
        -- Title doesn't start with base name + space - unexpected
        -- shape (PE might prepend something one day). Fall back to
        -- "everything before the rank" which is still useful as the
        -- name for dupe matching.
        local trimmed = liveName:sub(1, #liveName - #rankStr - 1)
        return { name = trimmed, rank = rank }
    end
    local affixName = liveName:sub(#baseName + 2, #liveName - #rankStr - 1)
    if affixName == "" then
        return nil
    end
    return { name = affixName, rank = rank }
end

-- v2.23.0: PE affix lines are delimited by literal `@affix@` markers
-- in the raw tooltip text. EC's private scan tooltip sees the raw
-- text; PE's tooltip post-processing strips the markers from the
-- live GameTooltip before display. Two-path scan handles both:
--   1. Look for a `@affix@...@affix@` wrapped line - hits on our
--      private scan tooltip with raw markers intact.
--   2. Fall back to: any line that, after normalisation, matches an
--      entry in knownAffixDescriptions. Handles the live GameTooltip
--      after PE has cleaned the markers off.
-- Returns the description text or nil.
function EC_compCache.scanTooltipForAffixDesc(tooltipName)
    if not tooltipName then
        return nil
    end
    -- Path 1: raw @affix@-wrapped line.
    for i = 1, 30 do
        local fs = _G[tooltipName .. "TextLeft" .. i]
        if fs and fs.GetText then
            local txt = fs:GetText()
            if txt then
                local desc = txt:match("@affix@%s*(.-)%s*@affix@")
                if desc and desc ~= "" then
                    return desc
                end
            end
        end
    end
    -- Path 2: PE-stripped tooltip. Match any line against the known
    -- set; if a line's normalised text is in the set, that line is
    -- the affix description. Returns the raw line text so the caller
    -- can re-normalise for the dupe lookup (idempotent).
    --
    -- Stat affixes have a "Stacks with other ranks." disclaimer
    -- appended in the bag tooltip that isn't on the engraving-spell
    -- side. If a full-line match fails, try matching against just
    -- the first sentence (up to the first ". " separator) so the
    -- disclaimer suffix is ignored. Proc affixes with embedded
    -- mid-sentence periods still match via the full-line path
    -- because their first-sentence trim won't appear in the set.
    local known = EC_compCache.knownAffixDescriptions
    if known then
        for i = 1, 30 do
            local fs = _G[tooltipName .. "TextLeft" .. i]
            if fs and fs.GetText then
                local txt = fs:GetText()
                if txt and txt ~= "" then
                    local norm = EC_compCache.normaliseAffixDesc(txt)
                    if norm and norm ~= "" and known[norm] then
                        return txt
                    end
                    -- First-sentence fallback for stat affixes.
                    local first = txt:match("^(.-)%.%s")
                    if first and first ~= "" then
                        local firstNorm = EC_compCache.normaliseAffixDesc(first)
                        if firstNorm and firstNorm ~= "" and known[firstNorm] then
                            return txt
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- v2.23.0: normalise an affix description for cross-source matching.
-- Item tooltip's @affix@ block may carry trailing punctuation that
-- the engraving spell tooltip's description omits (or vice versa).
-- Strip whitespace + trailing sentence punctuation so both ends of
-- the lookup compare equal. Case-folds the result so the comparison
-- tolerates source-side casing differences (e.g. rank-1 entries that
-- ship with a lowercase opening letter while rank-2 / rank-3 ship
-- with a capital, which would otherwise miss for an "already known"
-- duplicate check on the rank-1 affix only).
function EC_compCache.normaliseAffixDesc(s)
    if type(s) ~= "string" then
        return nil
    end
    -- Strip WoW colour escapes so a purple-formatted live tooltip
    -- line matches a plain-text spell tooltip description.
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    -- Strip lingering @affix@ markers in case any survived.
    s = s:gsub("@affix@", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("[%.%!%?]+$", "")
    return s:lower()
end

-- v2.23.0: structured affix lookup for a bag slot. Returns
-- { name, rank, description } or nil.
--   - name + rank come from the title's roman-numeral suffix (the
--     v2.19.0+ presence discriminator; what triggers protection).
--   - description is the engraved-effect string from the @affix@
--     line; matches against the player's known-affix set so we can
--     decide whether to allow the item through as an exact dupe.
-- bagSlotHasAffix is a thin boolean wrapper so existing call sites
-- (EC_IsSellable, BuildQueue, buildProcessSummary) keep working
-- unchanged.
-- v2.24.0: per-instance affix cache keyed by itemString. The
-- itemString fragment captures the suffix-DBC field, so two stacks
-- with different affix rolls are distinct keys naturally. Cleared on
-- /reload (same lifecycle as bindCache / processCache /
-- chanceOnHitCache - per-session, not persisted to DB). Stores
-- `false` for "scanned, no affix" to avoid rescanning bag items that
-- aren't affixed.
EC_compCache.affixDataCache = {}

function EC_compCache.bagSlotAffixData(bag, slot)
    if not bag or not slot then
        return nil
    end
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return nil
    end
    local link = GetContainerItemLink(bag, slot)
    local itemString = link and link:match("item[%-?%d:]+")
    if itemString then
        local cached = EC_compCache.affixDataCache[itemString]
        if cached ~= nil then
            return cached or nil -- `false` means "scanned, no affix"
        end
    end
    local baseName = GetItemInfo(itemID)
    if not baseName then
        return nil
    end
    scanTip():ClearLines()
    scanTip():SetBagItem(bag, slot)
    local titleFS = _G["EbonClearanceScanTooltipTextLeft1"]
    if not titleFS or not titleFS.GetText then
        return nil
    end
    local titleText = titleFS:GetText() or ""
    local data = EC_compCache.parseAffixFromTitle(titleText, baseName)
    if not data then
        -- Cache-poison guard. A fresh affixed drop sometimes hits this
        -- function before its tooltip's TextLeft1 has fully resolved
        -- (the link's suffix-DBC field needs a client-side load pass).
        -- The earlier implementation cached `false` unconditionally, so
        -- a cold-tooltip scan permanently masked the affix for the rest
        -- of the session - EC_IsSellable then saw "no affix" and the
        -- item vendored / DE'd despite EC_AnnotateTooltip (which reads
        -- the live tooltip with no cache) correctly showing the Keep
        -- protection label.
        --
        -- Fix: only cache `false` when we can positively identify the
        -- item as not a PE roguelite affix. The stable discriminator is
        -- the trailing roman-numeral rank suffix; its absence in a
        -- non-empty title is conclusive (standard ItemRandomSuffix.dbc
        -- entries like "of the Bear" also fall into this bucket and
        -- get cached cheaply). Empty / unparseable titles, AND titles
        -- that DO have a roman suffix but failed parseAffixFromTitle
        -- for some other reason, are NOT cached so the next call
        -- retries cleanly after the client finishes loading the link.
        local stableNoAffix = titleText ~= "" and titleText:match(" [IVXLCDM]+$") == nil
        if itemString and stableNoAffix then
            EC_compCache.affixDataCache[itemString] = false
        end
        return nil
    end
    data.description = EC_compCache.scanTooltipForAffixDesc("EbonClearanceScanTooltip")
    if itemString then
        EC_compCache.affixDataCache[itemString] = data
    end
    return data
end

function EC_compCache.bagSlotHasAffix(bag, slot)
    return EC_compCache.bagSlotAffixData(bag, slot) ~= nil
end

-- v2.23.0: structured affix lookup for a live tooltip + itemID.
-- Same shape as bagSlotAffixData but reads the FontString off the
-- live tooltip frame (used by the bag-item tooltip annotation path).
function EC_compCache.liveTooltipAffixData(tooltip, itemID)
    if not tooltip or not tooltip.GetName or not itemID then
        return nil
    end
    local baseName = GetItemInfo(itemID)
    if not baseName then
        return nil
    end
    local tname = tooltip:GetName()
    if not tname then
        return nil
    end
    local titleFS = _G[tname .. "TextLeft1"]
    if not titleFS or not titleFS.GetText then
        return nil
    end
    local data = EC_compCache.parseAffixFromTitle(titleFS:GetText(), baseName)
    if not data then
        return nil
    end
    data.description = EC_compCache.scanTooltipForAffixDesc(tname)
    return data
end

function EC_compCache.liveTooltipHasAffix(tooltip, link, itemID)
    -- link arg retained for backwards-compat with the v2.19.0 signature
    -- but no longer used (the discriminator is now the tooltip title's
    -- rank suffix, not the link's suffix-DBC field).
    return EC_compCache.liveTooltipAffixData(tooltip, itemID) ~= nil
end

-- ---------------------------------------------------------------------------
-- v2.23.0: PE engraving / affix integration
-- ---------------------------------------------------------------------------
-- PE affixes (the rank-suffixed "of Inner Light II"-style names on
-- Rare/Epic items) are backed by engraving spells in the player's
-- spellbook. After extracting an affix, the engraving spell is
-- learned; its tooltip reads "Allows you to engrave this affix on
-- any equippable item: <effect text>".
--
-- The matchable identifier is the EFFECT TEXT (e.g. "Increases your
-- total Spirit by 6%."), which appears verbatim:
--
--   * On the bag item's tooltip, wrapped in literal `@affix@`
--     markers on one of the lines below the item stats.
--   * On the engraving spell's tooltip, after the "Allows you to
--     engrave this affix on any equippable item: " prefix.
--
-- Rank is naturally encoded in the description ("by 3%" vs "by 6%"),
-- so a description-match implicitly does an exact-rank dupe check -
-- exactly the semantics the user wanted.
--
-- This indirection is necessary because the item-suffix name
-- ("of Inner Light") and the engraving-spell name ("Spirit Surge")
-- are unrelated strings in PE's data model.
--
-- We do not use ProjectEbonhold.PerkService.GetGrantedPerks() - that
-- returns RUN-PERK echoes ("Agility Boost", "Warm-Blooded", etc.),
-- a different system from item affixes.
EC_compCache.knownAffixDescriptions = {}

function EC_compCache.peDetected()
    return _G.ProjectEbonhold ~= nil
end

-- Engraving-spell tooltip prefix that identifies an affix in the
-- player's spellbook. Other PE spells (run perks, racials, profession
-- skills) don't carry this prefix.
EC_compCache.AFFIX_SPELL_PREFIX = "engrave this affix"

-- v2.26.0: dirty-check counter for the ExtractionService merge step.
-- Bumps when the count of `learned==true` records in
-- _G.ExtractionService.learnedAffixes changes; lets the BAG_UPDATE
-- and PLAYER_REGEN_ENABLED handlers skip the (more expensive)
-- description-scan loop when nothing has changed since the last
-- refresh.
EC_compCache.knownExtractionVersion = 0
-- Per-spell description cache. Populated lazily on first scan; never
-- invalidated because the engraving spell's description text is
-- immutable for a given spell ID (the same DBC record across all
-- characters). /reload wipes this naturally (EC_compCache is not
-- persisted).
EC_compCache.procIdToDescription = {}
-- v2.30.0: spellbook tooltip cache. Same rationale as procIdToDescription
-- but covers the spellbook walk. Maps spellID -> normalised affix
-- description string, or false if the spell is not an affix engraving.
-- Avoids re-scanning hundreds of tooltip SetHyperlink calls on every
-- refreshKnownAffixes invocation.
EC_compCache.spellbookAffixCache = {}

-- v2.30.0 perf: debounce SPELLS_CHANGED / LEARNED_SPELL_IN_TAB events.
-- Soul ash tree application and login can fire dozens of spell events in
-- rapid succession; each triggering a full spellbook walk with tooltip
-- scans caused 30+ second freezes. Same debounce pattern as BAG_UPDATE:
-- accumulate events, wait for a 0.5 s idle window, then fire once.
EC_compCache.spellUpdatePending = false
EC_compCache.spellUpdateAccum = 0
EC_compCache.SPELL_UPDATE_DEBOUNCE_S = 0.5
EC_compCache.spellUpdateFrame = CreateFrame("Frame")
EC_compCache.spellUpdateFrame:Hide()
EC_compCache.spellUpdateFrame:SetScript("OnUpdate", function(self, elapsed)
    EC_compCache.spellUpdateAccum = EC_compCache.spellUpdateAccum + elapsed
    if EC_compCache.spellUpdateAccum < EC_compCache.SPELL_UPDATE_DEBOUNCE_S then
        return
    end
    self:Hide()
    EC_compCache.spellUpdatePending = false
    if EC_compCache.refreshKnownAffixes then
        EC_compCache.refreshKnownAffixes()
    end
end)

-- v2.30.0 perf: chunked spellbook walk. Processes up to
-- SPELLS_PER_CHUNK spells per frame to avoid blocking the UI.
-- Only uncached spells need a tooltip scan; cached ones are free.
EC_compCache.SPELLS_PER_CHUNK = 30
EC_compCache._affixScanState = nil -- active chunked scan state

-- Internal: frame that drives the chunked spellbook walk.
EC_compCache._affixScanFrame = CreateFrame("Frame")
EC_compCache._affixScanFrame:Hide()
EC_compCache._affixScanFrame:SetScript("OnUpdate", function(self)
    local st = EC_compCache._affixScanState
    if not st then
        self:Hide()
        return
    end
    local tip = scanTip()
    if not tip then
        self:Hide()
        return
    end
    local cache = EC_compCache.spellbookAffixCache
    local map = st.map
    local spells = st.spells
    local idx = st.idx
    local scansLeft = EC_compCache.SPELLS_PER_CHUNK

    while idx <= #spells and scansLeft > 0 do
        local spellId = spells[idx]
        local cached = cache[spellId]
        if cached == nil then
            -- Uncached: tooltip scan required. Costs budget.
            cached = false
            tip:ClearLines()
            tip:SetHyperlink("spell:" .. spellId)
            for j = 1, tip:NumLines() do
                local fs = _G["EbonClearanceScanTooltipTextLeft" .. j]
                if fs and fs.GetText then
                    local txt = fs:GetText()
                    if txt and txt:find(EC_compCache.AFFIX_SPELL_PREFIX, 1, true) then
                        local desc = txt:match(":%s*(.+)$")
                        desc = EC_compCache.normaliseAffixDesc(desc)
                        if desc and desc ~= "" then
                            cached = desc
                        end
                        break
                    end
                end
            end
            cache[spellId] = cached
            scansLeft = scansLeft - 1
        end
        -- Cached hits are free - no budget cost.
        if cached then
            map[cached] = true
        end
        idx = idx + 1
    end
    st.idx = idx

    if idx > #spells then
        -- Spellbook walk done. Merge ExtractionService (small, always
        -- synchronous - procIdToDescription cache keeps it cheap).
        local svc = _G.ExtractionService
        if svc and type(svc.learnedAffixes) == "table" then
            for _, r in ipairs(svc.learnedAffixes) do
                if r and r.learned and r.id then
                    local desc = EC_compCache.procIdToDescription[r.id]
                    if desc == nil then
                        desc = false
                        tip:ClearLines()
                        tip:SetHyperlink("spell:" .. r.id)
                        for j = 1, tip:NumLines() do
                            local fs = _G["EbonClearanceScanTooltipTextLeft" .. j]
                            if fs and fs.GetText then
                                local txt = fs:GetText()
                                if txt and txt:find(EC_compCache.AFFIX_SPELL_PREFIX, 1, true) then
                                    local d = txt:match(":%s*(.+)$")
                                    d = EC_compCache.normaliseAffixDesc(d)
                                    if d and d ~= "" then
                                        desc = d
                                    end
                                    break
                                end
                            end
                        end
                        EC_compCache.procIdToDescription[r.id] = desc
                    end
                    if desc then
                        map[desc] = true
                    end
                end
            end
        end
        EC_compCache.knownAffixDescriptions = map
        EC_compCache._affixScanState = nil
        self:Hide()
    end
end)

-- v2.30.0 perf: ASYNCHRONOUS. The rebuild was synchronous before PR #2.
-- Now `refreshKnownAffixes` returns immediately after seeding the chunked-
-- scan state; the actual `knownAffixDescriptions` map is reassigned by
-- the `_affixScanFrame` OnUpdate one or more frames later (typically the
-- next frame on a warm cache; up to ceil(spellbook_size / SPELLS_PER_CHUNK)
-- frames on a cold cache). During the in-flight window
-- `knownAffixDescriptions` still holds the PREVIOUS map - that's the
-- right behaviour (stale data beats no data for the dupe gate) but is
-- worth noting if a future caller expects "after this returns, the map
-- reflects the current spellbook." If a SECOND refresh is requested
-- while one is in flight, the partial map is discarded and the scan
-- restarts from idx=1; the per-spellID cache makes the restart cheap.
function EC_compCache.refreshKnownAffixes()
    -- Build a flat list of spellIDs currently in the spellbook.
    local spells = {}
    if GetNumSpellTabs and GetSpellTabInfo and GetSpellLink then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, numSpells = GetSpellTabInfo(tab)
            if offset and numSpells then
                for i = offset + 1, offset + numSpells do
                    local link = GetSpellLink(i, BOOKTYPE_SPELL)
                    local spellId = link and tonumber(link:match("spell:(%d+)"))
                    if spellId then
                        spells[#spells + 1] = spellId
                    end
                end
            end
        end
    end
    -- Start (or restart) the chunked scan. Any in-flight scan is
    -- abandoned - its partial map is discarded and we start fresh.
    EC_compCache._affixScanState = {
        spells = spells,
        map = {},
        idx = 1,
    }
    EC_compCache._affixScanFrame:Show()
end

-- v2.26.0: cheap dirty-check rebuild. Counts learned-true records in
-- _G.ExtractionService.learnedAffixes and skips the rebuild if the
-- count hasn't changed since the last call. Wired into the 120 ms
-- BAG_UPDATE debounce frame and PLAYER_REGEN_ENABLED so the player's
-- post-extraction state (new proc learned at the Enchanted Anvil)
-- propagates without a manual /ec refresh.
--
-- v2.32.x: when learnedCount has GROWN since the last check, the
-- function now does a SYNCHRONOUS INCREMENTAL MERGE into the live
-- knownAffixDescriptions map (driven by the procIdToDescription cache
-- so repeat calls are O(1) per affix). This replaces the prior path
-- that always kicked off the async refreshKnownAffixes rebuild on
-- every dirty-check; with the async path, a player who learned an
-- affix at the Anvil and immediately hovered a new drop of that
-- affix saw a stale "Protected - Affix found" verdict until the
-- ~600-800 ms (BAG_UPDATE debounce + spell-event debounce + chunked
-- scan) settled. The incremental sync path makes the first hover
-- after the learn correct. Two fallback cases still defer to the
-- async rebuild: knownAffixDescriptions not yet bootstrapped (pre-
-- PLAYER_LOGIN) and learnedCount going DOWN (un-learn or reset, so
-- the now-stale entries need to be dropped via a full rebuild).
function EC_compCache.refreshExtractionIfDirty()
    local svc = _G.ExtractionService
    if not svc or type(svc.learnedAffixes) ~= "table" then
        return false
    end
    local learnedCount = 0
    for _, r in ipairs(svc.learnedAffixes) do
        if r and r.learned then
            learnedCount = learnedCount + 1
        end
    end
    if learnedCount == EC_compCache.knownExtractionVersion then
        return false
    end

    -- Fallback to the async rebuild when the map isn't bootstrapped
    -- yet (pre-PLAYER_LOGIN) or when learnedCount went down (un-
    -- learn / reset). The incremental path below only adds entries;
    -- a count decrease needs a from-scratch rebuild to drop the
    -- now-stale ones.
    local map = EC_compCache.knownAffixDescriptions
    if type(map) ~= "table" or learnedCount < EC_compCache.knownExtractionVersion then
        EC_compCache.knownExtractionVersion = learnedCount
        if EC_compCache.refreshKnownAffixes then
            EC_compCache.refreshKnownAffixes()
        end
        return true
    end

    -- Synchronous incremental merge. For each currently-learned
    -- entry, take the cached description if available; otherwise
    -- scan the engraving-spell tooltip once (and cache the result).
    -- Same scan body as the OnUpdate path above so the two stay
    -- equivalent in what they extract.
    local tip = NS.scanTooltip
    if tip and tip.ClearLines and tip.SetHyperlink and tip.NumLines then
        for _, r in ipairs(svc.learnedAffixes) do
            if r and r.learned and r.id then
                local desc = EC_compCache.procIdToDescription[r.id]
                if desc == nil then
                    desc = false
                    tip:ClearLines()
                    tip:SetHyperlink("spell:" .. r.id)
                    for j = 1, tip:NumLines() do
                        local fs = _G["EbonClearanceScanTooltipTextLeft" .. j]
                        if fs and fs.GetText then
                            local txt = fs:GetText()
                            if txt and txt:find(EC_compCache.AFFIX_SPELL_PREFIX, 1, true) then
                                local d = txt:match(":%s*(.+)$")
                                d = EC_compCache.normaliseAffixDesc(d)
                                if d and d ~= "" then
                                    desc = d
                                end
                                break
                            end
                        end
                    end
                    EC_compCache.procIdToDescription[r.id] = desc
                end
                if desc then
                    map[desc] = true
                end
            end
        end
    end
    EC_compCache.knownExtractionVersion = learnedCount
    return true
end

function EC_compCache.playerHasAffixDescription(desc)
    if type(desc) ~= "string" then
        return false
    end
    local norm = EC_compCache.normaliseAffixDesc(desc)
    if norm and norm ~= "" and EC_compCache.knownAffixDescriptions[norm] then
        return true
    end
    -- First-sentence fallback for stat affixes whose bag tooltip
    -- carries a "Stacks with other ranks." disclaimer not present on
    -- the engraving-spell side. Matches the same trim the live-tooltip
    -- scanner already uses.
    local first = desc:match("^(.-)%.%s")
    if first and first ~= "" then
        local firstNorm = EC_compCache.normaliseAffixDesc(first)
        if firstNorm and firstNorm ~= "" and EC_compCache.knownAffixDescriptions[firstNorm] then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- v2.20.0: PE Chance-on-hit detection
-- ---------------------------------------------------------------------------
-- Project Ebonhold lets players EXTRACT proc spells from weapons (the
-- green `Chance on hit:` tooltip line) and apply them to other items.
-- So an item with a Chance-on-hit proc is meaningfully different from
-- the base itemID even when the user has the base itemID on their
-- Sell List or Delete List. EC_compCache.itemHasChanceOnHit /
-- liveTooltipHasChanceOnHit are the detection helpers; gated by
-- DB.protectChanceOnHitItems in EC_IsSellable and BuildQueue's
-- delete fallback.
--
-- Caching: chance-on-hit is a STABLE per-itemID property (unlike
-- random-affix instances), so a per-itemID boolean cache is correct
-- and efficient. EC_compCache.chanceOnHitCache holds the result; it
-- resets naturally on /reload because EC_compCache itself isn't
-- persisted across sessions.
-- v2.26.0: two-phrasing match. PE items carry chance-on-hit procs in
-- two flavours: the classic `Chance on hit: ...` (Bloodpike-style)
-- and the older PPM-style `Equip: Chance to <verb>... ...`
-- (Quillshooter-style). Both should land under the same protection,
-- so the detector scans for either pattern.
-- Hung on EC_compCache (not a file-scope local) to stay under Lua
-- 5.1's 200-locals cap.
function EC_compCache.lineLooksLikeChanceProc(txt)
    if type(txt) ~= "string" then
        return false
    end
    local needle = ITEM_SPELL_TRIGGER_ONPROC or "Chance on hit:"
    if txt:find(needle, 1, true) then
        return true
    end
    -- Lua pattern: "Equip: Chance to <word>" - leading literal anchor
    -- + a verb word covers "strike", "deal", "wound", etc.
    if txt:find("^Equip:%s*Chance to%s+%a") then
        return true
    end
    return false
end

function EC_compCache.itemHasChanceOnHit(bag, slot, itemID)
    if not itemID then
        return false
    end
    if EC_compCache.chanceOnHitCache[itemID] ~= nil then
        return EC_compCache.chanceOnHitCache[itemID]
    end
    if not bag or not slot then
        return false
    end
    scanTip():ClearLines()
    scanTip():SetBagItem(bag, slot)
    local result = false
    for i = 1, 30 do
        local line = _G["EbonClearanceScanTooltipTextLeft" .. i]
        if not line then
            break
        end
        if EC_compCache.lineLooksLikeChanceProc(line:GetText()) then
            result = true
            break
        end
    end
    EC_compCache.chanceOnHitCache[itemID] = result
    return result
end

function EC_compCache.liveTooltipHasChanceOnHit(tooltip, itemID)
    if itemID and EC_compCache.chanceOnHitCache[itemID] ~= nil then
        return EC_compCache.chanceOnHitCache[itemID]
    end
    if not tooltip or not tooltip.NumLines or not tooltip.GetName then
        return false
    end
    local tname = tooltip:GetName()
    if not tname then
        return false
    end
    local n = tooltip:NumLines() or 0
    local result = false
    -- Start at line 2: line 1 is the item name; chance-on-hit lines
    -- never appear as the title.
    for i = 2, n do
        local fs = _G[tname .. "TextLeft" .. i]
        if fs and fs.GetText then
            if EC_compCache.lineLooksLikeChanceProc(fs:GetText()) then
                result = true
                break
            end
        end
    end
    if itemID then
        EC_compCache.chanceOnHitCache[itemID] = result
    end
    return result
end

-- Tome detection. A "tome" here means a spell-teaching item: profession
-- recipes (Recipe class via GetItemInfo) and class spell books / talent
-- tomes / mount-training scrolls (detected via a `Use: Teaches you...`
-- tooltip line). Two helpers because the two signals decay at different
-- rates:
--   * itemIsTome    - stable per itemID. Recipe class is a hard
--                     fast-path; tooltip-scan covers everything else.
--   * playerKnowsTomeSpell - flips when the player learns the spell.
--                     Scans the live tooltip for the locale-aware
--                     ITEM_SPELL_KNOWN string ("Already known").
function EC_compCache.itemIsTome(bag, slot, itemID)
    if not itemID then
        return false
    end
    if EC_compCache.tomeCache[itemID] ~= nil then
        return EC_compCache.tomeCache[itemID]
    end
    -- Fast path: GetItemInfo class "Recipe" covers every profession
    -- recipe (cookbook, schematic, manual, design, formula, etc.) and
    -- is set on the itemID alone, so it works even without a bag/slot.
    local _, _, _, _, _, itype, isubtype = GetItemInfo(itemID)
    if itype == "Recipe" then
        EC_compCache.tomeCache[itemID] = true
        return true
    end
    -- v2.32.x: exclude vanity pets and mount-training scrolls from
    -- tome detection. The text-scan path below matches "Use: Teaches"
    -- which is too broad - it catches "Use: Teaches you how to summon
    -- this companion" on pet items and "Use: Teaches you how to ride"
    -- on mount scrolls. These are collectibles rather than spell
    -- tomes worth vendoring after learning, so they fall back to the
    -- normal rule chain (typical: bound + low vendor price = nothing
    -- to sell anyway). Users who want protection for specific
    -- collectibles can add the itemID to the Keep List manually.
    if itype == "Miscellaneous"
        and (isubtype == "Companion" or isubtype == "Mount")
    then
        EC_compCache.tomeCache[itemID] = false
        return false
    end
    -- Slow path: tooltip-scan for `Use: Teaches...`. Covers class
    -- spell books (e.g. Death Knight talent tomes) and other PE
    -- custom tome formats whose class isn't "Recipe". Needs bag/slot
    -- for SetBagItem.
    if not bag or not slot then
        EC_compCache.tomeCache[itemID] = false
        return false
    end
    scanTip():ClearLines()
    scanTip():SetBagItem(bag, slot)
    local result = false
    local usePrefix = ITEM_SPELL_TRIGGER_ONUSE or "Use:"
    for i = 1, 30 do
        local line = _G["EbonClearanceScanTooltipTextLeft" .. i]
        if not line then
            break
        end
        local txt = line:GetText()
        if type(txt) == "string"
            and txt:find(usePrefix, 1, true) == 1
            and txt:find("[Tt]eaches", 1, false)
        then
            -- v2.32.x: belt-and-braces vanity-collectible reject.
            -- The GetItemInfo class/subclass check above catches
            -- the obvious case (class=Miscellaneous + subclass=
            -- Companion/Mount), but in 3.3.5a many vanity pets are
            -- actually filed under subclass="Junk" (the
            -- "Companion Pets" subtype is a later WoW addition).
            -- The tooltip text itself is the most reliable signal:
            -- pets use "summon this companion", mount-summon items
            -- use "summon this mount", and riding-training scrolls
            -- use "how to ride". Spell tomes / profession recipes
            -- don't carry any of these phrases. Hard-coded enUS
            -- because the addon targets a single locale (enUS PE).
            local low = txt:lower()
            if low:find("this companion", 1, true)
                or low:find("this mount", 1, true)
                or low:find("how to ride", 1, true)
            then
                break
            end
            result = true
            break
        end
    end
    EC_compCache.tomeCache[itemID] = result
    return result
end

function EC_compCache.playerKnowsTomeSpell(bag, slot, itemID)
    if not itemID then
        return false
    end
    if EC_compCache.tomeIsKnownCache[itemID] ~= nil then
        return EC_compCache.tomeIsKnownCache[itemID]
    end
    if not bag or not slot then
        return false
    end
    scanTip():ClearLines()
    scanTip():SetBagItem(bag, slot)
    local result = false
    local knownStr = ITEM_SPELL_KNOWN or "Already known"
    for i = 1, 30 do
        local line = _G["EbonClearanceScanTooltipTextLeft" .. i]
        if not line then
            break
        end
        local txt = line:GetText()
        if type(txt) == "string" and txt:find(knownStr, 1, true) then
            result = true
            break
        end
    end
    EC_compCache.tomeIsKnownCache[itemID] = result
    return result
end

-- Profession subtypes used by GetItemInfo for class="Recipe" items.
-- Items whose subtype is in this set are profession crafting recipes
-- (Plans / Schematic / Pattern / Formula / Recipe / Design / Manual);
-- items with class="Recipe" but a subtype NOT in this set are spell-
-- teaching tomes / books / scrolls (Tome of Echo, class spell books,
-- mount training scrolls, etc.). Used by EC_compCache.tomeKind to
-- pick the right label for the tooltip annotation. enUS strings;
-- the addon targets a single locale (enUS PE).
local EC_TOME_PROFESSION_SUBTYPES = {
    Alchemy = true,
    Blacksmithing = true,
    Cooking = true,
    Enchanting = true,
    Engineering = true,
    ["First Aid"] = true,
    Fishing = true,
    Inscription = true,
    Jewelcrafting = true,
    Leatherworking = true,
    Mining = true,
    Tailoring = true,
}

-- Pick the right label for a protected tome / recipe. Returns
-- "Recipe" for profession crafting items, "Tome" for everything else
-- (class tomes, mount scrolls, PE Tome of Echo, etc.). GetItemInfo's
-- class string is "Recipe" for both groups, so we have to consult
-- the subtype to tell them apart.
function EC_compCache.tomeKind(itemID)
    if not itemID then
        return "Tome"
    end
    local _, _, _, _, _, _, isubtype = GetItemInfo(itemID)
    if isubtype and EC_TOME_PROFESSION_SUBTYPES[isubtype] then
        return "Recipe"
    end
    return "Tome"
end

-- Live-tooltip variants of the tome helpers. Used by the tooltip
-- annotation system (EbonClearance_Tooltip.lua) which has the live
-- tooltip frame but not a bag/slot pair. Mirror
-- liveTooltipHasChanceOnHit's structure: cache hit fast-path; else
-- scan the visible tooltip lines and write the result back into the
-- same per-itemID caches shared with the bag-item path.
function EC_compCache.liveTooltipIsTome(tooltip, itemID)
    if itemID and EC_compCache.tomeCache[itemID] ~= nil then
        return EC_compCache.tomeCache[itemID]
    end
    if itemID then
        local _, _, _, _, _, itype, isubtype = GetItemInfo(itemID)
        if itype == "Recipe" then
            EC_compCache.tomeCache[itemID] = true
            return true
        end
        -- v2.32.x: exclude vanity pets and mount-training scrolls.
        -- Same rationale as itemIsTome above - the text-scan path
        -- below over-matches "Use: Teaches" lines on collectible
        -- items that aren't tome-protection targets. See itemIsTome
        -- for the full reasoning.
        if itype == "Miscellaneous"
            and (isubtype == "Companion" or isubtype == "Mount")
        then
            EC_compCache.tomeCache[itemID] = false
            return false
        end
    end
    if not tooltip or not tooltip.NumLines or not tooltip.GetName then
        return false
    end
    local tname = tooltip:GetName()
    if not tname then
        return false
    end
    local n = tooltip:NumLines() or 0
    local usePrefix = ITEM_SPELL_TRIGGER_ONUSE or "Use:"
    local result = false
    for i = 2, n do
        local fs = _G[tname .. "TextLeft" .. i]
        if fs and fs.GetText then
            local txt = fs:GetText()
            if type(txt) == "string"
                and txt:find(usePrefix, 1, true) == 1
                and txt:find("[Tt]eaches", 1, false)
            then
                -- v2.32.x: belt-and-braces vanity-collectible
                -- reject. Same phrasing-based filter as itemIsTome -
                -- catches the case where GetItemInfo reports an
                -- unexpected subclass (e.g. 3.3.5a pets often file
                -- under "Junk" rather than "Companion"). Hard-coded
                -- enUS; the addon targets a single locale.
                local low = txt:lower()
                if low:find("this companion", 1, true)
                    or low:find("this mount", 1, true)
                    or low:find("how to ride", 1, true)
                then
                    break
                end
                result = true
                break
            end
        end
    end
    if itemID then
        EC_compCache.tomeCache[itemID] = result
    end
    return result
end

function EC_compCache.liveTooltipPlayerKnowsTome(tooltip, itemID)
    -- v2.32.x: live tooltip is the authoritative source; the cache is
    -- a side-effect output (still consulted by playerKnowsTomeSpell
    -- which has no live tooltip), not a read-path fast-path. The
    -- cache-first fast-path was buggy: PE's roguelite "Tome of Echo"
    -- mechanic doesn't teach a Blizzard spell on use, so
    -- LEARNED_SPELL_IN_TAB / SPELLS_CHANGED don't fire, the cache
    -- never gets wiped, and a cached `false` from a hover BEFORE the
    -- tome was used stuck around forever - tooltip showed Blizzard's
    -- own "Already known" line but EC kept labelling the item as
    -- "Protected - Tome (unlearned)". Scanning the live tooltip on
    -- every hover is cheap (~30 line iterations) and self-healing:
    -- whatever state PE's tooltip code wrote IS what the user sees,
    -- so we read the same source.
    local tname = tooltip and tooltip.NumLines and tooltip.GetName and tooltip:GetName()
    if not tname then
        -- No tooltip to scan - fall back to the cache (if any) so the
        -- bag-scan variant's prior write stays useful.
        if itemID and EC_compCache.tomeIsKnownCache[itemID] ~= nil then
            return EC_compCache.tomeIsKnownCache[itemID]
        end
        return false
    end
    local n = tooltip:NumLines() or 0
    local knownStr = ITEM_SPELL_KNOWN or "Already known"
    local result = false
    for i = 2, n do
        local fs = _G[tname .. "TextLeft" .. i]
        if fs and fs.GetText then
            local txt = fs:GetText()
            if type(txt) == "string" and txt:find(knownStr, 1, true) then
                result = true
                break
            end
        end
    end
    if itemID then
        EC_compCache.tomeIsKnownCache[itemID] = result
    end
    return result
end

-- v2.26.0: bag-item -> ExtractionService record lookup. PE's own
-- Enchanted Anvil uses `FindItemAffix(link)` (in
-- ProjectEbonhold/modules/extraction/extraction.lua) to decide whether
-- to display "You already know this affix"; we re-implement that same
-- algorithm here so the dupe gate matches the Anvil's verdict exactly.
--
-- The bridge does NOT use description-text matching - the engraving
-- spell's tooltip describes the TRIGGER ("Your physical abilities have
-- a chance to..."), while the bag item's `Chance on hit:` line carries
-- the EFFECT spell's description ("Wounds the target..."). Different
-- sentences. Instead, PE encodes the affix NAME (e.g. "Hemorrhage")
-- inside the item's random-suffix DBC entry; `SetHyperlink(link)`
-- resolves that suffix and renders an extra tooltip line we can scan
-- for the name. SetBagItem doesn't always render that line, hence
-- the SetHyperlink-on-the-link approach.
--
-- Cached per itemLink (NOT per itemID) because the affix is per-
-- instance: two Bloodpikes with different random suffix rolls map to
-- different proc records.
EC_compCache.itemAffixLookupCache = {}

function EC_compCache.findLearnedAffixForItem(link)
    if not link then
        return nil
    end
    -- HasRandomProperty is the same gate PE uses. Items without a
    -- random-suffix DBC entry can't carry an extractable affix.
    if not HasRandomProperty or not HasRandomProperty(link) then
        return nil
    end
    local cached = EC_compCache.itemAffixLookupCache[link]
    if cached ~= nil then
        return cached or nil -- `false` cached "scanned, no match"
    end
    local svc = _G.ExtractionService
    if not svc or type(svc.learnedAffixes) ~= "table" then
        return nil
    end
    local affixes = svc.learnedAffixes
    if #affixes == 0 then
        return nil
    end
    -- Build lowercase name -> record lookup. Cheap; ~140 records.
    local nameToAffix = {}
    for _, affix in ipairs(affixes) do
        if affix and affix.name then
            nameToAffix[affix.name:lower()] = affix
        end
    end
    scanTip():ClearLines()
    scanTip():SetHyperlink(link)
    local found = nil
    for j = 1, scanTip():NumLines() do
        local fs = _G["EbonClearanceScanTooltipTextLeft" .. j]
        if fs and fs.GetText then
            local text = fs:GetText()
            if text then
                local lower = text:lower()
                for name, affix in pairs(nameToAffix) do
                    local startPos, endPos = lower:find(name, 1, true)
                    if startPos then
                        -- Word-boundary check mirrors PE: the affix
                        -- name must be a standalone token, not a
                        -- substring inside a longer word. Without this
                        -- "ire" would match every word containing it.
                        local before = startPos > 1 and lower:sub(startPos - 1, startPos - 1) or ""
                        local after = lower:sub(endPos + 1, endPos + 1)
                        if (before == "" or not before:match("%w")) and (after == "" or not after:match("%w")) then
                            found = affix
                            break
                        end
                    end
                end
            end
        end
        if found then
            break
        end
    end
    EC_compCache.itemAffixLookupCache[link] = found or false
    return found
end
