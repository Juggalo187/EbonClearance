ne# EbonClearance - Addon Development Guide

**Read this first if you are an AI agent or new contributor touching
this codebase.** It is prescriptive: when the guide and a random
internet tutorial disagree, follow the guide.

## TL;DR conventions

1. **Client target is WoW 3.3.5a (Interface 30300 / WotLK / Lua 5.1).**
   Do not copy-paste retail code. APIs like `C_Timer`, `C_Container`,
   and `BAG_UPDATE_DELAYED` do not exist here.
2. **Single file.** All code lives in `EbonClearance.lua`. Do not split
   into modules unless explicitly asked - see "When to split" below.
3. **Namespace via `EC_` prefixed locals.** There is no addon table.
   Nearly everything is `local`; the only intentional globals are the
   saved-variable tables (`EbonClearanceDB`, `EbonClearanceAccountDB`),
   the slash-command handles, the keybinding header / name strings
   (`BINDING_HEADER_EBONCLEARANCE`, `BINDING_NAME_EBONCLEARANCE_*`), the
   handlers wired from `Bindings.xml` (`EbonClearance_ToggleSettings`,
   `EbonClearance_ToggleEnabled`, `EbonClearance_ForceSell`), and the
   provenance globals required by `LICENSE` §2 (`EBONCLEARANCE_IDENT`,
   `EBONCLEARANCE_AUTHOR`, `EBONCLEARANCE_ORIGIN`,
   `__EbonClearance_origin`, `__EbonClearance_author`).
4. **State machine uses `STATE.*` constants**, never raw strings. See
   `STATE = { IDLE, LOOTING, WAITING_MERCHANT, SELLING }` in the file.
5. **Cache hot WoW API globals at file top**, then use the locals on
   hot paths (vendor loop, bag scans, OnUpdate callbacks).
6. **One event-dispatch frame.** All events hang off `f` at the bottom
   of `EbonClearance.lua`. Do not create new event frames for new events
   - add to the dispatch table.
7. **Print through `PrintNice` or `PrintNicef`.** Never call
   `DEFAULT_CHAT_FRAME:AddMessage` directly outside those helpers.
8. **Saved variables always go through `EnsureDB()`.** New fields must
   default without breaking an existing `EbonClearanceDB` table.
9. **Interface Options panels are idempotent via `self.inited`.** Every
   panel's OnShow does the "if inited then refresh-only; return" dance.
10. **No external libraries.** No Ace3, no LibStub, no LDB. See the
    Ace3 decision record below for the reasoning and escape hatch.
11. **Doc links never use `#L<n>` line anchors.** Link to the file by
    name (e.g. `[CreateListUI](../EbonClearance.lua)`) and let readers
    `grep` for the symbol. Line numbers shift on every refactor; symbol
    names don't.
12. **Do not remove attribution markers.** `LICENSE` §2 lists five
    things every redistribution must preserve: the `## Author:` TOC
    line, the file-header comment block at the top of
    `EbonClearance.lua`, the GUI byline rendered on the main options
    panel, the `EBONCLEARANCE_*` / `__EbonClearance_*` provenance
    globals, and the `LICENSE` file in full. If a refactor would touch
    any of those, leave them alone or update them with care - never
    delete.

## Client target: 3.3.5a

### `.toc` fields we use

```
## Interface: 30300                                # WotLK 3.3.5a; do not bump
## Title: ...                                      # colour codes allowed
## Notes: ...
## Author: ...                                     # required by LICENSE §2(a)
## X-Website: https://github.com/.../EbonClearance # canonical source
## Version: ...
## SavedVariables: EbonClearanceDB, EbonClearanceAccountDB

EbonClearance.lua
Bindings.xml
```

`EbonClearanceDB` is per-character (default for `## SavedVariables`);
`EbonClearanceAccountDB` is account-wide and stores the shared
whitelist that gets unioned at sell time. If you ever add a
character-scoped var that should *not* persist across characters in
this account, use `## SavedVariablesPerCharacter`. We do not use
`Dependencies`, `OptionalDeps`, `LoadOnDemand`, or `LoadManagers`.

`Bindings.xml` declares the three bindable actions and is loaded
straight after the Lua. Do not move bindings into Lua - WoW expects
them in XML at addon-load time.

### Lua 5.1 constraints

- No `goto` / labels.
- No integer division operator (`//`) - use `math.floor(a / b)`.
- No `bit32`; use the built-in `bit` library (`bit.band`, `bit.bor`, etc).
- No `string.pack`, no `utf8` library.
- `ipairs` stops at the first nil; use `pairs` for sparse tables.

## Architecture

### File layout

One file, roughly in this order:
- File header comment block (required by LICENSE §2(b); do not remove).
- Constants and cached API upvalues (top).
- Provenance globals (`EBONCLEARANCE_IDENT/AUTHOR/ORIGIN`, plus two
  `__EbonClearance_*` aliases - required by LICENSE §2(d)).
- Greedy Scavenger chat filters (`EC_GreedyEventFilter`,
  `EC_InstallGreedyMuteOnce`, `ApplyGreedyChatFilter`).
- Speech-bubble killer (`EC_bubbleFrame`).
- SavedVariable bootstrap (`EnsureDB`, `EnsureAccountDB`,
  `EC_GetListTable` list-name resolver, `EC_ExtraListTables`).
- Profile / bag / pet / merchant helpers.
- State machine constants (`STATE`).
- Timers (`EC_Delay`, `EC_delayFrame`).
- Session-stats table (`EC_session`) and `EC_ResetSession`.
- Pet check OnUpdate and auto-loot cycle (`EC_petCheckFrame`).
- Vendor loop (`BuildQueue`, `DoNextAction`, `worker`).
- UI: `CreateListUI` (search / sort / "Add matching in bags" row baked
  in), minimap button, dormant `EC_CreateVendorButton`,
  `StaticPopupDialogs` for confirmation, Interface Options panels
  (Main, Merchant Settings - includes the quality threshold,
  Whitelist - Character, Whitelist - Account, Profiles, Import/Export,
  Deletion List, Blacklist - Keep, Scavenger Settings, Character
  Settings).
- `EC_AddScanByQualityRow` helper used by both whitelist panels.
- Export / import / bug report.
- List-conflict helpers (`EC_ScanListConflicts`,
  `EC_PrintConflictReport`, `EC_ApplyCleanResolution`).
- Keybinding header / name strings and the three
  `EbonClearance_*` global handlers (called from `Bindings.xml`).
- Event dispatch (bottom) and slash commands (`/ec`, `/ec profile ...`,
  `/ec clean [apply]`, `/ec bugreport`, `/ecdebug`).

Approximate ordering - do not reshuffle unless splitting the file.

### The event hub

At the bottom of the file, one `CreateFrame("Frame")` registers every
event and dispatches via a switch on `event`. Adding a new event is a
two-liner: `f:RegisterEvent("NEW_EVENT")` and a branch in the OnEvent
handler. Do **not** add a second event frame for "your feature."

Currently registered: `ADDON_LOADED`, `PLAYER_LOGOUT`, `PLAYER_LOGIN`,
`PLAYER_ENTERING_WORLD`, `MERCHANT_SHOW`, `MERCHANT_CLOSED`,
`UNIT_AURA` (player-filtered when `RegisterUnitEvent` is available),
and `BAG_UPDATE`. The `BAG_UPDATE` branch dispatches to two helpers
in priority order: `EC_HandleBagFullForCycle` (auto-loot cycle's
threshold trigger; v2.2.0) and then `EC_HandleAutoOpenContainers`
(opens "Right Click to Open" containers; v2.3.0). The auto-open
helper yields to the vendor cycle via the `running` guard, so they
never collide.

### Saved variables shape

`EbonClearanceDB` is one flat table per character. Fields fall into
four groups:

- **Lists**: `whitelist`, `blacklist`, `deleteList`, `enableOnlyListedChars`.
- **Profiles**: `whitelistProfiles`, `blacklistProfiles`, `activeProfileName`.
- **Settings**: `enabled`, `summonGreedy`, `summonDelay`,
  `vendorInterval`, `maxItemsPerRun`, `fastMode`, `merchantMode`,
  `autoLootCycle`, `bagFullThreshold`, `autoOpenContainers`,
  `repairGear`, `keepBagsOpen`, `muteGreedy`, `hideGreedyChat`,
  `hideGreedyBubbles`, `enableDeletion`, `qualityRules` (v2.5.0+;
  per-rarity table, see below), `vendorBtnShown`
  (and `vendorBtnX`, `vendorBtnY`, `vendorBtnPoint`, `vendorBtnRelPoint`
  - dormant; see the `EC_CreateVendorButton` block).
  `fastMode` (v2.2.0+) pins the per-item interval to the 0.05 s floor
  and doubles the per-run cap; consume via `EC_EffectiveVendorInterval`
  / `EC_EffectiveMaxItemsPerRun`, never read it directly on hot paths.
  `qualityRules` (v2.5.0+) is a table indexed by quality (1=White,
  2=Green, 3=Blue, 4=Epic added in v2.8.0) with
  `{ enabled = bool, maxILvl = number, bindFilter = "any"|"boe"|"bop",
  useEquippedILvl = bool }` per rarity. `maxILvl == 0` means no cap.
  When `maxILvl > 0` the cap only filters items with a non-empty
  `equipLoc` (i.e. items that display "Item Level: N" on their
  tooltip); trade goods, reagents, and consumables - even if
  `GetItemInfo` returns a non-zero internal itemLevel - are protected.
  **`useEquippedILvl == true` (v2.12.0+) makes `maxILvl` irrelevant at
  runtime** - the rule fires when the looted iLvl is below the
  player's currently-equipped iLvl in the same slot, via
  `EC_compCache.isDowngradeVsEquipped`. The helper requires every
  candidate slot from `EC_compCache.INVTYPE_SLOTS` to be populated;
  any empty slot returns false (don't auto-sell when the user might
  want to fill the slot). Replaces the v2.3.x `whitelistMinQuality` /
  `whitelistQualityEnabled` pair (kept on the table for one release
  for rollback). If you ever add a fifth tier (Legendary), extend the
  loop in `EnsureDB` plus the three `quality >= 1 and quality <= 4`
  checks in `EC_IsSellable`, `EC_AnnotateTooltip`, and the `/ecdebug`
  bag scan, plus the per-rarity row builder in the Merchant Settings
  panel.
- **Stats**: `totalCopper`, `totalItemsSold`, `totalItemsDeleted`,
  `totalRepairs`, `totalRepairCopper`, `soldItemCounts`,
  `deletedItemCounts`, `inventoryWorthTotal`, `inventoryWorthCount`.
- **UI**: `minimapButtonAngle`, `allowedChars`.

`EbonClearanceAccountDB` is a separate, account-wide table holding only
`{ whitelist = { [itemID] = true, ... } }`. It is bootstrapped by
`EnsureAccountDB()` (called from `EnsureDB()`) and exposed to
`CreateListUI` via the `EC_GetListTable` resolver under the name
`accountWhitelist`. Sell-time consultation is a union of the per-char
and account whitelists.

In-memory only (not saved): `EC_session = { copper, sold, deleted,
repairs, repairCopper }`. Reset by the Reset Session button on the main
page or on `/reload`.

`EnsureDB()` is the **only** place defaults are written. Adding a new
setting means: pick the group, add a default line inside `EnsureDB()`,
and make sure it's `nil`-tolerant (`DB.myField or default`).

## Required patterns

### Locals everywhere

```lua
local function DoThing()  -- good
function DoThing()        -- bad - creates a global
```

Check with `luacheck EbonClearance.lua`; the W111/W112 family catches
this.

### Cached API globals

The block at the top of the file caches hot API functions:

```lua
local GetItemInfo = GetItemInfo
local GetContainerItemID = GetContainerItemID
-- ...and the rest of the bag / merchant / companion API
```

When you use one of these on a hot path, you are using the local
upvalue, which is a single register read rather than a `_G` hash
lookup. If you add new hot-path API calls, add them to the cache.

### State transitions

```lua
EC_lootCycleState = STATE.LOOTING          -- good
EC_lootCycleState = "looting"              -- bad - typos become silent
if EC_lootCycleState == STATE.IDLE then    -- good
```

A typo in a string state is a silent bug (the comparison fails, the
transition never fires). A typo in `STATE.XYZ` is a nil-compare that
fails closed and usually crashes loudly.

### Chat output

```lua
PrintNice("Hello")                          -- static string
PrintNicef("Sold %d items for %s", n, g)    -- formatted
-- never:
DEFAULT_CHAT_FRAME:AddMessage("[EbonClearance] ...")
```

The prefix/colour are owned by `PrintNice`. Direct `AddMessage` calls
drift the prefix over time.

### Event handler

Add to the hub's switch, do not spawn a new frame:

```lua
-- In the bottom event handler:
elseif event == "BAG_UPDATE" then
    -- new branch
```

## UI conventions

### Interface Options panels

Pattern for every panel:

```lua
local MyPanel = CreateFrame("Frame", "EbonClearanceOptionsMy",
    InterfaceOptionsFramePanelContainer)
MyPanel.name = "My Panel"
MyPanel.parent = "EbonClearance"           -- nest under main category

MyPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        -- refresh dynamic widgets from DB here, then
        return
    end
    self.inited = true
    -- static widget creation (called exactly once)
end)

InterfaceOptions_AddCategory(MyPanel)
```

