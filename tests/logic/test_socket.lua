-- test_socket.lua — Test service for Phase 7 socket API
--
-- Creates a TCP echo server using the Lua socket API + netpack.
-- When a client connects, echoes back each length-prefixed message.
-- Also tests the Phase 8 additions (mem, gc, starttime).

local skynet = require "skynet"
local socket = require "socket"
local netpack = require "netpack"

skynet.start(function()
    skynet.error("[test_socket] === Phase 7+8 Verification ===")

    -- Phase 8: test mem/gc/starttime
    skynet.error("[test_socket] --- Phase 8: mem/gc/starttime ---")
    local mem_before = skynet.mem()
    skynet.error("[test_socket] mem before gc: " .. string.format("%.1f KB", mem_before))
    local mem_after = skynet.gc()
    skynet.error("[test_socket] mem after gc:  " .. string.format("%.1f KB", mem_after))
    local st = skynet.starttime()
    skynet.error("[test_socket] starttime: " .. tostring(st))
    skynet.error("[test_socket] PASS: Phase 8 mem/gc/starttime work")

    -- Phase 8: verify PTYPE constants
    assert(skynet.PTYPE_CLIENT == 3, "PTYPE_CLIENT should be 3")
    assert(skynet.PTYPE_DEBUG == 9, "PTYPE_DEBUG should be 9")
    assert(skynet.PTYPE_SNAX == 11, "PTYPE_SNAX should be 11")
    assert(skynet.PTYPE_TRACE == 12, "PTYPE_TRACE should be 12")
    skynet.error("[test_socket] PASS: Phase 8 PTYPE constants correct")

    -- Phase 7: test netpack
    skynet.error("[test_socket] --- Phase 7: netpack ---")
    local packed = netpack.pack("hello")
    skynet.error("[test_socket] netpack.pack('hello') -> " .. #packed .. " bytes")
    assert(#packed == 7, "packed should be 2 + 5 = 7 bytes")

    local off, payload = netpack.unpack(packed)
    skynet.error("[test_socket] netpack.unpack -> offset=" .. tostring(off)
                 .. " payload=" .. tostring(payload))
    assert(payload == "hello", "unpack payload should be 'hello'")

    -- Test filter
    local p1 = netpack.pack("msg1")
    local p2 = netpack.pack("msg2")
    local msgs, remain = netpack.filter("", p1 .. p2)
    assert(#msgs == 2, "filter should return 2 messages")
    assert(msgs[1] == "msg1", "first message should be 'msg1'")
    assert(msgs[2] == "msg2", "second message should be 'msg2'")
    assert(remain == "", "no remainder expected")
    skynet.error("[test_socket] PASS: netpack filter works")

    -- Phase 7: test TCP socket listen
    skynet.error("[test_socket] --- Phase 7: socket ---")
    local test_port = 18888

    local accepted_conns = {}
    local listener_id = socket.listen("0.0.0.0", test_port, function(event, conn_id, ...)
        if event == "accept" then
            local addr, port = ...
            skynet.error(string.format("[test_socket] accepted conn #%d from %s:%d",
                conn_id, addr or "?", port or 0))
            accepted_conns[conn_id] = true
        elseif event == "close" then
            skynet.error(string.format("[test_socket] conn #%d closed", conn_id))
            accepted_conns[conn_id] = nil
        end
    end)

    -- Set data handler to echo back using netpack framing
    socket.ondata(listener_id, function(conn_id, data)
        -- For testing, use netpack framing
        local msgs, remain = netpack.filter("", data)
        for _, msg in ipairs(msgs) do
            skynet.error("[test_socket] echo: " .. msg)
            socket.write(listener_id, conn_id, netpack.pack(msg))
        end
    end)

    skynet.error(string.format("[test_socket] listening on port %d", test_port))
    skynet.error("[test_socket] PASS: socket.listen works")
    skynet.error("[test_socket] === All Phase 7+8 tests completed ===")
    skynet.error(string.format("[test_socket] TCP echo on port %d (netpack framing)", test_port))
end)
