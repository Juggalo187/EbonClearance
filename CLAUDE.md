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

- This is a WoW 3.3.5a addon for Project Ebonhold. After the file split (docs/CODE_REVIEW.md item 4), the v2.36.0 Help / Stats sub-panel extractions, the v2.38.0 Quickstart panel, the v2.39.0 `EbonClearance_Comms.lua` addition, and the v2.40.0 guild-share panel (`EbonClearance_GuildShare.lua` + `EbonClearance_GuildPanel.lua`), the addon ships as 29 `.lua` files; the event hub + slash commands + Bindings.xml glue live in [EbonClearance_Events.lua](EbonClearance_Events.lua) (renamed from the original monolith `EbonClearance.lua` in Stage 9). Addon-to-addon comms (the version-update gossip + the reusable `NS.Comms` transport) live in [EbonClearance_Comms.lua](EbonClearance_Comms.lua), which loads after the event hub; `EbonClearance_GuildShare.lua` (a `NS.Comms` consumer) + `EbonClearance_GuildPanel.lua` add the guild/group-scoped, opt-in, anonymous-by-default stats sharing ("Stats - Guild"). The [.toc](EbonClearance.toc) lists every file in load order.
- No external libraries. All Blizzard APIs.
- Run `stylua *.lua && luacheck *.lua` before committing. Luacheck sits at **0 warnings** (cleaned post-v2.6.0); keep it at zero. If a new warning appears, fix the cause or extend [`.luacheckrc`](.luacheckrc) - do not silence with blanket directives.
- Run all five invariant tests before committing:
  - `lua tests/test_layout_reactivity.lua` - the v2.11.0 reactive-panel-layout invariants. Any new widget that snapshots `EC_PANEL_WIDTH` MUST go through `EC_compCache.setPanelWidth(widget, x)` or `EC_compCache.registerWidth(widget, x)` - otherwise it'll silently freeze at build-time width on resize.
  - `lua tests/test_perf_guardrails.lua` - the v2.24.0 perf invariants (BAG_UPDATE coalescing, name-sort pre-compute, search debounce, affix-data cache by itemString) plus v2.29.0 invariants (normaliseAffixDesc case-fold, EnsureAccountDB allowedAffixes migration, list-mutation refresh call sites, sell-border helpers pinned to EC_compCache).
  - `lua tests/test_comment_hygiene.lua` - the v2.29.0 comment hygiene check. Counts comment-line occurrences of a fixed watch-list of forbidden patterns and fails if any count exceeds the v2.29.0 baseline.
  - `lua tests/test_comms_version.lua` - the v2.39.0 comms / version-alert invariants. Loads `EbonClearance_Comms.lua` in isolation and unit-tests `parseVersion` (numeric compare, not lexical), plus static-pattern checks that the comms layer keeps its 3.3.5a-safe shape (no `RegisterAddonMessagePrefix`, no `GROUP_ROSTER_UPDATE`, `versionAlerts` gate present).
  - `lua tests/test_guildshare.lua` - the v2.40.0 guild-share invariants. Loads `EbonClearance_GuildShare.lua` in isolation and unit-tests the payload encode/decode (items by `id~name`, per-rarity counts) + aggregation merge (pool items by id, contributor names, best-GPH holder name), plus static-pattern checks (reply gated on `shareGuildData`, uses `NS.Comms`, no `GROUP_ROSTER_UPDATE`).
  - CI runs all five on every push via [.github/workflows/test.yml](.github/workflows/test.yml), and (v2.39.0) the release workflow re-runs them before packaging so a tag can't ship red.
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

The release is driven by [.github/workflows/release.yml](.github/workflows/release.yml). It triggers on any `v*` tag push (and via `workflow_dispatch` for recovery). The workflow:

1. Rewrites `EbonClearance.toc` (Title colored badge + `## Version:` field) and `EbonClearance_Events.lua`'s `ADDON_VERSION` constant from the tag name. **Manual version-bumps to those files are not needed.**
2. Packages every `EbonClearance*.lua` file, `EbonClearance.toc`, `Bindings.xml`, and `LICENSE` into `EbonClearance.zip`.
3. Commits the version bump back to `origin/master` as a `Update version to vX.Y.Z [skip ci]` bot commit. **After the workflow runs, your local branch will be 1 commit behind origin; run `git pull --rebase` to catch up before the next commit.**
4. Extracts the `### vX.Y.Z` stanza from [CHANGELOG.md](CHANGELOG.md) and uses it as the body of the GitHub Release at `https://github.com/powerfulqa/EbonClearance/releases/tag/vX.Y.Z`. If no stanza exists, the workflow falls back to a generic stub: `Patch release. See the previous minor version for the feature description.` The auto-generated `**Full Changelog**: ...compare/...` footer is appended automatically.

