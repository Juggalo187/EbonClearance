#!/usr/bin/env lua
-- Single entry point for every EbonClearance invariant suite.
-- Run from the repo root:  lua tests/run_all.lua   (CI uses lua5.1)
--
-- Each suite is a standalone script that prints PASS/FAIL lines and then
-- os.exit(0/1). We can't dofile() them (their os.exit would kill this
-- runner) and they stub globals differently, so we run each in its own
-- subprocess for isolation and tally the exit codes.
--
-- This list is the single source of truth for "the invariant suites".
-- Add a new suite here and it runs locally and in CI automatically.

local TESTS = {
    "tests/test_layout_reactivity.lua",
    "tests/test_perf_guardrails.lua",
    "tests/test_comment_hygiene.lua",
    "tests/test_comms_version.lua",
    "tests/test_guildshare.lua",
    "tests/test_locale_integrity.lua",
}

-- Reuse whichever interpreter is running this file (lua, lua5.1, full path).
-- arg[-1] is that interpreter; fall back to a bare "lua" on PATH.
local interp = arg[-1] or "lua"
local is_windows = package.config:sub(1, 1) == "\\"

-- Returns true if the subprocess exited 0.
local function run(path)
    local cmd
    if is_windows then
        -- cmd.exe strips one outer pair of quotes, so wrap the whole line.
        cmd = string.format('""%s" "%s""', interp, path)
    else
        cmd = string.format('"%s" "%s"', interp, path)
    end
    local r = os.execute(cmd)
    -- Lua 5.1: os.execute returns the numeric exit code (0 == success).
    -- Lua 5.2+: returns (ok, "exit"|"signal", code).
    if type(r) == "number" then
        return r == 0
    end
    return r == true
end

local failed = {}
for _, path in ipairs(TESTS) do
    print("==================================================================")
    print(":: " .. path)
    print("==================================================================")
    if not run(path) then
        failed[#failed + 1] = path
    end
    print()
end

print("==================================================================")
if #failed > 0 then
    io.stderr:write("RESULT: " .. #failed .. " of " .. #TESTS .. " suite(s) FAILED:\n")
    for _, path in ipairs(failed) do
        io.stderr:write("  - " .. path .. "\n")
    end
    os.exit(1)
end
print("RESULT: all " .. #TESTS .. " suites passed")
os.exit(0)
