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
-- The comms module also defines a StaticPopup dialog and replaces SetItemRef
-- at load time (for the clickable update link), so provide the table it indexes.
_G.StaticPopupDialogs = {}

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

-- ---- static-pattern invariants (scan live code, not comments) ----
-- Whole-line comments are stripped first so an explanatory comment that
-- names a forbidden 4.0+ API (to document it is NOT used) doesn't trip the
-- absence checks below. Mirrors the whole-line-comment handling in
-- tests/test_no_addon_references.lua.
local function readCode(p)
    local fh = assert(io.open(p, "r"))
    local s = fh:read("*a")
    fh:close()
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        local stripped = line:match("^%s*(.-)%s*$") or ""
        if stripped:sub(1, 2) ~= "--" then
            out[#out + 1] = line
        end
    end
    return table.concat(out, "\n")
end

local comms = readCode("EbonClearance_Comms.lua")
ok("comms uses numeric version encoding", comms:find("1000000", 1, true) ~= nil)
ok("comms has no 4.0 prefix-registration API", not comms:find("RegisterAddonMessagePrefix", 1, true))
ok("comms defines NS.Comms", comms:find("NS.Comms", 1, true) ~= nil)
ok("comms gates on versionAlerts", comms:find("versionAlerts", 1, true) ~= nil)
ok("comms exposes RunSelfTest", comms:find("function Comms.RunSelfTest", 1, true) ~= nil)

local events = readCode("EbonClearance_Events.lua")
ok("hub registers PARTY_MEMBERS_CHANGED", events:find("PARTY_MEMBERS_CHANGED", 1, true) ~= nil)
ok("hub registers RAID_ROSTER_UPDATE", events:find("RAID_ROSTER_UPDATE", 1, true) ~= nil)
ok("no 4.0 GROUP_ROSTER_UPDATE introduced", not events:find("GROUP_ROSTER_UPDATE", 1, true))

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
end
print("RESULT: all tests passed")
os.exit(0)