**Reactive layout (v2.11.0+).** Panels are no longer width-frozen at
their first OnShow. The
[`InterfaceOptionsFramePanelContainer:HookScript("OnSizeChanged", ...)`](../EbonClearance.lua)
near the bottom of the file calls
[`EC_compCache.refreshLayouts`](../EbonClearance.lua) on every resize,
which walks `EC_compCache.widthRegistry.widgets` and re-applies
`SetWidth(EC_PANEL_WIDTH - x)` to each, then re-fits scroll content for
each `(content, lastWidget)` pair on `widthRegistry.scrollFits`.

**Use the helper.** New widgets that snapshot `EC_PANEL_WIDTH` MUST
go through one of these:

```lua
EC_compCache.setPanelWidth(widget, x)        -- SetWidth + register in one call
-- or, when you've already called SetWidth:
EC_compCache.registerWidth(widget, x)        -- register only
```

[`MakeLabel`](../EbonClearance.lua) and
[`EC_WrapPanelInScrollFrame`](../EbonClearance.lua) register their
widgets automatically;
[`EC_FitScrollContent`](../EbonClearance.lua) registers itself the
first time it's called per panel. List widgets created via
[`CreateListUI`](../EbonClearance.lua) and
[`CreateNameListUI`](../EbonClearance.lua) install their own
`box:OnSizeChanged` hook so internal rows track via the registered
content frame.

**Panels using CreateListUI / CreateNameListUI MUST anchor BOTTOMRIGHT
to the panel** so the box itself stretches with the panel:

```lua
self.listUI = CreateListUI(self, ...)
self.listUI:ClearAllPoints()
self.listUI:SetPoint("TOPLEFT", anchor, ...)
self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
```

Without the BOTTOMRIGHT anchor the box never receives an
`OnSizeChanged` event when the panel resizes, and the
`box:OnSizeChanged` hook inside the helper never fires.

The registry is session-scoped (lives on `EC_compCache`, not in
SavedVariables); a `/reload` reseeds.

**Regression tests.** The structural invariants are checked by
[`tests/test_layout_reactivity.lua`](../tests/test_layout_reactivity.lua),
run on every push by [`.github/workflows/test.yml`](../.github/workflows/test.yml).
The test catches: bare `:SetWidth(EC_PANEL_WIDTH - X)` calls outside
the helpers, missing `box:OnSizeChanged` hooks, panels missing the
`ClearAllPoints + BOTTOMRIGHT` follow-up, and list-row text using
`SetWidth(w - N)` instead of TOPLEFT/TOPRIGHT anchors. If you add a
new structural invariant, add a check to that file.

### Colour palette

Use the existing palette - do not invent new shades:

| Colour code  | Meaning         |
|--------------|-----------------|
| `\|cff4db8ff` | Addon title     |
| `\|cffb6ffb6` | Success / good  |
| `\|cffff4444` | Error / bad     |
| `\|cffffb84d` | Warning / note  |
| `\|cffffff00` | Emphasis yellow |
| `\|cff7fbfff` | Chat prefix     |
| `\|cff888888` | Muted / caption |

## Performance rules for 3.3.5a

- **Never do a full bag scan per frame.** OnUpdate scripts that run
  every frame must early-return unless an accumulator threshold
  (`elapsed`, interval counter) has elapsed. See `EC_petCheckFrame`
  for the canonical 5-second-tick pattern.
- **`GetItemInfo` returns `nil` for uncached items.** The canonical
  warm-up is a hidden `GameTooltip:SetHyperlink()` which forces the
  client to request the item data. After a short delay, `GetItemInfo`
  will return the real values. `CreateListUI` uses this pattern.
- **Vendor interval floor is 0.05s.** The server disconnects addons
  that hammer the merchant. Do not reduce the floor in
  `DB.vendorInterval` bounds.
- **`wipe(t)` is preferred over `t = {}`** when clearing a table that
  has external references (saved variables, widgets holding a ref).

## Saved variables

Always go through `EnsureDB()`. The function is idempotent and migrates
the legacy `EbonholdStuffDB` on first run. Adding a new field:

```lua
if type(DB.myNewField) ~= "number" then DB.myNewField = 0.5 end
```

Pick the type-tolerant form (`type(...) ~= "expected"`) so manually-
edited saved variables don't corrupt the addon.

Do **not** hard-delete fields when you rename; leave a migration:

```lua
if DB.oldName ~= nil and DB.newName == nil then
    DB.newName = DB.oldName
    DB.oldName = nil
end
```

## Ace3 - decision record

**We do not embed Ace3 in EbonClearance.** Reasoning:

- The addon works and is stable. A library migration is a rewrite, not
  a refactor.
- Ace3 embed is ~200KB of code for an addon that uses maybe 10% of
  the surface.
- 3.3.5a private servers sometimes gate on file sizes or forbid certain
  embedded libs. Shipping plain Lua avoids that friction.

If we ever did migrate, the minimum-viable Ace3 stack for this addon
would be:

| Library              | Replaces                                   |
|----------------------|--------------------------------------------|
| AceAddon-3.0         | The `ADDON_LOADED` / `PLAYER_LOGIN` dance  |
| AceDB-3.0            | `EnsureDB`, profile handling, per-char DBs |
| AceConfig-3.0 +      | Eight manual `InterfaceOptionsFramePanelContainer` |
| AceConfigDialog-3.0  | panels collapse to one options table       |
| AceTimer-3.0         | The four OnUpdate timer frames             |

Use a WotLK-compatible Ace3 revision (r1196–r1249 era; verify
`## Interface: 30300` on the tagged release before embedding).

**What we steal without embedding.** The *shape* of AceConfig's options
table (`type`, `name`, `desc`, `order`, `get`, `set`) is worth
imitating even in vanilla code. If we rebuild our options UI, structure
it as an AceConfig-style table first - future migration becomes a
mechanical substitution.

## Tooling

### StyLua (formatter)

```
stylua EbonClearance.lua            # rewrite
stylua --check EbonClearance.lua    # CI-style verify
```

Config is `stylua.toml`. 4-space indent, 120-column wrap, double
quotes preferred. Matches the existing file style - adopting it
produces no churn.

### Luacheck (linter)

```
luacheck EbonClearance.lua
```

Config is `.luacheckrc`. Goal is zero warnings. If Luacheck flags a
WoW global we actually use, add it to `read_globals` - don't silence
the whole check.

### Qlty-aligned smell gates

Not wired into CI, but enforce in review:

- Functions over 80 LOC → extract helpers. (OnShow / OnUpdate closures
  may exceed this when building UI; prefer to split the init branch
  into a helper, see `BuildMainPanel`.)
- Nesting depth over 4 → flatten with early-return or extract a
  predicate.
- Argument lists over 5 → pack into an options table.
- Identical or near-identical code blocks over 6 lines → extract. See
  `runImport` (import Merge/Replace dedupe) as the canonical example.

## Slash commands

- `/ec` - open the Interface Options panel.
- `/ec profile list|save|load|delete <name>` - profile management.
- `/ec clean` - report items present on more than one list.
- `/ec clean apply` - auto-resolve list conflicts (precedence:
  blacklist > deleteList > whitelist).
- `/ec bugreport` - diagnostic dump for issue reports.
- `/ecdebug` - debug info plus bag scan.

Key bindings (declared in `Bindings.xml`, handlers near the slash
commands):

- `EBONCLEARANCE_TOGGLE_SETTINGS` → `EbonClearance_ToggleSettings()`.
- `EBONCLEARANCE_TOGGLE_ENABLED` → `EbonClearance_ToggleEnabled()`.
- `EBONCLEARANCE_FORCE_SELL` → `EbonClearance_ForceSell()`.

Slash commands and binding handlers are registered at the very bottom
of `EbonClearance.lua`.

## 3.3.5a gotchas

- **Item links.** The only stable part of the hyperlink is the item ID.
  Parse with `link:match("|Hitem:(%d+)")` - do not parse bonus IDs,
  level info, or the post-Legion modifiers. They don't exist here.
- **No `C_Timer.After`.** Use `EC_Delay(seconds, func)`.
- **`GetContainerItemInfo` return signature.** 3.3.5a returns
  `texture, itemCount, locked, quality, readable, lootable, itemLink`.
  Retail reinvented this call three times. Never copy-paste retail.
- **`ChatFrame_AddMessageEventFilter` is global.** Once added, the
  filter runs for every ChatFrame. If you install one, track the
  installation with a module-level boolean (`EC_greedyFiltersInstalled`)
  so a `/reload` doesn't double-register.
- **`PLAYER_ENTERING_WORLD` fires after every zone transition**, not
  just login. Guard expensive one-time work with a `local inited`
  boolean.
- **No `C_Timer`, no `Mixin`, no `SecureHandler` templates** at the
  richness you'd find in retail. If a tutorial assumes those, it's not
  for 3.3.5a.

## Gotchas and refactoring traps

Read this section before touching any of the subsystems below. Each item is
a non-obvious design choice that has silently broken in the past (or would
if you "simplified" it).

### Saved-variable migration order is load-bearing

`EnsureDB()` does two migrations in a specific order that must not be reshuffled:

1. **Legacy rename**: if `EbonholdStuffDB` exists and `EbonClearanceDB` does
   not, rename the former into the latter. This has to happen first because
2. **Profile migration**: when the profile-aware schema first runs, it
   snapshots any existing `DB.whitelist` into an `"Imported"` profile and
   auto-activates it. If the legacy rename hasn't happened yet, `DB.whitelist`
   is empty and the user's pre-profile data is lost.

If you add a new migration, put it with the others at the top of
`EnsureDB()` and write the order dependency into the comment.

### Grey items are always sold, independent of every other setting

In `EC_IsSellable`, three independent predicates (`isJunk`, `qualityPass`,
`whitelistPass`) are ORed together. `isJunk` fires on `quality == 0 and
hasSellPrice`. This means grey items with a positive sell price are *always*
matched -- the quality-threshold toggle and the whitelist have no say.

Do not combine the three passes into "one cleaner check." You will silently
break the grey-always-sold invariant that users and the README rely on. The
only things that can veto a match are `IsEquippedItem(itemID)` and the
blacklist, both of which are safety gates.

### Localisation: `TARGET_NAME` / `PET_NAME` mirror `DB.merchantName` / `DB.scavengerName`

As of v2.9.0 these two file-scope locals are no longer string literals: they
hold the live names which `EnsureDB` (and `EC_compCache.refreshNames`, used
by the Scavenger Settings text inputs) writes from `DB.merchantName` and
`DB.scavengerName`. Defaults are the enUS strings the addon shipped with
through v2.8.0; users can edit them in the Scavenger Settings panel without
having to fork.

Companion lookup is now ID-first via `EC_compCache` - we learn each pet's
creature ID on first successful name match and prefer that ID on every
subsequent lookup. Editing a name in the UI wipes the cache so the next
lookup re-learns. The `spellID == 600126` fallback in
`FindGoblinMerchantIndex` is now the safety net for the case where a user
clears or mistypes the merchant name AND the cache is cold (e.g. fresh
session after the change). If you need to add a similar safety net for the
Scavenger on a future realm, drop a hardcoded `spellID == ...` branch into
`EC_compCache.findByName` mirroring the merchant pattern.

### The `"CRITTER"` companion type covers both pet and merchant

On 3.3.5a, the Goblin Merchant and the Greedy Scavenger both occupy the
`"CRITTER"` companion slot despite one being a vanity pet and the other a
functional merchant. They **cannot coexist**. That's why summoning the
merchant dismisses the Scavenger and vice versa, and why the auto-loot
cycle's `WAITING_MERCHANT` / `SELLING` states explicitly dismiss before
re-summoning.

If you want to add a third `CRITTER` feature, know that it will mutually
exclude with the existing two.

### The auto-loot cycle resets on `MERCHANT_CLOSED`, not before

`EC_lootCycleState` transitions to `IDLE` only when `MERCHANT_CLOSED` fires
(plus the `FinishRun` happy path). If a user dismisses the Goblin Merchant
manually without ever opening the vendor window, the state stays at
`WAITING_MERCHANT` indefinitely, and the 5-second pet-check tick won't
re-summon the Scavenger until either the 8-second reminder timer lapses or
another event resets state.

If you ever add a new "we've given up on this sell" path, also clear
`EC_lootCycleState` to `IDLE` or `LOOTING` explicitly -- don't assume the
normal `MERCHANT_CLOSED` flow will rescue it.

### `EC_Delay` callbacks must surface errors via `geterrorhandler`

The custom `EC_Delay` timer wraps each callback in `pcall`. Without a
follow-up call to `geterrorhandler()(err)`, errors inside delayed callbacks
disappear silently -- which is exactly what hid the v2.0.13 scoping bugs
for several releases.

If you add a new delayed-callback helper (or a new timer frame), route
errors the same way `EC_Delay` does. Do not add new bare `pcall` swallows.

### Delete-list seeding is deliberately empty

`EnsureDB()` still has a `_seededLists` one-shot flag, but the list it used
to seed (item IDs 300581 and 300574) was removed as stale cruft. Empty
delete list on first install is intentional. If a future scenario needs to
pre-populate specific IDs, use the `_seededLists` guard to avoid re-seeding
existing users.

