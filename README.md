# EbonClearance

[![Download Latest](https://img.shields.io/github/v/release/powerfulqa/EbonClearance?label=Download&style=for-the-badge&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/powerfulqa/EbonClearance/badge-data/downloads.json&style=for-the-badge&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)

A **Project Ebonhold-aware** bag manager. Out of the box it sells your junk and old gear at any merchant, keeps your upgrades, and never touches anything important. It reads your account's affix-extraction and chance-on-hit-proc state from PE's own services, so two identical-itemID drops can land on different sides of "sell" or "keep" depending on which affix rolled and which procs you've already extracted. No external libraries; stock Blizzard 3.3.5a APIs only.

## What It Does

- **Auto-sell trash + auto-vendor your loot.** Per-rarity rules (White / Green / Blue / Purple) with two cap modes: follow your equipped iLvl (default on Whites and Greens for fresh installs) or set a fixed max. Per-rarity bind-type filter (Any / BoE / BoP). Grey junk always auto-sells. Equipped gear is never touched.
- **Per-character + account-wide Sell Lists**, plus a Keep List and a Delete List. Bulk-add buttons scan your bags and add by colour or name. Saved profiles let you switch lists by activity.
- **Project Ebonhold-specific protections** that the auto-rule sweep respects: affixed Rare/Epic drops (per-instance), chance-on-hit proc items, tomes and recipes (learned-state-aware), quest items, profession tools, equipped gear and looted upgrades, equipment-manager set members. Each protection has an Alt+Right-Click → **Allow Sell** override that's account-wide for items / per-affix-description for affixes.
- **Greedy Scavenger + Goblin Merchant loop.** Auto-summon, dismiss-on-mount, re-summon-if-stuck, combat-resilient. Auto-loot cycle dismisses the scavenger and brings up the merchant when bags fill, then re-summons to continue. Heavy-combat safe.
- **Fast Loot.** Throttled drain (~110 ms per slot) on manual loot windows so private-server anti-flood doesn't disconnect you. BoP-bind popups auto-confirm.
- **Process Bags panel** for disenchant / mill / prospect / pick-lock. One button drives the casts; bind a key and hold to drain a stack. Honours every protection.
- **Tooltip annotations** show what the addon will do *before* it does it: `Will Sell (<reason>)`, `Keep (<reason>)`, `Won't Sell (<reason>)`, `Will Delete`. No surprises at the merchant.
- **Per-item sellability inspector** (`/ec sellinfo` or Alt+Shift+Right-Click) traces the entire decision chain in chat. "Why isn't this selling?" is always one click away.
- **Per-category bag-slot border tints** in five colours (Delete / Account Sell / Character Sell / Junk / Rule-match), with per-category enable + colour picker. Slot-frame ring only, not an icon overlay.
- **Profile import/export** for sharing whole settings packs (lists + per-rarity rules) between characters or with other players.
- **Reactive layout**, minimap button + LDB launcher, keybindings, first-run welcome, session + lifetime stats.

A complete enumeration of every feature lives in [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md). Behaviour history is in [CHANGELOG.md](CHANGELOG.md). For the design lineage and prior-art acknowledgement, see [NOTICE.md](NOTICE.md).

## Installation

1. Head to the [latest release](https://github.com/powerfulqa/EbonClearance/releases/latest) and download the zip file.
2. Extract the `EbonClearance` folder into your `Interface/AddOns` directory.
3. Log in and type `/ec` to open the settings panel.
4. Sensible defaults are seeded for new characters - White and Green auto-vendor below your equipped iLvl, equipped gear is auto-Kept, the Scavenger / auto-loot cycle are on. Tune from there.

Per-character on/off: use the minimap button's right-click or `/ec` to disable the addon on alts you'd rather it skip.

## Configuration

All settings live under `/ec`, which opens the scrollable config panel. Highlights:

- **Lists.** Sell List, Account Sell List, Keep List, Delete List. Each panel has bulk-add buttons (by quality on the Sell Lists) and a name-substring matcher.
- **Profiles.** Save / load / rename / clear. Default profile is locked empty.
- **Merchant Settings.** Per-rarity quality thresholds with `Use equipped iLvl` or fixed-max-iLvl cap, per-rarity bind-type filter, merchant target (Goblin / normal vendors / both), Fast Mode toggle, vendor sell speed, summon delay.
- **Protection Settings.** Auto-protect equipped gear, looted upgrades, equipment-manager sets, affixed Rare/Epic items, chance-on-hit items, tomes / recipes (with optional extension to already-known items).
- **Scavenger Settings.** Summon controls, chat / speech-bubble mute, auto-loot cycle threshold, auto-open containers, Fast Loot.
- **Process Bags.** Disenchant / mill / prospect from your bags; configurable DE rarity cap, Soulbound inclusion toggle, per-character ignore list.
- **Import / Export.** Sell List sharing strings, per-section source/target.
- **Character Settings.** Restrict which characters the addon runs on. Toggle the bag-slot sell-border tint and pick its colour through the standard colour-picker dialog.
- **Statistics.** Lifetime + session counters side-by-side, reset independently.
- **Key Bindings (WoW).** Open settings, toggle enabled, force sell at current merchant, Process Next.
- **Minimap button.** Left: options, Middle: Process Bags, Right: toggle.
- **Alt+Right-Click any bag item** for a quick-action menu.

## Slash Commands

| Command | Description |
|---------|-------------|
| `/ec` | Open the settings panel |
| `/ec profile list` | Show all saved Sell List profiles |
| `/ec profile save <name>` | Save the current Sell List as a named profile |
| `/ec profile load <name>` | Load a saved profile into the active Sell List |
| `/ec profile delete <name>` | Delete a saved profile |
| `/ec clean` | Report any item IDs present in more than one list |
| `/ec clean apply` | Auto-resolve list conflicts using precedence Keep List > Delete List > Sell List |
| `/ec clean upgrades` | Report stale `Auto-Protected (Upgrade)` Keep List entries that are no longer above your equipped iLvl |
| `/ec clean upgrades apply` | Remove the stale `Auto-Protected (Upgrade)` entries (with confirmation) |
| `/ec bugreport` | Generate a diagnostic report you can copy and paste into a bug report |
| `/ec sellinfo [bag slot]` | Trace why a bag item will or won't sell - per-predicate chain trace (also available via Alt+Shift+Right-Click on the item) |
| `/ec help` | Print the full slash-command reference in chat |
| `/ecdebug` | Show debug info and run a bag scan |

## Requirements

- World of Warcraft (WotLK client, Interface 30300)
- Project Ebonhold server

## For Contributors

Working on the addon? There's developer documentation under [docs/](docs/):

- [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) is the prescriptive guide for coding in this addon. Read it first: it covers 3.3.5a client gotchas, the file's architecture, naming conventions, the state machine, UI patterns and the decision not to embed Ace3.
- [docs/CODE_REVIEW.md](docs/CODE_REVIEW.md) is a short list of known follow-up cleanups that weren't part of the last pass.

A Luacheck config ([.luacheckrc](.luacheckrc)) and a StyLua formatter config ([stylua.toml](stylua.toml)) are checked in. Run `stylua --check *.lua` and `luacheck *.lua` before opening a PR. (The addon ships as 23 `.lua` files after the v2.32.0 file-split; the entry hub is `EbonClearance_Events.lua`.)

## Changelog

Per-release notes live in [CHANGELOG.md](CHANGELOG.md). For prior-art acknowledgement and the design lineage, see [NOTICE.md](NOTICE.md).

## Notice

EbonClearance ships in a niche where similar inventory-management addons exist for the same private server. [NOTICE.md](NOTICE.md) documents prior art and convergent patterns honestly: which structural elements (the source-available licence shape, the provenance globals form) are adopted from conventions already present in the 3.3.5a addon ecosystem, and which (the fingerprint and watermark mechanism) are specific to this project. Read it before drawing conclusions about influence in either direction.

## Licence

This project is distributed under the EbonClearance Source-Available Attribution Licence. You may use, modify, and redistribute the addon (including in private-server addon-pack bundles) provided you preserve the author credit, the in-game byline, the provenance globals, and the LICENSE file itself, and you do not silently rebrand the addon name, the `/ec` slash command, the SavedVariable names, or the `EC:` import/export prefix. Forks under a new name are welcome as long as attribution to the original author and source URL is preserved. See the [LICENSE](LICENSE) file for the full terms.
