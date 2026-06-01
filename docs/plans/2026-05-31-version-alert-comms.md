# Version-available alert + reusable comms transport - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alert the player (one quiet chat line per session) when a newer EbonClearance version is detected via addon-message gossip, built on a small reusable `NS.Comms` transport that later features (guild stats, server-wide comms) reuse.

**Architecture:** New `EbonClearance_Comms.lua` holds (1) a generic `NS.Comms` transport - prefix filter, `CHAT_MSG_ADDON` dispatch, `Send`/`RegisterHandler`, per-channel throttle - and (2) a version-check consumer that broadcasts a version request on GUILD/PARTY/RAID, replies by whisper, and nudges once per session. Gameplay-event triggers are wired in the existing event hub (`EbonClearance_Events.lua`); the addon-message receive frame lives in the comms module.

**Tech Stack:** WoW 3.3.5a client API (Lua 5.1). `SendAddonMessage` / `CHAT_MSG_ADDON`. No `C_Timer` (use `NS.Delay`), no `RegisterAddonMessagePrefix` (4.0+), no `GROUP_ROSTER_UPDATE` (4.0+). Reuses `NS.GetVersion`, `NS.PrintNicef`, `NS.Delay`, `NS.EnsureDB`, `NS.AddCheckbox`.

**Spec:** `docs/specs/2026-05-31-version-alert-comms-design.md`

---

## Shipping discipline (read before committing)

Per the project's verify-before-ship rule: per-task `git commit` steps below are **local** commits. **Do NOT `git push` or tag a release** until the in-game smoke test (Task 11) passes on Ebonhold - that test is the gate that proves the server even relays addon messages. The user copies the working tree into the live AddOns folder and tests in-game; wait for their confirmation before any push/tag. If you prefer, hold all commits until after Task 10's verification sweep.

Also: no em dashes (U+2014) anywhere. Player-facing strings stay brief. Shipped comments use neutral framing - never name another addon (the no-references test enforces this once the new file is in `SOURCE_PATHS`).

## File structure

- **Create** `EbonClearance_Comms.lua` - transport (`NS.Comms`) + version consumer. One responsibility: all addon-to-addon comms.
- **Create** `tests/test_comms_version.lua` - isolated-load unit tests for `parseVersion` + static-pattern invariants.
- **Modify** `EbonClearance.toc` - add the new file after `EbonClearance_Events.lua`.
- **Modify** `.github/workflows/test.yml` - add `luac5.1 -p EbonClearance_Comms.lua` and a run step for the new test.
- **Modify** `tests/test_perf_guardrails.lua` and `tests/test_no_addon_references.lua` - add the new file to both `SOURCE_PATHS`.
- **Modify** `EbonClearance_Events.lua` - `EnsureDB` default + event-hub triggers.
- **Modify** `EbonClearance_MainPanel.lua` - opt-out checkbox.
- **Modify** `EbonClearance_HelpPanel.lua` - FAQ entry.

---

### Task 1: Pure version parse/compare + isolated-load unit test

**Files:**
- Create: `tests/test_comms_version.lua`
- Create: `EbonClearance_Comms.lua`

- [ ] **Step 1: Write the failing test**

Create `tests/test_comms_version.lua`:

```lua
#!/usr/bin/env lua
-- Unit + static-pattern tests for EbonClearance comms / version logic.
-- Run from repo root:  lua tests/test_comms_version.lua
--
-- parseVersion is pure Lua, so unlike the other suites we LOAD the comms
-- chunk in isolation (stubbing only CreateFrame) and call it for real.

-- Minimal stub so EbonClearance_Comms.lua loads: any method on a frame is a no-op.
local function makeFrame()
    return setmetatable({}, { __index = function() return function() end end })
end
_G.CreateFrame = function() return makeFrame() end

-- Load with the addon vararg shape WoW uses: (addonName, NS).
local NS = {}
local chunk = assert(loadfile("EbonClearance_Comms.lua"))
chunk("EbonClearance", NS)

local fails = 0
local function eq(name, got, want)
    if got == want then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name .. "  (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
        fails = fails + 1
    end
end
local function ok(name, cond)
    eq(name, cond and true or false, true)
end

local pv = NS.Comms.parseVersion
eq("v2.10.0 encodes", pv("v2.10.0"), 2 * 1000000 + 10 * 1000 + 0)
eq("v2.38.4 encodes", pv("v2.38.4"), 2 * 1000000 + 38 * 1000 + 4)
ok("v2.10.0 > v2.9.0 (lexical-bug guard)", pv("v2.10.0") > pv("v2.9.0"))
eq("no-v prefix still parses", pv("2.9.0"), 2 * 1000000 + 9 * 1000 + 0)
eq("malformed -> nil", pv("v99.banana"), nil)
eq("missing patch -> nil", pv("2.3"), nil)
eq("non-string -> nil", pv(nil), nil)
eq("component >= 1000 -> nil (cap)", pv("v1000.0.0"), nil)

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
end
print("RESULT: all tests passed")
os.exit(0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/test_comms_version.lua`
Expected: FAIL - `cannot open EbonClearance_Comms.lua` / `loadfile` assertion (file does not exist yet).

