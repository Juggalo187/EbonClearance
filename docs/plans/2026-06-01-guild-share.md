# Guild-scoped anonymous farming + stats sharing - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let opted-in guildmates anonymously pool their best farming zones (`DB.copperByZone`) and headline stats over the existing `NS.Comms` transport, shown in a new "Guild" options panel.

**Architecture:** A new `EbonClearance_GuildShare.lua` registers two message types (`GREQ`/`GDAT`) on the v2.39.0 `NS.Comms` layer, builds a compact anonymous payload from data EC already tracks, and aggregates replies into a transient table. A new `EbonClearance_GuildPanel.lua` displays the aggregate and owns the opt-in toggle + Refresh.

**Tech Stack:** WoW 3.3.5a / Lua 5.1. `NS.Comms` (SendAddonMessage/CHAT_MSG_ADDON). Reuses `NS.Delay`, `EnsureDB`, `NS.AddCheckbox`, `NS.CopperToColoredText`, `EC_compCache.initPanel`.

**Spec:** `docs/specs/2026-06-01-guild-share-design.md`

---

## Shipping discipline

Per-task `git commit` steps are **local**. Do NOT push or tag until the in-game smoke test (Task 7) passes. No em dashes (U+2014) anywhere. Player-facing text brief. Shipped comments use neutral framing (no third-party addon names). New file: account-level opt-in defaults OFF.

## File structure

- **Create** `EbonClearance_GuildShare.lua` - pure encode/decode/merge helpers + the `GREQ`/`GDAT` consumer + `RequestNow`/`GetAggregate`. One responsibility: guild data exchange.
- **Create** `EbonClearance_GuildPanel.lua` - the "Guild" Interface Options sub-panel (UI only).
- **Modify** `EbonClearance.toc` (load both after `EbonClearance_Comms.lua`), `EbonClearance_Events.lua` (EnsureDB default), `.github/workflows/test.yml` + `release.yml` (CI), `tests/test_perf_guardrails.lua` + `tests/test_comment_hygiene.lua` (SOURCE_PATHS).
- **Create** `tests/test_guildshare.lua` - isolated-load unit + static tests.

---

### Task 1: Pure payload + aggregation core (TDD)

**Files:**
- Create: `tests/test_guildshare.lua`
- Create: `EbonClearance_GuildShare.lua`

- [ ] **Step 1: Write the failing test** - create `tests/test_guildshare.lua`:

