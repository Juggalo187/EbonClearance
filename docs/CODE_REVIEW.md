# EbonClearance - Code Review Follow-ups

A curated backlog of known follow-ups not yet actioned. Each item is
scoped to be a single-session change unless flagged otherwise.

> **Last refresh:** post-v2.17.0 on 2026-05-13.
> Statuses below verified against the current `EbonClearance.lua`.
> v2.13.0-v2.13.4 shipped a feature burst (auto-open combat-defer,
> quest-item safety net, Equipment Manager protection, ElvUI bag
> buttons, default-merchant flip), then a maintenance cluster:
> v2.13.2 fixed a silent ADDON_VERSION drift across two prior
> releases and added a CI test to lock the invariant; v2.13.3 ran
> an audit-driven cleanup removing ~148 LOC of dead/vestigial code
> (dormant vendor-button cluster, unreachable v2.10.0 migration
> notice, write-only flags, an always-true stub); v2.13.4 closed
> two correctness gaps from the same audit. The v2.14.x-v2.16.x
> cycle then shipped UI/UX work: v2.14.0 renamed Whitelist/Blacklist/
> Deletion to Sell/Keep/Delete List + simplified tooltip annotations
> + the resummon-line polish; v2.15.0 split the Keep List panel
> (header + list) from a new Keep List Settings panel (auto-protect
> toggles) + design-language pass on checkbox label case; v2.16.0
> added Fast Loot (LOOT_READY-driven manual loot vacuum + BoP-bind
> auto-confirm). v2.17.0 actioned **item 4 below** (panel OnShow
> boilerplate extraction). Item 4 is now resolved.

> **Audit deferred item 6 (added 2026-05-08)**: the post-v2.13.2
> audit identified `EC_IsSellable` <-> `EC_AnnotateTooltip` as a
> two-way parallel implementation of the sell-decision logic
> (down from the original three-way after v2.13.4 routed
> `/ecdebug` through `EC_IsSellable`). A full extraction into a
> shared `EC_ClassifyItem(itemID, bag, slot, junkOnly) -> (decision,
> reason, detail)` was scoped but deferred when closer inspection
> revealed it would net ~+100 LOC because the formatting layer in
> `EC_AnnotateTooltip` has many distinct labels per rule outcome
> (Will Sell - Green iLvl X / Protected - Quest item / Protected -
> BoP-only filter / Potential Upgrade / etc.) that don't compress
> cleanly into a reason+detail pair. The remaining paired-edit
> burden has held up across v2.10.0-v2.13.4 with one drift
> incident (the v2.13.x quest-item check) caught within hours.
> Re-evaluate when adding a new sell condition naturally creates
> pressure to unify, OR when a concrete drift incident demonstrates
> the paired-edit discipline is breaking down.

---

## Active backlog

> Item 4 below was added in a qlty.sh-aligned re-review of the codebase
> (post-v2.6.0). It surfaced from running the eight default qlty
> code-smell checks plus a Lua best-practice sweep. The original item 4
> (extract panel OnShow boilerplate) was actioned in v2.17.0 and moved
> to Resolved; what was item 5 is now numbered 4 below.

### 1. Consolidate the two chat-filter systems - medium impact, medium risk

Two independent filter installations coexist:

- [`EC_InstallGreedyMuteOnce`](../EbonClearance.lua) installs
  `EC_GreedyEventFilter` across 10 chat events.
- [`ApplyGreedyChatFilter`](../EbonClearance.lua) installs
  `GreedyScavengerChatFilter` across the events listed in
  [`CHAT_FILTER_EVENTS`](../EbonClearance.lua).