- [ ] **Step 3: Create `EbonClearance_Comms.lua` with the parse function**

```lua
-- EbonClearance_Comms.lua
-- Addon-to-addon comms for EbonClearance.
--
-- Modeled on a proven 3.3.5a version-gossip pattern: broadcast a version
-- request on a group channel, peers reply by whisper, nudge once per
-- session. (Neutral framing per repo rule; no third-party addon named.)
--
-- 3.3.5a constraints baked in:
--   * No RegisterAddonMessagePrefix (4.0+): filter CHAT_MSG_ADDON by prefix.
--   * SendAddonMessage channels: PARTY / RAID / GUILD / BATTLEGROUND / WHISPER.
--   * Group events are PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE (the event-hub
--     wiring in EbonClearance_Events.lua uses those, not the 4.0 GROUP_ROSTER_UPDATE).
local NS = select(2, ...)

local Comms = {}
NS.Comms = Comms

-- Encode "v?MAJOR.MINOR.PATCH" as MAJOR*1000000 + MINOR*1000 + PATCH so peers
-- compare numerically. A plain string compare breaks at two digits
-- ("2.10.0" < "2.9.0" lexically); numeric encoding fixes that. Each component
-- must be < 1000; anything malformed returns nil and is ignored upstream.
function Comms.parseVersion(str)
    if type(str) ~= "string" then
        return nil
    end
    local s = str:gsub("^v", "")
    local maj, min, pat = s:match("^(%d+)%.(%d+)%.(%d+)")
    maj, min, pat = tonumber(maj), tonumber(min), tonumber(pat)
    if not (maj and min and pat) then
        return nil
    end
    if maj >= 1000 or min >= 1000 or pat >= 1000 then
        return nil
    end
    return maj * 1000000 + min * 1000 + pat
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `lua tests/test_comms_version.lua`
Expected: PASS (all 8 assertions) - note `v2.10.0 > v2.9.0` passing is the bug-fix proof.

- [ ] **Step 5: Commit (local)**

```bash
git add EbonClearance_Comms.lua tests/test_comms_version.lua
git commit -m "feat: comms version parse with numeric compare + isolated unit test"
```

---

### Task 2: Transport layer (Send / RegisterHandler / receive frame)

**Files:**
- Modify: `EbonClearance_Comms.lua`

- [ ] **Step 1: Add the transport below `Comms.parseVersion`**

```lua
-- ---- transport ----------------------------------------------------------
local PREFIX = "ECLR1" -- short, distinctive; trailing 1 = protocol version
local SEP = "\t" -- field separator; never appears in version strings or links

local handlers = {} -- msgType -> fn(payload, sender, channel)
local lastSendAt = {} -- throttle key -> GetTime() of last send
local SEND_THROTTLE_S = 30

function Comms.RegisterHandler(msgType, fn)
    handlers[msgType] = fn
end

function Comms.Send(msgType, payload, channel, target)
    local now = GetTime()
    -- Whisper replies throttle per target so we don't re-whisper the same
    -- peer repeatedly; broadcasts throttle per channel.
    local key = (channel == "WHISPER") and ("WHISPER:" .. tostring(target)) or channel
    if lastSendAt[key] and (now - lastSendAt[key]) < SEND_THROTTLE_S then
        return
    end
    lastSendAt[key] = now
    SendAddonMessage(PREFIX, msgType .. SEP .. tostring(payload), channel, target)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(self, event, prefix, message, channel, sender)
    if prefix ~= PREFIX then
        return -- cheap early-out: unrelated addon traffic costs one compare
    end
    local msgType, payload = message:match("^(.-)" .. SEP .. "(.*)$")
    if not msgType then
        return
    end
    local fn = handlers[msgType]
    if fn then
        fn(payload, sender, channel)
    end