### The correct order

**Always add the CHANGELOG stanza AND sync the surrounding docs BEFORE you tag.** The recommended sequence:

1. Make code changes; verify with the four invariant tests.
2. **Audit the iteration for leftovers and clean them up.** Multi-iteration features leave debris: stale comments that describe controls/parameters that were renamed or removed, orphaned locals/functions, unreachable branches, doc-comment return signatures that drifted. Sweep the diff (grep for the names of any symbols you removed; read each changed function end-to-end) and fix what you find BEFORE tagging, so the release ships clean. This is also the moment to spot feature-creep duplication introduced across iterations.
3. Add the `### vX.Y.Z` stanza to `CHANGELOG.md` describing what's in the release.
4. **Sync the docs.** Audit the diff and ask "did this patch touch anything externally visible to a player or a contributor?" If yes, update the relevant docs in the same patch:
   - In-game Help / FAQ ([EbonClearance_HelpPanel.lua](EbonClearance_HelpPanel.lua)) - for any player-facing surface change (new panel, toggle, view, slash command, tooltip annotation, changed default, schema-visible change).
   - [README.md](README.md) - for installation, configuration, slash-command table, or feature-bullet changes. Slash-command additions ALWAYS get a row in the README table.
   - [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) - for architecture, file layout, shared helpers, naming conventions, test invariants, or 3.3.5a gotchas. Contributors read this first.
   - [NOTICE.md](NOTICE.md) - for adopting or diverging from a convention shared with related projects.
   - This file ([CLAUDE.md](CLAUDE.md)) - if you add or remove a `.lua` file (update the count), change the test invariants list, or introduce a new release-process step.
5. Commit code + CHANGELOG + docs together (or in two commits if the diff is large: features first, then docs).
6. Push to `origin/master`.
7. Tag the release: `git tag vX.Y.Z && git push origin vX.Y.Z`.
8. The workflow runs (~1-2 min) and re-runs all five test suites at the gate. The version-bump bot commit (`Update version to vX.Y.Z [skip ci]`) lands on `origin/master`, carrying the CI-side rewrites of `EbonClearance.toc` + `EbonClearance_Events.lua`'s `ADDON_VERSION`.
9. **Required final step: `git pull --rebase` to sync local with the CI build work.** Because step 8 committed the version bump upstream, your local branch is now 1 commit behind `origin/master`. You MUST rebase before any further work, or the next local commit diverges from origin. Confirm with `git status -sb` - it should read `## master...origin/master` with no `[ahead N]` / `[behind N]`.

If you tag without a CHANGELOG stanza (e.g. a fast patch where the commit message was the only record), the release page ships with the fallback stub and players reading the release notes see no detail. The recovery path:

- Add the stanza to CHANGELOG.md retroactively + commit + push.
- Extract the stanza and update the existing release body:
  ```
  awk -v target="### vX.Y.Z" '$0 == target { f=1; print; next } f && /^### v/ { f=0 } f { print }' CHANGELOG.md > /tmp/notes.md
  printf "\n\n**Full Changelog**: https://github.com/powerfulqa/EbonClearance/compare/vPREV...vX.Y.Z\n" >> /tmp/notes.md
  gh release edit vX.Y.Z --notes-file /tmp/notes.md
  ```
  The `gh release edit` REPLACES the body, so re-append the compare-link footer manually (the workflow's `generate_release_notes: true` adds it on first creation but doesn't preserve it on edits).

### Discord patch note

After each tag, the user expects a copy-paste Discord post in chat-summary style. The format matches the CHANGELOG stanza tone but compresses heavily (Discord's 2000-char limit). Lead with the headline change in **bold**, then a short feature list, then a `**Full Changelog**:` link. No emojis (the project rule applies). Patch releases get tighter posts than minor releases.

### Version numbering

- **Minor (`vX.Y.0`)**: new features, schema additions, sizeable changes. Earns a long-form CHANGELOG stanza with the headline-bullet format the v2.37.0 entry uses.
- **Patch (`vX.Y.Z` where Z > 0)**: fixes only, no new features, no schema-breaking changes. Shorter CHANGELOG stanza. Always safe-overwrite from the previous minor.

Schema additions are allowed in patch releases as long as they're additive and gated by `EnsureDB`'s nil-default pattern (existing saves auto-migrate, downgrade-safe). Schema *removals* require a minor bump.

For everything else, [docs/ADDON_GUIDE.md](docs/ADDON_GUIDE.md) is authoritative.
