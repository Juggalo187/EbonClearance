# EbonClearance

[![Download Latest](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/powerfulqa/EbonClearance/badge-data/version.json&style=for-the-badge&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/powerfulqa/EbonClearance/badge-data/downloads.json&style=for-the-badge&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)

**Full bags, every quest hub, every farm session. EbonClearance handles the chore.**

Sells what you don't want. Keeps what you do. Knows the difference because it reads your Project Ebonhold affix and proc state directly. Zero config to start, one click for a guided setup, deep controls when you want them. No external libraries, stock Blizzard 3.3.5a APIs only.

## How it sells

- **Per-rarity auto-sell rules** (White / Green / Blue / Purple). Caps follow your equipped iLvl, or set a fixed max. Bind-type filter per rarity.
- **Sell, Keep, and Delete lists**, per-character and account-wide. Bulk-add from your bags by colour, switch lists by activity with saved profiles.
- **Tooltip says what will happen** before you vendor. `/ec sellinfo` traces every decision so "why isn't this selling?" is one click away.

## What it protects

- **Affixed Rare/Epic drops.** Affix-keyed Allow-Sell overrides for the ones you've decided you don't need.
- **Chance-on-hit procs you haven't extracted yet**, plus tomes and recipes you haven't learned. Class-aware: bows on Druids and relics on Mages stay off your Keep List.
- **Quest items, equipped gear, equipment-manager set members.** Each protection has an Alt+Right-Click → Allow Sell override.

## The loop

- **Greedy Scavenger summon** with auto-rebuy and dismiss-on-mount. Heavy-combat safe.
- **Goblin Merchant + Fast Loot.** Throttled drain so private-server anti-flood doesn't disconnect you.
- **Process Bags panel** for disenchant / mill / prospect / pick-lock. Bind a key, hold to drain a stack.

A complete enumeration of every feature lives in [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md). Behaviour history is in [CHANGELOG.md](CHANGELOG.md). For the design lineage, see [NOTICE.md](NOTICE.md).

## Installation

1. Head to the [latest release](https://github.com/powerfulqa/EbonClearance/releases/latest) and download the zip file.
2. Extract the `EbonClearance` folder into your `Interface/AddOns` directory.
3. Log in and type `/ec` to open the settings panel.
4. Sensible defaults are seeded for new characters - White and Green auto-vendor below your equipped iLvl, equipped gear is auto-Kept, the Scavenger / auto-loot cycle are on. Tune from there.

Per-character on/off: tick / untick the **Enable EbonClearance** checkbox at the top of the main panel, right-click the minimap button, or type `/ec enable` / `/ec disable` to skip the addon on alts you'd rather it leave alone. Use `/ec status` to check the current state at any time.

## Configuration

All settings live under `/ec`, which opens the scrollable config panel. Highlights:

- **Lists.** Sell List, Account Sell List, Keep List, Delete List. One "Add item" field takes an item ID or a name (exact, or part of a name to add matching items from your bags); the Sell Lists also have by-quality bulk-add buttons. Rows show the item icon and a quality-colored name; hover a row for the item tooltip. Filter the view by name or rarity, and sort by name. The Delete List has an optional "auto-delete on pickup" toggle (off by default) that destroys listed items the moment they're looted, to cut vendor trips while farming.
- **Profiles.** Save / load / rename / clear. Default profile is locked empty.
- **Merchant Settings.** Per-rarity quality thresholds with `Use equipped iLvl` or fixed-max-iLvl cap, per-rarity bind-type filter, merchant target (Goblin / normal vendors / both), Fast Mode toggle, vendor sell speed, summon delay.
- **Protection Settings.** Auto-protect equipped gear, looted upgrades, equipment-manager sets, affixed Rare/Epic items, chance-on-hit items, tomes / recipes (with optional extension to already-known items).
- **Scavenger Settings.** Summon controls, chat / speech-bubble mute, auto-loot cycle threshold, auto-open containers, Fast Loot.
- **Process Bags.** Disenchant / mill / prospect from your bags; configurable DE rarity cap, Soulbound inclusion toggle, per-character ignore list.
- **Import / Export.** Sell List sharing strings, per-section source/target.
- **Item Highlighting.** Toggle the bag-slot sell-border tint per category (Delete / Keep / Account Sell / Character Sell / Junk / Rule), pick each category's colour through the standard colour-picker dialog, opt into the item-level overlay (with sub-toggles for bags / character sheet & inspect / merchant + a font-size slider), and optionally show the numeric item ID on bag-item tooltips. (Per-character on/off lives on the minimap button + `/ec`, not in a panel.)
- **Statistics.** Lifetime + session counters side-by-side, reset independently. Includes per-rarity breakdowns of sells and deletions, top-5 most-sold and most-deleted items, lifetime Process Bags counters (Disenchant / Mill / Prospect / Pick Lock), and a top-zones leaderboard by lifetime gold earned at vendor.
- **Updates.** "Tell me when an update is available" toggle on the main panel (on by default). EbonClearance learns the newest version from other users in your guild or group and shows one chat line with a clickable copy-link.
- **Key Bindings (WoW).** Open settings, toggle enabled, force sell at current merchant, Process Next.
- **Minimap button.** Left: options, Middle: Process Bags, Right: toggle.
- **Alt+Right-Click any bag item** for a quick-action menu.

## Slash Commands

| Command | Description |
|---------|-------------|
| `/ec` | Open the settings panel |
| `/ec status` | Show whether EbonClearance is currently enabled or disabled |
| `/ec enable` | Turn EbonClearance on for this character |
| `/ec disable` | Turn EbonClearance off for this character |
| `/ec profile list` | Show all saved Sell List profiles |
| `/ec profile save <name>` | Save the current Sell List as a named profile |
| `/ec profile load <name>` | Load a saved profile into the active Sell List |
| `/ec profile delete <name>` | Delete a saved profile |
| `/ec clean` | Report any item IDs present in more than one list |
| `/ec clean apply` | Auto-resolve list conflicts using precedence Keep List > Delete List > Sell List |
| `/ec clean upgrades` | Report stale `Keep (upgrade)` Keep List entries that are no longer above your equipped iLvl (v2.33.1+ auto-cleans these on every bag update; this command is now mainly for one-shot inspection) |
| `/ec clean upgrades apply` | Manually remove stale `Keep (upgrade)` entries (with confirmation) |
| `/ec bugreport` | Generate a diagnostic report you can copy and paste into a bug report (includes a list of your loaded addons for conflict diagnosis) |
| `/ec sellinfo [bag slot]` | Trace why a bag item will or won't sell - per-predicate chain trace (also available via Alt+Shift+Right-Click on the item) |
| `/ec rules` | Open a plain-English summary of every active rule + the order EC applies them (also the "Current Rules" button on the Main panel) |
| `/ec affixdebug on\|off\|status\|dump\|clear` | Record affix-detection events for bug reports; `dump` opens a copyable window with the event log |
| `/ec processdebug` | Diagnostic: open a copyable window listing every Process Bags gate (recognised profession spells, per-slot scan results) for bug reports |
| `/ec perf` | Show EbonClearance's memory, CPU, cache and list sizes |
| `/ec commtest` | Diagnostic: check that addon messages are delivered on this server and preview the update nudge (works solo) |
| `/ec guildtest` | Diagnostic: preview the Stats - Guild panel with simulated members (works solo) |
| `/ec locale [auto\|frFR\|deDE]` | Show or force the addon's display language. `auto` follows your client; a code forces that language (handy when your client is locked to one language). `/reload` to apply fully |
| `/ec help` | Print the full slash-command reference in chat |
| `/ecdebug` | Show debug info and run a bag scan |

## Requirements

- World of Warcraft (WotLK client, Interface 30300)
- Project Ebonhold server

## For Contributors

Working on the addon? There's developer documentation under [docs/](docs/):

- [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) is the prescriptive guide for coding in this addon. Read it first: it covers 3.3.5a client gotchas, the file's architecture, naming conventions, the state machine, UI patterns and the decision not to embed Ace3.
- [docs/CODE_REVIEW.md](docs/CODE_REVIEW.md) is a short list of known follow-up cleanups that weren't part of the last pass.

- [docs/TRANSLATING.md](docs/TRANSLATING.md) is the guide for translating the addon into your language (French and German templates ship ready to fill in).

A Luacheck config ([.luacheckrc](.luacheckrc)) and a StyLua formatter config ([stylua.toml](stylua.toml)) are checked in. Run `stylua --check *.lua` and `luacheck *.lua` before opening a PR. (The addon ships as 32 `.lua` files after the v2.32.0 file-split, the v2.36.0 Help / Stats panel splits, the v2.38.0 Quickstart panel, the v2.39.0 `EbonClearance_Comms.lua` addition, the v2.40.0 guild-share files, and the v2.43.0 localization files; the entry hub is `EbonClearance_Events.lua`.)

## Thanks

Feature ideas and bug reports from the Project Ebonhold community shape the addon. Recent suggestions:

- **Auto-delete on pickup** - suggested by Sanavesa.

## Changelog

Per-release notes live in [CHANGELOG.md](CHANGELOG.md). For prior-art acknowledgement and the design lineage, see [NOTICE.md](NOTICE.md).

## Notice

EbonClearance ships in a niche where similar inventory-management addons exist for the same private server. [NOTICE.md](NOTICE.md) documents prior art and convergent patterns honestly: which structural elements (the source-available licence shape, the provenance globals form) are adopted from conventions already present in the 3.3.5a addon ecosystem, and which (the fingerprint and watermark mechanism) are specific to this project. Read it before drawing conclusions about influence in either direction.

## Licence

This project is distributed under the EbonClearance Source-Available Attribution Licence. You may use, modify, and redistribute the addon (including in private-server addon-pack bundles) provided you preserve the author credit, the in-game byline, the provenance globals, and the LICENSE file itself, and you do not silently rebrand the addon name, the `/ec` slash command, the SavedVariable names, or the `EC:` import/export prefix. Forks under a new name are welcome as long as attribution to the original author and source URL is preserved. See the [LICENSE](LICENSE) file for the full terms.