### Stuck-Scavenger detection uses movement time, not distance

`UnitPosition("pet")` does not return data for CRITTER-type companions on
3.3.5a (the `"pet"` unit ID refers to combat pets only). An earlier
`EC_GetCompanionDistance` helper tried to use it but no-opped in practice.

The current detection path is in `EC_HandleScavengerOut`: a per-frame
accumulator (`EC_scavMovementAccum`) sums `elapsed` while the player is
moving (`GetUnitSpeed("player") > 0`) and the Scavenger is flagged as out.
When the accumulator crosses `EC_STUCK_MOVEMENT_THRESHOLD` seconds the
addon dismisses the Scavenger and the next 5 s tick re-summons it at the
player's current position. The accumulator resets on every Scavenger
out↔in transition.

### Stuck detection has two signals; do not collapse them

The movement-time signal above misses kills-and-loots-in-place (AOE
channels, melee in one spot, tight kiting). A complementary signal lives
alongside it: `EC_GreedyEventFilter` records `EC_lastScavSpokeAt` on
every Scavenger speech, `LOOT_CLOSED` pushes timestamps into
`EC_recentLootTimes`, and `EC_IsLootSilenceStuck()` fires when the player
has looted at least 2 corpses inside 60 s without the Scavenger speaking
since the oldest. Both signals OR together inside `EC_HandleScavengerOut`;
the chat output distinguishes which fired so the user knows what happened.

The timestamp recording and the `LOOT_CLOSED` accumulator are both gated
on `DB.autoLootCycle` so cycle-off users pay nothing on the chat-event
path. `EC_recentLootTimes` is pruned in place on every check AND cleared
on Scavenger out↔in transitions in `EC_PetCheckTick`; both clears are
required (the prune bounds growth, the transition reset prevents an
immediate re-fire after a benign respawn).

**Silent-realm guard (v2.10.0+).** The loot-silence signal assumes the
Scavenger pet audibly chats on each loot pickup. On Project Ebonhold
the pet's chat events don't reliably reach the chat filter (verified
across multiple heavy-farming sessions: zero pet-speech messages). The
on-summon synthetic refresh of `EC_lastScavSpokeAt` then resets the
silence clock at every dismiss-and-resummon cycle, producing a
feedback loop where the signal fires every ~60 s of farming. v2.10.0
adds `EC_compCache.scavSpeechEverHeard` (boolean, false at session
start) that is set to true ONLY by real chat-filter matches in
`EC_GreedyEventFilter` (NOT by the on-summon refresh). The
`EC_IsLootSilenceStuck` early-returns false when the flag is unset,
so the signal self-disables on silent realms while preserving the
v2.7.0 / v2.8.0 behaviour on any realm where the pet does broadcast.
The flag is session-scoped (lives on `EC_compCache`, not in
SavedVariables); a `/reload` re-evaluates from scratch.

If you add a third stuck signal, do it the same way: another OR clause
in `EC_HandleScavengerOut`, with its own state cleared on transitions,
and with cause-distinguishing chat output so the user can tell the
signals apart.

### `EC_IsPlayerBusy()` gates every CallCompanion the addon issues (v2.8.0+)

`CallCompanion` goes through WoW's spell-cast pipeline. If the player is
mid-cast, mid-channel, or moving when the addon fires it, the server
silently rejects the call (the spell can't queue into someone else's
cast slot) and *no error is raised*. Worse, on Project Ebonhold a
CRITTER summon issued while the player is moving spawns the pet but
never engages its follow AI -- the critter sits at the spawn point as a
zombie. Stationary heavy-DPS rotations and bag-full mid-combat both
hit this constantly.

`EC_IsPlayerBusy()` checks `UnitCastingInfo("player")`,
`UnitChannelInfo("player")`, and `GetUnitSpeed("player") > 0`. When any
of those are true, the call defers. Three places gate on it:

- `EC_TryResummonScavenger` -- the tick-driven retry path. When
  `EC_addonDismissed = true` and the player is busy, it returns
  without firing; the OnUpdate samples at 1 s instead of 5 s while
  the dismiss flag is set so the next clear window catches faster.
- `SummonGreedyScavenger` -- called from `EC_SummonGreedyWithDelay`
  after every merchant cycle. If busy, it sets `EC_addonDismissed
  = true` and bails out so the tick path picks up recovery.
- `EC_TickGoblinSummon` -- the bag-full Goblin Merchant summon path
  pushes its 1.5 s post-dismiss timer forward by 0.5 s if the player
  is busy, until a clear window opens.

`EC_TickGoblinTarget`'s retry budget (`EC_GOBLIN_MAX_RETRIES = 3`) is
the failure mode for the Goblin path: if three CallCompanion attempts
all miss (e.g. the cast-busy gate keeps firing them but the spell
system rejects them anyway under sustained casting), it gives up and
prints `Goblin Merchant failed to summon. Resuming looting.`.

`EC_IsPlayerBusy()` is defined just above `SummonGreedyScavenger` so
it's reachable as an upvalue from all three gate sites. Don't add a
fourth `CallCompanion` call site without routing it through the gate;
it will silently fail on lossy connections or during heavy combat.

The bare GCD from instant-cast abilities is *not* covered by the gate
(3.3.5a doesn't expose a clean GCD query). The retry-until-confirmed
loops (`EC_addonDismissed` stays true until `EC_PetCheckTick` observes
`scavengerOut = true` on the enumeration) and the Goblin retry budget
compensate.

### `EC_TryResummonScavenger` distinguishes leftover-goblin from user's pet (v2.8.0+)

The Goblin Merchant doesn't auto-dismiss when the merchant window
closes -- it lingers in the CRITTER slot for some time. The naive
`if anyPetOut then return end` guard (designed to respect the user's
manually-summoned bank mule / mailbox) treated this leftover goblin
as a user pet and refused to bring the Scavenger back. Forever.

`EC_PetCheckTick` now tracks a separate `goblinStillOut` flag in its
companion enumeration, set when the in-slot pet matches `TARGET_NAME`
or `GOBLIN_MERCHANT_SPELL_ID`. `EC_TryResummonScavenger` uses
`anyPetOut and not goblinStillOut` as the bail condition, so:

- Slot empty: proceed normally.
- Slot has the Scavenger: skip (already out).
- Slot has the goblin: dismiss it explicitly, then summon Scavenger.
- Slot has anything else (user's third-party companion): respect it.

Don't simplify back to "any pet out → respect"; the leftover goblin is
the common case after every bag-full cycle.

### Caches that mirror server-side state need a `PLAYER_ENTERING_WORLD` bootstrap

`EC_lastScavengerOut` is a forward-declared local that mirrors
server-side companion state. Its declared default is `false`, but the
player can `/reload` with the Scavenger already summoned -- in which
case the gate stays false until the first 5 s tick observes the state.
The OnUpdate accumulator that gates on it then loses ~5 s of counting
-- which is exactly what made Test B fail during the v2.4 quality pass
before the bootstrap landed.

The fix lives in the `PLAYER_ENTERING_WORLD` branch of the event hub:
a one-shot scan via `EC_FindGreedyScavenger()`, guarded by
`EC_scavStateBootstrapped` so it doesn't re-fire on every zone change.

If you add another local boolean that mirrors external/server state
(companion list, merchant list, group state, etc.), bootstrap it the
same way. Trusting the declared default works only when the addon
loaded *before* the state could exist -- which isn't true for `/reload`.

### Manual-dismiss is honoured implicitly: do not try to classify *why* the pet went away

v2.4.0 shipped an `EC_ClassifyScavengerTransition` helper that watched
every Scavenger out→not-out transition at the 5 s tick and used
`GetUnitSpeed("player")` as a heuristic to guess whether the player had
right-clicked the portrait (stationary → "manual dismiss") or the leash
had fired (moving → "auto-resummon"). It set an `EC_userDismissed` flag
that suppressed the re-summon path forever.

**v2.6.1 removed both the helper and the flag.** The premise was wrong:
plenty of non-manual reasons (server-side companion-duration timers,
brief disconnects, loading screens, phasing) cause the pet to despawn
while the player happens to be standing still. Each of those latched
`EC_userDismissed = true` permanently, and nothing the user did short
of an explicit `/ec` re-summon would clear it.

The new contract is simpler:

- `EC_addonDismissed` is the single source of truth. **We** set it when
  **we** dismiss (`DismissGreedyScavenger`, `EC_HandleScavengerOut`,
  the mount-up branch). Anything else -- manual portrait dismiss,
  server despawn, phase change -- leaves it `false`.
- `EC_TryResummonScavenger` only fires when `EC_addonDismissed == true`.
  This naturally honours manual dismisses and benign server despawns
  alike: the addon won't auto-resummon, but the user can trigger it
  themselves via `/ec` or the panel.

If you bring back any heuristic that wants to distinguish manual from
non-manual transitions, weigh the cost carefully. The previous
implementation broke for users on lossy connections; the simpler
"only auto-resummon what we dismissed" rule is correct.

### Mount handler must check actual companion state before dismiss/restore

`DismissGreedyScavenger()` unconditionally sets `EC_addonDismissed = true`
-- that's its contract. If the mount handler calls it when the Scavenger
isn't actually out, the flag is set on a no-op, and the unmount branch
then "restores" something the user actively dismissed.

The `UNIT_AURA` branch in the event hub:

- On mount: only dismiss if `EC_FindGreedyScavenger()` returns
  `isSummoned == true`.
- On unmount: only restore if `EC_addonDismissed`. The mount-up branch
  above is what protects manual-dismiss-before-mount: if the pet wasn't
  summoned at mount-up time, the dismiss is skipped and the flag stays
  `false`, so the dismount branch correctly leaves the pet alone.

If you add a similar dismiss-and-restore around another event
(instance load, vehicle entry, taxi flight), follow the same
"verify-then-act" gate pattern.

### `SummonGreedyScavenger` and `DismissGreedyScavenger` must sync cached state

These two helpers are the addon's authoritative summon/dismiss path.
They write to three module-level locals that the OnUpdate accumulator
and the re-summon gate read on every frame / every tick:

- `EC_addonDismissed` -- dismiss path sets true; summon path clears.
- `EC_lastScavengerOut` -- summon sets true, dismiss sets false. Syncs
  the stuck-detection gate immediately so the OnUpdate accumulator
  doesn't lag the next 5 s tick observation.
- `EC_scavMovementAccum` -- zero on either side; fresh count from the
  new state.

If you add another helper that summons or dismisses the Scavenger,
either call into these two helpers or set all three locals consistently.
A bare `CallCompanion("CRITTER", idx)` that bypasses
`SummonGreedyScavenger` will desync the gate and either over-fire
stuck detection or miss legitimate summons.

### `muteGreedy` is the master flag, not a sibling

In `EC_GreedyEventFilter` and the `EC_bubbleFrame` OnUpdate the
resolution is:

```lua
hideChat    = (DB.muteGreedy == true) or (DB.hideGreedyChat == true)
hideBubbles = (DB.muteGreedy == true) or (DB.hideGreedyBubbles == true)
```

`muteGreedy` ORs into both children. Unticking `hideGreedyChat` or
`hideGreedyBubbles` while `muteGreedy` is on does **nothing** -- the
master forces both children true. The Scavenger Settings panel
exposes all three checkboxes; users will reasonably expect them to be
independent and won't be (this tripped up testing during the v2.4
quality pass).

If you ever split these into truly independent flags, audit
`EC_GreedyEventFilter`'s tail (the `string.find` / `string.match` block
on the Scavenger-name path) and the bubble-kill OnUpdate's guard
accordingly.

### Cross-list conflicts are refused at input time, not just resolved post-hoc

`EC_ScanListConflicts` and `EC_ApplyCleanResolution` (driven by `/ec clean`)
sweep up items present on multiple lists with overlapping intent;
precedence is `blacklist > deleteList > whitelist`. They remain, but they
are a safety net for legacy DBs and imports rather than a routine cleanup
tool.

`EC_FindAddConflict` is the upstream guard. It runs at every add site:
the bag-context single-add inside `EC_AddItemToList`, the panel "Add by
ID" button in `CreateListUI`, the `AddMatchingFromBags` substring scan,
and the `ScanBagsForQuality` bulk-by-quality scan. It refuses adds that
would create a cross-intent conflict and prints which list already holds
the item. Same-intent scopes (per-character `whitelist` + account-wide
`accountWhitelist`, both intent "keep") do not conflict and the add
proceeds normally.

If you add another list or another scope, update both `EC_FindAddConflict`
(its `intentOf` map and the `checks` table) and `EC_ScanListConflicts` so
they stay in sync. Skipping the guard means silent post-hoc cleanups will
surprise the user; skipping the cleaner means legacy or imported data has
nowhere to be detected.

### `DB.blacklistAuto` is a source-tag map, not a second blacklist (v2.10.0+)

The auto-protect-equipped feature stores `{ [itemID] = true }` on
`DB.blacklistAuto`. This map is a **diagnostic tag**, not an additive
blacklist. The actual blacklist-veto predicate (`IsInSet(DB.blacklist, ...)`
inside `EC_IsSellable`) only ever reads `DB.blacklist`; `DB.blacklistAuto`
exists exclusively so `EC_AnnotateTooltip` can append the `(auto-protected:
equipped)` suffix when an entry got onto the Keep list via the equipment
handler instead of a manual user add.

