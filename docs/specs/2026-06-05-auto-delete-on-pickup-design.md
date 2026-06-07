# Spec: Auto-delete Delete-List items on pickup

**Date**: 2026-06-05
**Status**: Approved (brainstorming complete; awaiting implementation plan)
**Target release**: v2.42.0 (new opt-in feature + one additive per-character schema field, downgrade-safe)
**Requested by**: Sanavesa - "an option (defaults to false) that auto-deletes items marked for deletion as soon as they enter your bag instead of when you interact with a vendor", to reduce vendor trips while farming.

## Goal

Let a player opt in (default OFF) to having Delete-List items destroyed the moment they enter the bags, instead of only at a vendor. The action is instant and irreversible, so it is gated, defaults off, requires an explicit confirm to enable, and prints one chat line per item destroyed.

## Decisions locked (via brainstorming)

- **Policy matches the existing vendor delete exactly.** Same rules as today's vendor-time deletion: affix protection still vetoes Rare/Epic affixed drops (unless allowed via Alt+Right-Click or the exact-dupe gate); quest items / tomes / profession tools are NOT protected (the Delete List is explicit user intent); the whole feature is gated by the existing `DB.enableDeletion`. Only the *trigger timing* changes - no behavioural divergence between vendor-delete and auto-delete.
- **Feedback: one chat line per deleted item** (`Auto-deleted <item>.`) - the only visible record of an irreversible action.
- **No rarity backstop / quality cap** (out of scope - policy matches vendor delete exactly).

## Architecture

### DB
- New **account-wide** boolean `DB.autoDeleteOnPickup` (default `false`), to match its gate `enableDeletion` (which is top-level, NOT in `PER_CHAR_FIELDS`). Add the nil-default in `EnsureDB` next to `enableDeletion` (`EbonClearance_Events.lua`). Do NOT add it to `PER_CHAR_FIELDS`: the Delete List items stay per-character, but the toggle is global, exactly like `enableDeletion`.

### Shared eligibility helper (DRY)
- The Delete-List eligibility decision is currently inline in `BuildQueue` (`EbonClearance_Events.lua`: delete-list membership + not-locked + the affix-protection veto block). Extract it into one helper, e.g. `EC_compCache.deleteListSlotEligible(bag, slot, itemID)`, and route both `BuildQueue`'s delete branch and the new auto-delete scan through it. This makes vendor-delete and auto-delete policy identical by construction. Keep `BuildQueue`'s observable behaviour byte-identical.

