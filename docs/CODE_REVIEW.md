# EbonClearance - Code Review Follow-ups

A curated backlog of known follow-ups not yet actioned. Each item is
scoped to be a single-session change unless flagged otherwise.

> **Last refresh:** post-v2.29.0 on 2026-05-19.
>
> v2.29.0 shipped the Release 1 cut: bag-slot sell-border tint
> (default Blizzard + host bag-UI adapter), `/ec sellinfo` predicate-
> trace inspector (`/ec sellinfo [bag slot]` + Alt+Shift+Right-Click),
> full settings pack export/import (`EC_PACK_V1` marker with
> auto-detect on import), plus the supporting fixes (combat-deferred
> minimap open, list-mutation refresh, allow-list mutation refresh,
> deep-bag tracking fix, affix dupe gate case-fold + one-shot
> migration, `/ec bugreport` refactor to neutral capability flags,
> Merchant Settings narrow-width fix, import/export box backdrop
> chrome). New gotchas documented in `docs/ADDON_GUIDE.md` between
> the magic-numbers table and the Fingerprint section: sell-border
> three invariants, affix case-fold load-bearing pair, list-mutation
> refresh rule, no-third-party-references rule.
>
> **EC_compCache namespace observation.** The 200-locals cap kept
> pushing new helpers onto `EC_compCache`; v2.29.0 added 12 more
> entries to that table (`applySellBorder`, `bagSlotWillSell`,
> `updateSellBordersForBagFrame`, `installHostBagBorderHook`,
> `sellBorderButtons`, `describeSellability`, `printSellabilityTrace`,
> `bagSlotFromButton`, `exportFullPack`, `importFullPack`,
> `qualityNames`, `PACK_PREFIX`). The table is now the de-facto module
> namespace for everything that doesn't fit in the 200-locals budget.
> Not a refactor task in itself; observation worth surfacing because
> any future file split (when the file finally crosses the ~8000 LOC
> threshold per `docs/ADDON_GUIDE.md` "When to split the file")
> should treat `EC_compCache` as a candidate seed for the shared
> namespace rather than reinventing the structure. The single-file
> threshold is currently sitting around 11,800 LOC; the original 8K
> bump may need re-evaluation soon.
>
> v2.27.0 ran a perf + cleanup review of the v2.22.0-v2.26.1 batch
> (Process Bags, BAG_UPDATE coalescing, affix dupe gate, Lockpick
> mode, Allow Sell workflow). Five items landed in the v2.27.0
> commit: negative-cache sentinel in `processTooltipHasLine`, sort
> comparator pre-computes names in `buildProcessSummary`, dead
> `local short` in `rearmProcessButton`, dead
> `EC_compCache.findNextProcessable`, and a luacheck zero-warning
> cleanup. Three lower-priority items were noted in-review but not
> actioned (diagnostic-only `findLearnedAffixForItem`, double walk
> in `refreshExtractionIfDirty`, hard-coded `PROF_LOOT_SPELLS`
> "Pick Lock" name). The pre-v2.18.0 active backlog (items 1, 2, 3
> below) is unchanged.
>
> **Pre-v2.18.0 history (kept for context):**
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

> Item 3 below was added in a qlty.sh-aligned re-review of the codebase
> (post-v2.6.0). It surfaced from running the eight default qlty
> code-smell checks plus a Lua best-practice sweep. The original items 2
> and 4 (split CreateListUI and extract panel OnShow boilerplate) were
> actioned in v2.18.0 and v2.17.0 respectively and moved to Resolved.
> Items 1 (chat-filter consolidation) and 3 (TUNING constants) remain.
> Item 2 was reused to renumber the former L10n stub item, since it's
> still parked. Item 4 (file split) was added post-v2.29.0 audit when
> the 200-locals cap became a recurring active constraint. Numbering
> now: 1 chat-filter, 2 L10n stub, 3 TUNING, 4 file split.

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

### 2. L10n stub - low cost, future-proofing

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

### 3. Named tuning constants (`TUNING` table) - low impact, very low risk

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

### 4. File split (in progress) - multi-stage internal refactor

