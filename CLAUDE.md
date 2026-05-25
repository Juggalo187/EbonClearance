# Agent entry point

If you're an AI agent or a new contributor, **read [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) first**. It is the prescriptive guide for working in this codebase and covers:

- WoW 3.3.5a / WotLK / Lua 5.1 constraints (no `C_Timer`, no `goto`, no retail APIs)
- Multi-file architecture (one Core file + feature files + per-panel files + the event hub), and state-machine conventions
- Cached API upvalue patterns for hot paths
- SavedVariables migrations via `EnsureDB`
- Interface Options panel idempotency
- The decision record for **not** embedding Ace3
- **Gotchas and refactoring traps** - non-obvious design choices that have silently broken in the past. Read this before you "simplify" anything.

## The short version

- This is a WoW 3.3.5a addon for Project Ebonhold. After the file split (docs/CODE_REVIEW.md item 4) the addon ships as 23 `.lua` files; the event hub + slash commands + Bindings.xml glue live in [EbonClearance_Events.lua](EbonClearance_Events.lua) (renamed from the original monolith `EbonClearance.lua` in Stage 9). The [.toc](EbonClearance.toc) lists every file in load order.
- No external libraries. All Blizzard APIs.
- Run `stylua *.lua && luacheck *.lua` before committing. Luacheck sits at **0 warnings** (cleaned post-v2.6.0); keep it at zero. If a new warning appears, fix the cause or extend [`.luacheckrc`](.luacheckrc) - do not silence with blanket directives.
- Run all three invariant tests before committing:
  - `lua tests/test_layout_reactivity.lua` - the v2.11.0 reactive-panel-layout invariants. Any new widget that snapshots `EC_PANEL_WIDTH` MUST go through `EC_compCache.setPanelWidth(widget, x)` or `EC_compCache.registerWidth(widget, x)` - otherwise it'll silently freeze at build-time width on resize.
  - `lua tests/test_perf_guardrails.lua` - the v2.24.0 perf invariants (BAG_UPDATE coalescing, name-sort pre-compute, search debounce, affix-data cache by itemString) plus v2.29.0 invariants (normaliseAffixDesc case-fold, EnsureAccountDB allowedAffixes migration, list-mutation refresh call sites, sell-border helpers pinned to EC_compCache).
  - `lua tests/test_no_addon_references.lua` - the v2.29.0 no-third-party-references regression test. Counts comment-line occurrences of forbidden patterns and fails if any count exceeds the v2.29.0 baseline.
  - CI runs all three on every push via [.github/workflows/test.yml](.github/workflows/test.yml).
- **No third-party addon references in new EC artefacts** - the v2.29.0 implementation constraint. Code comments, commit messages, `CHANGELOG.md`, `README.md`, `docs/`, slash command help, `/ec bugreport` output, settings labels, and tooltip annotations MUST NOT name other addons. Detection code may still call specific globals (necessary), but the comment uses neutral framing ("host bag UI", "third-party bag UI adapter"). Existing mentions stay. Full statement in `docs/ADDON_GUIDE.md` "No third-party addon references in new EC artefacts".
- **Player-facing text stays brief, concise, and new-player friendly.** The v2.32.x text-simplification pass set the bar: tooltip labels, panel descriptions, checkbox text, chat messages, slash command help, and any other string a player can read in-game must lead with what happens, drop the "why" / mechanism, and avoid code jargon (no "predicate", "sweep", "veto", "throughput", "case-fold", "qualifying event", "auto-rule"). Use plain verbs ("Keep" / "Will Sell" / "Won't Sell" / "Will Delete"), parenthesised one-or-two-word reasons, active voice, present tense. Internal docstrings and code comments may stay technical; the rule is about the surface the player sees. When adding a new label, ask: "would a brand-new player understand this without context?" If not, simplify before shipping.
- **Never use em dashes (Unicode U+2014) anywhere in this repo.** Not in player-facing text, not in code comments, not in markdown docs, not in commit messages, not in CHANGELOG entries. Em dashes are a dead giveaway that an LLM wrote the text and read as inauthentic for an addon shipped by a human author. Use plain hyphens with spaces (` - `), periods, colons, or commas instead. The same rule applies to en dashes (Unicode U+2013) outside numeric ranges. A grep for the U+2014 character against the repo MUST return zero results - this is enforced by spot-check before commit and by reviewers. The rule applies recursively: this line itself does not contain the banned character, and neither should any future rule that references it (use the Unicode codepoint instead).
- Known deferred refactors are tracked in [docs/CODE_REVIEW.md](docs/CODE_REVIEW.md). Don't repeat items that are already there - cite them by number if you touch adjacent code.

## Conventions at a glance

- Everything is `local`, prefixed `EC_`. Globals are `EbonClearanceDB` and the slash-command handles only.
- Chat output goes through `PrintNice` / `PrintNicef`. Never call `DEFAULT_CHAT_FRAME:AddMessage` directly.
- State transitions use `STATE.*` constants (not raw strings) so typos fail loudly.
- Forward-declare `local` variables at the top of the file when functions defined earlier need to capture them as upvalues. This bit us in v2.0.12 and is now explicit.
- Cross-file references go through the shared `NS` namespace (`local NS = select(2, ...)` at the top of every file; `NS.compCache = EC_compCache` exposes the shared cache table; per-feature exposures like `NS.RefreshSellBorders` are wired at the end of the file that owns the body).

## Release process

- Bump version by pushing a `v*` tag; the GitHub workflow rewrites the `.toc` and `EbonClearance_Events.lua` (ADDON_VERSION constant) from the tag automatically
- Manual version-bumps to the `.toc` are not needed
- Release artifacts include every `EbonClearance*.lua` file, `EbonClearance.toc`, `Bindings.xml`, and `LICENSE`

For everything else, [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) is authoritative.
