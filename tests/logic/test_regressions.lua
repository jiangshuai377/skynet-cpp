local skynet = require "skynet"
local socket = require "socket"

skynet.start(function()
    skynet.error("[test_regressions] === Regression Verification ===")

    local failed_connect_done = false
    skynet.fork(function()
        local conn = socket.connect("127.0.0.1", 1)
        assert(conn == nil, "connect to closed port should return nil")
        failed_connect_done = true
        skynet.error("[test_regressions] PASS: failed socket.connect wakes caller")
    end)

    skynet.sleep(500)
    assert(failed_connect_done, "failed socket.connect did not wake within 5s")

    local seen = {}
    local l1 = socket.listen("127.0.0.1", 19001, function(event, conn_id)
        if event == "accept" then
            seen.l1 = (seen.l1 or 0) + 1
            socket.close(conn_id)
        end
    end)
    local l2 = socket.listen("127.0.0.1", 19002, function(event, conn_id)
        if event == "accept" then
            seen.l2 = (seen.l2 or 0) + 1
            socket.close(conn_id)
        end
    end)

    local c1 = socket.connect("127.0.0.1", 19001)
    if c1 then socket.close(c1) end
    local c2 = socket.connect("127.0.0.1", 19002)
    if c2 then socket.close(c2) end

    skynet.sleep(50)
    assert(seen.l1 == 1, "listener 1 accept routed incorrectly: " .. tostring(seen.l1))
    assert(seen.l2 == 1, "listener 2 accept routed incorrectly: " .. tostring(seen.l2))
    skynet.error("[test_regressions] PASS: multi-listener accept routing")

    socket.close_listener(l1)
    socket.close_listener(l2)

    skynet.error("[test_regressions] === All regression tests completed ===")
    skynet.exit()
end)
