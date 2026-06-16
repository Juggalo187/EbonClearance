# EbonClearance

[![Download Latest](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/powerfulqa/EbonClearance/badge-data/version.json&style=for-the-badge&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases/latest/download/EbonClearance.zip)
[![Downloads](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/powerfulqa/EbonClearance/badge-data/downloads.json&style=for-the-badge&cacheSeconds=3600)](https://github.com/powerfulqa/EbonClearance/releases)
[![Licence](https://img.shields.io/badge/Licence-Source--Available-blue?style=for-the-badge)](LICENSE)

A **Project Ebonhold-aware** bag manager. Out of the box it sells your junk and old gear at any merchant, keeps your upgrades, and never touches anything important. It reads your account's affix-extraction and chance-on-hit-proc state from PE's own services, so two identical-itemID drops can land on different sides of "sell" or "keep" depending on which affix rolled and which procs you've already extracted. No external libraries; stock Blizzard 3.3.5a APIs only.

## What It Does

- **Auto-sell trash + auto-vendor your loot.** Per-rarity rules (White / Green / Blue / Purple) with two cap modes: follow your equipped iLvl (default on Whites and Greens for fresh installs) or set a fixed max. Per-rarity bind-type filter (Any / BoE / BoP). Grey junk always auto-sells. Equipped gear is never touched.
- **Per-character + account-wide Sell Lists**, plus a Keep List and a Delete List. Add items by ID or name (or bulk-add from your bags by colour), and switch lists by activity with saved profiles. Each list row shows the item's icon and a quality-colored name, hovering a row brings up the item tooltip, and you can filter the view by rarity.
- **Project Ebonhold-specific protections** that the auto-rule sweep respects: affixed Rare/Epic drops (per-instance), chance-on-hit proc items, tomes and recipes (learned-state-aware), quest items, profession tools, equipped gear and looted upgrades, equipment-manager set members. Each protection has an Alt+Right-Click → **Allow Sell** override that's account-wide for items / per-affix-description for affixes.
- **Greedy Scavenger + Goblin Merchant loop.** Auto-summon, dismiss-on-mount, re-summon-if-stuck, combat-resilient. Auto-loot cycle dismisses the scavenger and brings up the merchant when bags fill, then re-summons to continue. Heavy-combat safe.
- **Fast Loot.** Throttled drain (~110 ms per slot) on manual loot windows so private-server anti-flood doesn't disconnect you. BoP-bind popups auto-confirm.
- **Process Bags panel** for disenchant / mill / prospect / pick-lock. One button drives the casts; bind a key and hold to drain a stack. Honours every protection.
- **Tooltip annotations** show what the addon will do *before* it does it: `Will Sell (<reason>)`, `Keep (<reason>)`, `Won't Sell (<reason>)`, `Will Delete`. No surprises at the merchant.
- **Per-item sellability inspector** (`/ec sellinfo` or Alt+Shift+Right-Click) traces the entire decision chain in chat. "Why isn't this selling?" is always one click away.
- **Per-category bag-slot border tints** in seven colours (Delete / Keep / Account Sell / Character Sell / Random affix / Junk / Rule-match), with per-category enable + colour picker. Slot-frame ring only.
- **Item-level overlay** (opt-in). Quality-coloured iLvl in the bottom-right corner of equippable gear slots, with player-adjustable font size. Three independently togglable surfaces: bags, character sheet & inspect, merchant.
- **Profile import/export** for sharing whole settings packs (lists + per-rarity rules) between characters or with other players.
- **Update nudge** (on by default). Tells you when a newer version is out. WoW 3.3.5a addons can't check the web, so EbonClearance learns the latest version from other users in your guild or group, then shows one chat line per session with a clickable copy-link to the latest release. Toggle it off on the main panel.
- **Guild stats sharing** (opt-in, off by default). The **Stats - Guild** panel pools your guild's or group's best farming zones, most-sold items, totals, and sold-by-rarity counts from members who also run EbonClearance. Anonymous by default (optionally show your name), guild/group only, shown as a live snapshot. Most-sold rows show the item tooltip on hover.
- **Reactive layout**, minimap button + LDB launcher, keybindings, first-run welcome, session + lifetime stats.
- **French & German ready.** The addon reads your client's language and shows translated text where a translation exists, falling back to English otherwise. Translations are community-written; see [docs/TRANSLATING.md](docs/TRANSLATING.md) to help translate into your language.

A complete enumeration of every feature lives in [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md). Behaviour history is in [CHANGELOG.md](CHANGELOG.md). For the design lineage and prior-art acknowledgement, see [NOTICE.md](NOTICE.md).

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
