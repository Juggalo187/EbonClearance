# Spec: Empty-state wording pass (add missing list states + reword existing)

**Date**: 2026-06-05
**Status**: Approved (brainstorming complete; awaiting implementation plan)
**Target release**: patch (e.g. v2.41.3) - player-facing wording + one small widget, additive, no schema change
**Touched files**: `EbonClearance_ListWidget.lua` (new empty-state FontString), `EbonClearance_MainPanel.lua` (Stats empty strings, set in `RefreshStats`), `EbonClearance_ProcessBagsPanel.lua` (next-item label); docs sync in `CHANGELOG.md` (+ a Help-panel check)

## Goal

Every empty/placeholder state in the UI should tell a new player what they're looking at and - where they can act - what to do next. Today the editable lists and the no-search-match case show **nothing at all** (a blank box), and a few existing empty strings are terse or use jargon. This pass adds the missing states and rewords the existing ones to one consistent, new-player-friendly tone.

## Decisions locked (via brainstorming)

- **Scope:** add the missing list empty states (empty list + no-search/filter-match) AND reword the existing terse ones (Stats, Process Bags). The Guild panel's strings are already good and stay.
- **Approach:** inline per-surface (Approach B). The empty states live in heterogeneous structures (list scroll frame / Stats multi-line FontString / Process Bags label), so no shared empty-state widget - that would be over-abstraction. Each surface keeps its structure; only the tone is unified.
- **Tone:** grey text; lead with the state in plain words; add a short "what to do" ONLY where the user can act (the lists). Read-only surfaces (Stats) just say "Nothing yet" - no false call-to-action, since the data accrues on its own. Plain language per the project's player-facing-text rule (no jargon like "eligible").

## Part A - list widget empty state (the genuinely missing piece)

`EbonClearance_ListWidget.lua`, in `CreateListUI`:

- Create one greyed FontString once (parented to the scroll `content`, anchored top-left a few px in), hidden by default. Store on the widget (e.g. `content.emptyFS` or a `CreateListUI` upvalue).
- In `Refresh`, after the row loop, when `shown == 0` show it; otherwise hide it. Text depends on why it's empty (the loop already has the data):
  - `#keys == 0` (no items on the list at all): **"This list is empty. Add an item by ID or name above, or Alt+Right-Click an item in your bags."**
  - `#keys > 0` but `shown == 0` (search text and/or the rarity filter hid everything): **"No items match your search."**
- Hidden the instant any row renders. Applies to all four editable lists (Sell / Account Sell / Keep / Delete) and the Keep/Protected list, since they all build through `CreateListUI`.
- Reactive width: the FontString is left-anchored and wraps; register it with the layout system (`EC_compCache.registerWidth` / `setPanelWidth`) the same way other wrapped labels do, so it reflows on panel resize and doesn't trip `test_layout_reactivity`.

## Part B - reword existing terse empty states

| Where | File | Now | Proposed |
|---|---|---|---|
| Stats Top-5 Most Sold (empty) | `EbonClearance_MainPanel.lua` (`RefreshStats`) | `None yet` | `Nothing sold yet.` |
| Stats Top-5 Most Deleted (empty) | `EbonClearance_MainPanel.lua` | `None yet` | `Nothing deleted yet.` |
| Stats zones (empty) | `EbonClearance_MainPanel.lua` | `None yet` | `No zones tracked yet.` |
| Process Bags next-item (nothing to do) | `EbonClearance_ProcessBagsPanel.lua` | `Nothing eligible.` | `Nothing to process right now.` |

Guild panel (`None shared yet.` / `No items shared yet.`) and the Clear-All-on-empty chat line (`<List> is already empty.`) are already clear and stay unchanged. Verify each `None yet` occurrence in `RefreshStats` maps to the right replacement (Most Sold vs Most Deleted vs zones share the literal today).

## Testing

1. `luac -p` on each touched file.
2. All five suites stay green (`test_layout_reactivity`, `test_perf_guardrails`, `test_comment_hygiene`, `test_comms_version`, `test_guildshare`). No test pins the changed strings (confirmed by grep). The new FontString must use the reactive-width registration so `test_layout_reactivity` stays green.
3. Repo grep for U+2014 returns zero on changed files.
4. In-game smoke: open an empty Keep List -> see the "add an item" guidance; type a search that matches nothing -> see "No items match your search"; add an item -> guidance disappears; a fresh character's Stats shows "Nothing sold yet." etc.; open Process Bags with nothing eligible -> "Nothing to process right now."

## Docs sync

- **CHANGELOG.md** - patch stanza.
- **Help/FAQ** - check whether any FAQ entry describes the lists in a way the new empty-state guidance should match; no new entry expected.
- README / ADDON_GUIDE / CLAUDE.md - no change (no feature, schema, slash command, file-count, or test-invariant change).

## Out of scope

- The colorblind-friendly borders and help-icon-coverage sub-themes (deferred from this pass).
- Any new empty-state widget abstraction / shared helper.
- Changing the Guild panel's already-good empty strings.