```lua
#!/usr/bin/env lua
-- Unit + static tests for guild-share encode/decode/merge.
-- Run: lua tests/test_guildshare.lua
-- Loads the chunk in isolation with a stub NS.Comms (it registers handlers at load).

local NS = {
    Comms = { RegisterHandler = function() end, Send = function() end },
    Delay = function() end,
}
local chunk = assert(loadfile("EbonClearance_GuildShare.lua"))
chunk("EbonClearance", NS)
local gs = NS.GuildShare

local fails = 0
local function ok(name, cond)
    if cond then print("PASS  " .. name) else print("FAIL  " .. name); fails = fails + 1 end
end
local function eq(name, a, b) ok(name .. " (" .. tostring(a) .. ")", a == b) end

-- topZones: sort desc, cap to n
local top = gs.topZones({ ["Durotar"] = 50, ["Barrens"] = 200, ["Mulgore"] = 10 }, 2)
eq("topZones count", #top, 2)
eq("topZones[1] name", top[1].name, "Barrens")
eq("topZones[1] copper", top[1].copper, 200)

-- encode/decode round-trip
local payload = gs.encodePayload({ { name = "Barrens", copper = 200 } }, { totalCopper = 999, itemsSold = 12, bestGPH = 3456 })
ok("payload has stats", payload:find("stats:", 1, true) ~= nil)
ok("payload has zones", payload:find("zones:", 1, true) ~= nil)
local dec = gs.decodePayload(payload)
eq("decode totalCopper", dec.stats.totalCopper, 999)
eq("decode itemsSold", dec.stats.itemsSold, 12)
eq("decode bestGPH", dec.stats.bestGPH, 3456)
eq("decode zone name", dec.zones[1].name, "Barrens")
eq("decode zone copper", dec.zones[1].copper, 200)

-- cap to 5 zones + skip delimiter-bad names
local many = {}
for i = 1, 9 do many[i] = { name = "Zone" .. i, copper = i * 10 } end
many[10] = { name = "Bad=Zone", copper = 5 }
local capped = gs.encodePayload(many, { totalCopper = 0, itemsSold = 0, bestGPH = 0 })
local dc = gs.decodePayload(capped)
ok("capped to <= 5 zones", #dc.zones <= 5)
ok("delimiter zone skipped", capped:find("Bad=Zone", 1, true) == nil)
ok("payload under 255 bytes", #capped < 255)

-- merge: pool two replies
local agg = gs.newAggregate()
gs.mergeReply(agg, gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 100 } }, { totalCopper = 100, itemsSold = 5, bestGPH = 1000 })))
gs.mergeReply(agg, gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 50 } }, { totalCopper = 200, itemsSold = 3, bestGPH = 2000 })))
eq("merge memberCount", agg.memberCount, 2)
eq("merge Barrens copper", agg.zones["Barrens"].copper, 150)
eq("merge Barrens contributors", agg.zones["Barrens"].contributors, 2)
eq("merge totalCopper", agg.totalCopper, 300)
eq("merge totalItems", agg.totalItems, 8)
eq("merge bestGPH (max)", agg.bestGPH, 2000)

print()
if fails > 0 then io.stderr:write("RESULT: " .. fails .. " test(s) failed\n"); os.exit(1) end
print("RESULT: all tests passed")
os.exit(0)
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua tests/test_guildshare.lua`
Expected: FAIL - `cannot open EbonClearance_GuildShare.lua`.

- [ ] **Step 3: Create `EbonClearance_GuildShare.lua` with the pure core**

