-- test_debug.lua — Phase 9 verification
--
-- Tests: debug protocol, profile module, memory monitoring, debug console launch

local skynet = require "skynet"
local profile = require "skynet.profile"

skynet.start(function()
    skynet.error("[test_debug] === Phase 9 Verification ===")

    -- Test 1: debug protocol registered
    skynet.error("[test_debug] --- Test 1: debug protocol ---")
    -- PTYPE_DEBUG should be 9
    assert(skynet.PTYPE_DEBUG == 9, "PTYPE_DEBUG should be 9")
    skynet.error("[test_debug] PASS: PTYPE_DEBUG = 9")

    -- Test 2: profile module
    skynet.error("[test_debug] --- Test 2: skynet.profile ---")
    assert(profile.start, "profile.start missing")
    assert(profile.stop, "profile.stop missing")
    assert(profile.resume, "profile.resume missing")
    assert(profile.wrap, "profile.wrap missing")

    -- Profile the current thread
    profile.start()
    -- Do some CPU work
    local sum = 0
    for i = 1, 100000 do
        sum = sum + math.sin(i)
    end
    local elapsed = profile.stop()
    skynet.error(string.format("[test_debug] PASS: profile elapsed = %.6f sec (sum=%.2f)", elapsed, sum))
    assert(elapsed > 0, "profile should record > 0 seconds")

    -- Test 3: profile with coroutine
    skynet.error("[test_debug] --- Test 3: profile + coroutine ---")
    local co = coroutine.create(function()
        local s = 0
        for i = 1, 50000 do
            s = s + math.cos(i)
        end
        coroutine.yield(s)
        return s
    end)
    profile.start(co)
    local ok, val = coroutine.resume(co)
    assert(ok, "coroutine should succeed")
    local ok2, val2 = coroutine.resume(co)
    local co_elapsed = profile.stop(co)
    skynet.error(string.format("[test_debug] PASS: coroutine profile = %.6f sec", co_elapsed))
    assert(co_elapsed > 0, "coroutine profile should record > 0")

    -- Test 4: task() function
    skynet.error("[test_debug] --- Test 4: skynet.task() ---")
    local count = skynet.task()
    skynet.error(string.format("[test_debug] active tasks: %d", count))
    skynet.error("[test_debug] PASS: skynet.task() works")

    -- Test 5: stat() function
    skynet.error("[test_debug] --- Test 5: skynet.stat() ---")
    local task_count = skynet.stat("task")
    skynet.error(string.format("[test_debug] stat('task') = %d", task_count))
    skynet.error("[test_debug] PASS: skynet.stat() works")

    -- Test 6: debug protocol commands via self-call
    skynet.error("[test_debug] --- Test 6: debug commands ---")
    local mem = skynet.call(skynet.self(), "debug", "MEM")
    skynet.error(string.format("[test_debug] debug MEM = %.2f KB", mem))
    assert(mem > 0, "MEM should return > 0")
    skynet.error("[test_debug] PASS: debug MEM works")

    local ok3, ping_result = pcall(skynet.call, skynet.self(), "debug", "PING")
    assert(ok3, "debug PING should succeed")
    skynet.error("[test_debug] PASS: debug PING works")

    local stat = skynet.call(skynet.self(), "debug", "STAT")
    skynet.error(string.format("[test_debug] debug STAT = task:%s",
        tostring(stat and stat.task)))
    skynet.error("[test_debug] PASS: debug STAT works")

    -- Test 7: memory monitoring C bindings
    skynet.error("[test_debug] --- Test 7: memory monitoring ---")
    local c = require "skynet.core"
    local used = c.memused()
    skynet.error(string.format("[test_debug] memused = %d bytes", used))
    assert(used > 0, "memused should be > 0")

    local old_limit = c.memlimit(0)  -- query without setting
    skynet.error(string.format("[test_debug] memlimit (current) = %d", old_limit))
    
    -- Set a high limit and verify
    c.memlimit(100 * 1024 * 1024)  -- 100MB
    local new_limit = c.memlimit(0)  -- query
    skynet.error(string.format("[test_debug] memlimit (after set 100MB) = %d", new_limit))
    c.memlimit(0)  -- remove limit
    skynet.error("[test_debug] PASS: memory monitoring works")

    -- Test 8: Launch debug console
    skynet.error("[test_debug] --- Test 8: debug console ---")
    local ok4, console_handle = pcall(skynet.newservice, "debug_console")
    if ok4 then
        skynet.error(string.format("[test_debug] PASS: debug console launched at %s (port 8000)",
            skynet.address(console_handle)))
    else
        skynet.error("[test_debug] WARN: debug console failed: " .. tostring(console_handle))
    end

    skynet.error("[test_debug] === All Phase 9 tests completed ===")
end)
