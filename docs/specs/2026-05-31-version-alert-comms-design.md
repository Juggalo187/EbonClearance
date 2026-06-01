# Spec: Version-available alert + reusable addon-comms transport (Slice 1)

**Date**: 2026-05-31
**Status**: Approved (brainstorming complete; awaiting implementation plan)
**Target release**: v2.39.0 (next minor - new feature + new SavedVariables field + new file)
**Touched files**: `EbonClearance_Comms.lua` (new), `EbonClearance.toc`, `EbonClearance_Events.lua`, `EbonClearance_MainPanel.lua`, `EbonClearance_HelpPanel.lua`, `tests/test_perf_guardrails.lua`

## Goal

Alert a player, with one quiet chat line per session, when a newer EbonClearance version exists. WoW 3.3.5a Lua cannot make HTTP calls, so the only way EC can learn a newer version exists is by gossiping versions with other players running EC over the addon-message channel.

This slice also delivers the **reusable comms transport** (`NS.Comms`) that two planned follow-on features build on: a guild-shared stats screen (Slice 2) and a server-wide farming-spots / stats channel (Slice 3). Building version-alert first is deliberate: it is the smallest consumer, carries no personal data, and proves whether Project Ebonhold actually delivers addon messages before we invest in the larger features. Slices 2 and 3 are out of scope here (see "Out of scope").

## Prior art

`other/Auctionator/Auctionator.lua` ships the same gossip pattern (prefix `"ATR"`; a `VREQ` broadcast on GUILD, peers whisper a `V_` reply, a once-per-session reminder). We model on its proven shape. We fix its one defect: it compares versions with `verString > checkVerString` (lexical string compare), which is wrong at two digits (`"2.10.0" < "2.9.0"`). EC parses to an integer and compares numerically. Per the project's no-third-party-references rule, shipped comments use neutral framing ("a proven 3.3.5a version-gossip pattern") and never name the reference addon.

## Architecture

New file `EbonClearance_Comms.lua`, listed in `EbonClearance.toc` **after `EbonClearance_Events.lua`** so `EC_GetVersion()` / `ADDON_VERSION` are available at load. It contains two layers:

### 1. `NS.Comms` - generic transport (reused by Slices 2/3)

| API | Behaviour |
|---|---|
| `NS.Comms.Send(msgType, payload, channel, target)` | Builds the envelope, applies a per-channel send throttle, calls `SendAddonMessage(PREFIX, envelope, channel, target)`. |
| `NS.Comms.RegisterHandler(msgType, fn)` | Registers a consumer. `fn(payload, sender, channel)` runs on each matching inbound message. |

- Owns a single hidden frame registered for `CHAT_MSG_ADDON` (decoupled from the main event hub so the hub stays clean). 3.3.5a has no `RegisterAddonMessagePrefix` (that is 4.0+), so the handler filters by prefix itself and early-returns on mismatch - unrelated addon traffic costs one string compare.
- `SendAddonMessage` in 3.3.5a accepts only `"PARTY" | "RAID" | "GUILD" | "BATTLEGROUND" | "WHISPER"`. There is no `"CHANNEL"` type and no global channel; we use GUILD / PARTY / RAID / WHISPER only.

### 2. Version-check consumer

Registers `"VERQ"` and `"VERR"` handlers on `NS.Comms` and owns the parse / compare / nudge logic below.

**Event-registration split** (to avoid ambiguity): the *receive* path (`CHAT_MSG_ADDON`) is owned by the `NS.Comms` frame. The *send-trigger* events (`PLAYER_ENTERING_WORLD`, `PARTY_MEMBERS_CHANGED`, `RAID_ROSTER_UPDATE`) are registered in the existing event hub in `EbonClearance_Events.lua`, which forwards to a small `EC_FireVersionProbe(channel)` entry point in the version consumer. This keeps gameplay-event registration centralised in the hub (existing convention) while the addon-message receive frame stays self-contained in the comms module.

### Prefix and wire format

- Prefix: `"ECLR1"` (short, distinctive; the `1` is a protocol version for forward-compat; no spaces; within the 3.3.5a prefix length limit).
- Envelope: `msgType .. "\t" .. payload`. Tab is the field separator (never appears in version strings, item links, or colour codes). The dispatcher splits on the first tab; an unknown `msgType` is ignored.

## Version parse + compare

| Function | Behaviour |
|---|---|
| `EC_ParseVersion(str)` | Strip optional leading `v`; split on `.`; require exactly three numeric parts; return integer `major*1000000 + minor*1000 + patch` (each component must be `< 1000`). Any non-conforming input returns `nil` and is ignored. |

Numeric comparison replaces the prior-art lexical bug. `EC_GetVersion()` (returns `ADDON_VERSION`, e.g. `"v2.38.4"`) is the local source; confirm it is reachable cross-file and expose on `NS` if not already.