end)
```

- [ ] **Step 2: Verify syntax**

Run: `luac -p EbonClearance_Comms.lua` (or `luac5.1 -p`)
Expected: no output (clean).

- [ ] **Step 3: Verify the unit test still loads + passes**

Run: `lua tests/test_comms_version.lua`
Expected: PASS (the `makeFrame` stub absorbs `RegisterEvent`/`SetScript`).

- [ ] **Step 4: Commit (local)**

```bash
git add EbonClearance_Comms.lua
git commit -m "feat: NS.Comms transport - send/handler/dispatch over CHAT_MSG_ADDON"
```

---

### Task 3: Version-check consumer (VERQ/VERR, nudge, probe entry point)

**Files:**
- Modify: `EbonClearance_Comms.lua`

- [ ] **Step 1: Append the consumer below the transport**

```lua
-- ---- version-check consumer ---------------------------------------------
local DOWNLOAD_URL = "github.com/powerfulqa/EbonClearance"
local versionNudgeShown = false -- once per session

local function myVersionStr()
    return NS.GetVersion and NS.GetVersion() or nil
end

local function playerName()
    return UnitName("player")
end

local function showVersionNudge(peerVerStr)
    if versionNudgeShown then
        return
    end
    versionNudgeShown = true
    NS.PrintNicef(
        "Update available: %s (you have %s). %s",
        peerVerStr,
        tostring(myVersionStr()),
        DOWNLOAD_URL
    )
end

-- Decide whether a peer's advertised version should trigger a nudge.
local function considerPeerVersion(verStr, sender)
    if not EbonClearanceDB or not EbonClearanceDB.versionAlerts then
        return
    end
    if sender and sender == playerName() then
        return -- ignore our own broadcast echoed back
    end
    local peerInt = Comms.parseVersion(verStr)
    local myInt = Comms.parseVersion(myVersionStr() or "")
    if not peerInt or not myInt then
        return
    end
    -- Sanity cap: ignore an absurd version (e.g. a troll whispering v99.99.99).
    -- Worst case a spoof costs one harmless chat line, so the guard stays light.
    local myMaj = math.floor(myInt / 1000000)
    local peerMaj = math.floor(peerInt / 1000000)
    if peerMaj > myMaj + 1 then
        return
    end
    if peerInt > myInt then
        NS.Delay(3, function()
            showVersionNudge(verStr)
        end)
    end
end

-- A VERQ carries the sender's version (learn it directly) AND asks us to
-- reply: whisper our version straight back to the requester.
Comms.RegisterHandler("VERQ", function(payload, sender, channel)
    considerPeerVersion(payload, sender)
    if EbonClearanceDB and EbonClearanceDB.versionAlerts and sender and sender ~= playerName() then
        Comms.Send("VERR", myVersionStr() or "", "WHISPER", sender)
    end
end)

-- A VERR is a direct reply carrying the replier's version.
Comms.RegisterHandler("VERR", function(payload, sender, channel)
    considerPeerVersion(payload, sender)
end)

-- Send-trigger entry point. Called by the event hub in EbonClearance_Events.lua
-- with "GUILD" / "PARTY" / "RAID". Gated + throttled internally.
function Comms.FireVersionProbe(channel)
    if not EbonClearanceDB or not EbonClearanceDB.versionAlerts then
        return
    end
    local v = myVersionStr()
    if not v then
        return
    end
    Comms.Send("VERQ", v, channel)
end
```

- [ ] **Step 2: Verify syntax + unit test**

Run: `luac -p EbonClearance_Comms.lua && lua tests/test_comms_version.lua`
Expected: clean syntax; unit test PASS (consumer references WoW globals only at call time, so isolated load is unaffected).

- [ ] **Step 3: Commit (local)**

```bash
git add EbonClearance_Comms.lua
git commit -m "feat: version consumer - VERQ/VERR handlers, sanity cap, once-per-session nudge"
```

---

### Task 4: SavedVariables default (`DB.versionAlerts`, opt-out)

**Files:**
- Modify: `EbonClearance_Events.lua` (inside `EnsureDB`, account-level defaults area, after the `if EbonClearanceDB == nil then EbonClearanceDB = {}` guard near line 543-545)

- [ ] **Step 1: Add the additive nil-default**

Locate the account-level default region in `EnsureDB` (search for an existing top-level default such as `EbonClearanceDB.autoAddEquipped`). Add:

```lua
    -- Version-update nudge (opt-out, default ON). Account-level: a single
    -- toggle that also gates all addon-message comms in this release.
    if EbonClearanceDB.versionAlerts == nil then
        EbonClearanceDB.versionAlerts = true
    end
