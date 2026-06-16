# Architecture (code map)

A bird's-eye map of where things live, for a contributor or AI agent landing
in the repo. This is a map, not a manual: it tells you which file to open, not
how every function works. For the deep reference (3.3.5a constraints, gotchas,
refactoring traps, comms/guild-share internals) read
[ADDON_GUIDE.md](ADDON_GUIDE.md). For deferred work, read
[CODE_REVIEW.md](CODE_REVIEW.md).

EbonClearance is a WoW 3.3.5a (WotLK, Lua 5.1) bag manager: it vendors, deletes,
loots, protects items by rule, and runs profession processing. No external
libraries; all Blizzard APIs.

## How the files fit together

The `.toc` ([EbonClearance.toc](../EbonClearance.toc)) is the load-order source
of truth; the list below groups those files by role, not load order. Every file
starts with `local NS = select(2, ...)` and shares state through that `NS`
table. The only true globals are `EbonClearanceDB`, `EbonClearanceAccountDB`,
the slash-command handles, and the `EbonClearance_*` keybind handlers called
from `Bindings.xml`.

### Engine (no UI)

| File | Owns |
|------|------|
| [EbonClearance_Core.lua](../EbonClearance_Core.lua) | Provenance/fingerprint, shared "junk-drawer" state, `STATE` constants, the `NS` bootstrap, and the `EnsureDB` / `EnsureAccountDB` SavedVariables migrations. Loads first; depends on nothing. |
| [EbonClearance_Companion.lua](../EbonClearance_Companion.lua) | The Greedy Scavenger companion: summon/dismiss, chat + speech-bubble filtering, pet-check OnUpdate. |
| [EbonClearance_Protection.lua](../EbonClearance_Protection.lua) | What to *keep*: PE roguelite affix + chance-on-hit detection and the affix-data cache. |
| [EbonClearance_Vendor.lua](../EbonClearance_Vendor.lua) | The vendor cycle: `BuildQueue` / `DoNextAction` / `worker`, plus the `EC_Effective*` pacing helpers. |
| [EbonClearance_Process.lua](../EbonClearance_Process.lua) | The Process Bags engine: Disenchant / Mill / Prospect / Lockpick. |
| [EbonClearance_BagDisplay.lua](../EbonClearance_BagDisplay.lua) | Bag-slot sell-border tint + the sellinfo inspector (host bag UI adapter). |

### Event hub & comms

| File | Owns |
|------|------|
| [EbonClearance_Events.lua](../EbonClearance_Events.lua) | The single event frame, the `/ec` slash commands, and the residual glue. Adding an event = `RegisterEvent` + a branch here, never a new frame. Also where every Interface Options panel is registered centrally. |
| [EbonClearance_Comms.lua](../EbonClearance_Comms.lua) | `NS.Comms` addon-to-addon transport + the version-update gossip. |
| [EbonClearance_GuildShare.lua](../EbonClearance_GuildShare.lua) | Opt-in, anonymous-by-default guild/group stats sharing (a `NS.Comms` consumer). |

### Interface Options panels (feature UI)

One file per panel (or closely-related pair). All register centrally in
`Events.lua`; none self-registers.

[MainPanel](../EbonClearance_MainPanel.lua) ·
[MerchantPanel](../EbonClearance_MerchantPanel.lua) ·
[ScavengerPanel](../EbonClearance_ScavengerPanel.lua) ·
[ProcessBagsPanel](../EbonClearance_ProcessBagsPanel.lua) ·
[SellListPanels](../EbonClearance_SellListPanels.lua) ·
[KeepDeletePanels](../EbonClearance_KeepDeletePanels.lua) ·
[ProtectionPanel](../EbonClearance_ProtectionPanel.lua) ·
[ItemHighlightingPanel](../EbonClearance_ItemHighlightingPanel.lua) ·
[ProfilesPanel](../EbonClearance_ProfilesPanel.lua) ·
[StatsPanel](../EbonClearance_StatsPanel.lua) ·
[GuildPanel](../EbonClearance_GuildPanel.lua) ·
[QuickstartPanel](../EbonClearance_QuickstartPanel.lua) ·
[HelpPanel](../EbonClearance_HelpPanel.lua)