The list is the **Blacklist (Keep)** - i.e. `DB.blacklist`, not
`DB.whitelist`. EbonClearance's naming is inverted from the conventional
"whitelist = allow, blacklist = block" sense: in this codebase
`DB.whitelist` is the SELL list ("items to sell on this character") and
`DB.blacklist` is the KEEP / DO-NOT-SELL list ("items the auto-rules
must never touch"). v2.10.0 originally shipped against the wrong list
and was corrected before tag; do not re-introduce that confusion.

**Three invariants any Blacklist remove path must preserve:**

1. Every `DB.blacklist[id] = nil` must be paired with
   `DB.blacklistAuto[id] = nil` (or a `wipe(DB.blacklistAuto)` for bulk
   wipes). Otherwise the tooltip annotation can claim auto-protection
   for an item the user has explicitly removed.
2. Manual adds (panel UI, slash, Alt+Right-Click context menu) MUST NOT
   write to `DB.blacklistAuto`. Only the equipment handler /
   `EC_compCache.protectEquipSlot` /
   `EC_compCache.syncEquipped` paths stamp it.
3. Profile load wipes `DB.blacklistAuto` alongside `DB.blacklist`. A
   profile snapshot doesn't carry the auto flag, so loading a profile
   starts the auto map from scratch. The profile-clear button (which
   only wipes the live whitelist, not the live blacklist) MUST NOT
   touch `blacklistAuto` - the blacklist itself isn't being cleared.

The 200-local cap influenced the implementation: the helpers
`protectEquipSlot` and `syncEquipped` hang off `EC_compCache` (already a
junk-drawer for v2.9.x state) rather than as module-scope `local function`
declarations. Same pattern as `PROF_LOOT_SPELLS`.

### BAG_UPDATE handler must coalesce bursts (v2.24.0+)

The Greedy Scavenger picking up N items in an AOE pull fires N
BAG_UPDATE events in <100 ms. Any work in the BAG_UPDATE branch that
walks all 5 bags or scans tooltip text per Rare/Epic item compounds:
N events × bag walk = lag spike. v2.22.0 and v2.23.0 each added new
work to the BAG_UPDATE branch without coalescing; the combined cost
hit 1.5 s freezes during AOE farming.

The rule: **BAG_UPDATE must route deferred work through
`EC_compCache.bagUpdateFrame`** (a single shared OnUpdate frame that
waits 120 ms for the burst to settle, then fires the heavy chain
once). Direct calls to `rearmProcessButton`, `checkBagsForUpgrades`,
`HandleAutoOpenContainers`, or `refreshProcessPanel` from inside
the BAG_UPDATE branch are caught by
[tests/test_perf_guardrails.lua](../tests/test_perf_guardrails.lua).

The one exception is `EC_HandleBagFullForCycle`, which stays
synchronous because its internal 1.5 s hysteresis already debounces
and the bag-full cycle wants the first trip across the threshold
without extra delay.

Two adjacent rules in the same vein:

1. **Heavy per-bag-walk helpers should be gated on whether the user
   is actively using the feature.** `rearmProcessButton` early-returns
   when `panel:IsShown() == false` AND `GetBindingKey(...)` returns
   nil. Users who never open Process Bags pay zero cost. The hold-
   key-to-drain workflow still works because the keybind check keeps
   the rearm running when a binding exists.

2. **Per-instance affix scans must cache by `itemString`, not by
   `itemID`.** Two stacks of the same itemID can carry different
   affix rolls; the suffix-DBC field in the link distinguishes them.
   `bagSlotAffixData` follows this pattern via
   `EC_compCache.affixDataCache`.

### Bind-type detection shares `EC_scanTooltip` (v2.10.0+)

The per-rarity `bindFilter` rule reads bind type via the same hidden
`EC_scanTooltip` frame the openable-container check uses. `EC_compCache.getBindType`
returns `"boe"`, `"bop"`, or `"any"` and stamps `EC_compCache.bindCache`
to avoid rescanning on every bag walk.

Strings matched (`Binds when picked up`, `Soulbound`, `Binds when equipped`)
are enUS only. EbonClearance's L10n posture is enUS-only on Project
Ebonhold; if the project ever ships a localised realm, this scanner needs
the same treatment as `ITEM_OPENABLE` / `LOCKED` in `EC_IsOpenable`.

Items with no bind line at all (consumables, reagents, trade goods, quest
items) return `"any"`. Critically, `"any"` is matched by neither `"boe"`
nor `"bop"` filters - so a `BoE only` rule on Blue does NOT sweep up
reagents that happen to be blue quality. This matches user mental model
("sell BoE blues only" should not touch reagents) and is the reason the
filter check is INSIDE the `qualityPass` branch, not outside it.

### PE affix detection uses three sources, not one (v2.23.0+)

The affix-protection system (`protectAffixedRareItems`) and the v2.23.0
exact-rank dupe gate (`affixAllowExactDupes`) lean on three independent
signals:

1. **Item title rank-suffix** - `parseAffixFromTitle` checks whether the
   live tooltip title ends with a roman-numeral suffix (` I` / ` II` /
   ` III` / ` IV`) and differs from `GetItemInfo`'s base name. This is
   the presence discriminator; it gates the protection rule. Standard
   `ItemRandomSuffix.dbc` entries (`of the Bear`, etc.) don't end with
   roman numerals, so they aren't false-positive protected. (v2.20.0
   narrowing.)

2. **`@affix@`-wrapped tooltip line** - PE wraps each affix's effect
   text with literal `@affix@` sentinel markers in the raw tooltip
   text. EC's private `EC_scanTooltip` sees the markers intact;
   `scanTooltipForAffixDesc` strips them on Path 1. The live
   GameTooltip has these markers replaced by PE's tooltip
   post-processor (purple coloured text instead), so the same parser
   needs a Path 2 fallback.

3. **Player's spellbook (the "Affixes" tab)** - extracting an affix
   adds an engraving spell (e.g. `Spirit Surge II`) to the player's
   spellbook. `refreshKnownAffixes` walks every tab via
   `GetSpellTabInfo`, scans each spell's tooltip for the
   `engrave this affix on any equippable item:` prefix, and stores the
   description text after the colon (normalised) as the canonical
   match key. Refresh fires on `LEARNED_SPELL_IN_TAB` and
   `SPELLS_CHANGED`.

4. **`_G.ExtractionService.learnedAffixes` (v2.26.0+)** - PE exposes a
   global catalog of every extractable affix and chance-on-hit proc as
   an array of `{id, name, learned, weaponOnly, ...}` records.
   `refreshKnownAffixes` merges entries where `learned == true` into
   the same description map, using a per-spell-ID tooltip cache
   (`procIdToDescription`) so each engraving description is scanned at
   most once per session. The dirty-check helper
   `refreshExtractionIfDirty` is wired into the 120 ms BAG_UPDATE
   debounce frame and `PLAYER_REGEN_ENABLED`; it counts learned
   records and skips the rebuild when the count is unchanged. This
   catches procs PE keeps outside the spellbook and is the source
   that drives the v2.26.0 chance-on-hit dupe gate
   (`chanceOnHitAllowExactDupes`). The catalog is global, not under
   `_G.ProjectEbonhold`.

The three sources do NOT share names. The item-suffix name
(`of Inner Light`) and the engraving-spell name (`Spirit Surge II`)
are different strings - PE uses cosmetic suffixes that don't map to
the spell. The bridge is the EFFECT TEXT, which appears verbatim on
both sides:

- Bag tooltip: `@affix@ Increases your total Spirit by 6%.@affix@`
- Spell tooltip: `Allows you to engrave this affix on any equippable item: Increases your total Spirit by 6%`

Both normalise to `Increases your total Spirit by 6%`. Rank semantics
are organic: rank I says `3%`, rank II says `6%`, etc., so a
description match implies an exact-rank match.

**Do NOT use `ProjectEbonhold.PerkService.GetGrantedPerks()`** for
affix lookup. That returns RUN PERKS (run-time roguelite ability
selections like "Agility Boost", "Warm-Blooded") - a different system
from item-engraving affixes. v2.23.0 development burned a cycle on
this; the diff is recorded in commit history.

**Two normalisation hazards** future contributors should know:

- **Color codes**: the live GameTooltip's affix line carries
  `|cff...|r` purple formatting. `normaliseAffixDesc` strips them.
- **`Stacks with other ranks.` disclaimer**: stat affixes (Spirit,
  Armor, Strength, ...) have this disclaimer sentence appended to
  their bag-tooltip line that isn't on the engraving-spell side. Both
  `scanTooltipForAffixDesc` Path 2 and `playerHasAffixDescription`
  fall back to a first-sentence trim (`txt:match("^(.-)%.%s")`) to
  match against the set. Proc affixes (`Your X may...`) with embedded
  mid-sentence periods rely on the full-line match.

Diagnostic commands `/ec affixdump`, `/ec affixfind <text>`, and
`/ec procdump` are undocumented but useful for inspecting the known
set when chasing match failures.

### Allow Sell override (v2.26.0 / v2.27.0)

The auto-dupe gate (`affixAllowExactDupes`) is a global toggle that
auto-releases items whose affix description appears in the known set.
For cases where the auto-detect can't bridge (chance-on-hit procs
have no client-side identity bridge to PE's catalog; vanilla items
have no random suffix) the user can manually mark an item via
Alt+Right-Click -> `Allow Sell`. Three account-wide tables back this:

1. **`ADB.allowedItems[itemID]`** - chance-on-hit items. The proc is
   bound to the item identity for vanilla items, so per-itemID is the
   right grain. v2.26.0 originally called this `allowedProcs`; the
   `EnsureAccountDB` migration carries the data forward.
2. **`ADB.allowedAffixes[normalised_description]`** - random-affix
   items. The affix description IS the identity (per-instance roll),
   so per-itemID would be too coarse. Marking Orb of Mistmantle
   (Inner Light II) writes the `Increases your total Spirit by 6%`
   description; any future drop with that affix on any base item
   passes.
3. **`ADB.affixedListedItems[itemID]`** - side meta. Flagged when an
   affixed-item-instance is added to a Sell/Keep/Delete list via the
   Alt+Right-Click menu. Lets the list panels render an
   `(affix-gated)` tag on those rows so the per-itemID list entry
   doesn't read as "blanket sell every drop" (the affix protection
   still filters per-drop).

The menu hides Sell/Keep/Delete list rows while an item is protected
(`procProtected = hasProtection AND not itemAllowed`), forcing the
user to consciously pick `Allow Sell` before adding to a sell rule.
Once allowed, the full menu opens up and the `sellNow` row becomes
`Remove from Allow List` (orange, toggle).

Tooltip annotation priority (`Will Sell -` labels get replaced by):

- `Allowed - Delete` / `Allowed - Account Sell` / `Allowed - Character Sell` when on the corresponding list AND allowed
- `Allowed - Choose List` when manual-marked but not on any list (call to action)
- `Allowed - <name> rank N already known` when auto-dupe-allowed AND not on any list
- `Protected - Random affix` / `Protected - Chance on hit` when unmarked
- Keep List membership wins everything (the Protected / Auto-Protected label stands)

Diagnostic: `/ec procdump` walks bags for the first chance-on-hit
item, prints the `HasRandomProperty(link)` gate result and the
result of `findLearnedAffixForItem(link)` (a port of PE's own
algorithm from `extraction.lua`).

### Index of magic numbers

| Value | Location | Meaning |
|---|---|---|
| 0.05s | vendor worker OnUpdate | Per-item pacing floor. Below this, the server boots you for packet spam. |
| 5s | `EC_PET_CHECK_INTERVAL` | Cadence for pet-check tick (state sync, stuck detection, re-summon). |
| 180s | `EC_STUCK_MOVEMENT_THRESHOLD` | Player time-spent-moving after which the Scavenger is dismissed-and-resummoned (stuck-on-terrain detection). Was 20 s in v2.4-v2.6.0, briefly 60 s in early v2.6.1 testing, settled at 180 s after in-game UX feedback -- below that the dismiss fired during normal kill-loot-move questing cadence. |
| 60s | `EC_IsLootSilenceStuck` (inline `WINDOW`) | Window over which the loot-silence stuck signal evaluates. Player must have looted at least `MIN_LOOTS` corpses inside this window without hearing the Scavenger speak before the signal fires. |
| 2 | `EC_IsLootSilenceStuck` (inline `MIN_LOOTS`) | Minimum corpse loots inside the loot-silence window before the signal can fire. Floor of 2 prevents a single-corpse false positive. |
| 80 items | `maxItemsPerRun` | Sell-queue cap per run. Prevents the same disconnect risk as the vendor-interval floor. Recursive batching kicks in for larger inventories. |
| 1.5s | `EC_summonGoblinTimer` | Wait between dismiss and Goblin Merchant summon so the client has time to process the companion switch. |
| 2.0s | `EC_targetGoblinTimer` | Wait after summon before checking `isSummoned` via `GetCompanionInfo`. |
| 8.0s | `EC_merchantReminderTimer` | Gap before we remind the user to right-click the merchant (or use their keybind). |
| 10s | `EC_mountDismissTime` cooldown | Suppress pet re-summon within 10s of a mount-dismount to avoid cancelling the mount cast. |
| 600126 | `GOBLIN_MERCHANT_SPELL_ID` | Companion spell ID for the Goblin Merchant, used as the localisation escape hatch. |