```lua
-- EbonClearance_GuildShare.lua
-- Guild/group-scoped anonymous sharing of best farming zones + headline stats.
-- Rides on NS.Comms (GREQ request / GDAT reply). Anonymous = the GDAT sender is
-- ignored and never stored or shown; only pooled aggregates are displayed. (A
-- 3.3.5a addon message always carries its sender, so this is anonymity at the
-- display/storage layer, not concealment from anyone logging addon traffic.)
local NS = select(2, ...)

local GuildShare = {}
NS.GuildShare = GuildShare

local MAX_ZONES = 5
local MAX_PAYLOAD = 240 -- stay safely under the ~255-byte addon-message limit

-- Return an array of {name, copper} for the top n zones, highest copper first.
function GuildShare.topZones(copperByZone, n)
    local arr = {}
    for name, copper in pairs(copperByZone or {}) do
        arr[#arr + 1] = { name = name, copper = tonumber(copper) or 0 }
    end
    table.sort(arr, function(a, b) return a.copper > b.copper end)
    while #arr > (n or MAX_ZONES) do
        arr[#arr] = nil
    end
    return arr
end

-- A zone name is unsafe if it contains one of our payload delimiters.
local function zoneNameSafe(name)
    return type(name) == "string" and not name:find("[=;|,\t]")
end

-- Build the compact wire payload. Caps to MAX_ZONES, skips delimiter-unsafe
-- names, and trims trailing zones until the whole thing fits MAX_PAYLOAD.
function GuildShare.encodePayload(zones, stats)
    local s = stats or {}
    local statsPart = string.format(
        "stats:%d,%d,%d",
        math.floor(tonumber(s.totalCopper) or 0),
        math.floor(tonumber(s.itemsSold) or 0),
        math.floor(tonumber(s.bestGPH) or 0)
    )
    local picked = {}
    for _, z in ipairs(zones or {}) do
        if #picked >= MAX_ZONES then
            break
        end
        if zoneNameSafe(z.name) then
            picked[#picked + 1] = z
        end
    end
    local function assemble(list)
        local parts = {}
        for _, z in ipairs(list) do
            parts[#parts + 1] = z.name .. "=" .. tostring(math.floor(tonumber(z.copper) or 0))
        end
        return statsPart .. "|zones:" .. table.concat(parts, ";")
    end
    local payload = assemble(picked)
    while #payload > MAX_PAYLOAD and #picked > 0 do
        picked[#picked] = nil
        payload = assemble(picked)
    end
    return payload
end

-- Parse a payload back into { stats = {...}, zones = { {name, copper}, ... } }.
function GuildShare.decodePayload(str)
    local out = { stats = { totalCopper = 0, itemsSold = 0, bestGPH = 0 }, zones = {} }
    if type(str) ~= "string" then
        return out
    end
    local c, i, g = str:match("stats:(%d+),(%d+),(%d+)")
    if c then
        out.stats.totalCopper = tonumber(c) or 0
        out.stats.itemsSold = tonumber(i) or 0
        out.stats.bestGPH = tonumber(g) or 0
    end
    local zonesPart = str:match("zones:(.*)$")
    if zonesPart then
        for entry in zonesPart:gmatch("[^;]+") do
            local name, copper = entry:match("^(.-)=(%d+)$")
            if name and name ~= "" then
                out.zones[#out.zones + 1] = { name = name, copper = tonumber(copper) or 0 }
            end
        end
    end
    return out
end

-- Fresh transient aggregate (session-only; never saved).
function GuildShare.newAggregate()
    return { zones = {}, totalCopper = 0, totalItems = 0, bestGPH = 0, memberCount = 0 }
end

-- Merge one decoded reply into the aggregate.
function GuildShare.mergeReply(agg, decoded)
    if not agg or not decoded then
        return
    end
    agg.memberCount = agg.memberCount + 1
    agg.totalCopper = agg.totalCopper + (decoded.stats.totalCopper or 0)
    agg.totalItems = agg.totalItems + (decoded.stats.itemsSold or 0)
    if (decoded.stats.bestGPH or 0) > agg.bestGPH then
        agg.bestGPH = decoded.stats.bestGPH
    end
    for _, z in ipairs(decoded.zones or {}) do
        local e = agg.zones[z.name]
        if not e then
            e = { copper = 0, contributors = 0 }
            agg.zones[z.name] = e
        end
        e.copper = e.copper + (z.copper or 0)
        e.contributors = e.contributors + 1
    end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `lua tests/test_guildshare.lua`
Expected: PASS - all assertions, `RESULT: all tests passed`.

- [ ] **Step 5: Commit (local)**

```bash
git add EbonClearance_GuildShare.lua tests/test_guildshare.lua
git commit -m "feat: guild-share payload encode/decode + aggregation core with unit tests"
```

---

### Task 2: Transport wiring (request/reply + opt-in gate)

**Files:**
- Modify: `EbonClearance_GuildShare.lua`

- [ ] **Step 1: Append the consumer + request logic below the pure core**

```lua
-- ---- transport consumer + on-demand request ----------------------------
local GREQ_THROTTLE_S = 8 -- min seconds between our own GREQ broadcasts
local lastReqAt = 0

-- Build this player's anonymous payload from data EC already tracks.
local function localPayload()
    local DB = EbonClearanceDB or {}
    local itemsSold = 0
    for _, n in pairs(DB.soldItemsByQuality or {}) do
        itemsSold = itemsSold + (tonumber(n) or 0)
    end
    local stats = { totalCopper = DB.totalCopper or 0, itemsSold = itemsSold, bestGPH = DB.bestGPH or 0 }
    return GuildShare.encodePayload(GuildShare.topZones(DB.copperByZone, MAX_ZONES), stats)
end

-- The live aggregate the panel reads. Lives on the shared cache (session-only).
local function agg()
    if not NS.compCache.guildAgg then
        NS.compCache.guildAgg = GuildShare.newAggregate()
    end
    return NS.compCache.guildAgg
end

function GuildShare.GetAggregate()
    return agg()
end