The single-file architecture crossed the documented 8K-LOC trigger
during v2.22.0 (Process Bags) and reached ~11,800 LOC by v2.29.0. The
post-v2.29.0 audit (see the plan file's §16) confirmed the file is in
good shape internally - no urgent perf or quality findings - but the
200-locals cap is now an active design constraint: it forced 2 helpers
onto `EC_compCache` during v2.29.0 alone for cap-relief reasons, not
namespacing reasons. `EC_compCache` has grown to 50+ entries, many of
which are de-facto module-namespace inhabitants. The split crystallises
what's already happening organically.

The refactor is staged across commits, NOT releases. Stages are
internal engineering work with no user-facing behaviour change; they
ship to `master` as soon as the in-game smoke checklist passes but
do NOT get their own version tags. `ADDON_VERSION` and the `.toc`
Version stay frozen at whatever the last user-facing release was
(currently v2.29.0) for the entire duration of the split. The next
version bump happens whenever the next feature release lands.

Each stage is independently shippable and bisectable. Do NOT mix
feature work into a split stage - keep diffs move-only where possible.

| Stage | Scope | Status |
|---|---|---|
| 1 | Namespace bootstrap (`local NS = select(2, ...)`; `NS.compCache = EC_compCache` alias) | **DONE** (commit `8201442`) |
| 2 | Extract `EbonClearance_Core.lua` (provenance globals, EC_Fingerprint, EC_compCache table literal) | **DONE** (commit `119eca8`) |
| 3 | Extract `EbonClearance_Companion.lua` (chat filters + speech-bubble killer cluster) | **DONE** (commit `987b5b5`) |
| 4 | Extract `EbonClearance_Protection.lua` (PE affix + chance-on-hit + Anvil-bridge cluster; bind-type cache stays in EbonClearance.lua for later) | **DONE** (commit `9d65e64`) |
| 5 | Extract `EbonClearance_Vendor.lua` (narrow scope: just HookDeletePopupOnce + the deletePopupHooked gate; `running` + `pendingDelete` promoted to EC_compCache as Stage 5 prep). EC_IsSellable / BuildQueue / DoNextAction / worker / StartRun / EC_manualSell remain in EbonClearance.lua for future "Stage 5b"+ stages | **DONE** (commit `08c3893`) |
| 6 | Extract `EbonClearance_BagDisplay.lua` (sell-border tint helpers + sellability-trace inspector + NS.RefreshSellBorders body). Auto-open driver + Fast Loot stay in EbonClearance.lua | **DONE** (commit `5c9399b`) |
| 7 | Extract `EbonClearance_Process.lua` (Process Bags ENGINE: spell IDs + eligibility predicates + buildProcessSummary). UI panel + rearmProcessButton + refreshProcessPanel stay in EbonClearance.lua for Stage 8 | **DONE** (commit `a24be7d`) |
| 8 | Extract `EbonClearance_BugReport.lua` (smallest UI cluster: diagnostic snapshot builder + popup frame). Three cycle-state locals (`lootCycleState`, `lastScavengerOut`, `addonDismissed`) promoted to `EC_compCache.*` as Stage 8 prep. Larger UI surface (Interface Options panels, minimap, LDB, tooltip annotation, CreateListUI + list-row factories) deferred to future Stages 8b / 8c | **DONE** (commit `d2fe9b6`) |
| 8b | Extract `EbonClearance_Minimap.lua` (minimap button + LDB launcher + combat-vendor SecureActionButton, ~210 LOC). Three self-contained UI buttons outside the Interface Options panel hierarchy. Uses `_G[<panel-name>]` lookup for MainOptions / ProcessBagsPanel instead of explicit NS exposures | **DONE** (commit `37d7565`) |
| 8c | Extract `EbonClearance_Tooltip.lua` (per-bag-item tooltip annotation system: EC_AnnotateTooltip + EC_ClearTooltipFlag + EC_InstallTooltipHookOnce, ~362 LOC). Local IsInSet copy; cross-file deps satisfied via earlier-stage NS exposures. Mid-stage: added the missing grey/junk branch to the annotation chain (pre-existing gap surfaced by tester) | **DONE** (commit `471ae04`) |
| 8d | Extract `EbonClearance_BagContextMenu.lua` (Alt+Right-Click bag quick-action popup: EC_CTX_ROWS + EC_BuildCtxFrame + EC_ShowItemContextMenu + EC_InstallBagContextHookOnce, ~375 LOC). Four list-helpers (AddItemToList, RemoveItemFromList, FindAddConflict, GetListTable) exposed on NS as Stage 8d prep. Mid-stage fix: row-click handler called `EC_GetListTable` (file-scope local in EbonClearance.lua) as a global; promoted to `NS.GetListTable` + extended Test 39 with a bare-call check scoped to the new file | **DONE** (commit `af81c07`) |
| 8e-i | Extract `EbonClearance_ProcessBagsPanel.lua` (v2.22.0 Process Bags Interface Options panel: frame + 4 EC_compCache helpers + OnShow build body, ~662 LOC moved). Stage 8e narrow first slice: a self-contained domain that depends only on `NS.MakeHeader` / `NS.MakeLabel` / `NS.PrintNicef`. MakeHeader + MakeLabel exposed on NS as Stage 8e-i prep. Registration in EbonClearance.lua converted to `_G[]` lookup. The .toc loads the new file BEFORE `EbonClearance.lua` so the frame exists at registration time; helper bodies resolve `NS.*` lookups lazily at call time | **DONE** (commit `7db22bf`) |
| 8e-ii | Extract `EbonClearance_MerchantPanel.lua` (Merchant Settings Interface Options panel: frame + OnShow build body + 2 dropdown data tables, ~478 LOC moved). Five additional widget primitives (AddCheckbox, AddSlider, ColorTextByQuality, StyleInputBox, FitScrollContent) exposed on NS as Stage 8e-ii prep. Same `_G[]` lookup + .toc-before-main pattern as 8e-i. Mid-stage fix 1: file-header doc block must not contain the literal `MerchantPanel:SetScript("OnShow"` text because Test 6 in `tests/test_layout_reactivity.lua` greps that pattern; reworded the header. Mid-stage fix 2: EC_WHITELIST_QUALITIES eager file-scope construction called `NS.ColorTextByQuality(...)` which was nil at load time (file loads before EbonClearance.lua); moved table construction inside the OnShow build callback. New Test 41 invariant locks against future load-order traps | **DONE** (commit `850587f`) |
| 8e-iii | Extract `EbonClearance_ScavengerPanel.lua` (Scavenger Settings panel: frame + OnShow build body, ~275 LOC moved). **Zero new NS exposures needed** - the 5 widget primitives the OnShow body uses (MakeHeader, MakeLabel, AddCheckbox, AddSlider, FitScrollContent) are all already NS-exposed from 8e-i / 8e-ii prep. Same _G[] lookup + .toc-before-main pattern. Smallest extraction in the panel-split sequence. (Originally scoped as Character + Scavenger bundled, but CharPanel was heavily reworked into "Item Highlighting" in the §4.5 batch and now sits much smaller; defer CharPanel extraction to a later stage) | **DONE** (commit `<pending>`) |
| 8e-iv | Future: extract `EbonClearance_ProfilesImportExport.lua` (Profiles + ImportExport panels bundled; ~950 LOC). Depends on the profile-management helpers + the `runImport` / `runExport` plumbing | pending |
| 8e-v | Future: extract `EbonClearance_DeletionBlacklistPanels.lua` (Deletion + Blacklist + BlacklistSettings; ~480 LOC) | pending |
| 8e-vi | Future: extract `EbonClearance_WhitelistPanels.lua` (Whitelist + AccountWhitelist; ~110 LOC tiny pair) | pending |
| 8e-vii | Future: extract `EbonClearance_MainPanel.lua` + `EbonClearance_PanelInfra.lua` (MainOptions + CreateListUI + the panel-infra helpers like MakeHeader / MakeLabel / AddCheckbox / AddSlider / panel-width registry, ~2000 LOC). The remaining foundation; could split further if it lands too big | pending |
| 9 | Rename `EbonClearance.lua` -> `EbonClearance_Events.lua`; close out the refactor (sweep any residuals - auto-open driver, Fast Loot, vendor-cycle remnants from Stage 5's narrow scope - to their target files) | pending |

Cross-file references resolve at call time via `NS.foo` table-index
lookup, so load order between feature files doesn't matter (Core must
still load first because it owns the namespace shape and the EnsureDB
migrations). See docs/ADDON_GUIDE.md "File split - in progress" for
the full target-architecture table.

Tests stay whole-codebase: the three invariant test files will be
updated at Stage 2 to concatenate the split files at test time, so
every existing `src:find` check continues to apply unchanged across
the split boundary.

LICENSE §2(b) requires the file-header attribution block. It stays
on whichever file is loaded first in the `.toc` - currently
`EbonClearance.lua`, will move to `EbonClearance_Core.lua` in Stage 2.

Re-evaluate the stage cadence if a stage proves harder than expected,
but don't abandon mid-refactor: a half-split codebase (some features
in `_Companion.lua`, the rest still in the monolith) is genuinely
worse than either endpoint.

