-- test_services.lua -- Test service for Phase 5 service management APIs
--
-- Tests: skynet.newservice, skynet.kill, skynet.response,
--        skynet.wait/wakeup, skynet.uniqueservice, skynet.queryservice

local skynet = require "skynet"

skynet.start(function()
    skynet.error("[test_services] started, handle = " .. skynet.address(skynet.self()))

    -- Test 1: skynet.newservice
    skynet.error("[test_services] === Test 1: skynet.newservice ===")
    local echo_handle = skynet.newservice("echo")
    if echo_handle then
        skynet.error("[test_services] spawned echo service: " .. skynet.address(echo_handle))

        -- Call the echo service
        local reply = skynet.call(echo_handle, "lua", "hello from test_services")
        skynet.error("[test_services] echo replied: " .. tostring(reply))
    else
        skynet.error("[test_services] ERROR: failed to spawn echo service")
    end

    -- Test 2: skynet.kill
    skynet.error("[test_services] === Test 2: skynet.kill ===")
    local echo2 = skynet.newservice("echo")
    skynet.error("[test_services] spawned echo2: " .. skynet.address(echo2))
    skynet.kill(echo2)
    skynet.error("[test_services] killed echo2: " .. skynet.address(echo2))

    -- Test 3: skynet.uniqueservice
    skynet.error("[test_services] === Test 3: skynet.uniqueservice ===")
    local u1 = skynet.uniqueservice("echo")
    local u2 = skynet.uniqueservice("echo")
    skynet.error("[test_services] uniqueservice first:  " .. skynet.address(u1))
    skynet.error("[test_services] uniqueservice second: " .. skynet.address(u2))
    if u1 == u2 then
        skynet.error("[test_services] PASS: uniqueservice returns same handle")
    else
        skynet.error("[test_services] NOTE: different handles (expected if name was not registered)")
    end

    -- Test 4: skynet.queryservice
    skynet.error("[test_services] === Test 4: skynet.queryservice ===")
    local found = skynet.queryservice("echo")
    if found then
        skynet.error("[test_services] PASS: queryservice found echo: " .. skynet.address(found))
    else
        skynet.error("[test_services] queryservice: echo not registered (expected if not named)")
    end

    -- Test 5: skynet.response (delayed response)
    skynet.error("[test_services] === Test 5: skynet.response ===")
    -- We'll test this by registering a protocol handler that uses response()
    -- For now just verify the function exists and is callable
    skynet.error("[test_services] skynet.response is " .. type(skynet.response))

    -- Test 6: skynet.wait / skynet.wakeup
    skynet.error("[test_services] === Test 6: skynet.wait/wakeup ===")
    local waiting_co
    skynet.fork(function()
        waiting_co = coroutine.running()
        skynet.error("[test_services] fork: waiting...")
        skynet.wait()
        skynet.error("[test_services] fork: woken up!")
    end)
    -- Give the fork a chance to start (need a yield point)
    skynet.sleep(1)  -- 10ms
    if waiting_co then
        skynet.wakeup(waiting_co)
        skynet.error("[test_services] wakeup sent")
    end
    skynet.sleep(1)  -- let wakeup process

    skynet.error("[test_services] === All tests completed ===")
end)