-- Broadcast a request and reset the aggregate for a fresh snapshot. Throttled
-- so spam-clicking Refresh cannot flood the guild channel. Uses GetTime gated
-- by our own throttle (NS.Comms.Send has its own per-channel guard too).
function GuildShare.RequestNow()
    local now = GetTime()
    if (now - lastReqAt) < GREQ_THROTTLE_S then
        return
    end
    lastReqAt = now
    NS.compCache.guildAgg = GuildShare.newAggregate()
    if GetGuildInfo("player") then
        NS.Comms.Send("GREQ", "", "GUILD")
    end
    if GetNumRaidMembers() > 0 then
        NS.Comms.Send("GREQ", "", "RAID")
    elseif GetNumPartyMembers() > 0 then
        NS.Comms.Send("GREQ", "", "PARTY")
    end
end

local function playerName()
    return UnitName("player")
end

-- A peer asked for data: reply by whisper IF we opted in. The sender is used
-- only as the whisper target; it is never stored or displayed (anonymity).
NS.Comms.RegisterHandler("GREQ", function(_, sender, _)
    if not (EbonClearanceDB and EbonClearanceDB.shareGuildData) then
        return
    end
    if sender and sender ~= playerName() then
        NS.Comms.Send("GDAT", localPayload(), "WHISPER", sender)
    end
end)

-- A reply arrived: merge it anonymously (sender ignored entirely).
NS.Comms.RegisterHandler("GDAT", function(payload, _, _)
    GuildShare.mergeReply(agg(), GuildShare.decodePayload(payload))
    if NS.RefreshGuildPanel then
        NS.RefreshGuildPanel()
    end
end)
```

- [ ] **Step 2: Verify syntax + unit test still passes**

Run: `luac -p EbonClearance_GuildShare.lua && lua tests/test_guildshare.lua`
Expected: clean; `RESULT: all tests passed` (runtime globals are referenced only inside functions, so isolated load is unaffected).

- [ ] **Step 3: Commit (local)**

```bash
git add EbonClearance_GuildShare.lua
git commit -m "feat: guild-share GREQ/GDAT handlers, opt-in-gated reply, on-demand request"
```

---

### Task 3: SavedVariables default + registration (toc, CI, tests)

**Files:**
- Modify: `EbonClearance_Events.lua` (in `EnsureDB`, account-level defaults, near the `versionAlerts` default added in v2.39.0)
- Modify: `EbonClearance.toc`, `.github/workflows/test.yml`, `.github/workflows/release.yml`, `tests/test_perf_guardrails.lua`, `tests/test_comment_hygiene.lua`

- [ ] **Step 1: EnsureDB default (opt-in, default off)**

In `EnsureDB`, next to the `versionAlerts` default, add:
```lua
    -- Guild farming/stats sharing (opt-in, default OFF). Account-level.
    if EbonClearanceDB.shareGuildData == nil then
        EbonClearanceDB.shareGuildData = false
    end
```

- [ ] **Step 2: `.toc` - add both files after the comms file**

After `EbonClearance_Comms.lua`:
```
EbonClearance_GuildShare.lua
EbonClearance_GuildPanel.lua
```

- [ ] **Step 3: CI**

In `.github/workflows/test.yml`, under the syntax-check `run:` block add:
```
          luac5.1 -p EbonClearance_GuildShare.lua
          luac5.1 -p EbonClearance_GuildPanel.lua
```
and add a run step after the comms test step:
```yaml
      - name: Guild-share regression tests
        run: lua5.1 tests/test_guildshare.lua
```
In `.github/workflows/release.yml`, add to the "Verify before packaging" step's command list:
```
          lua5.1 tests/test_guildshare.lua
```
(`luac` there is already globbed via `for f in EbonClearance*.lua`.)

- [ ] **Step 4: Test SOURCE_PATHS**

In both `tests/test_perf_guardrails.lua` and `tests/test_comment_hygiene.lua`, add to the `SOURCE_PATHS` table after `"EbonClearance_Comms.lua",`:
```lua
    "EbonClearance_GuildShare.lua",
    "EbonClearance_GuildPanel.lua",
