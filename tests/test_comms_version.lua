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