```

- [ ] **Step 2: Verify syntax**

Run: `luac -p EbonClearance_Events.lua`
Expected: clean.

- [ ] **Step 3: Commit (local)**

```bash
git add EbonClearance_Events.lua
git commit -m "feat: EnsureDB default for versionAlerts (opt-out, additive)"
```

---

### Task 5: Event-hub triggers (GUILD on login, PARTY/RAID on group join)

**Files:**
- Modify: `EbonClearance_Events.lua` (the event-hub frame's `RegisterEvent` block and its `OnEvent` dispatcher - locate by searching for `RegisterEvent("MERCHANT_SHOW")`)

3.3.5a-correct events: `PARTY_MEMBERS_CHANGED`, `RAID_ROSTER_UPDATE` (NOT `GROUP_ROSTER_UPDATE`). `PLAYER_ENTERING_WORLD` is already registered.

- [ ] **Step 1: Register the two group events**

In the `RegisterEvent` block, add:

```lua
    f:RegisterEvent("PARTY_MEMBERS_CHANGED")
    f:RegisterEvent("RAID_ROSTER_UPDATE")
```

- [ ] **Step 2: Add the GUILD probe to the existing `PLAYER_ENTERING_WORLD` branch**

In the `OnEvent` dispatcher, inside the existing `PLAYER_ENTERING_WORLD` handling, add:

```lua
        -- Version gossip: after a short settle, ask the guild for versions.
        NS.Delay(5, function()
            if NS.Comms and GetGuildInfo("player") then
                NS.Comms.FireVersionProbe("GUILD")
            end
        end)
```

- [ ] **Step 3: Add group-join branches to the dispatcher**

Following the existing `elseif event == ...` chain, add:

```lua
    elseif event == "PARTY_MEMBERS_CHANGED" then
        -- Probe the party only when not in a raid (raid uses its own event).
        if NS.Comms and GetNumRaidMembers() == 0 and GetNumPartyMembers() > 0 then
            NS.Comms.FireVersionProbe("PARTY")
        end
    elseif event == "RAID_ROSTER_UPDATE" then
        if NS.Comms and GetNumRaidMembers() > 0 then
            NS.Comms.FireVersionProbe("RAID")
        end
```

(The 30s per-channel throttle in `Comms.Send` keeps these chatty roster events from spamming.)

- [ ] **Step 4: Verify syntax**

Run: `luac -p EbonClearance_Events.lua`
Expected: clean.

- [ ] **Step 5: Commit (local)**

```bash
git add EbonClearance_Events.lua
git commit -m "feat: wire version-probe triggers (guild on login, party/raid on group join)"
```

---

### Task 6: Register the new file (.toc, CI, both test SOURCE_PATHS)

**Files:**
- Modify: `EbonClearance.toc`
- Modify: `.github/workflows/test.yml`
- Modify: `tests/test_perf_guardrails.lua`
- Modify: `tests/test_no_addon_references.lua`

Note: both test `SOURCE_PATHS` lists already contain `EbonClearance_QuickstartPanel.lua` even though the working-tree `.toc` may not (working-tree version drift). Add the comms file in load-order position (after the `EbonClearance_Events.lua` entry); do not remove the Quickstart entry from the test lists.

- [ ] **Step 1: Add to `.toc` after the Events line**

In `EbonClearance.toc`, after `EbonClearance_Events.lua`:

```
EbonClearance_Comms.lua
```

- [ ] **Step 2: Add the syntax check to CI**

In `.github/workflows/test.yml`, under the "Lua syntax check" `run:` block, add a line:

```
          luac5.1 -p EbonClearance_Comms.lua
```

Then add a new test step after the "No third-party addon references" step:

```yaml
      - name: Comms / version regression tests
        run: lua5.1 tests/test_comms_version.lua