### Trigger + mechanism
- Hook the existing 120ms-coalesced BAG_UPDATE debounce frame (`EC_compCache.bagUpdateFrame` OnUpdate). After the current settle work, call a new `EC_compCache.runAutoDeleteOnPickup()`. The auto-delete MUST run from this debounce, never from the raw `BAG_UPDATE` branch, so the BAG_UPDATE-coalescing perf invariant holds.
- `runAutoDeleteOnPickup` gates:
  - `DB.enableDeletion and DB.autoDeleteOnPickup`
  - `not EC_compCache.vendorRunning` (don't fight an active vendor cycle)
  - `not EC_compCache.pendingDelete` (a delete is already in flight)
  - `GetCursorInfo() == nil` (don't clobber an item/spell the player is holding)
  Then scan bags 0-4 for the FIRST slot where `deleteListSlotEligible` is true.
- Delete via the existing path, unchanged: `EC_compCache.pendingDelete = { bag, slot, itemID }`; `PickupContainerItem(bag, slot)`; `DeleteCursorItem()`. The existing `HookDeletePopupOnce` (`EbonClearance_Vendor.lua`) auto-confirms the `DELETE_*` popup - verified vendor-independent: it gates only on `pendingDelete` + `IsInSet(DB.deleteList, id)` and types "DELETE" / clicks accept, then clears `pendingDelete`.
- **One item per debounce cycle.** Setting `pendingDelete` blocks a second delete via the gate above; the deletion fires another BAG_UPDATE, which re-fires the debounce (by then the popup hook has cleared `pendingDelete`), which deletes the next eligible item. Self-terminates when none remain (ineligible/protected items are skipped, so no loop). This reuses the single-`pendingDelete` + popup-hook design with no batching. `EC-TRAP:` marker - looks like a missing batch loop, is intentional.
- Print one line per deletion via `PrintNicef`, using the item link (capture name/link before pickup).
- **Not gated on `InCombatLockdown`.** `DeleteCursorItem` is not combat-protected on 3.3.5a and farming happens in combat - that is the whole point. `EC-TRAP:` marker - looks like a missing combat guard, is intentional.

### Toggle UX (`EbonClearance_KeepDeletePanels.lua`, Delete List panel)
- New checkbox under "Allow items to be deleted": **"Auto-delete these items the moment they enter your bags"**.
- Dependent sub-toggle: disabled + greyed when `enableDeletion` is off (mirror the guild-share `shareGuildName` dependent-toggle pattern); refresh its enabled state when "Allow items to be deleted" is toggled.
- **Confirm-on-enable popup** (new `StaticPopup` `EC_CONFIRM_AUTODELETE`, modelled on `EC_CONFIRM_CLEAR_LIST`): Accept enables; Cancel reverts the checkbox to unchecked. Enabling also kicks one debounce scan so items already in bags get cleaned.
- A brief grey hint line under the checkbox.

### Player-facing text (brief, plain, NO em dashes)
- Checkbox: `Auto-delete these items the moment they enter your bags`
- Confirm popup: `Auto-delete permanently destroys Delete List items the instant they're looted - no vendor step, no undo. Turn it on?`
- Chat: `Auto-deleted <item>.`

## Files

- `EbonClearance_Events.lua` - `EnsureDB` default + `PER_CHAR_FIELDS`; extract `deleteListSlotEligible` and route `BuildQueue` through it; `runAutoDeleteOnPickup` + the debounce-frame call; register the `EC_CONFIRM_AUTODELETE` popup.
- `EbonClearance_KeepDeletePanels.lua` - the dependent sub-checkbox + confirm-on-enable + hint.
- `EbonClearance_Vendor.lua` - `HookDeletePopupOnce` reused unchanged (no edit expected; confirmed compatible).
- Docs: `CHANGELOG.md` (v2.42.0 stanza), `EbonClearance_HelpPanel.lua` (FAQ entry), `README.md` (Delete List config + the toggle), `docs/ADDON_GUIDE.md` (the shared helper + the debounce hook + the two `EC-TRAP` notes).

## Testing

1. `luac -p` on each changed file.
2. All five suites stay green. Critically, the auto-delete is invoked from the debounce frame (not the raw `BAG_UPDATE` branch), so the BAG_UPDATE-coalescing invariant (`tests/test_perf_guardrails.lua` Test 1) stays green.
3. New perf-guardrail invariant: lock that `runAutoDeleteOnPickup` is gated on `autoDeleteOnPickup` + `enableDeletion` + `not vendorRunning` + cursor-free, runs from the debounce, and that `BuildQueue` + the auto path both use `deleteListSlotEligible`.
4. Repo grep for U+2014 returns zero.
5. In-game smoke: enable (confirm popup appears) -> loot a Delete-List grey -> it vanishes + an "Auto-deleted" chat line; an affix-protected listed Rare is NOT deleted; a quest item on the list IS deleted; it works in combat; it does nothing during a vendor cycle; an item held on the cursor is not clobbered; toggling "Allow items to be deleted" off greys the sub-toggle; enabling with junk already in bags cleans it.

## Out of scope

- No rarity backstop / quality cap (policy matches vendor delete exactly).
- No change to the vendor delete flow beyond extracting the shared eligibility helper.
- No batching of deletions (one-per-debounce, self-retriggering, is intentional).