If you change any of these, update this table and the nearest comment.

### Bag display: sell-border tint (v2.29.0+)

The opt-in slot-border tint draws an additive ring around bag slot frames whose items the rule chain would sell. Three invariants every contributor touching this code must preserve:

1. **Every button that goes through `EC_compCache.applySellBorder` MUST be added to `EC_compCache.sellBorderButtons`**, regardless of the current `willSell` verdict. The registry is the lookup the settings-flip refresh uses; if a button never enters it (e.g. because its first paint was `won't sell`), the refresh can't find it later when the verdict flips. Before v2.29.0 only buttons that received a texture entered the registry; the fix was to track unconditionally. Don't gate the registry insert on `willSell` again.

2. **The host bag-UI adapter MUST install at `ADDON_LOADED` for the host addon, not at `PLAYER_LOGIN` plus a delay.** The host builds its slot class during its own load pass; by the time `PLAYER_LOGIN` plus a 2-second delay fires, the host may already have painted its first set of slots without our hook in place, and those slots stay un-decorated until something else triggers an update. Installing at the host's `ADDON_LOADED` puts our hook in BEFORE the host can build any bag-display frames. The `PLAYER_LOGIN`-deferred install path is kept as an idempotent fallback only.

3. **The ring texture sits on `OVERLAY` sublevel 6 with `BlendMode("ADD")`.** This is deliberately above the host bag-UI's own quality border (sublevel 0) so the two compose additively — a Blue/Rare quality border + an EC sell-border tint read as both colours layered, not one fighting the other. Don't drop the sublevel or change the blend mode without considering how the composition will read.

Anything that mutates the verdict of a bag slot — list adds/removes, allow-list mutations, settings pack imports, colour picks, the master toggle — MUST call `EC_RefreshSellBorders()` after the mutation. The helper is a no-op when the toggle is off, so calling it from a mutation site that isn't gated on the toggle is cheap and correct.

### Affix description normalisation: case-folds (v2.29.0+)

`EC_compCache.normaliseAffixDesc` strips colour codes, `@affix@` markers, leading/trailing whitespace, trailing sentence punctuation — AND case-folds via `:lower()` at the end. The case-fold is load-bearing: at least one rank-I affix description in Project Ebonhold ships with a lowercase opening letter while rank-II / rank-III ship with a capital, and the comparison would miss otherwise.

If you ever remove the `:lower()` you must ALSO revert the one-shot migration in `EnsureAccountDB` that lowercases existing `ADB.allowedAffixes` keys, because the migration assumes the normaliser produces lowercase output. The pair is idempotent on the current normaliser; reverting one side without the other breaks Allow Sell for users who marked affixes under the old (mixed-case) normaliser.

`Stacks with other ranks.` disclaimer hazard from the v2.23.0 design is unchanged; the first-sentence-trim fallback in `scanTooltipForAffixDesc` Path 2 and `playerHasAffixDescription` still handles it.

### List-mutation must call `EC_RefreshSellBorders`

Every site that writes to `DB.whitelist`, `DB.blacklist`, `DB.deleteList`, `ADB.whitelist`, `ADB.allowedItems`, or `ADB.allowedAffixes` MUST follow the write with `EC_RefreshSellBorders()`. The helper is forward-declared as a no-op stub at file head and reassigned with the real body once the F2 hooks land further down; the call is safe at any file position.

Current sites that do this correctly:
- `EC_AddItemToList` and `EC_RemoveItemFromList` (Sell / Keep / Delete / Account Sell)
- The Alt+Right-Click `Allow Sell` / `Remove from Allow List` click handlers (chance-on-hit and random-affix)
- The Character Settings slot-border colour picker (commit callback)
- The `importFullPack` deserialiser

If you add a new mutation site without calling the refresh helper, the slot-border ring goes stale until the user closes and reopens their bags. The proposed test (`tests/test_no_addon_references.lua` companion check, see CODE_REVIEW.md) catches this at CI time.

### No third-party addon references in new EC artefacts (v2.29.0+)

EC's shipped artefacts MUST NOT name, mention, or compare against any other addon in NEW code or docs. This includes code comments, commit messages, `CHANGELOG.md`, `README.md`, this file, slash command help text, the `/ec bugreport` output, settings-panel labels, and tooltip annotations.

Allowed alternatives when integration code genuinely needs to be discussed:
- "Host bag UI integration" / "third-party bag UI adapter"
- "Cross-character inventory data source (when available)"
- "Optional external data backend"
- "Detected at runtime via the `_G` lookup; ungated when absent"

The runtime detection still calls the specific global (`_G.Bagnon`, `LibStub("AceAddon-3.0"):GetAddon("AdiBags")`, etc.) — that's necessary for the API to work — but the comment explaining what's happening uses neutral framing.

**Existing mentions stay.** Pre-v2.29.0 comments in `EbonClearance.lua` and entries in `NOTICE.md` / older `README.md` changelog stanzas remain untouched. The rule is forward-only.

Rationale: EC reads as a self-contained piece of engineering, not a synthesis or a port. Comments explain WHY a piece of code exists and HOW it works, never "where the idea came from". Borrowing another addon's terminology in EC comments dilutes that voice and signals derivation where the implementations are EC-native.

## Fingerprint and watermark

EbonClearance carries a deliberate, visible fingerprint mechanism so
verbatim copies of the source or the export-string format can be
mechanically detected. Three pieces:

1. **`EC_FINGERPRINT_SALT`** at the top of `EbonClearance.lua`. A
   project-specific string. **Do not** "clean up", refactor, rename,
   or shorten this constant; its presence in code is the point. Any
   addon source containing this exact string is a verbatim copy.
2. **`EC_Fingerprint(payload)`** helper. djb2-style 24-bit hash
   folded into 6 hex chars, salted with the constant above. Used
   for both the watermark and export strings.
3. **`__EbonClearance_watermark`** global. Set at addon load to
   `EC_Fingerprint("EbonClearance@" .. ADDON_VERSION)`. Visible to
   `/run` and to external auditors. The hex value is reproducible:
   for any version, run the salted hash on
   `"EbonClearance@" .. version` and confirm.

Export strings carry a `;fp=<6 hex>` suffix produced by
`EC_Fingerprint` over the export payload. Imports tolerate strings
with or without the suffix (back-compat with hand-edited and
pre-fingerprint exports); imports do **not** verify the fingerprint
or warn on a bad one. The fingerprint exists to mark our exports
**going out**, not to police imports coming in.

Convention for future agents and contributors:

- Do not normalise, refactor, rename, or remove the salt constant
  or the helper. They are intentional artefacts.
- Do not add a fingerprint-verification step on import. This is a
  considered design choice (see `EC_StripFingerprint` and the
  comment above it).
- If we ever need a per-export-type fingerprint (profiles, settings,
  etc.), reuse `EC_Fingerprint` rather than introducing a second
  hash function. One salt, one helper, one mechanism.
- Section 2(d) of the LICENSE lists `__EbonClearance_watermark`
  alongside the other provenance globals as required-to-preserve in
  derivatives. Adding a new provenance global means updating
  LICENSE 2(d) and `NOTICE.md`.

The convergent prior-art story for the broader provenance pattern
(`__<addon>_origin` / `__<addon>_author`) is documented in
[`NOTICE.md`](../NOTICE.md). Read that before assuming we invented
either pattern.

## File split - in progress

The single-file layout was kept until the 200-locals cap started forcing
helpers onto `EC_compCache` for the wrong reasons (the table existed to
work around the cap; it accreted into the de-facto module namespace).
Triggers that finally crossed the line:

- File grew past 11,800 LOC (the documented 8K threshold below was
  conservative and was rebuilt mid-flight to the 12K mark before the
  split started).
- The 200-locals cap was hit during v2.29.0 release work twice in a
  single feature - any further module-level local additions now require
  an `EC_compCache` placement or another existing slot to be freed.
- `EC_compCache` had grown to 50+ entries, many of them helpers that
  belong as their own file's locals, not table fields.

The split is a multi-stage internal refactor. Stages are commit-only;
they do NOT bump `ADDON_VERSION` or get their own version tags, because
they ship no user-facing behaviour change. `ADDON_VERSION` stays frozen
at whatever the last feature release was (currently v2.29.0) for the
duration of the split. See docs/CODE_REVIEW.md item 4 for the staged
schedule. Don't mix feature work into a split stage.

### Stage 1: namespace bootstrap (commit `8201442`)

Stage 1 is purely additive. It introduces the shared namespace table
WoW addons use for cross-file state without moving any code:

```lua
local NS = select(2, ...)
```

`select(2, ...)` is used instead of `local addonName, NS = ...` because
the main chunk is at the 200-locals cap; capturing only the second
vararg spends one slot instead of two. WoW passes
`(addonName, namespaceTable)` as the file-load varargs to every `.lua`
file in an addon; the same table is shared across files.

The first thing the bootstrap does is mirror the existing
`EC_compCache` table onto `NS.compCache`. Both names alias the same
memory. Existing call sites continue to use the `EC_compCache` upvalue;
future split files will reach the table via `NS.compCache` without any
churn at existing call sites.

Stage 1 invariants (enforced by `tests/test_perf_guardrails.lua` Test 28):

- The `local NS = select(2, ...)` bootstrap line is present at the top
  of every shipped source file (count >= number of files in the test's
  `SOURCE_PATHS` list).
- `NS.compCache = EC_compCache` appears immediately after the
  `EC_compCache` table literal closes.
- `EC_compCache` has exactly ONE table-literal declaration AND exactly
  ONE re-alias declaration across all shipped sources - shadowing
  literals would silently desync NS.compCache, and a missing re-alias
  would leave EbonClearance.lua's `EC_compCache.foo` references
  resolving to global nil.

### Stage 2: extract EbonClearance_Core.lua (commit `119eca8`)

Stage 2 moves the smallest set of chunks that have no dependencies on
the rest of the file:

- The provenance globals block (`EBONCLEARANCE_*` and `__EbonClearance_*`
  `_G` writes) and the `ADDON_AUTHOR` / `ADDON_URL` locals that back them.
  Both are also exposed on the namespace as `NS.ADDON_AUTHOR` /
  `NS.ADDON_URL` so the settings byline (still in EbonClearance.lua)
  re-aliases them.
- The `EC_Fingerprint` helper, exposed as `NS.Fingerprint`. The two
  export call sites in EbonClearance.lua now call `NS.Fingerprint(payload)`
  directly (no re-alias - cold-path, only fires when the user clicks
  Export, so the table-index lookup is free).
- The `EC_compCache` table literal. Exposed as `NS.compCache`.
  EbonClearance.lua keeps a file-scope `local EC_compCache = NS.compCache`
  re-alias so the ~50+ `EC_compCache.foo` call sites resolve to the
  same table via upvalue.

Things that did NOT move in Stage 2 (deliberate):

- `ADDON_VERSION` - the CI release workflow's `sed` rule targets the
  `local ADDON_VERSION = "..."` line by file path. Moving it would
  require a `.github/workflows` change; deferred to a later split stage.
- `EC_GetVersion` and the watermark `_G` write - both depend on
  `ADDON_VERSION`, so they stay where `ADDON_VERSION` is.
- API cached upvalues, `STATE`, forward declarations, `EnsureDB`,
  `EC_Delay`, session stats - planned for a later stage. Moving them
  requires either re-aliasing on the EbonClearance.lua side (one local
  slot each) or rewriting call sites (large diff). Pacing matters more
  than blast radius here.

Slot accounting on EbonClearance.lua's main chunk:

- Removed: `ADDON_DISPLAY` (already done in Stage 1), `EC_Fingerprint`,
  `ADDON_AUTHOR` was inline but is now a re-alias from `NS.ADDON_AUTHOR`
  (still one slot), `ADDON_URL` likewise.
- Net slot delta: -1 (the `EC_Fingerprint` function definition).

Stage 2 invariants (enforced by `tests/test_perf_guardrails.lua` Test 28):

- Concatenated source contains AT LEAST one `local NS = select(2, ...)`
  per file listed in `SOURCE_PATHS`.
- Exactly one `local EC_compCache = { ... }` (the table literal, now
  in Core).
- At least one `local EC_compCache = NS.compCache` re-alias per
  consumer file (EbonClearance.lua post-Stage-2; EbonClearance_Companion.lua
  post-Stage-3; more files in later stages).
- `NS.compCache = EC_compCache` appears exactly once (still in Core,
  immediately after the table literal).

### Stage 3: extract EbonClearance_Companion.lua (commit `987b5b5`)

Stage 3 moves the contiguous chat-filter / speech-bubble killer cluster
out of EbonClearance.lua (previously lines ~164-446):

- `EC_StripCodes`, `EC_IsGreedyAuthor`, `EC_TrackGreedySpeech` (helpers
  internal to the chat filter).
- `EC_greedyMessages` table + `EC_greedyFiltersInstalled` boolean
  (Companion-only session state).