```

- [ ] **Step 3: Add to both test `SOURCE_PATHS`**

In `tests/test_perf_guardrails.lua` and `tests/test_no_addon_references.lua`, add `"EbonClearance_Comms.lua",` to the `SOURCE_PATHS` table immediately after the `"EbonClearance_Events.lua",` entry.

- [ ] **Step 4: Verify the no-references test still passes (neutral framing check)**

Run: `lua tests/test_no_addon_references.lua`
Expected: PASS. If it FAILS on `Auctionator` (baseline 3) or any other name, the comms file's comments leaked a forbidden name - reword to neutral framing. Do NOT bump the baseline.

- [ ] **Step 5: Verify perf guardrails still pass**

Run: `lua tests/test_perf_guardrails.lua`
Expected: PASS (adding a clean file to the concat changes nothing the static checks key on).

- [ ] **Step 6: Commit (local)**

```bash
git add EbonClearance.toc .github/workflows/test.yml tests/test_perf_guardrails.lua tests/test_no_addon_references.lua
git commit -m "build: register EbonClearance_Comms.lua in toc, CI, and test source lists"
```

---

### Task 7: Main panel opt-out checkbox

**Files:**
- Modify: `EbonClearance_MainPanel.lua` (in the panel build function, after an existing checkbox - follow the `NS.AddCheckbox` usage around line 319-374)

- [ ] **Step 1: Add the checkbox**

Pick the last checkbox/anchor widget in the relevant section and add below it (replace `PREVIOUS_ANCHOR` with the actual preceding widget variable, matching the file's pattern):

```lua
        local versionAlertCB = NS.AddCheckbox(
            content,
            "EbonClearanceVersionAlertCB",
            PREVIOUS_ANCHOR,
            "Tell me when an update is available",
            function()
                return DB.versionAlerts
            end,
            function(v)
                DB.versionAlerts = v
            end,
            -10
        )
```

If a subsequent widget anchors to `PREVIOUS_ANCHOR`, re-anchor it to `versionAlertCB` so layout flows.

- [ ] **Step 2: Verify syntax**

Run: `luac -p EbonClearance_MainPanel.lua`
Expected: clean.

- [ ] **Step 3: Verify layout-reactivity tests still pass**

Run: `lua tests/test_layout_reactivity.lua`
Expected: PASS.

- [ ] **Step 4: Commit (local)**

```bash
git add EbonClearance_MainPanel.lua
git commit -m "feat: Main panel toggle for the update-available nudge"
```

---

### Task 8: Help / FAQ entry

**Files:**
- Modify: `EbonClearance_HelpPanel.lua` (FAQ entries table - open the file and follow the existing entry shape)

- [ ] **Step 1: Add an FAQ entry following the existing format**

Locate the FAQ/troubleshooting entries structure in `EbonClearance_HelpPanel.lua` and add a new entry mirroring the existing entries' fields (id/question/answer or equivalent). Use this exact copy (brief, no em dash):

- Question: `How do I know when there's a new version?`
- Answer: `If another EbonClearance user in your guild or group has a newer version, you get one chat line at login telling you an update is available, with the download link. Turn this off with the "Tell me when an update is available" box on the main EbonClearance panel. EbonClearance cannot check for updates on its own; it learns the latest version from other players running it.`

- [ ] **Step 2: Verify syntax**

Run: `luac -p EbonClearance_HelpPanel.lua`
Expected: clean.

- [ ] **Step 3: Commit (local)**

```bash
git add EbonClearance_HelpPanel.lua
git commit -m "docs: Help FAQ entry for the update-available nudge"
```

---

### Task 9: Static-pattern invariants

**Files:**
- Modify: `tests/test_comms_version.lua` (append static-pattern checks before the final result block)

- [ ] **Step 1: Append source-pattern assertions**

```lua
-- ---- static-pattern invariants ----
local function readFile(p)
    local fh = assert(io.open(p, "r"))
    local s = fh:read("*a")
    fh:close()
    return s
end

local comms = readFile("EbonClearance_Comms.lua")
ok("comms uses numeric version encoding", comms:find("1000000", 1, true) ~= nil)
ok("comms has no 4.0 prefix-registration API", not comms:find("RegisterAddonMessagePrefix", 1, true))
ok("comms defines NS.Comms", comms:find("NS.Comms", 1, true) ~= nil)
ok("comms gates on versionAlerts", comms:find("versionAlerts", 1, true) ~= nil)

local events = readFile("EbonClearance_Events.lua")
ok("hub registers PARTY_MEMBERS_CHANGED", events:find("PARTY_MEMBERS_CHANGED", 1, true) ~= nil)
ok("hub registers RAID_ROSTER_UPDATE", events:find("RAID_ROSTER_UPDATE", 1, true) ~= nil)
ok("no 4.0 GROUP_ROSTER_UPDATE introduced", not events:find("GROUP_ROSTER_UPDATE", 1, true))
```