```

- [ ] **Step 5: Verify**

Run: `lua tests/test_perf_guardrails.lua && lua tests/test_comment_hygiene.lua && lua tests/test_guildshare.lua`
Expected: all `RESULT: all tests passed`. (Note: `EbonClearance_GuildPanel.lua` must exist before the SOURCE_PATHS suites can open it - if doing Task 3 before Task 4, create an empty stub `EbonClearance_GuildPanel.lua` with a single comment line first, or reorder Step 4 to after Task 4. Recommended: do Task 4 before this Step 4.)

- [ ] **Step 6: Commit (local)** (after Task 4 exists)

```bash
git add EbonClearance_Events.lua EbonClearance.toc .github/workflows/test.yml .github/workflows/release.yml tests/test_perf_guardrails.lua tests/test_comment_hygiene.lua
git commit -m "build: shareGuildData default + register guild-share files in toc/CI/tests"
```

---

### Task 4: Guild panel UI

**Files:**
- Create: `EbonClearance_GuildPanel.lua`

- [ ] **Step 1: Build the panel mirroring `EbonClearance_StatsPanel.lua`**

Open `EbonClearance_StatsPanel.lua` and follow its exact structure: `local NS = select(2, ...)`, a `CreateFrame` config frame, `EC_compCache.initPanel(self, function(refreshSelf) ... end)`, and `InterfaceOptions_AddCategory`-style registration (match how Stats registers its sort order; place "Guild" after the existing panels). The panel must:

1. Use `EC_compCache.setPanelWidth(widget, x)` for any text widget that spans the panel width (layout-reactivity invariant - `tests/test_layout_reactivity.lua` enforces this).
2. Add the opt-in checkbox via `NS.AddCheckbox(content, "EbonClearanceGuildShareCB", anchor, "Share my farming data with my guild (anonymous)", getter, setter, yOff)` where:
```lua
   function() return EbonClearanceDB and EbonClearanceDB.shareGuildData end,
   function(v) if EbonClearanceDB then EbonClearanceDB.shareGuildData = v end end,
```
   (Read/write the top-level field directly - this builder has no `DB` proxy upvalue, same as the v2.39.0 Main-panel update toggle.)
3. A "Guild's Best Farming Zones" header + a FontString that the refresh function fills from `NS.GuildShare.GetAggregate()`: sort `agg.zones` by `copper` desc, show up to 5 rows `"<zone> - <gold> (from <contributors>)"` using `NS.CopperToColoredText(copper)`. Empty -> `"No zones shared yet."`.
4. A "Guild Totals" FontString: `"Members shared: <memberCount>"`, `"Combined gold: <CopperToColoredText(totalCopper)>"`, `"Combined items sold: <totalItems>"`. When `memberCount == 0`, show an empty-state hint: `"Open with guildmates online, or click Refresh. Needs at least one other member sharing."`.
5. A Refresh button (`UIPanelButtonTemplate`) whose `OnClick` calls `NS.GuildShare.RequestNow()` then `PlaySound("igMainMenuOptionCheckBoxOn")`.
6. On the frame's `OnShow` (inside `initPanel`'s build/refresh wiring), call `NS.GuildShare.RequestNow()` and `NS.Delay(3, refreshSelf)` so replies have time to arrive.
7. Expose `NS.RefreshGuildPanel = refreshSelf` (or a wrapper) so the `GDAT` handler in Task 2 can repaint the panel live as replies land.

All player text brief, no em dashes, neutral framing.

- [ ] **Step 2: Verify syntax + layout invariants**

Run: `luac -p EbonClearance_GuildPanel.lua && lua tests/test_layout_reactivity.lua`
Expected: clean; layout suite passes.

- [ ] **Step 3: Commit (local)**

```bash
git add EbonClearance_GuildPanel.lua
git commit -m "feat: Guild options panel - best zones, totals, opt-in, refresh"
```

---

### Task 5: Static-pattern invariants

**Files:**
- Modify: `tests/test_guildshare.lua` (append before the result block)

- [ ] **Step 1: Append source-pattern assertions**

```lua
-- ---- static-pattern invariants (scan live code, not comments) ----
local function readCode(p)
    local fh = assert(io.open(p, "r")); local s = fh:read("*a"); fh:close()
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        local t = line:match("^%s*(.-)%s*$") or ""
        if t:sub(1, 2) ~= "--" then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end