---

## Resolved

### Split `CreateListUI` - DONE (v2.18.0)

Actioned in v2.18.0. Five helper functions extracted onto `EC_compCache`
(same discipline as `EC_compCache.initPanel`):

- `EC_compCache.buildListHeaderRow(box, titleText, setTableName)` returns
  `(input, addBtn, clearAllBtn)`. Wires focus-tracking + drag-to-receive
  on the input as pure layout; OnClick handlers stay in CreateListUI.
- `EC_compCache.buildListSearchAndSortRow(box, setTableName)` returns
  `(search, sortIDBtn, sortNameBtn)`. No OnClick wiring.
- `EC_compCache.buildListMatchRow(box, setTableName)` returns
  `(matchInput, matchBtn)`. No OnClick wiring.
- `EC_compCache.buildListScrollArea(box, w, setTableName)` returns
  `(scroll, content)`. Installs the auto-hide scrollbar hook and the
  OnSizeChanged reactive-width hook internally.
- `EC_compCache.makeListRowFactory(content, setTableName)` returns a
  small table `{ getRow, hideAllRows, setActiveRows }`. Encapsulates
  the `rowPool` and `activeRows` state.

`CreateListUI` shrunk from 407 LOC to 261 LOC (~36% reduction). The
remaining body holds `sortMode` + `pendingRetry` state, the
`MatchesSearch` helper, the `Refresh` closure (too entangled to extract
cleanly), and all OnClick wiring. The wiring necessarily stays inline
because the handlers need to call `Refresh` which is defined in the same
scope.

Test 2 in `tests/test_layout_reactivity.lua` was updated to follow the
OnSizeChanged hook call into `EC_compCache.buildListScrollArea` (it now
lives in the helper instead of inline in CreateListUI). The structural
invariant - "the reactive-width hook chain stays intact" - is unchanged;
the test just had to learn where the hook moved to.

Zero behaviour change. Every list panel (Sell List, Keep List, Delete
List, Account Sell List) renders and behaves identically to v2.17.0.

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
