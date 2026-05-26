# Spec: Help / FAQ Interface Options panel

**Date**: 2026-05-26
**Status**: Approved (brainstorming complete; awaiting implementation plan or direct implementation)
**Target release**: v2.36.0 (new feature; minor bump)
**Touched files**: new `EbonClearance_HelpPanel.lua`, `.toc`, `EbonClearance.toc`, `EbonClearance_Events.lua` (slash-command output), `tests/test_perf_guardrails.lua`, `.github/workflows/release.yml` (zip packaging glob), `tests/test_layout_reactivity.lua` (SOURCE_PATHS), `tests/test_no_addon_references.lua` (if it has its own path list), `README.md` (one-line mention).

## Goal

Add a curated **troubleshooting FAQ** as a new Interface Options panel under EbonClearance. Each entry is a short question + plain-English answer + optional one-click jump to the relevant settings panel. Closes the discoverability gap for users who hit common confusions (auto-Keep tagging surprise, "why isn't this selling?", lists not shared across characters, etc.) without forcing them to read `docs/ADDON_GUIDE.md` or open `/ec bugreport`.

## Surface

- New `CreateFrame("Frame", "EbonClearanceOptionsHelp", InterfaceOptionsFramePanelContainer)` panel.
- `panel.name = "Help"`, `panel.parent = "EbonClearance"`.
- Registered **last** in the Interface Options sidebar via `InterfaceOptions_AddCategory` at the end of the .toc load order (so the sidebar reads: Main -> Merchant -> Protection -> Scavenger -> Item Highlighting -> Sell List -> Account Sell List -> Keep List -> Delete List -> Process Bags -> Profiles -> Import/Export -> **Help**).
- Scroll-wrapped via `NS.EC_WrapPanelInScrollFrame` (consistent with the other text-heavy panels like Main and Scavenger).
- `OnShow` wrapped in `EC_compCache.initPanel(self, refresh, build, wrapScroll=true)` for the standard idempotency pattern.

## Content data structure

All entries live in a file-scope `local EC_HELP_ENTRIES = { ... }` table at the top of `EbonClearance_HelpPanel.lua`:

```lua
local EC_HELP_ENTRIES = {
    { q = "...",
      a = "...",
      panel = "EbonClearanceOptionsProtection",  -- optional; nil means no jump button
    },
    -- ... more entries ...
}
```

Fields:

- **`q`** (string, required) - the question. Rendered as a bold yellow heading via `|cffffff00` colour escape and `GameFontNormal`.
- **`a`** (string, required) - the answer. Multi-line allowed (the FontString is `SetWordWrap(true)` and width-tracked via `EC_compCache.setPanelWidth`). Rendered via `GameFontHighlight`.
- **`panel`** (string, optional) - the target Interface Options panel's frame name (e.g., `"EbonClearanceOptionsProtection"`). When present, a `[ Open <Panel Display Name> -> ]` button is rendered at the bottom-right of the entry. When nil, no button.

Entries are append-only: adding a new FAQ entry is a single block addition to the table. Editing an existing entry is a one-line change. No string keys are user-facing - the question text IS the identifier.

## Seed entries for v1

Ten troubleshooting entries focused on the most common confusion cases. Wording follows the project's CLAUDE.md "player-facing text stays brief / no jargon" rule.

1. **"Why isn't this item selling?"**
   - A: Alt+Shift+Right-Click the item or type `/ec sellinfo` to print a step-by-step trace of every protection rule. Most common cause is a protection toggle - open the panel below and review.
   - panel: `EbonClearanceOptionsProtection`

2. **"The addon keeps adding my equipped gear to the Keep List."**
   - A: "Keep gear you're wearing" is on by default. Open the panel below and untick it to stop auto-Keep on every equip event.
   - panel: `EbonClearanceOptionsProtection`

3. **"Items keep appearing on Keep List as 'Keep (upgrade)' that I want to vendor."**
   - A: "Keep looted upgrades" auto-adds items whose ilvl is above your currently-equipped piece. Stale entries auto-clean on every BAG_UPDATE since v2.33.1; you can also run `/ec clean upgrades apply` manually. To stop the auto-add entirely, untick the toggle in the panel below.
   - panel: `EbonClearanceOptionsProtection`

4. **"What does 'Keep (affix rank known)' or 'Keep (affix rank needed)' mean on a tooltip?"**
   - A: Project Ebonhold affix items are protected from auto-vendoring. "Rank known" means you've already extracted this exact rank; "Rank needed" means you don't have it yet (whether the family is new or you only have a different rank). The protection toggles are in the panel below; Alt+Right-Click an affixed item for a per-affix `Allow Sell` override.
   - panel: `EbonClearanceOptionsProtection`

5. **"Why are my Sell / Keep / Delete lists different on each character?"**
   - A: Lists are per-character since v2.34.0. Each character has its own independent state. Use the Account Sell List (shared across all characters) for items you want every alt to vendor.
   - panel: nil (informational only)