(Place these after the `parseVersion` assertions and before the `print()` / result block. They reuse the `ok` helper from Task 1.)

- [ ] **Step 2: Run the suite**

Run: `lua tests/test_comms_version.lua`
Expected: PASS (all unit + static checks).

- [ ] **Step 3: Commit (local)**

```bash
git add tests/test_comms_version.lua
git commit -m "test: static-pattern invariants for comms event names + numeric compare"
```

---

### Task 10: Full verification sweep

**Files:** none (verification only)

- [ ] **Step 1: Syntax-check every touched source file**

Run:
```bash
luac -p EbonClearance_Comms.lua EbonClearance_Events.lua EbonClearance_MainPanel.lua EbonClearance_HelpPanel.lua
```
Expected: no output.

- [ ] **Step 2: Run all four test suites**

Run:
```bash
lua tests/test_comms_version.lua
lua tests/test_perf_guardrails.lua
lua tests/test_layout_reactivity.lua
lua tests/test_no_addon_references.lua
```
Expected: each ends `RESULT: all tests passed`.

- [ ] **Step 3: Em-dash / en-dash guard**

Run (must return nothing):
```bash
grep -rnP "\x{2014}" --include="*.lua" --include="*.md" --include="*.toc" . || echo "clean: no U+2014"
```
Expected: `clean: no U+2014`.

- [ ] **Step 4: Commit any test/verification fixes (local)**

```bash
git add -A
git commit -m "chore: verification sweep for version-alert comms" || echo "nothing to commit"
```

---

### Task 11: In-game smoke test on Ebonhold (the gate)

**Files:** none (manual, in-game). This step validates whether Ebonhold relays `SendAddonMessage` at all - the prerequisite for Slices 2 and 3. **No push or release tag before this passes.**

- [ ] **Step 1:** User copies the working tree into the live `Interface/AddOns/EbonClearance` folder (the established local-repo-to-AddOn workflow).
- [ ] **Step 2:** Two clients in the **same guild**. On client A, temporarily edit `local ADDON_VERSION = "v2.38.4"` in `EbonClearance_Events.lua` to a higher value (e.g. `"v2.99.0"`) and `/reload`. On client B (real version), `/reload`. Expected: within ~5-8s, client B prints exactly one `Update available: v2.99.0 (you have ...)` line. Client A prints nothing.
- [ ] **Step 3:** Repeat in a **party** (not guilded together) to confirm the PARTY path. Then a raid for the RAID path.
- [ ] **Step 4:** Toggle the Main panel checkbox OFF on client B, `/reload`, repeat Step 2. Expected: no nudge.
- [ ] **Step 5:** Solo, non-guilded client: `/reload`. Expected: no error, no nudge.
- [ ] **Step 6:** Revert the temporary `ADDON_VERSION` edit on client A.
- [ ] **Step 7:** Report results. If Ebonhold drops addon messages (client B never nudges despite a higher peer), record that - it kills Slices 2/3 as designed and we rethink the transport. If it works, the feature is ready for the user to decide on push + release per the normal release process.

---

## Self-review notes

- **Spec coverage:** transport (Task 2), parse/compare bug fix (Task 1), VERQ/VERR + whisper reply + once-per-session nudge + sanity cap (Task 3), `DB.versionAlerts` default + gate (Tasks 3,4), 3.3.5a-correct triggers (Task 5), file registration (Task 6), checkbox (Task 7), Help FAQ (Task 8), tests (Tasks 1,9), verification + in-game gate (Tasks 10,11). All spec sections map to a task.
- **Simplification vs spec:** dropped `EC_compCache.latestKnownVersionInt` (the spec's "max seen" tracker) - `considerPeerVersion` compares peer-vs-mine directly and nudges once, so a max tracker is unused (YAGNI). `versionNudgeShown` is a file-local in the new small file (no 200-local-cap pressure outside `EbonClearance_Events.lua`).
- **Type/name consistency:** `Comms.parseVersion`, `Comms.Send`, `Comms.RegisterHandler`, `Comms.FireVersionProbe`, `EbonClearanceDB.versionAlerts`, prefix `"ECLR1"`, separator `"\t"`, message types `"VERQ"`/`"VERR"` are used identically across all tasks.
- **No placeholders** except the intentional `PREVIOUS_ANCHOR` in Task 7 (the anchor widget varies with where the implementer inserts the checkbox; instructions say to use the actual preceding widget and re-anchor the next one).