## Flow

### Triggers (3.3.5a-correct events)

- **Login settle**: on `PLAYER_ENTERING_WORLD`, `EC_Delay(5, fn)`; if `GetGuildInfo("player")` is non-nil, `NS.Comms.Send("VERQ", myVersionStr, "GUILD")`.
- **Group join**: `PARTY_MEMBERS_CHANGED` and `RAID_ROSTER_UPDATE` (NOT `GROUP_ROSTER_UPDATE`, which is 4.0+), throttled, send `"VERQ"` to `"PARTY"` / `"RAID"`.

### Exchange

- A `VERQ` payload carries the sender's version, so a receiver learns it directly **and** whispers its own version back: `NS.Comms.Send("VERR", myVersionStr, "WHISPER", sender)`.
- A `VERR` reply lets the original requester learn each peer's version.
- Both inbound `VERQ` (from others) and `VERR` run the same `considerPeerVersion(verStr, sender)`.

### Compare + notify

```lua
-- considerPeerVersion(verStr, sender):
--   parse peer version; ignore if nil, if sender is the player (self), or if it
--   fails the sanity cap; track EC_compCache.latestKnownVersionInt = max seen.
--   if peerInt > myInt: EC_Delay(3, showVersionNudge)
```

`showVersionNudge` is guarded by `EC_compCache.versionNudgeShown` (once per session) and prints one brief line:

```lua
PrintNicef("Update available: %s (you have %s). %s",
    peerVerStr, myVerStr, "github.com/powerfulqa/EbonClearance")
```

Leads with what happens; no em dash; new-player-friendly.

## Safety / anti-spoof

The only damage a spoofed version can do is a single harmless chat line, so the guard stays light (no signing / crypto - YAGNI):

- Strict numeric parse rejects malformed versions.
- Self-sent broadcasts are ignored (no self-nudge).
- **Sanity cap**: ignore an advertised version whose major is more than `+1` over ours, or any component `>= 1000`. Stops a troll whispering `"v99.99.99"` from triggering a false nudge.
- **Send throttle**: at most one `VERQ` per channel per 30s. Inbound is naturally bounded - we whisper back per distinct sender and nudge once per session.
- Graceful degradation: if Ebonhold drops addon messages, no peers reply, no nudge fires, nothing errors.

## SavedVariables / settings

- One additive account-level field via the `EnsureDB` nil-default pattern (downgrade-safe):
  ```lua
  DB.versionAlerts = (DB.versionAlerts == nil) and true or DB.versionAlerts  -- default ON
  ```
- Both send and notify are gated on `DB.versionAlerts`. In Slice 1 this toggle effectively gates all comms, since version traffic is the only consumer.
- One checkbox on the Main panel: "Tell me when an update is available".
- **Help/FAQ**: add an entry to `EbonClearance_HelpPanel.lua` describing the update nudge and the toggle (per the project rule that any player-facing change updates the Help FAQ).

## Reused existing utilities

- `EC_Delay(seconds, fn)` - existing delay helper (no `C_Timer`).
- `PrintNicef` - existing chat output (never `DEFAULT_CHAT_FRAME:AddMessage` directly).
- `EnsureDB` nil-default migration pattern.
- `EC_GetVersion()` / `ADDON_VERSION` (in `EbonClearance_Events.lua`).
- `NS = select(2, ...)` namespace pattern; `EC_compCache` for session flags.

## Testing

1. `luac -p` on every new/modified `.lua` (stylua/luacheck are CI-only in this environment).
2. The three invariant suites stay green: `tests/test_perf_guardrails.lua`, `tests/test_layout_reactivity.lua`, `tests/test_no_addon_references.lua`. The no-references test guards against any competitor name leaking into shipped EC artefacts.
3. New pure-Lua test for `EC_ParseVersion` + compare: `v2.10.0 > v2.9.0` (the fixed bug), `v2.38.4` parses, `"v99.banana"` -> nil, sanity cap rejects `v99.0.0`.
4. Repo grep for U+2014 returns zero before any commit.
5. In-game smoke on Ebonhold (the real unknown, and the gate for Slices 2/3): two clients in the same guild, one with a temporarily bumped `ADDON_VERSION`; the lower client prints the nudge exactly once. Repeat in a party for the PARTY/RAID path. A non-guilded solo client never errors and never nudges.

## Out of scope

- **Slice 2 - guild stats screen**: adds a `"STAT"` message type, an aggregation / merge / staleness model, and a UI. Requires explicit opt-in. Its own spec.
- **Slice 3 - server-wide farming spots / stats**: 3.3.5a has no native global addon channel, so "server-wide" would need a custom joined chat channel or a server-side relay, plus a consent model and a private-server ToS review. Deliberately deferred until Slice 1 proves the transport works on Ebonhold.