Both currently run; the mute behaviour is layered (each filter early-
returns when its condition isn't met). Consolidating to one system
would simplify reasoning but risks regressing edge cases - especially
around `CHAT_MSG_MONSTER_*` vs `CHAT_MSG_SAY` dispatch when the
Scavenger is nearby other mobs.

**Approach if picked up**: audit both filter functions side-by-side,
produce a truth table for every input (muteGreedy × hideGreedyChat ×
hideGreedyBubbles × event-type), and collapse to a single filter that
satisfies the table. Keep the old functions in a feature branch and
do side-by-side testing in a stable zone before deleting.

---

### 2. Split [`CreateListUI`](../EbonClearance.lua) - high impact, low risk

`CreateListUI` is now **369 lines** (was 227 when this doc was first
written). Since then the v2.x.0 series added the "Add matching in
bags:" row, account / character scope handling, and tooltip-warm
refresh logic - all bolted onto the same closure.

Suggested split (still the right shape, plus the new responsibilities
above):

- `BuildListHeader(parent, titleText)` - title + EditBox + search.
- `BuildListSortControls(parent, onSortChange)` - 4 sort buttons.
- `BuildListMatchRow(parent, setTableName, refreshFn)` - the
  "Add matching in bags:" row + handler.
- `BuildListScrollArea(parent)` - the scroll frame + child.
- `MakeListRow(parent)` - one row factory; returns a frame with
  `:SetItem(id, name)` and `:Clear()` methods.
- `RefreshList(listFrame, items)` - the former nested closure.

Each helper is pure layout; no shared mutable state. Extracting pays
off every time a panel uses the list widget (whitelist, blacklist,
delete-list, account whitelist, any future list).

---

### 3. L10n stub - low cost, future-proofing

Even without AceLocale, a trivial passthrough makes future
localisation mechanical:

```lua
local L = setmetatable({}, { __index = function(_, k) return k end })
-- Usage: PrintNice(L["Vendoring complete!"])
```

English keys stay English by default. When a locale table is added,
it overrides keys. Adoption is incremental - wrap new strings first,
then sweep existing ones.

Status: still applicable, still nobody asking for it. Park unless a
concrete localisation request lands.

---

### 4. Named tuning constants (`TUNING` table) - low impact, very low risk

Coverage is currently partial. The codebase already has named
constants for some tuning values - `EC_STUCK_MOVEMENT_THRESHOLD`,
`EC_PET_CHECK_INTERVAL`, `EC_PANEL_HEIGHT` - but many others are
still inline literals scattered across the file:

- `0.05` - vendor interval floor (anti-disconnect)
- `80` - sell cap per merchant visit
- `30` - panel OK/Cancel button-strip clearance
- `26` - scrollbar gutter width
- `22` - list row height
- `1.6` - summon delay default
- and a handful of similar numerics

qlty doesn't ship a default check for "name your magic numbers", but
it's straightforward to add as a custom ripgrep or ast-grep rule via
`qlty.toml`. The practical maintainability win is concrete: a
contributor wanting to tune the vendor cap can grep for one named
constant instead of finding the literal `80` in three or four
unrelated places.

Suggested shape: a `local TUNING = { ... }` block near the file top,
co-located with the existing named constants
(`EC_PANEL_HEIGHT` etc). Migration is incremental - wrap new code
in `TUNING.VENDOR_CAP` etc first, sweep the existing literals later
(or never; the goal is consistency for new code, not retrofitting
the entire file in one go).

This is the smallest qlty-flagged item on the backlog and the
lowest priority. Action only when already touching tuning-related
code.

---

## Resolved

### Extract panel OnShow boilerplate - DONE (v2.17.0)

Actioned in v2.17.0. New helper `EC_compCache.initPanel(self, refresh,
build, wrapScroll)` consolidates the 5-line preamble (EnsureDB +
EC_UpdatePanelWidth + inited guard + refresh-or-build branch +
optional scroll-wrap) that every Interface Options panel's OnShow
shared. All 11 panels migrated (MainOptions, CharPanel, ScavengerPanel,
MerchantPanel, ProfilesPanel, ImportExportPanel, DeletePanel,
BlacklistPanel, BlacklistSettingsPanel, WhitelistPanel,
AccountWhitelistPanel). Helper is hung off `EC_compCache` rather than
a file-scope local to stay under Lua 5.1's 200-locals-per-main-chunk
cap (CLAUDE.md discipline).

The `wrapScroll` arg internalises the `EC_WrapPanelInScrollFrame` call
for panels that need it (MainOptions, ScavengerPanel, MerchantPanel,
BlacklistSettingsPanel). The test-layout-reactivity test 6 was updated
to recognise the new `end, true)` closer as evidence of scroll-wrap via
the helper, in addition to the literal inline `EC_WrapPanelInScrollFrame`
call. Old test had a block-boundary bug that grabbed too much source
across adjacent panels; v2.17.0 fixed by scoping each panel's check to
the start of the next panel's OnShow rather than the (far-away) first
`InterfaceOptions_AddCategory` line.

Adding a new panel is now a 5-line OnShow + the panel-specific bodies,
instead of ~30 lines of preamble + body.

### Luacheck clean-sweep - DONE (post-v2.6.0)

71 warnings -> 0 warnings. `.luacheckrc` extended with previously
undeclared 3.3.5a globals (`GetCursorInfo`, `GetUnitSpeed`,
`WorldFrame`, `OpenBackpack`, `OpenBag`, `IsShiftKeyDown`,
`IsControlKeyDown`, `StaticPopup1*`, `ITEM_QUALITY_COLORS`,
`IsMouseButtonDown`, `tinsert`); forward-declared locals (`DB`,
`ADB`) treated as writable globals; `StaticPopupDialogs` moved to
the writable-globals block so per-dialog field assignments stop
tripping the read-only-field check.

Surfaced and removed real dead code:
- Unused cached API upvalues `GetMerchantNumItems`,
  `GetMerchantItemInfo`, `GetMerchantItemLink`.
- Unused constant `PET_CHAT_PREFIX`.
- Unused helpers `SummonGoblinMerchant`, `DismissGoblinMerchant`
  (their job is now done by `EC_TickGoblinSummon` and friends).
- Unused `EC_PANEL_HEIGHT` global + the GetHeight branch in
  `EC_UpdatePanelWidth` (was scaffolding for a future feature that
  never landed).

Other fixes:
- `msg`/`self` shadowing on a few sites (slash-command handler,
  Profiles panel `RefreshProfileList` method definition).
- Unused arguments / varargs on chat filter handlers and
  destructured returns underscore-prefixed.

Net file delta: -27 LOC. CLAUDE.md now states "0 warnings; keep at
zero" instead of the old 93-warning baseline.

### `local EC = {}` namespace - DECIDED (post-v2.6.0): stay single-file, threshold raised

The original deferral predicate ("if we ever split") was overtaken by
the file passing the documented 4000-LOC trigger (file is 5561 LOC at
v2.6.0). Decision made post-v2.6.0: **stay single-file** for now.
Comprehension and grep latency at this size aren't actually painful;
forcing a split for its own sake is pure churn.

`docs/ADDON_GUIDE.md` "When to split the file" updated to bump the
threshold from ~4000 LOC to ~8000 LOC and to note that organic module
boundaries (not LOC alone) should drive any future split. Re-evaluate
at the next threshold rather than auto-splitting on growth.

If the file does eventually split, the original guidance still
applies: introduce `local EC = {}` in `EbonClearance_Core.lua`, load
it first, and have each feature file attach to it.

### Split [`EC_petCheckFrame`](../EbonClearance.lua) OnUpdate - DONE (v2.4.0)

Done in `refactor/perf-and-quality-pass`. Helpers extracted:
`EC_TickGoblinSummon`, `EC_TickGoblinTarget`, `EC_TickMerchantReminder`,
`EC_AutoLootStateSync`, `EC_HandleScavengerOut`, `EC_TryResummonScavenger`,
`EC_PetCheckTick`. The OnUpdate body is now a small dispatch.

### StyLua diff once - DONE

`stylua --check EbonClearance.lua` is clean and has been kept clean
across multiple recent commits. The formatter runs as part of every
release-prep pass.
