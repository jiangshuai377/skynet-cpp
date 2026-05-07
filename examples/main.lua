local skynet = require "skynet"

skynet.start(function()
    skynet.error("[main] === Example startup ===")

    -- Test 1: getenv/setenv (pure Lua table)
    skynet.error("[main] --- Test 1: getenv/setenv ---")
    skynet.setenv("mykey", "hello_skynet")
    local val = skynet.getenv("mykey")
    skynet.error("[main] setenv/getenv('mykey') = " .. tostring(val))

    if val == "hello_skynet" then
        skynet.error("[main] PASS: getenv/setenv works")
    else
        skynet.error("[main] FAIL: getenv/setenv broken")
    end

    -- Test 2: launcher service
    skynet.error("[main] --- Test 2: launcher ---")
    local launcher = skynet.queryservice(".launcher")
    if launcher then
        skynet.error("[main] launcher found: " .. skynet.address(launcher))

        -- Launch echo service via launcher
        local echo_handle = skynet.call(launcher, "lua", "LAUNCH", "echo")
        if echo_handle then
            skynet.error("[main] launcher spawned echo: " .. skynet.address(echo_handle))

            -- Call the echo service
            local reply = skynet.call(echo_handle, "lua", "hello from main via launcher")
            skynet.error("[main] echo replied: " .. tostring(reply))
            skynet.error("[main] PASS: launcher LAUNCH works")
        else
            skynet.error("[main] FAIL: launcher LAUNCH returned nil")
        end

        -- List services
        local list = skynet.call(launcher, "lua", "LIST")
        skynet.error("[main] launcher LIST:\n" .. tostring(list))

        -- Query service by name
        local found = skynet.call(launcher, "lua", "QUERY", "echo")
        if found then
            skynet.error("[main] PASS: launcher QUERY found echo: " .. skynet.address(found))
        else
            skynet.error("[main] FAIL: launcher QUERY not found")
        end
    else
        skynet.error("[main] FAIL: launcher not found")
    end

    skynet.error("[main] === Example completed ===")
end)