local share = readCode("EbonClearance_GuildShare.lua")
ok("exposes NS.GuildShare", share:find("NS.GuildShare", 1, true) ~= nil)
ok("uses NS.Comms transport", share:find("NS.Comms", 1, true) ~= nil)
ok("reply gated on shareGuildData", share:find("shareGuildData", 1, true) ~= nil)
ok("registers GREQ + GDAT", share:find('"GREQ"', 1, true) and share:find('"GDAT"', 1, true) ~= nil)
ok("zone cap present", share:find("MAX_ZONES", 1, true) ~= nil)
ok("no 4.0 group event", not share:find("GROUP_ROSTER_UPDATE", 1, true))
local panel = readCode("EbonClearance_GuildPanel.lua")
ok("panel reads aggregate", panel:find("GetAggregate", 1, true) ~= nil)
ok("panel opt-in writes shareGuildData", panel:find("shareGuildData", 1, true) ~= nil)
```

- [ ] **Step 2: Run**

Run: `lua tests/test_guildshare.lua`
Expected: PASS (unit + static).

- [ ] **Step 3: Commit (local)**

```bash
git add tests/test_guildshare.lua
git commit -m "test: static-pattern invariants for guild-share consumer + panel"
```

---

### Task 6: Full verification sweep

- [ ] **Step 1: Syntax** - `lua -e "for _,f in ipairs({'EbonClearance_GuildShare.lua','EbonClearance_GuildPanel.lua','EbonClearance_Events.lua'}) do assert(loadfile(f)) end print('OK')"` (or `luac5.1 -p` per file).
- [ ] **Step 2: All suites** -
```bash
lua tests/test_guildshare.lua
lua tests/test_comms_version.lua
lua tests/test_perf_guardrails.lua
lua tests/test_layout_reactivity.lua
lua tests/test_comment_hygiene.lua
```
Each must end `RESULT: all tests passed`.
- [ ] **Step 3: Em-dash guard** - `LC_ALL=C grep -rnF $'\xe2\x80\x94' EbonClearance_GuildShare.lua EbonClearance_GuildPanel.lua && echo FOUND || echo clean` -> `clean`.
- [ ] **Step 4: Commit any fixes (local).**

---

### Task 7: In-game smoke test on Ebonhold (gate)

Manual; no push or tag before this passes.

- [ ] Copy the working tree into the live AddOns folder.
- [ ] Two guildmates, both tick "Share my farming data with my guild (anonymous)", each having sold in different zones (so `copperByZone` differs). Both `/reload`.
- [ ] Player A opens the Guild panel. Expected within ~3s: pooled zones from both, "Members shared: 1" (the other member), combined totals. Click Refresh -> re-queries.
- [ ] Untick sharing on player B, B `/reload`, A Refreshes. Expected: B no longer contributes (members shared drops).
- [ ] Solo / non-guilded client opens the panel: empty-state hint, no errors.
- [ ] Confirm no chat spam and no disconnects from the GUILD addon traffic.

---

## Self-review notes

- **Spec coverage:** transport reuse + GREQ/GDAT (Task 2), anonymous aggregate (Tasks 1-2, sender ignored), top-5 cap + <255 payload (Task 1), opt-in default-off (Task 3), panel UI + Refresh + empty state (Task 4), tests (Tasks 1,5), CI/registration (Task 3), verification + in-game gate (Tasks 6-7). All spec sections map to a task.
- **Type/name consistency:** `GuildShare.topZones/encodePayload/decodePayload/newAggregate/mergeReply/RequestNow/GetAggregate`, `EbonClearanceDB.shareGuildData`, `NS.compCache.guildAgg`, `NS.RefreshGuildPanel`, message types `"GREQ"`/`"GDAT"`, `MAX_ZONES`/`MAX_PAYLOAD` used identically across tasks.
- **Ordering note:** Task 4 (panel file) should be created before Task 3 Step 4/5, because the two SOURCE_PATHS suites open every listed file - flagged inline in Task 3 Step 5.
- **No placeholders** except the deliberate "mirror StatsPanel" pattern-pointer in Task 4 (panel boilerplate varies; the spec'd widgets, bindings, and behaviours are all given explicitly).
