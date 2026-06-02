# Spec: Guild-scoped anonymous farming + stats sharing (comms Slice 3, descoped)

**Date**: 2026-06-01
**Status**: Approved (brainstorming complete; awaiting implementation plan)
**Target release**: v2.40.0 (next minor - new feature + new file(s) + new SavedVariables field)
**Touched files**: `EbonClearance_GuildShare.lua` (new), `EbonClearance_GuildPanel.lua` (new), `EbonClearance.toc`, `EbonClearance_Events.lua` (EnsureDB default), `.github/workflows/test.yml` (two new `luac` lines + a `test_guildshare.lua` run step), `.github/workflows/release.yml` (add `test_guildshare.lua` to the verify step; `luac` there is already globbed), `tests/test_perf_guardrails.lua` + `tests/test_comment_hygiene.lua` (SOURCE_PATHS), new `tests/test_guildshare.lua`

## Goal

Let guildmates (and group members) pool, anonymously, two things EbonClearance already tracks locally: **best farming zones** (`DB.copperByZone`, gold earned at sell time per zone) and **headline stats** (lifetime gold / items / best GPH). On opening a new "Guild" panel, a player sees their guild's best farming zones ranked by pooled gold, plus combined guild totals. Reuses the proven `NS.Comms` transport from v2.39.0.

This is the **descoped** form of the original "server-wide farming spots / stats" idea (comms Slice 3). Server-wide delivery was dropped deliberately: 3.3.5a `SendAddonMessage` has no global channel, and the only client-side path to "everyone on the server" is a custom chat channel via `SendChatMessage`, which carries real anti-spam / disconnect risk and a private-server ToS grey-area. Guild/group scope keeps the feature on the safe, proven addon-message transport.

## Decisions locked (via brainstorming)

- **Scope:** guild/group only (no server-wide channel, no server-operator dependency).
- **Data:** both farming zones and a stats view, in one "Guild" panel.
- **Identity:** anonymous aggregate - no names shown or stored (see anonymity caveat).
- **Refresh:** on-demand (request on panel open + a Refresh button), mirroring the v2.39.0 version handshake.
- **Consent:** opt-in, default off.

## Architecture

Two new files:

1. `EbonClearance_GuildShare.lua` - the comms consumer + aggregation. Loads after `EbonClearance_Comms.lua` (needs `NS.Comms`). Registers two message types on `NS.Comms`, builds the local payload, aggregates replies into a transient table, and exposes:
   - `NS.GuildShare.RequestNow()` - broadcast a request (throttled).
   - `NS.GuildShare.GetAggregate()` - return the current aggregate for the panel.
2. `EbonClearance_GuildPanel.lua` - the Interface Options "Guild" sub-panel, registered like the other sub-panels.

Both are added to `EbonClearance.toc` (after `EbonClearance_Comms.lua`), the CI `luac` checks (the `release.yml` glob already covers `EbonClearance*.lua`; add explicit lines to `test.yml`), and the `SOURCE_PATHS` of `tests/test_perf_guardrails.lua` and `tests/test_comment_hygiene.lua`.

## Wire protocol (rides on `NS.Comms`, prefix `ECLR1`)

| Type | Direction | When | Payload |
|---|---|---|---|
| `GREQ` | broadcast on GUILD (+ PARTY/RAID if grouped) | panel `OnShow`, Refresh click | empty (or a short nonce) |
| `GDAT` | WHISPER reply to the requester | on receiving a `GREQ` from someone else, if opted in | compact, < 255 bytes, top-5 zones |

`GDAT` payload format (single message, capped to stay under the ~255-byte addon-message limit):
```
stats:<totalCopper>,<itemsSold>,<bestGPH>|items:<itemID>=<count>;... (max 3)|zones:<Zone>=<copper>;... (max 5)
```
Items are the player's top-3 by `DB.soldItemCounts` (lifetime vendor-sell count; numeric IDs, so always delimiter-safe). Zones are the player's top-5 by `copperByZone`; any zone whose name contains a delimiter (`=`, `;`, `|`, `,`, tab) is skipped defensively. Sections are split on `|` and dispatched by prefix, so order is irrelevant and old (no-items) payloads still decode. If the assembled payload would exceed the limit, trailing **zones** are dropped until it fits - stats and items are tiny and kept (worst-case floor payload is ~105 bytes, leaving ~135 bytes for zones).

`GREQ` send is throttled (aligned with the comms per-channel send throttle, ~30 s) so spam-clicking Refresh cannot flood the guild channel or blank the panel. `RequestNow()` resets the aggregate, sends `GREQ`, and schedules `NS.Delay(3, refreshDisplay)`.