### Panel infrastructure (shared widgets)

| File | Owns |
|------|------|
| [EbonClearance_PanelInfra.lua](../EbonClearance_PanelInfra.lua) | The panel-width registry + reactivity layer (`EC_compCache`). Any widget that snapshots panel width MUST go through it. |
| [EbonClearance_PanelWidgets.lua](../EbonClearance_PanelWidgets.lua) | Panel widget primitives. |
| [EbonClearance_ListWidget.lua](../EbonClearance_ListWidget.lua) | The reusable list-management widget (add input / search / sort / rarity filter). |

### Other UI & utility

| File | Owns |
|------|------|
| [EbonClearance_Minimap.lua](../EbonClearance_Minimap.lua) | Minimap button, LDB launcher, combat-vendor button. |
| [EbonClearance_Tooltip.lua](../EbonClearance_Tooltip.lua) | Bag-item tooltip annotations. Deliberately mirrors `EC_IsSellable` (paired edit; see EC-TRAP). |
| [EbonClearance_BagContextMenu.lua](../EbonClearance_BagContextMenu.lua) | Alt+Right-Click bag-item quick-action popup. |
| [EbonClearance_BugReport.lua](../EbonClearance_BugReport.lua) | Diagnostic snapshot builder + display frame (`/ec bugreport`). |

`Bindings.xml` defines keybinds that call the `EbonClearance_*` global handlers.

## Boundaries (the things that must stay true)

These are the invariants an agent should not "simplify" across. Many are pinned
in code with `EC-TRAP:` markers; run `grep -rn "EC-TRAP:"` before touching
anything that looks like dead code or a bug.

- **One event frame.** It lives in `Events.lua`. Features do not create their own.
- **Cross-file state goes through `NS`.** New globals are not added.
- **SavedVariables change only via `EnsureDB` / `EnsureAccountDB`** nil-default
  migrations (downgrade-safe, additive). Both live in `Core.lua`.
- **Chat output only through `PrintNice` / `PrintNicef`.** Never
  `DEFAULT_CHAT_FRAME:AddMessage` directly.
- **Panel width only through `EC_compCache`** (PanelInfra), or it freezes at
  build-time width on resize.
- **State transitions use `STATE.*` constants,** not raw strings.
- **No third-party addon names** in new code, docs, or player-facing text.
- **No em dashes (U+2014) anywhere.**

## Where do I make change X?

| I want to... | Open |
|--------------|------|
| Change what counts as sellable / keepable | `Protection.lua` (+ the Vendor predicates) |
| Change vendor pacing / per-run cap | `Vendor.lua` (`EC_Effective*` helpers) |
| Add a profession-processing rule | `Process.lua` |
| Add a settings checkbox | the relevant `*Panel.lua` + an `EnsureDB` default in `Core.lua` |
| Add a whole new options panel | new `*Panel.lua` + register it centrally in `Events.lua` |
| React to a new game event | `RegisterEvent` + a branch in `Events.lua` (not a new frame) |
| Add a `/ec` subcommand | the slash handler in `Events.lua` (and a row in `README.md`) |
| Change a bag border or tooltip annotation | `BagDisplay.lua` / `Tooltip.lua` |
| Send an addon-to-addon message | `NS.Comms` in `Comms.lua` |

## Verifying a change

From the repo root:

```
lua tests/run_all.lua          # all five invariant suites in one shot
luac -p EbonClearance_*.lua     # syntax check every shipped file (luac5.1 in CI)
luacheck *.lua                  # 0 warnings expected (runs in CI; see CLAUDE.md)
```

CI ([.github/workflows/test.yml](../.github/workflows/test.yml)) runs the syntax
check, luacheck, and `tests/run_all.lua` on every push; the release workflow
re-runs them at the tag gate. See [CLAUDE.md](../CLAUDE.md) for the full release
process.