6. **"How do I share a Sell List across all my characters?"**
   - A: Open the Account Sell List panel below. Items added there get unioned with each character's per-character Sell List at vendor time.
   - panel: `EbonClearanceOptionsAccountWhitelist`

7. **"The Goblin Merchant isn't being summoned when my bags fill up."**
   - A: Three things must all be true: `Summon Greedy Scavenger` is on, `Auto-Loot Cycle` is on, and you have the Greedy Scavenger / Goblin Merchant companion in your spellbook. Configure in the panel below.
   - panel: `EbonClearanceOptionsScavenger`

8. **"The bag-slot border tints aren't showing."**
   - A: Sell-border tints are off by default. Tick `Enable sell-border tints` in the panel below, then enable the per-category checkboxes you want to see (Delete / Account Sell / Character Sell / Junk / Rule).
   - panel: `EbonClearanceOptionsHighlighting`

9. **"How do I disable the addon on one specific character?"**
   - A: Right-click the minimap button on that character to toggle the addon off, or type `/ec` and use the toggle on the Main panel. The setting is per-character; other characters stay enabled.
   - panel: nil (`/ec` action, not a panel)

10. **"How do I see exactly why a bag item will or won't sell?"**
    - A: Alt+Shift+Right-Click the item, or type `/ec sellinfo` (defaults to the first non-empty bag slot). Prints the full predicate chain in chat.
    - panel: nil (diagnostic command)

## Layout

```
[ scroll content, full panel width ]

  Help / Troubleshooting
  Common issues and how to fix them.

  ───────────────────────────────────────

  |cffffff00Why isn't this item selling?|r
  Alt+Shift+Right-Click the item, or /ec sellinfo, to print a per-
  step trace of every protection rule for that slot. The most common
  cause is a protection toggle catching the item; open the panel
  below to review.
                                          [ Open Protection Settings -> ]

  ───────────────────────────────────────

  |cffffff00The addon keeps adding my equipped gear to the Keep List.|r
  ...
```

Per-entry structure inside the scroll content:

- **Title** (FontString, `GameFontNormal`, full width, yellow colour escape, anchored TOPLEFT to previous entry's bottom + 18px).
- **Answer** (FontString, `GameFontHighlight`, full width, word-wrapped, anchored TOPLEFT to title's BOTTOMLEFT + 4px).
- **Button** (UIPanelButtonTemplate, autosized to the panel name string + 24px chrome, anchored TOPRIGHT to answer's BOTTOMRIGHT + 6px) - only when `panel` field is set.
- **Separator** (Texture, `Interface\COMMON\Common-Input-Border`, hairline grey, full width, 1px tall, anchored BOTTOMLEFT to button-or-answer + 8px).
- Spacing: 18px between entries.

Width tracking: every FontString registered via `EC_compCache.setPanelWidth(fs, 16)` so they reflow on Interface Options panel resize.

## Hyperlink mechanism

The optional `[ Open <Panel> -> ]` button's OnClick:

```lua
local target = _G[entry.panel]
if target and InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(target)
    InterfaceOptionsFrame_OpenToCategory(target)
end
```

Standard double-call pattern (3.3.5a Interface Options quirk: first call registers the category focus, second call actually focuses). Same pattern as `EC_compCache.openPanelToList` in `EbonClearance_Events.lua`. Safe when the target panel doesn't exist (just no-ops via the nil guard).

The button's display label comes from the target panel's `name` field (e.g., `target.name = "Protection Settings"`), prefixed with `"Open "` and suffixed with `" ->"`. Looked up at OnClick time so a future panel rename doesn't require updating EC_HELP_ENTRIES.

## Discoverability

- **Sidebar entry**: visible whenever the user opens `/ec`. Browsing finds it.
- **Slash command**: existing `/ec help` chat output gains one line at the end:
  ```
  |cffffff00Open /ec -> Help|r for the in-game FAQ + troubleshooting panel.
  ```
- **README**: brief mention in the "Configuration" section adding "Help" to the panel list, plus a `/ec` -> `Help` callout in the "If something looks wrong" sub-section (or equivalent).

## Test additions

Added to `tests/test_perf_guardrails.lua`:

- **Test 71**: `EbonClearance_HelpPanel.lua` exists, is added to `SOURCE_PATHS` in the three test files, and is included in the release workflow's `cp` glob in `.github/workflows/release.yml`.
- **Test 72**: panel registration sanity - frame named `EbonClearanceOptionsHelp`, registered via `InterfaceOptions_AddCategory`, wrapped via `EC_compCache.initPanel`, scroll-wrapped via `NS.EC_WrapPanelInScrollFrame`.
- **Test 73**: `EC_HELP_ENTRIES` table is declared at file scope with at least 8 entries (defensive against a future refactor that empties the table and ships an empty Help panel). Each entry has both `q` and `a` fields (the `panel` field is optional).
- **Test 74**: `/ec help` chat output includes the FAQ-panel mention (string match against the new line).

## File-load order in .toc

The new file goes **last** in the .toc, after `EbonClearance_BagContextMenu.lua` (the current last entry). The panel registers `_G["EbonClearanceOptionsHelp"]`, but no other code references this name at file-load time - only the user's click on the sidebar entry uses it.

## Out of scope (v1)

Deferred-not-rejected so future work has clear hooks:

- **Search box** for the FAQ. ~10 entries fit in one scrolled view; search is premature. Revisit at ~25 entries.
- **Widget-level highlighting** (pulse the specific checkbox in the target panel when the user clicks "Open <Panel> ->"). Panel-level jump is enough for v1; widget-level highlighting requires a registry mapping FAQ entries -> widget refs that has to be kept in sync with every panel refactor.
- **Slash-command FAQ topics** (`/ec help <topic>`). One line in `/ec help` pointing to the panel is enough. Topic shortcuts are power-user-only; add later if asked.
- **Inline hyperlinks within answer text** (clickable `|H|h` patterns). The single right-aligned button per entry covers the navigation case; inline hyperlinks add a custom hyperlink handler and aren't worth the complexity for v1.
- **User-extensible FAQ** (saving custom notes). Out of scope; CHANGELOG / `/ec bugreport` cover that use case.
- **Per-locale content**. EC's L10n posture is enUS-only on Project Ebonhold per CLAUDE.md; defer along with any future L10n work.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| FAQ content drifts as the addon evolves (e.g., a panel renamed, a feature removed) and entries point to non-existent panels or describe stale behaviour. | The `_G[panel]` nil-guard prevents the click from erroring. The entry table is small and append-only; review on every release. The `q` text is the identifier so renames don't break entry tracking. |
| The 10 seed entries don't match the actual top-N user confusion cases. | Append-only data structure - adding/removing entries is a one-block diff. After ~2 releases with user feedback, prune the unused entries and add the actually-confused-about ones. |
| Panel grows past one screen and users have to scroll. | Already scroll-wrapped, so visually fine. Search box deferred to when count exceeds ~25 entries. |
| New player opens the panel as their first stop and finds it too dense. | The 10-entry set is tuned for "second visit, looking for an answer to something specific" rather than "first visit, what does this addon do?" The Main panel + first-run welcome popup cover the "what is this" case. Could add a one-line "First time? Start at /ec -> Main" hint at the top of the panel. (Bonus polish; not required for v1.) |
| User clicks "Open Protection Settings ->" and Interface Options re-opens; navigation can be jarring. | Same UX as the existing context-menu `Open <List> Panel` flow; users are familiar. Double-call pattern is the standard 3.3.5a quirk and well-tested across the codebase. |

## Implementation notes (for the plan)

- New file `EbonClearance_HelpPanel.lua` follows the same shape as `EbonClearance_ScavengerPanel.lua` (a non-list-management, mostly-text panel that's scroll-wrapped). Use that file as the structural template.
- The build callback (inside `EC_compCache.initPanel`'s build slot) iterates `EC_HELP_ENTRIES` once. Each iteration creates the three FontStrings + optional button + separator and anchors them to the previous entry's separator BOTTOMLEFT. A local `prevAnchor` variable threads the anchoring.
- After the loop, call `NS.FitScrollContent(content, lastSeparator)` so the scroll content grows to the bottom-most widget (matches every other scroll-wrapped panel).
- The button's display name lookup at OnClick time: `_G[entry.panel].name` returns the panel's display string ("Protection Settings", "Account Sell List", etc.). Falls back to `entry.panel` if `_G[entry.panel]` or its `name` field is missing (defensive against rename drift).
- `/ec help` body lives in `EbonClearance_Events.lua` near the slash-command handlers. The new line is a one-line append.
- README change is one bullet under "Configuration" and (optionally) a one-line callout under "Slash Commands" or a new "Troubleshooting" sub-section.

## Verification (in-game checklist for the implementation PR)

- [ ] `/ec` opens; sidebar shows `Help` as the last entry under EbonClearance.
- [ ] Clicking `Help` shows the FAQ. Scroll works; entries are readable; word-wrap follows panel resize.
- [ ] Each entry with a `panel` field renders a `[ Open <Panel Display Name> -> ]` button at the bottom-right.
- [ ] Clicking `[ Open Protection Settings -> ]` on entry #1 swaps the Interface Options panel to Protection Settings.
- [ ] Entries without a `panel` field (5, 9, 10) have no button. Layout shifts cleanly.
- [ ] `/ec help` chat output includes the new line about the in-game FAQ panel.
- [ ] No `EbonClearance_*.lua` file errors at addon load. `EbonClearanceOptionsHelp` is a valid global frame after PLAYER_LOGIN.
- [ ] Test suite passes (all three invariant test files).
- [ ] `luac -p` clean on the new file.
