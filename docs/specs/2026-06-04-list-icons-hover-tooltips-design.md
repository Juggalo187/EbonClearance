# Spec: Item icons + hover tooltips on the four editable lists

**Date**: 2026-06-04
**Status**: Approved (brainstorming complete; awaiting implementation plan)
**Target release**: v2.41.0 (next minor - new user-facing UX feature, fully additive, no schema change)
**Touched files**: `EbonClearance_ListWidget.lua` (the only code file); docs sync in `CHANGELOG.md`, `README.md`, `docs/ADDON_GUIDE.md`, and (only if an existing entry reads wrong) `EbonClearance_HelpPanel.lua`

## Goal

Make the four editable item lists more interactive:

1. **Hover tooltip** - mousing over a list row brings up that item's full tooltip, anchored at the cursor.
2. **Icon instead of the ID number** - the green item ID currently shown at the start of each row is replaced by the item's icon.
3. **Quality-colored name** - the item name is colored to match its quality (white / green / blue / purple / etc.), so lists are easy to scan at a glance.

Scope is the four editable lists built by `CreateListUI`: **Sell List, Account Sell List, Keep List, Delete List**. The Process Bags queue, the personal Stats Top-5, and the Guild most-sold rows are explicitly out of scope (the Guild panel already has hover tooltips; the Stats Top-5 is a single multi-line text block, not real rows).

## Decisions locked (via brainstorming)

- **Scope:** the four editable `CreateListUI` lists only.
- **ID handling:** the green item ID is *fully replaced* by the icon. The raw ID is no longer rendered on the row. It remains reachable two ways that already exist: the list's Search box still matches on the ID string, and the hover tooltip shows the full item.
- **Implementation:** Approach A - extend the existing pooled row factory in place; reuse the `GetItemInfo` call that already runs per row; copy the Guild panel's hover pattern verbatim. No new helper abstraction (YAGNI), no Blizzard `ItemButton` rewrite.

## Architecture

All changes live in `EbonClearance_ListWidget.lua`, in two spots.

### 1. Row factory (`EC_compCache.makeListRowFactory` -> `getRow`)

Each pooled row gains one Texture plus hover wiring, created once at mint time and reused by the pool:

- `row.icon = row:CreateTexture(nil, "ARTWORK")`, size **18x18**, anchored `LEFT, row, LEFT, 2, 0`, with `SetTexCoord(0.07, 0.93, 0.07, 0.93)` to crop the stock icon border for a clean square.
- The existing `text` FontString re-anchors its LEFT from `row, LEFT, +2` to `row.icon, RIGHT, +4`. Its RIGHT -> `rm.LEFT` anchor is unchanged, so it still stretches with the (resizable) content frame.
- Hover wired once at mint, copying the Guild panel pattern (`EbonClearance_GuildPanel.lua`):
  - `row:EnableMouse(true)`
  - `OnEnter`: if `self.itemID` then `GameTooltip:SetOwner(self, "ANCHOR_CURSOR")`, `GameTooltip:SetHyperlink("item:" .. self.itemID)`, `GameTooltip:Show()`.
  - `OnLeave`: `GameTooltip:Hide()`.

### 2. Refresh loop (the per-row body, around the current line 481)

- Capture the icon texture **and quality** from the **existing** call (no new API call): `local name, _, quality, _, _, _, _, _, _, itemTexture = GetItemInfo(id)`.
- `row.icon:SetTexture(itemTexture or "Interface\\Icons\\INV_Misc_QuestionMark")` - question-mark fallback for not-yet-cached items.
- `row.itemID = id` so the already-wired `OnEnter` resolves the right tooltip.
- Quality-color the name only: `local qc = quality and ITEM_QUALITY_COLORS[quality]` then `local coloredName = qc and (qc.hex .. name .. "|r") or name`.
- Row text drops the green ID prefix and uses the colored name: `string.format("%s%s%s", coloredName, affixTag, procTag)` (was `"|cffb6ffb6%d|r  %s%s%s"`). The grey `(affix-gated)` and `(Hit-proc)` tags are unchanged (only the name portion is colored, so they still read as secondary).

## Edge cases (already handled by existing code)

- **Uncached item:** `name` is nil -> the existing tooltip-prime + `pendingRetry` path requeues a Refresh in 1.5 s. Until then the row shows the question-mark icon and the existing `ItemID: <n>` placeholder name (quality nil, so the placeholder stays uncolored). On retry icon, name, and color all fill in. No new logic.
- **Search / sort:** unchanged. Search still matches the ID string (the ID is simply not rendered anymore); the name-sort precompute is untouched.
- **Remove button / Clear All / reactive width:** untouched. The icon is fixed-size, so it introduces no `EC_PANEL_WIDTH` snapshot and no `test_layout_reactivity` concern. Reusing the existing `GetItemInfo` introduces no `test_perf_guardrails` concern.

