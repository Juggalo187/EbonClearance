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

## When to split the file

Keep the single-file layout until one of these is true:

- File exceeds ~8000 LOC. The original threshold here was ~4000 but
  was bumped post-v2.6.0 (file was 5561 LOC and the single-file
  architecture was working well; comprehension and grep latency
  weren't actually painful at that size). Re-evaluate at the next
  threshold rather than auto-splitting on growth alone.
- Two largely-independent features share almost no state. A clean
  module boundary appears organically; resist forcing one.
- We adopt Ace3, at which point AceAddon lifecycle encourages modules.

If you do split: introduce a `local EC = {}` namespace table in a new
`EbonClearance_Core.lua`, loaded first in the `.toc`, and have each
feature file attach to it. Do **not** split mid-feature - keep bag
code together, vendor code together, UI together.
