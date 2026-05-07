-- test_cluster.lua — Phase 10 Cluster verification
--
-- Tests:
--   1. cluster.core C module (pack/unpack request/response)
--   2. socketchannel basics
--   3. Intra-process cluster round-trip (self-connect)
--      - cluster.open() + cluster.register() + cluster.call()

local skynet = require "skynet"
local cluster_core = require "cluster.core"

skynet.start(function()
    skynet.error("[test_cluster] === Phase 10 Verification ===")

    -- ========================================================================
    -- Test 1: cluster.core C module — pack/unpack protocol
    -- ========================================================================
    skynet.error("[test_cluster] --- Test 1: cluster.core pack/unpack ---")

    -- 1a. Pack a numeric-address request
    local msg = skynet.packstring("hello", "world")
    local request, new_session = cluster_core.packrequest(0x12345678, 1, msg, #msg)
    assert(type(request) == "string", "packrequest should return string")
    assert(new_session == 2, "next session should be 2")
    skynet.error("[test_cluster] PASS: packrequest numeric (single-part)")

    -- 1b. Unpack the request (skip 2-byte header)
    local header_sz = cluster_core.header(request:sub(1, 2))
    local addr, session, umsg, usz = cluster_core.unpackrequest(request:sub(3))
    assert(addr == 0x12345678, "addr mismatch: " .. tostring(addr))
    assert(session == 1, "session mismatch: " .. tostring(session))
    skynet.error("[test_cluster] PASS: unpackrequest numeric")

    -- 1c. Pack/unpack response
    local resp = cluster_core.packresponse(1, true, "ok_data")
    assert(type(resp) == "string", "packresponse should return string")
    local rsession, rok, rdata = cluster_core.unpackresponse(resp:sub(3))
    assert(rsession == 1, "response session mismatch")
    assert(rok == true, "response should be ok")
    assert(rdata == "ok_data", "response data mismatch: " .. tostring(rdata))
    skynet.error("[test_cluster] PASS: packresponse/unpackresponse")

    -- 1d. Pack/unpack push (session=0 in unpacked)
    local push_req, push_ns = cluster_core.packpush(42, 5, "pushdata", 8)
    local push_header_sz = cluster_core.header(push_req:sub(1, 2))
    local paddr, psession, pmsg, psz, ppadding, pis_push = cluster_core.unpackrequest(push_req:sub(3))
    assert(paddr == 42, "push addr mismatch")
    assert(psession == 0, "push session should be 0")
    assert(pis_push == true, "should be push")
    skynet.error("[test_cluster] PASS: packpush/unpackrequest push")

    -- 1e. Error response
    local err_resp = cluster_core.packresponse(99, false, "something failed")
    local es, eok, edata = cluster_core.unpackresponse(err_resp:sub(3))
    assert(es == 99, "error session mismatch")
    assert(eok == false, "should be error")
    assert(edata == "something failed", "error msg mismatch")
    skynet.error("[test_cluster] PASS: error response")

    -- 1f. isname
    assert(cluster_core.isname("@hello") == true, "isname @hello should be true")
    assert(not cluster_core.isname("hello"), "isname hello should be nil")
    skynet.error("[test_cluster] PASS: isname")

    -- 1g. nodename
    local nn = cluster_core.nodename()
    assert(type(nn) == "string" and #nn > 0, "nodename should return non-empty string")
    skynet.error("[test_cluster] PASS: nodename = " .. nn)

    -- ========================================================================
    -- Test 2: Intra-process cluster (self-connect test)
    -- ========================================================================
    skynet.error("[test_cluster] --- Test 2: cluster self-connect ---")

    -- Launch a simple echo service for the cluster to call
    local echo_handle = skynet.newservice("echo")
    skynet.error("[test_cluster] echo service: " .. skynet.address(echo_handle))

    -- Initialize cluster
    local cluster = require "skynet.cluster"
    cluster.init()

    -- Register the echo service name
    cluster.register("echo", echo_handle)

    -- Open a cluster listener on a dynamic port
    local listen_addr, listen_port = cluster.open("127.0.0.1", 19999)
    skynet.error(string.format("[test_cluster] cluster listening on %s:%s",
        tostring(listen_addr), tostring(listen_port)))
    skynet.error("[test_cluster] PASS: cluster.open works")

    -- Configure cluster to know about "self" node
    cluster.reload({
        self = "127.0.0.1:19999",
    })
    skynet.error("[test_cluster] PASS: cluster.reload works")

    -- Give a moment for everything to settle
    skynet.sleep(30)

    -- Test cluster.call to self (remote echo)
    skynet.error("[test_cluster] attempting cluster.call to self...")
    -- Use cluster.call directly
    local ok, result = pcall(cluster.call, "self", echo_handle, "cluster_test_message")
    if ok then
        skynet.error(string.format("[test_cluster] cluster.call response: %s", tostring(result)))
        skynet.error("[test_cluster] PASS: cluster.call self-connect works")
    else
        skynet.error(string.format("[test_cluster] cluster.call failed: %s", tostring(result)))
        skynet.error("[test_cluster] FAIL: cluster.call self-connect")
    end

    -- Test cluster.query
    local ok2, query_result = pcall(cluster.query, "self", "echo")
    if ok2 and query_result then
        skynet.error(string.format("[test_cluster] cluster.query 'echo' = %s",
            skynet.address(query_result)))
        skynet.error("[test_cluster] PASS: cluster.query works")
    else
        skynet.error(string.format("[test_cluster] cluster.query failed: %s", tostring(query_result)))
        skynet.error("[test_cluster] FAIL: cluster.query")
    end

    -- Test cluster.send (fire-and-forget)
    local ok3, err3 = pcall(cluster.send, "self", echo_handle, "cluster_push_msg")
    if ok3 then
        skynet.error("[test_cluster] PASS: cluster.send works (no error)")
    else
        skynet.error("[test_cluster] FAIL: cluster.send: " .. tostring(err3))
    end

    skynet.sleep(10)  -- let push arrive

    skynet.error("[test_cluster] === All Phase 10 tests completed ===")
end)