- `EC_GreedyEventFilter` (per-chat-event mute + Scavenger-speech tracker).
- `EC_InstallGreedyMuteOnce` (one-shot install on 10 chat events).
  Exposed as `NS.InstallGreedyMuteOnce`.
- `EC_bubbleFrame` OnUpdate (200 ms WorldFrame walker + 8 s TTL speech
  window + weak-table kill set).
- `CHAT_FILTER_EVENTS`, `GreedyScavengerChatFilter`, `ApplyGreedyChatFilter`
  (secondary chat-filter system). `ApplyGreedyChatFilter` exposed as
  `NS.ApplyGreedyChatFilter`.

Cross-file plumbing added in this stage:

- `EC_lastScavSpokeAt` was a file-scope local read by both the chat
  filter (now in Companion) and `EC_IsLootSilenceStuck` (still in
  EbonClearance.lua). **Promoted to `EC_compCache.lastScavSpokeAt`**
  so both files reach it via the shared cache table. Initial value
  declared next to `scavSpeechEverHeard` in Core.
- `EnsureAccountDB` now writes `NS.ADB = ADB` and `EnsureDB` writes
  `NS.DB = DB` so Companion's chat filter can read the live binding
  inline (`local DB = NS.DB` at function entry).
- The PET_NAME_LC / PET_NAME / TARGET_NAME refresh sites (initial
  init in EbonClearance.lua, EnsureDB body, and `EC_compCache.refreshNames`)
  all mirror onto `NS.PET_NAME_LC` etc. Companion's `EC_IsGreedyAuthor`
  reads `NS.PET_NAME_LC` inline so localised / renamed pets work.

Four call sites in EbonClearance.lua were updated:

- `ApplyGreedyChatFilter()` -> `NS.ApplyGreedyChatFilter()` (settings
  toggle in the chat-mute checkbox; ADDON_LOADED branch).
- `EC_InstallGreedyMuteOnce()` -> `NS.InstallGreedyMuteOnce()`
  (PLAYER_LOGIN branch; MERCHANT_SHOW branch).

Stage 3 invariants (enforced by `tests/test_perf_guardrails.lua` Test 29):

- `NS.InstallGreedyMuteOnce` and `NS.ApplyGreedyChatFilter` are both
  published by Companion at file-load time.
- No bare `EC_InstallGreedyMuteOnce()` or `ApplyGreedyChatFilter()`
  call sites exist (definition lines in Companion are masked from
  the scan).
- `EnsureDB` writes `NS.DB = DB`.
- Every site that rebinds `PET_NAME_LC` mirrors onto `NS.PET_NAME_LC`.

### Stage 4: extract EbonClearance_Protection.lua (commit `9d65e64`)

Stage 4 moves the PE-protection detection cluster previously in
EbonClearance.lua at lines ~1817-2477:

- **PE random-affix detection** - `linkHasAffix`, `romanToInt`,
  `parseAffixFromTitle`, `scanTooltipForAffixDesc`, `normaliseAffixDesc`,
  `bagSlotAffixData`, `bagSlotHasAffix`, `liveTooltipAffixData`,
  `liveTooltipHasAffix`. The `ROMAN_VALUES` lookup table and the
  `affixDataCache` (per-itemString) live here too.
- **PE engraving / affix-catalog integration** - `knownAffixDescriptions`
  table, `peDetected`, `refreshKnownAffixes`, `refreshExtractionIfDirty`,
  `playerHasAffixDescription`. The `AFFIX_SPELL_PREFIX` literal, the
  `knownExtractionVersion` dirty counter, and the `procIdToDescription`
  cache also live here.
- **PE chance-on-hit detection** - `lineLooksLikeChanceProc`,
  `itemHasChanceOnHit`, `liveTooltipHasChanceOnHit`.
- **PE Anvil bridge** - `findLearnedAffixForItem` plus
  `itemAffixLookupCache` (per-itemLink).

Every helper is attached to `EC_compCache` (Core's table, exposed as
`NS.compCache`). Call sites elsewhere in the addon already resolve
through the shared `EC_compCache` upvalue, so this move required NO
call-site changes anywhere in EbonClearance.lua.

Cross-file plumbing added in this stage:

- `NS.scanTooltip` is written by EbonClearance.lua immediately after
  the `EC_scanTooltip` frame is created. Protection's helper bodies
  dereference `NS.scanTooltip` lazily inside the function body via a
  `scanTip()` accessor (Protection loads BEFORE EbonClearance.lua's
  main chunk, so an upvalue capture at Protection's load time would
  store `nil`; by the time any of these helpers is first CALLED,
  EbonClearance.lua has finished its main chunk).
- The named `GameTooltip` frame stays in EbonClearance.lua because it
  has non-protection callers (auto-open container detection, bug-report
  builder, Process Bags mode detection, bind-type cache).

Stage 4 invariants (enforced by `tests/test_perf_guardrails.lua` Test 30):

- 17 protection helpers stay attached to `EC_compCache` and are not
  shadowed by a module-level `local function NAME(...)` definition.
- `EbonClearance.lua` writes `NS.scanTooltip = EC_scanTooltip`
  immediately after creating the frame.

### Stage 5: extract EbonClearance_Vendor.lua (commit `08c3893`)

Stage 5 is deliberately scoped narrowly. The full vendor cycle
(`EC_IsSellable`, `BuildQueue`, `DoNextAction`, `worker`, `StartRun`,
`EC_manualSell`, `EC_PreviewSellable`) is interleaved with bag-display
helpers (Stage 6 target) AND has wide cross-file dependencies on
EbonClearance.lua-side helpers (`PrintNice`, `EC_Delay`, `EC_session`,
`EC_lootCycleState`, `STATE`, `EC_GetItemPrice`, ...). Moving the whole
thing in one stage requires either a large NS-exposure blast or
function-entry capture boilerplate at every entry point.

Instead, Stage 5 establishes the Vendor file with the smallest
self-contained subsystem and leaves the rest for future stages.

What moved in this stage:

- **`HookDeletePopupOnce`** (the StaticPopup1 DELETE_* auto-confirm
  driver) + its install-once gate `deletePopupHooked`. Exposed as
  `NS.HookDeletePopupOnce`.

What was promoted (Stage 5 prep, both inside this same diff):

- **`running`** -> `EC_compCache.vendorRunning` (vendor cycle gate).
  Cross-cutting readers in 5+ non-vendor handlers in EbonClearance.lua
  all read the new cache field; future Vendor-extraction stages can
  write to the same field from their new home.
- **`pendingDelete`** -> `EC_compCache.pendingDelete` (deletion-popup
  state). Written by `HookDeletePopupOnce` (now in Vendor) AND by
  `DoNextAction` (still in EbonClearance.lua); cleared at
  MERCHANT_CLOSED (event hub in EbonClearance.lua). Cache promotion
  was needed because the writers + clearer ended up in different files.

What did NOT move (future stage targets):

- `EC_IsSellable`, `BuildQueue`, `FinishRun`, `DoNextAction`, `worker`,
  `EC_IsMerchantAllowed`, `EC_PreviewSellable`, `StartRun`,
  `EC_compCache.isQuestItem` (the merchant cycle itself).
- `EC_manualSell` table + methods (manual-sell attribution via
  `hooksecurefunc("UseContainerItem", ...)`).
- The bag-display helpers (`sellBorderButtons`, `applySellBorder`,
  `bagSlotWillSell`, `updateSellBordersForBagFrame`,
  `installHostBagBorderHook`, the `EC_RefreshSellBorders` body,
  `qualityNames`, `describeSellability`, `printSellabilityTrace`,
  `bagSlotFromButton`) which are physically interleaved with vendor
  code in EbonClearance.lua but belong in Stage 6 (BagDisplay).

Future "Stage 5b" / "Stage 5c" will extract those incrementally as
their cross-file dependencies are sorted (probably by exposing the
helpers they call on `NS` one cluster at a time).

Stage 5 invariants (enforced by `tests/test_perf_guardrails.lua` Test 31):

- `NS.HookDeletePopupOnce` exposed by Vendor at file load.
- No bare `HookDeletePopupOnce()` call sites (every call NS-qualified).
- `EC_compCache.vendorRunning` initialised to `false` in Core's table
  literal.
- `EC_compCache.pendingDelete` initialised to `nil` in Core's table
  literal.
- No file-scope `local running` or `local pendingDelete` lurking
  anywhere in the shipped sources (either would silently desync from
  the cache field).

### Stage 6: extract EbonClearance_BagDisplay.lua (commit `5c9399b`)

Stage 6 moves the Release-1 bag-display layer (sell-border tint +
sellinfo predicate-trace inspector) out of EbonClearance.lua to a new
`EbonClearance_BagDisplay.lua`. The block is contiguous (no Stage-5-style
straddling), all helpers are on `EC_compCache`, so call sites elsewhere
in the addon already resolve via the shared cache.

What moved:

- **Sell-border tint helpers**: `EC_compCache.sellBorderButtons`
  (weak-keyed registry), `applySellBorder`, `bagSlotWillSell`,
  `updateSellBordersForBagFrame`, `installHostBagBorderHook`. The
  opt-in coloured ring around bag-slot frames whose items would be
  sold at the next vendor visit. Hooks default `ContainerFrame_Update`
  AND any host bag UI's per-slot class detected at runtime via LibStub.
- **`NS.RefreshSellBorders` real body** (settings-flip repaint). The
  forward-declared stub stays in EbonClearance.lua; this file replaces
  it with the actual body that walks `sellBorderButtons` and re-applies.
- **`EC_compCache.qualityNames`** lookup table.
- **Sellability-trace inspector**: `describeSellability` +
  `printSellabilityTrace`. Drives `/ec sellinfo` and Alt+Shift+Right-Click.
- **`bagSlotFromButton`** helper.

Cross-file API surface added in this stage:

- **`EC_RefreshSellBorders` promoted from a file-scope local to
  `NS.RefreshSellBorders`.** The stub-and-reassign pattern needed to
  cross the file boundary; a `local` in EbonClearance.lua would mean
  BagDisplay's assignment creates a global instead of replacing the
  stub. 14 reference sites (7 call sites × the `if foo then foo() end`
  guard pattern) substituted from `EC_RefreshSellBorders` to
  `NS.RefreshSellBorders` in code-only positions.
- **`NS.IsSellable = EC_IsSellable`** published right after the
  EC_IsSellable definition. BagDisplay's `bagSlotWillSell` and
  `describeSellability` consult it via `NS.IsSellable`.
- **`NS.PrintNice = PrintNice`** and **`NS.PrintNicef = PrintNicef`**
  for the sellinfo trace's chat output.

**Load order is load-bearing.** `.toc` order is `Core → Companion →
Protection → Vendor → EbonClearance.lua → BagDisplay`. BagDisplay loads
AFTER EbonClearance.lua because EbonClearance.lua's stub
`NS.RefreshSellBorders = function() end` would otherwise OVERWRITE
BagDisplay's real body if it loaded second. Reversed order = silently
broken sell-border refresh. Test 33 enforces this ordering.

Stage 6 invariants (enforced by `tests/test_perf_guardrails.lua` Test 33):

- `NS.RefreshSellBorders` stub declared in EbonClearance.lua's
  forward-decl block.
- BagDisplay reassigns `NS.RefreshSellBorders` with the real body.
- All 9 named bag-display helpers (`sellBorderButtons`, `applySellBorder`,
  `bagSlotWillSell`, `updateSellBordersForBagFrame`,
  `installHostBagBorderHook`, `qualityNames`, `describeSellability`,
  `printSellabilityTrace`, `bagSlotFromButton`) present in BagDisplay
  AND attached to `EC_compCache`.
- `.toc` loads BagDisplay AFTER EbonClearance.lua.
- No bare `EC_RefreshSellBorders()` call sites anywhere.

### Stage 7: extract EbonClearance_Process.lua (commit `a24be7d`)

Stage 7 moves the Process Bags ENGINE out of EbonClearance.lua. The
Process Bags PANEL (UI side) stays in EbonClearance.lua for Stage 8
because it pulls in a dense web of UI-building helpers (`MakeHeader`,
`AddCheckbox`, `CreateListUI`, `EC_FitScrollContent`,
`EC_WrapPanelInScrollFrame`, `EC_compCache.initPanel`, etc.) that
themselves haven't moved yet.

Moved into `EbonClearance_Process.lua` (~390 LOC):

- **Spell ID constants** on `EC_compCache`: `SPELL_DISENCHANT` (13262),
  `SPELL_MILLING` (51005), `SPELL_PROSPECTING` (31252),
  `SPELL_PICK_LOCK` (1804), plus `PICK_LOCK_NAME` (resolved at file
  load via `GetSpellInfo`).
- **Eligibility predicates** on `EC_compCache`: `canDisenchant`,
  `canMill`, `canProspect`, `canPickLock`.
- **Tooltip-scan helper** `processTooltipHasLine` (used by canMill /
  canProspect to detect the "Mill" / "Prospect" usage line).
- **BoP check** `processIsSoulbound` (used by buildProcessSummary).
- **The bag walk** `buildProcessSummary` (the categorisation driver
  that walks bags 0-4, applies all eligibility + protection gates,
  and returns the queue table the UI panel renders).

Stays in EbonClearance.lua (Stage 8 target):

