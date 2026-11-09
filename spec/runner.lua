--[[--
Minimal busted-style test runner (describe/it/assert) for plain LuaJIT/Lua 5.1.

Used instead of busted so the suite runs with no third-party rocks, both on a
stock LuaJIT and on KOReader's bundled LuaJIT (integration_spec.lua).
Usage: luajit spec/runner.lua spec/arxiv_spec.lua [more specs...]
]]

local passed, failed, stack = 0, 0, {}

function describe(name, fn) -- luacheck: globals describe
    stack[#stack + 1] = name
    fn()
    stack[#stack] = nil
end

function it(name, fn) -- luacheck: globals it
    local full = table.concat(stack, " ") .. " " .. name
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL: ", full, "\n  ", tostring(err), "\n")
    end
end

local function fmt(v)
    return type(v) == "string" and string.format("%q", v) or tostring(v)
end

assert = setmetatable({ -- luacheck: globals assert
    equal = function(expected, actual, msg)
        if expected ~= actual then
            error(string.format("%sexpected %s, got %s", msg and msg .. ": " or "", fmt(expected), fmt(actual)), 2)
        end
    end,
    truthy = function(v, msg)
        if not v then error(msg or ("expected truthy, got " .. fmt(v)), 2) end
    end,
    falsy = function(v, msg)
        if v then error(msg or ("expected falsy, got " .. fmt(v)), 2) end
    end,
}, { __call = function(_, v, msg, ...) if not v then error(msg or "assertion failed", 2) end return v, msg, ... end })

local repo = (arg[0]:match("^(.*)/spec/[^/]+$") or ".")
package.path = repo .. "/arxiv.koplugin/?.lua;" .. repo .. "/spec/?.lua;" .. package.path
SPEC_REPO_ROOT = repo -- luacheck: globals SPEC_REPO_ROOT

for i = 1, #arg do
    dofile(arg[i])
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
