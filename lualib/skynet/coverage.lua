local core = require "skynet.core"

local coverage = {}

local enabled = false
local out_dir
local out_file
local hits = {}
local event_count = 0
local flush_every = 5000
local hook_fn
local original_create
local original_wrap

local function normalize_source(source)
    if type(source) ~= "string" then
        return nil
    end
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    source = source:gsub("\\", "/")
    if source:find("/lualib/", 1, true) or source:find("/service/", 1, true) then
        return source
    end
    return nil
end

local function record_line(source, line)
    source = normalize_source(source)
    if not source or not line or line <= 0 then
        return
    end
    local file_hits = hits[source]
    if not file_hits then
        file_hits = {}
        hits[source] = file_hits
    end
    file_hits[line] = true
end

function coverage.flush()
    if not enabled or not out_file then
        return
    end

    local old_hook = debug.gethook()
    debug.sethook()

    local parts = {}
    for source, file_hits in pairs(hits) do
        for line in pairs(file_hits) do
            parts[#parts + 1] = source .. ":" .. tostring(line) .. "\n"
        end
    end
    hits = {}
    event_count = 0

    if #parts > 0 then
        core.writefile(out_file, table.concat(parts), true)
    end

    if old_hook then
        debug.sethook(old_hook, "l")
    end
end

local function line_hook(event, line)
    if event ~= "line" then
        return
    end
    local info = debug.getinfo(2, "S")
    if info then
        record_line(info.source, line)
        event_count = event_count + 1
        if event_count >= flush_every then
            coverage.flush()
        end
    end
end

local function install_thread_hook(co)
    if enabled and co then
        debug.sethook(co, hook_fn, "l")
    end
    return co
end

function coverage.start(dir)
    if enabled then
        return
    end

    out_dir = dir or core.getenv("SKYNET_LUA_COVERAGE_DIR") or "coverage-lua"
    out_dir = out_dir:gsub("\\", "/"):gsub("/$", "")
    out_file = out_dir .. "/lua_hits_" .. tostring(core.self()) .. ".log"
    hook_fn = line_hook
    enabled = true

    original_create = coroutine.create
    original_wrap = coroutine.wrap

    coroutine.create = function(f)
        return install_thread_hook(original_create(f))
    end

    coroutine.wrap = function(f)
        local co = install_thread_hook(original_create(f))
        return function(...)
            local ok, result = coroutine.resume(co, ...)
            if not ok then
                error(result, 2)
            end
            return result
        end
    end

    debug.sethook(hook_fn, "l")
end

function coverage.create(f)
    if original_create then
        return install_thread_hook(original_create(f))
    end
    return coroutine.create(f)
end

function coverage.enabled()
    return enabled
end

function coverage._selftest()
    assert(coverage.enabled(), "coverage should already be enabled in coverage mode")
    coverage.start(out_dir)

    local co = coverage.create(function(v)
        return v + 1
    end)
    assert(type(co) == "thread", "coverage.create should return coroutine")
    local ok, value = coroutine.resume(co, 1)
    assert(ok and value == 2, "coverage.create coroutine failed")

    local wrapped = coroutine.wrap(function(v)
        return v .. "-wrapped"
    end)
    assert(wrapped("coverage") == "coverage-wrapped", "coverage.wrap failed")

    local bad = coroutine.wrap(function()
        error("coverage wrap error")
    end)
    assert(not pcall(bad), "coverage.wrap error path failed")

    flush_every = 1
    local marked = function()
        return true
    end
    assert(marked() == true, "coverage marker failed")
    coverage.flush()
    flush_every = 5000
    return true
end

return coverage