- The Process Bags UI panel (`ProcessBagsPanel`, the SecureActionButton,
  collapsible sections, scroll wiring).
- `rearmProcessButton`, `updateProcessSelection`, `skipProcessTarget`,
  `refreshProcessPanel` (UI-driving helpers that read panel widget
  state).

Cross-file API surface added in this stage:

- **`NS.Delay = EC_Delay`** published right after the EC_Delay body.
  Process uses it to schedule the `EC_compCache.refreshExtractionIfDirty`
  follow-up after a Disenchant / Mill / Prospect cast.
- **`NS.IsAddonEnabledForChar = EC_IsAddonEnabledForChar`** published
  right after the body. Process gates its operations on per-character
  enable.
- Existing `NS.scanTooltip`, `NS.PrintNicef`, `NS.DB`, `NS.ADB` are
  consumed inline (function-entry capture for DB/ADB, direct read for
  the others).

`.toc` order: `Core → Companion → Protection → Vendor → Process →
EbonClearance.lua → BagDisplay`. Process loads BEFORE EbonClearance.lua
because its function bodies are called from EbonClearance.lua's
Process UI panel; that panel's code reads `EC_compCache.canDisenchant`
etc. by the time it runs, but the methods need to exist by file-load
time so the panel's setup code (e.g. dropdown population) doesn't
hit nil.

Stage 7 invariants (enforced by `tests/test_perf_guardrails.lua` Test 35):

- 7 eligibility / scan helpers on `EC_compCache`: `canDisenchant`,
  `canMill`, `canProspect`, `canPickLock`, `processTooltipHasLine`,
  `processIsSoulbound`, `buildProcessSummary`.
- 4 spell ID constants on `EC_compCache` with their correct values
  (13262, 51005, 31252, 1804). Drift would silently break the
  Process panel's spell-known checks.
- `NS.Delay = EC_Delay` and `NS.IsAddonEnabledForChar` published.

### Stage 8: extract EbonClearance_BugReport.lua (commit `d2fe9b6`)

Stage 8 in the original plan was "extract everything UI" - ~3,500 LOC
of dense Interface Options panels, list-row factories, the minimap +
LDB + tooltip-annotation cluster. That's too much for one bite, so
Stage 8 is the smallest meaningful UI cluster instead: the bug-report
builder. Future Stages 8b / 8c can take on heavier UI surface.

Moved into `EbonClearance_BugReport.lua` (~430 LOC):

- `EC_CopperToPlainText` (plain-text gold/silver/copper formatter).
- `EC_BuildBugReport` (walks DB / ADB / cache state to build a
  copy-pasteable diagnostic snapshot).
- `EC_ShowBugReport` (lazy popup frame with a scrolling read-only
  EditBox; exposed as `NS.ShowBugReport` so the `/ec bugreport`
  slash command and any settings-panel button can reach it).

Stage 8 prep (state promotions + NS exposures, included in this
commit because the move depends on them):

- **Three cycle-state locals promoted to `EC_compCache.*` fields**
  (matching the Stage 3 `lastScavSpokeAt` + Stage 5 `vendorRunning` /
  `pendingDelete` pattern):
  - `EC_lootCycleState` → `EC_compCache.lootCycleState` (initial
    value `"idle"`, matches `STATE.IDLE`).
  - `EC_lastScavengerOut` → `EC_compCache.lastScavengerOut` (initial
    `false`).
  - `EC_addonDismissed` → `EC_compCache.addonDismissed` (initial
    `false`).
  40 reference sites in EbonClearance.lua substituted in code-only
  positions. Future Scavenger / Vendor extraction stages can read
  these via the shared cache.