## Aggregation + anonymity

- Transient aggregate on `EC_compCache.guildAgg` (session-only, never saved):
  `{ zones = { [name] = { copper, contributors } }, items = { [itemID] = { count, contributors } }, totalCopper, totalItems, bestGPH, memberCount }`.
- On each `GREQ` the requester sends, the aggregate is reset (fresh snapshot per query).
- On each inbound `GDAT`: parse, then merge - sum copper per zone and count per item ID (each bumping its `contributors`), accumulate `totalCopper` / `totalItems`, track max `bestGPH`, increment `memberCount`.
- **Anonymous:** EC ignores the `GDAT` sender entirely - it is neither stored nor displayed. Only pooled aggregates are shown.
- **Honest caveat (documented in-panel and in code comments):** a 3.3.5a addon message always carries its sender in the `CHAT_MSG_ADDON` event. "Anonymous" therefore means EC discards the sender and presents only aggregates - it does not hide the sender from someone actively logging addon traffic. No attempt is made to claim otherwise.

## Opt-in / privacy

- New account-level field via the additive `EnsureDB` nil-default: `EbonClearanceDB.shareGuildData` (boolean, default `false`).
- Gates **sending** `GDAT`. Receiving / viewing aggregates is always allowed (it just shows only what opted-in peers sent).
- Panel checkbox: "Share my farming data with my guild (anonymous)".

## UI (`EbonClearance_GuildPanel.lua`)

A "Guild" Interface Options sub-panel:
- Header + one-line description (brief, new-player-friendly).
- Opt-in checkbox bound to `EbonClearanceDB.shareGuildData` (read/write the top-level field directly, as the Main-panel update toggle does - the builder has no `DB` proxy upvalue).
- **Guild's Best Farming Zones**: top-N pooled zones, each `Zone - Xg (from N)`, gold via `NS.CopperToColoredText`.
- **Guild Totals**: combined gold / items, member count, best gold/hour seen.
- **Guild's Most-Sold Items**: top-5 pooled by lifetime sell count, each `Item - N sold (from M)`; item names resolved via `GetItemInfo` with an `item #<id>` fallback for items not yet client-cached.
- **Refresh** button -> `NS.GuildShare.RequestNow()`.
- A "N shared in the last query" line; empty-state help when not in a guild, not opted in, or no replies yet.

Reuses `NS.AddCheckbox`, `NS.MakeHeader`, `NS.MakeLabel`, `NS.CopperToColoredText`, and the panel infra (`initPanel` registration, `EC_compCache.setPanelWidth` for reactive width).

## Triggers

- Panel `OnShow` and the Refresh button call `NS.GuildShare.RequestNow()`.
- `GREQ` / `GDAT` handlers are registered on `NS.Comms` at load (in `EbonClearance_GuildShare.lua`).
- No new event-hub registrations are required (the comms receive frame already owns `CHAT_MSG_ADDON`).

## Reused existing utilities

- `NS.Comms.Send` / `NS.Comms.RegisterHandler` (v2.39.0 transport).
- `DB.copperByZone` (existing per-character per-zone gold), lifetime `totalCopper` / `itemsSold` / `bestGPH`.
- `NS.Delay`, `NS.PrintNicef`, `EnsureDB`, `NS.CopperToColoredText`, panel widget factories.

## Testing

1. `luac -p` on the two new files (+ the local `loadfile` syntax check).
2. New `tests/test_guildshare.lua`: load `EbonClearance_GuildShare.lua` in isolation (stub `CreateFrame` etc. like `test_comment_hygiene`/`test_comms_version`) and unit-test the **pure** functions - payload encode/decode round-trip, the top-5 cap + over-limit trimming, delimiter-skip, and the aggregation merge (two payloads pool correctly). Plus static-pattern checks: gated on `shareGuildData`, uses `NS.Comms`, exposes `NS.GuildShare`, no new globals, ≤5-zone cap present.
3. The existing suites stay green: `test_perf_guardrails`, `test_layout_reactivity` (new panel uses `setPanelWidth`), `test_comment_hygiene` (no third-party names; neutral comments), `test_comms_version`.
4. Repo grep for U+2014 returns zero.
5. In-game smoke on Ebonhold: two guildmates, both opted in, each having sold in different zones; open the Guild panel and confirm pooled zones + totals appear and the member count is right; confirm a non-opted-in client contributes nothing; confirm a solo / non-guilded client sees the empty-state without errors.

## Out of scope

- Server-wide delivery (custom chat channel or server relay) - dropped.
- Named leaderboards / per-player attribution.
- Persisting the guild aggregate across sessions (transient only).
- Sharing anything beyond zones + the three headline stats.