## Testing

1. `luac -p EbonClearance_ListWidget.lua` (local syntax check).
2. All five invariant suites stay green: `test_layout_reactivity`, `test_perf_guardrails`, `test_comment_hygiene`, `test_comms_version`, `test_guildshare`. Before editing, grep the test files for any assertion pinned to the old `|cffb6ffb6` row-text format and update it in lockstep if one exists.
3. Repo grep for U+2014 returns zero.
4. In-game smoke on Ebonhold, for each of the four lists (Sell / Account Sell / Keep / Delete):
   - icons render for cached items;
   - an uncached item shows the question-mark icon, then fills in on the 1.5 s retry;
   - hovering a row shows the item tooltip at the cursor; moving off hides it;
   - Remove, Clear All, Search, and both sort buttons still work.

## Docs sync (project rule)

Player-facing visual change to existing lists; no new toggle, command, or schema:

- **CHANGELOG.md** - `### v2.41.0` stanza.
- **README.md** - one feature bullet: list rows now show item icons, quality-colored names, and a hover tooltip.
- **docs/ADDON_GUIDE.md** - one line under the list-widget description noting rows carry an icon, a quality-colored name, and a cursor-anchored hover tooltip.
- **EbonClearance_HelpPanel.lua** - touch only if an existing list-related FAQ entry would now read wrong; no new entry needed (no new control). Check during implementation.
- **CLAUDE.md** - no change (file count and test-invariant list both unchanged).
- **NOTICE.md** - no change.

## Version

`v2.41.0` - minor bump (new user-facing UX feature, fully additive, downgrade-safe).

## As shipped (v2.41.0, scope expanded during build at user request)

Two additions agreed after the core landed and verified:

1. **Process Bags rows get the icon + cursor tooltip too.** The Process Bags queue (`EbonClearance_ProcessBagsPanel.lua`) already showed a quality-colored item link and a hover tooltip (anchored right). Added an 18px item icon at the left of each row (sourced from the live bag slot via `GetContainerItemInfo`, always cached) and switched its tooltip anchor to `ANCHOR_CURSOR` to match the editable lists.

2. **Grouped, clearer list-header controls** (the "confusing for new users" cluster), in `CreateListUI`:
   - The redundant in-box title is dropped (each panel already has a heading + description + how-to-add hint above the box). `buildListHeaderRow` no longer takes `titleText`.
   - Controls regroup into an **Add to list** group and a **Find in list** group (Sort button + Clear All on the header line, Search input + rarity filter below), separated by a thin divider. Clear All moved from the header row into the Find group (returned from `buildListSearchAndSortRow` now).
   - **The two add inputs are merged into one** (later user request): a single "Add item:" field takes an item ID or a name. `buildListMatchRow` was removed; its bag-name-scan folded into CreateListUI's `DoAdd`, which routes a numeric entry to an ID add and resolves text via an exact cached-name `GetItemInfo` hit plus a bag substring scan. 3.3.5a has no full item-database name search, so an uncached name can't be resolved; the empty-result message says so and notes an ID always works. The `tests/test_perf_guardrails.lua` factory-list invariant dropped `buildListMatchRow` in lockstep.
   - The broken sort-direction arrows (triangle glyphs U+25B2 / U+25BC, absent from the 3.3.5 client font, rendered as `?`) are replaced by inline button-arrow textures (`SORT_ASC` / `SORT_DESC` file-scope constants).
   - **The "ID" sort button is removed and replaced by a "Show:" rarity filter** (a `UIDropDownMenuTemplate` matching the Merchant DE-cap dropdown style; options from the `EC_RARITY_FILTERS` file-scope table, quality-colored via `NS.ColorTextByQuality`). Sorting by an ID the row no longer displays was dead weight; filtering by rarity pairs with the quality-colored names. The filter (`rarityFilter` upvalue, nil = All) stacks with the search filter in `Refresh`; uncached items (unknown quality) stay hidden under a specific rarity until they cache. The default sort is now `name_asc` (alphabetical); the Name button still toggles asc/desc and the now-unreachable id-sort comparator branches were removed.
   - Every control gains a plain-language hover tip via the new `EC_AddControlTip` helper (`HookScript` so it never clobbers the ID input's focus-tracking handlers).
   - The scroll area top offset moves from -102 to -132 to clear the taller grouped header.

The manual add controls were reviewed for removal (Alt+Right-Click + rules cover most adds now) and deliberately kept: "By ID" is the only path to pre-stage an item you do not currently hold, and shift-click-to-add is an expected convention.

## Out of scope

- Personal Stats Top-5 and Guild most-sold rows (the Guild rows already have hover tooltips).
- Click / shift-click-to-link behaviour on rows (hover tooltip only).
- Keeping the raw ID visible on the editable-list row in any form.
- Removing any manual add control (reviewed, kept).