- **Four cross-file helpers exposed on NS**:
  - `NS.GetVersion = EC_GetVersion` (bug-report reads it for the
    "Version: vX.Y.Z" line in the snapshot).
  - `NS.GetFreeBagSlots = EC_GetFreeBagSlots` (snapshot reads "Free
    Slots: N").
  - `NS.CopperToColoredText = CopperToColoredText` (reused by future
    UI extractions; exposed now while we're touching the helpers).
  - `NS.EnsureDB = EnsureDB` (BugReport calls it once at the top of
    `EC_BuildBugReport` to guarantee fields exist before reading).

`.toc` order: `Core → Companion → Protection → Vendor → Process →
EbonClearance.lua → BagDisplay → BugReport`. BugReport loads AFTER
EbonClearance.lua so the `NS.ShowBugReport` exposure happens by the
time anything could call it; the slash command + any settings-panel
button references resolve via NS at call time anyway, but the
file-load order keeps it tidy.

Stage 8 invariants (enforced by `tests/test_perf_guardrails.lua` Test 36):

- `NS.ShowBugReport = EC_ShowBugReport` published by BugReport.
- No bare `EC_ShowBugReport()` call sites (every call NS-qualified).
- `EC_compCache.lootCycleState` / `lastScavengerOut` / `addonDismissed`
  initialised in Core's table literal.
- No file-scope `local EC_lootCycleState` / `local EC_lastScavengerOut` /
  `local EC_addonDismissed` lurking anywhere (would silently desync
  from the cache fields).
- `NS.GetVersion` / `NS.GetFreeBagSlots` / `NS.CopperToColoredText` /
  `NS.EnsureDB` exposures all present.

### Stage 8b: extract EbonClearance_Minimap.lua (commit `<pending>`)

Stage 8b moves the minimap button + LDB launcher + the combat-vendor
SecureActionButton to `EbonClearance_Minimap.lua` (~210 LOC). Three
self-contained UI buttons that live OUTSIDE the Interface Options
panel hierarchy.

Moved into Minimap:

- `EC_UpdateMinimapPos` (positions the minimap button using
  `DB.minimapAngle`).
- `EC_CreateMinimapButton` (draggable minimap button with left /
  middle / right-click bindings: options / Process Bags / toggle;
  hover tooltip showing free bag slots, sellable count, est. value).
- `EC_CreateTargetMerchantButton` (hidden SecureActionButton dispatched
  through by the "Target Goblin Merchant" key binding — combat-lockdown safe).
- `EC_CreateLDBLauncher` (LibDataBroker plugin for users running
  Bazooka / ChocolateBar / etc.).

Cross-file reach pattern:

- Both main settings panel (`EbonClearanceOptionsMain`) and Process Bags
  panel (`EbonClearanceOptionsProcessBags`) are named frames. Minimap
  reaches them via `_G[<name>]` lookup instead of an explicit NS
  exposure. One less NS surface to maintain.
- Other helpers (`PreviewSellable`, `CopperToColoredText`,
  `GetFreeBagSlots`, `PrintNice`, `PrintNicef`, `TARGET_NAME`)
  already on NS from prior stages.
- `EbonClearance_ToggleSettings` / `ToggleEnabled` / `ForceSell` are
  WoW globals (Bindings.xml glue) — reachable from any file.

Exposed on NS for the ADDON_LOADED branch in EbonClearance.lua:

- `NS.UpdateMinimapPos`
- `NS.CreateMinimapButton`
- `NS.CreateTargetMerchantButton`
- `NS.CreateLDBLauncher`

Three external call sites in EbonClearance.lua's ADDON_LOADED branch
updated to NS-qualified form.

Stage 8b invariants (enforced by `tests/test_perf_guardrails.lua` Test 37):

- All four `NS.<name>` exposures published by Minimap.
- No bare `EC_CreateMinimapButton()` / `EC_CreateTargetMerchantButton()` /
  `EC_CreateLDBLauncher()` call sites in any shipped source.

### Stage 8c: extract EbonClearance_Tooltip.lua (commit `471ae04`)

Stage 8c moves the bag-item tooltip annotation system to
`EbonClearance_Tooltip.lua` (~362 LOC). The system that adds the
coloured "Will Sell" / "Protected - Random affix" / "Allowed -
Account Sell" / "Protected - Profession tool" / etc. line on every
bag item's tooltip.

Moved into Tooltip:

- `EC_AnnotateTooltip` (per-tooltip body — walks the same decision
  chain as `EC_IsSellable` and produces a humane status line;
  mirrors rather than calls `EC_IsSellable` because tooltip output
  needs to know WHY, not just yes/no; see docs/CODE_REVIEW.md
  item 6 for the documented parallel-impl tradeoff).
- `EC_ClearTooltipFlag` (resets the per-tooltip dedupe flag —
  recipe tooltips fire `OnTooltipSetItem` twice).
- `EC_InstallTooltipHookOnce` (hooks `OnTooltipSetItem` +
  `OnTooltipCleared` on `GameTooltip` + `ItemRefTooltip`).
  Exposed as `NS.InstallTooltipHookOnce` for the ADDON_LOADED
  branch.

Cross-file pattern:

- Tooltip carries its own local `IsInSet` helper (same convention
  as Vendor and BagDisplay - pure function, cheap to duplicate,
  avoids cross-file lookup on every tooltip refresh).
- `EC_IsAddonEnabledForChar` substituted to `NS.IsAddonEnabledForChar`
  (exposure already present from Stage 7).
- 9 `EC_compCache.*` references work via the shared cache table.

One external call site in EbonClearance.lua's ADDON_LOADED branch
updated:

- `EC_InstallTooltipHookOnce()` → `NS.InstallTooltipHookOnce()`

Stage 8c invariants (enforced by `tests/test_perf_guardrails.lua` Test 38):

- `NS.InstallTooltipHookOnce = EC_InstallTooltipHookOnce` published
  by Tooltip.
- No bare `EC_InstallTooltipHookOnce()` call sites anywhere.

### Stage 8d: extract EbonClearance_BagContextMenu.lua (commit `af81c07`)

Stage 8d moves the Alt+Right-Click bag-item quick-action popup
(~375 LOC) to `EbonClearance_BagContextMenu.lua`. A custom popup
frame (not a Blizzard DropDownMenu) wired through `hooksecurefunc`
on `ContainerFrameItemButton_OnModifiedClick`.

Moved into BagContextMenu:

- `EC_CTX_ROWS` (row metadata: list rows + special rows like cancel /
  allow-sell).
- `EC_BuildCtxFrame` (lazy popup frame creation).
- `EC_ShowItemContextMenu` (per-show: sets row labels + OnClick
  handlers, anchors at cursor, shows the frame).
- `EC_InstallBagContextHookOnce` (hooks
  `ContainerFrameItemButton_OnModifiedClick`). Exposed as
  `NS.InstallBagContextHookOnce` for ADDON_LOADED.

Stage 8d prep (NS exposures, same commit):

- `NS.AddItemToList = EC_AddItemToList`
- `NS.RemoveItemFromList = EC_RemoveItemFromList`
- `NS.FindAddConflict = EC_FindAddConflict`

Row-click handlers in the context menu call these three list-mutation
helpers; they were file-scope locals in EbonClearance.lua, so the
move required publishing them on NS first.

Local `IsInSet` helper carried along (same pattern as Vendor /
BagDisplay / Tooltip).

One external call site in EbonClearance.lua's ADDON_LOADED branch
updated:

- `EC_InstallBagContextHookOnce()` → `NS.InstallBagContextHookOnce()`

Stage 8d invariants (enforced by `tests/test_perf_guardrails.lua` Test 39):

- `NS.InstallBagContextHookOnce` exposed by BagContextMenu.
- `NS.AddItemToList` / `NS.RemoveItemFromList` / `NS.FindAddConflict`
  / `NS.GetListTable` exposed by EbonClearance.lua.
- No bare `EC_InstallBagContextHookOnce()` call sites anywhere; no bare
  `EC_GetListTable()` call sites inside `EbonClearance_BagContextMenu.lua`.

### Stage 8e-i: extract EbonClearance_ProcessBagsPanel.lua (commit `7db22bf`)

Stage 8e-i moves the v2.22.0 Process Bags Interface Options panel
(~662 LOC moved, file is ~709 LOC with header) to
`EbonClearance_ProcessBagsPanel.lua`. The narrow first slice of the
Stage 8e UI extraction: a self-contained domain (profession
processing) with its four helpers already on `EC_compCache`
(`rearmProcessButton`, `updateProcessSelection`, `skipProcessTarget`,
`refreshProcessPanel`).

The PROFESSION ENGINE (spell IDs, eligibility predicates,
`buildProcessSummary`) was already extracted in Stage 7 into
`EbonClearance_Process.lua`; Stage 8e-i splits the UI layer off from
that. The two files share state through `EC_compCache`
(`processCache`, the can-* predicates, the cast button macrotext) so
the boundary is clean.

Moved into the new file:

- `local ProcessBagsPanel = CreateFrame(...)` frame creation
- `EC_compCache.rearmProcessButton`, `updateProcessSelection`,
  `skipProcessTarget`, `refreshProcessPanel` bodies
- `ProcessBagsPanel:SetScript("OnShow", ...)` panel-build body

Stage 8e-i prep (NS exposures, same commit):

- `NS.MakeHeader` / `NS.MakeLabel` - panel-text primitives that the
  OnShow build body calls. The locals stay in `EbonClearance.lua`;
  the NS bindings let split files reach them lazily at call time.
  Subsequent panel-extraction stages (8e-ii+) reuse these exposures.

Cross-file dependencies satisfied by NS / EC_compCache:

- `NS.PrintNice` / `NS.PrintNicef` (already on NS since Stage 8 prep).
- `NS.DB` captured at function entry per helper / OnShow (matches the
  Stage 4+ pattern for cross-file DB access).
- `EC_compCache.initPanel` / `setPanelWidth` / `registerWidth` /
  `refreshLayouts` (panel infra in `EbonClearance.lua`; reached via
  the shared `EC_compCache` reference).
- `EC_compCache.canDisenchant` / `canMill` / `canProspect` /
  `buildProcessSummary` (from `EbonClearance_Process.lua`).

`InterfaceOptions_AddCategory(ProcessBagsPanel)` in `EbonClearance.lua`
was converted to
`InterfaceOptions_AddCategory(_G["EbonClearanceOptionsProcessBags"])`
since the local binding no longer exists in that file. The .toc loads
`EbonClearance_ProcessBagsPanel.lua` BEFORE `EbonClearance.lua` so the
frame exists at registration time; the helpers' references to
`NS.MakeHeader` / `NS.PrintNicef` resolve lazily at call time (not
load time) so the late binding is safe.

Stage 8e-i invariants (enforced by `tests/test_perf_guardrails.lua` Test 40):

- `NS.MakeHeader` / `NS.MakeLabel` exposed by EbonClearance.lua.
- All four `EC_compCache` helpers defined in
  `EbonClearance_ProcessBagsPanel.lua` (not in `EbonClearance.lua`).
- `EbonClearance_ProcessBagsPanel.lua` calls `NS.MakeHeader` /
  `NS.MakeLabel` rather than the bare locals (which only exist in
  `EbonClearance.lua`'s scope).
- `EbonClearance.lua` registers the panel via the `_G[]` lookup.

### Stage 8e-ii: extract EbonClearance_MerchantPanel.lua (commit `850587f`)

Stage 8e-ii moves the Merchant Settings Interface Options panel
(~478 LOC moved, file is ~513 LOC with header) into
`EbonClearance_MerchantPanel.lua`. Second slice of the UI extraction:
the Merchant panel is a single self-contained domain (vendor mode +
repair + sliders + per-rarity rules) that uses five additional shared
widget primitives.

Moved into the new file:

- `EC_WHITELIST_QUALITIES` table - rarity labels for the per-rarity
  rule rows (used only by this panel; safe to move).
- `local MerchantPanel = CreateFrame(...)` frame creation.
- `EC_MERCHANT_MODES` table - vendor mode dropdown data (used only by
  this panel; safe to move).
- The MerchantPanel OnShow handler (the panel-build body that
  constructs the dropdowns, sliders, fast-mode toggle, and the four
  per-rarity rule rows).

Stage 8e-ii prep (NS exposures, same commit):

- `NS.AddCheckbox` / `NS.AddSlider` - widget primitives that the
  OnShow body invokes for every settings toggle and slider.
- `NS.FitScrollContent` - called at the end of the panel build to
  size the scroll content to the bottom-most widget.
- `NS.ColorTextByQuality` - the `EC_WHITELIST_QUALITIES` table calls
  this at load time of `EbonClearance_MerchantPanel.lua`, but the
  table is only consumed when the panel is built (much later), so
  the lookup resolves at the right time even though the file loads
  before `EbonClearance.lua`.
- `NS.StyleInputBox` - the per-rarity rule rows have iLvl input
  boxes that need the layered-OVERLAY treatment.

Cross-file dependencies satisfied by NS / EC_compCache:

- `NS.MakeHeader` / `NS.MakeLabel` (already on NS since Stage 8e-i).
- `NS.PrintNice` / `NS.PrintNicef` (already on NS).
- `NS.DB` captured at OnShow entry.
- `EC_compCache.initPanel`, `getBindType`, `setPanelWidth`,
  `registerWidth`, `refreshLayouts` (already shared via `EC_compCache`).

`InterfaceOptions_AddCategory(MerchantPanel)` converted to
`InterfaceOptions_AddCategory(_G["EbonClearanceOptionsMerchant"])`
since the local binding no longer exists in `EbonClearance.lua`.
The .toc loads `EbonClearance_MerchantPanel.lua` BEFORE
`EbonClearance.lua` so the frame exists at registration time.

**Mid-stage gotcha 1**: the file-header doc block must NOT contain the
literal text `MerchantPanel:SetScript("OnShow"` because
`tests/test_layout_reactivity.lua` Test 6 (`panelsNeedingWrap`)
greps for that pattern as the panel's OnShow marker. The first hit
wins; if a comment matches before the actual code, the test sees the
comment-to-code range as the panel "block" and misses the
`end, true)` closer. Reworded the header to describe the OnShow
without using the literal pattern.

**Mid-stage gotcha 2 (load-order trap)**: `EC_WHITELIST_QUALITIES`
originally lived as a file-scope local with eager table construction
calling `NS.ColorTextByQuality(...)` for each entry. But this file
loads BEFORE `EbonClearance.lua` (so the `_G[]` registration lookup
works), which means `NS.ColorTextByQuality` is nil at file-scope
load time. The eager call nil-errored, the file aborted before the
MerchantPanel frame was created, and `InterfaceOptions_AddCategory`
in `EbonClearance.lua` then dereferenced a nil frame at the
following line. Fix: move the table construction INSIDE the OnShow
build callback (which fires lazily; by first OnShow,
`EbonClearance.lua` has loaded and NS.* is populated). The
`initPanel` "build once" gate keeps the cost equivalent to the
file-scope upvalue.

**General rule for split files that load BEFORE EbonClearance.lua**:
function bodies referencing `NS.*` are fine (lazy lookup at call
time). Top-level table constructors and other eager code that calls
`NS.*` are NOT fine — defer them into a function body, or move the
helper into Core.lua so it's available before any of the dependent
files load. Test 41 includes a load-order-trap regression check
scanning the file's pre-build-callback region for bare
`NS.ColorTextByQuality(` calls; extend the check to other NS
primitives if future panel extractions reveal new traps.

Stage 8e-ii invariants (enforced by `tests/test_perf_guardrails.lua` Test 41):

- `NS.AddCheckbox` / `NS.AddSlider` / `NS.FitScrollContent` /
  `NS.ColorTextByQuality` / `NS.StyleInputBox` exposed by
  `EbonClearance.lua`.
- MerchantPanel frame created in
  `EbonClearance_MerchantPanel.lua` (not in `EbonClearance.lua`).
- `EbonClearance_MerchantPanel.lua` uses `NS.AddCheckbox` /
  `NS.AddSlider` / `NS.FitScrollContent` (not bare locals).
- `EbonClearance.lua` registers the panel via the `_G[]` lookup.

### Stage 8e-iii: extract EbonClearance_ScavengerPanel.lua (commit `240046d`)

Stage 8e-iii moves the Scavenger Settings Interface Options panel
(~275 LOC moved, file is ~304 LOC with header) to
`EbonClearance_ScavengerPanel.lua`. **Zero new NS exposures needed** -
the five widget primitives the OnShow body uses (`NS.MakeHeader`,
`NS.MakeLabel`, `NS.AddCheckbox`, `NS.AddSlider`,
`NS.FitScrollContent`) were all exposed in 8e-i / 8e-ii prep. The
smallest extraction in the panel-split sequence so far.

Moved into the new file:

- `local ScavengerPanel = CreateFrame(...)` frame creation.
- The ScavengerPanel OnShow handler (companion summon toggles,
  summon-delay slider, mute / hide-chat / hide-bubbles toggles,
  auto-loot cycle, bag-full threshold, auto-open containers, fast
  loot driver).

`InterfaceOptions_AddCategory(ScavengerPanel)` converted to the
`_G[]` lookup; .toc loads the new file BEFORE `EbonClearance.lua`.
DB captured at OnShow entry per the established pattern.

Stage 8e-iii invariants (Test 45): ScavengerPanel frame lives in the
new file (not duplicated in EbonClearance.lua); new file uses
`NS.MakeHeader` / `NS.AddCheckbox` / `NS.AddSlider` (not bare
locals); registration uses `_G[]` lookup.

### Stage 8e-iv: extract EbonClearance_SellListPanels.lua (commit `bcfde1a`)

Stage 8e-iv bundles two sibling panels (Sell List + Account Sell
List) into one file: `EbonClearance_SellListPanels.lua`. Same
concept, different scope (per-character vs account-wide); both are
list-management UIs anchored on the shared `CreateListUI` helper.
~98 LOC moved, new file is ~125 LOC.

Two new NS exposures (Stage 8e-iv prep) - both share between Sell
List family panels AND Keep / Delete list panels (a future stage),
so the exposures stay on the cross-file surface:

- `NS.CreateListUI` - the scrollable item-list UI builder; called by
  every list-management panel.
- `NS.AddScanByQualityRow` - the "Add from bags: White / Green /
  Blue" bulk-add row used by Sell List + Account Sell List.

Moved into the new file:

- `local WhitelistPanel = CreateFrame(...)` + OnShow build body
- `local AccountWhitelistPanel = CreateFrame(...)` + OnShow build body

Both `InterfaceOptions_AddCategory` calls converted to `_G[]` lookups;
.toc loads the new file BEFORE `EbonClearance.lua`. DB captured at
each OnShow entry per the established pattern.

Stage 8e-iv invariants (Test 46): both panel frames live in the new
file (not duplicated in EbonClearance.lua); new file uses
`NS.CreateListUI` / `NS.AddScanByQualityRow` (not bare locals); both
registrations use `_G[]` lookups; the two new NS exposures are
present.

### Stage 8e-v: extract EbonClearance_KeepDeletePanels.lua (commit `17c8d12`)

Stage 8e-v bundles two sibling list-management panels (Keep List +
Delete List) into one file: `EbonClearance_KeepDeletePanels.lua`.
Both are list-management UIs anchored on the shared `CreateListUI`
helper, with the same panel rhythm (header + description + hint +
list).

~123 LOC moved, new file is ~156 LOC.

**Zero new NS exposures needed** - `NS.MakeHeader`, `NS.MakeLabel`,
`NS.CreateListUI` are all already NS-exposed from 8e-i / 8e-iv prep.

Moved into the new file:

- `local DeletePanel = CreateFrame(...)` + OnShow build body (Delete
  List, including the `Enable item deletion` checkbox with its
  refresh-on-toggle wiring from Issue B)
- `local BlacklistPanel = CreateFrame(...)` + OnShow build body
  (Keep List)

**`BlacklistSettingsPanel` (Protection Settings) stays in
EbonClearance.lua for now.** Despite the name overlap with
BlacklistPanel, it's a different domain (auto-protect toggles for
equipped / upgrades / sets / affixes / chance-on-hit) and will move
in a later stage.

Both registrations converted to `_G[]` lookups. .toc loads the new
file BEFORE `EbonClearance.lua`. DB captured at each OnShow entry.

Stage 8e-v invariants (Test 47): both panel frames in the new file
(not duplicated in EbonClearance.lua); new file uses `NS.CreateListUI`
(not bare local); both registrations use `_G[]` lookups; the
`BlacklistSettingsPanel` (Protection Settings) frame is still in
EbonClearance.lua (sentinel check that the wrong panel didn't get
swept up by accident).

### Target architecture (post-split)

Per docs/CODE_REVIEW.md item 4, the planned split shape is:

| File | Responsibility |
|---|---|
| `EbonClearance_Core.lua` | Namespace, constants, API caches, forward decls, EnsureDB / EnsureAccountDB, EC_Delay, EC_compCache |
| `EbonClearance_Companion.lua` | Scavenger / Goblin Merchant lifecycle, chat filters, mount handler, stuck detection |
| `EbonClearance_Protection.lua` | Affix detection, chance-on-hit detection, bind-type cache, process cache |
| `EbonClearance_Vendor.lua` | EC_IsSellable, BuildQueue, DoNextAction, vendor worker, auto-repair |
| `EbonClearance_Process.lua` | Process Bags engine, hold-key-to-drain |
| `EbonClearance_BagDisplay.lua` | Sell-border hooks, /ec sellinfo, auto-open driver, Fast Loot driver |
| `EbonClearance_UI.lua` | CreateListUI + helpers, all Interface Options panels, minimap, LDB, bug-report |
| `EbonClearance_Events.lua` | Event hub, slash commands, Bindings.xml glue handlers |

Stages 2-8 each extract one file from the monolith. Stage 9 renames
`EbonClearance.lua` -> `EbonClearance_Events.lua` and closes out the
refactor.

### Rules for future stages

- Each stage is a separate release; no feature work in the same release.
- Move-only commits where possible; pure mechanical refactor.
- After each stage, all three invariant tests must still pass. Tests
  concatenate the split files at test time (see the SOURCE_PATH loop
  at the top of each test file after Stage 2 ships) so existing
  invariants apply unchanged.
- LICENSE §2(b) requires the file-header attribution block: it stays
  on whichever file is loaded first in the `.toc` (currently
  `EbonClearance.lua`; will move to `EbonClearance_Core.lua` in Stage 2).
- Forward declarations move from file-scope `local foo = function() end`
  stubs to `NS.foo = function() end` table-slot stubs, reassigned in
  the owning file. Cross-file callers invoke `NS.foo()` - table-index
  lookup at call time, so load order between feature files doesn't
  matter (Core must still load first because it owns the namespace
  shape and the EnsureDB migrations).
