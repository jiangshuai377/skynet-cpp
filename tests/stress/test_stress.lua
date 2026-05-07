local skynet = require "skynet"
local socket = require "socket"
local core = require "skynet.core"

local worker_count = 32
local calls_per_worker = 200
local fire_per_worker = 500
local lifecycle_count = 100
local socket_clients = 48
local socket_messages = 60
local socket_port = 19191

local function env_number(name)
    local value = core.getenv(name)
    if value and value ~= "" then
        return tonumber(value)
    end
    return nil
end

if core.getenv("SKYNET_LUA_COVERAGE") then
    worker_count = 4
    calls_per_worker = 10
    fire_per_worker = 20
    lifecycle_count = 5
    socket_clients = 6
    socket_messages = 6
end

local summary = {}
local cluster_fire_count = 0

local function install_stress_dispatch()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "cluster_echo" then
            skynet.retpack("cluster_echo", ...)
        elseif cmd == "cluster_large" then
            local payload = ...
            skynet.retpack("cluster_large", #payload, payload:sub(1, 8), payload:sub(-8))
        elseif cmd == "cluster_huge_return" then
            skynet.retpack("cluster_huge_return", string.rep("R", 70000))
        elseif cmd == "cluster_fire" then
            cluster_fire_count = cluster_fire_count + 1
            if session ~= 0 then
                skynet.retpack("cluster_fire", cluster_fire_count)
            end
        else
            error("unknown test_stress command: " .. tostring(cmd))
        end
    end)
end

local function wait_until(label, predicate, timeout_cs, detail)
    local deadline = skynet.now() + timeout_cs
    while skynet.now() < deadline do
        if predicate() then
            return
        end
        skynet.sleep(1)
    end
    if detail then
        error(label .. " timed out: " .. detail())
    end
    error(label .. " timed out")
end

local function run_case(name, fn)
    local start_time = skynet.now()
    skynet.error("[stress] CASE begin: " .. name)
    local ok, err = xpcall(fn, debug.traceback)
    local elapsed = math.max(1, skynet.now() - start_time)
    summary[#summary + 1] = {
        name = name,
        ok = ok,
        elapsed = elapsed,
        err = err,
    }
    if not ok then
        error("[stress] CASE failed: " .. name .. "\n" .. tostring(err))
    end
    skynet.error(string.format("[stress] CASE pass: %s in %.2fs", name, elapsed / 100))
end

local function run_actor_stress()
    local workers = {}
    for i = 1, worker_count do
        workers[i] = skynet.newservice("stress_worker", tostring(i))
    end

    local done = 0
    local errors = {}
    local start_time = skynet.now()

    for i, handle in ipairs(workers) do
        skynet.fork(function()
            local ok, err = pcall(function()
                for n = 1, calls_per_worker do
                    local seq = i * 1000000 + n
                    local r, wid, got_seq, payload_len = skynet.call(handle, "lua", "ping", seq, "payload-" .. seq)
                    assert(r == "pong", "bad response tag")
                    assert(wid == i, "bad worker id")
                    assert(got_seq == seq, "bad sequence")
                    assert(payload_len > 0, "bad payload length")
                end
                for n = 1, fire_per_worker do
                    skynet.send(handle, "lua", "fire", i, n)
                end
            end)
            if not ok then
                errors[#errors + 1] = tostring(err)
            end
            done = done + 1
        end)
    end

    wait_until("actor stress", function()
        return done == worker_count
    end, 3000, function()
        return string.format("done=%d/%d errors=%d", done, worker_count, #errors)
    end)
    assert(#errors == 0, table.concat(errors, "\n"))

    local elapsed = math.max(1, skynet.now() - start_time)
    local rpc_count = worker_count * calls_per_worker
    local fire_count = worker_count * fire_per_worker
    skynet.error(string.format(
        "[stress] actor: %d rpc + %d fire messages in %.2fs, rpc %.0f/s",
        rpc_count, fire_count, elapsed / 100, rpc_count * 100 / elapsed))

    return workers
end

local function run_session_api_stress(workers)
    local target = workers[1]

    do
        local msg, sz = skynet.pack("raw", 12345, "raw-payload")
        local rmsg, rsz = skynet.rawcall(target, "lua", msg, sz)
        local tag, wid, seq, payload = skynet.unpack(rmsg, rsz)
        skynet.trash(rmsg, rsz)
        assert(tag == "raw", "rawcall tag mismatch")
        assert(wid == 1, "rawcall worker mismatch")
        assert(seq == 12345, "rawcall seq mismatch")
        assert(payload == "raw-payload", "rawcall payload mismatch")
    end

    do
        local msg, sz = skynet.pack("fire", "redirect", 1)
        skynet.redirect(target, skynet.self(), "lua", 0, msg, sz)
        local count = skynet.call(target, "lua", "stats")
        assert(type(count) == "number" and count > 0, "redirect did not reach target")
    end

    do
        local r, wid, seq = skynet.call(target, "lua", "delayed", 77)
        assert(r == "delayed", "delayed response tag mismatch")
        assert(wid == 1 and seq == 77, "delayed response payload mismatch")
    end

    do
        local slow = skynet.newservice("stress_slowstart", "901")
        local r, wid = skynet.call(slow, "lua", "ready")
        assert(r == "ready" and wid == 901, "startup pending message failed")
        skynet.kill(slow)
    end

    do
        local temp = skynet.newservice("stress_worker", "902")
        skynet.kill(temp)
        skynet.sleep(1)
        local ok = pcall(skynet.call, temp, "lua", "ping", 1, "dead")
        assert(not ok, "call to killed service should fail")
    end

    do
        local timeout_done = 0
        local wait_done = 0
        local waiters = {}
        for i = 1, 200 do
            skynet.timeout(0, function()
                timeout_done = timeout_done + 1
            end)
            skynet.fork(function()
                waiters[i] = coroutine.running()
                skynet.wait()
                wait_done = wait_done + 1
            end)
        end
        wait_until("waiters ready", function()
            local n = 0
            for i = 1, 200 do
                if waiters[i] then n = n + 1 end
            end
            return n == 200
        end, 500)
        for i = 1, 200 do
            assert(skynet.wakeup(waiters[i]), "wakeup failed")
        end
        wait_until("timer/wakeup stress", function()
            return timeout_done == 200 and wait_done == 200
        end, 500, function()
            return string.format("timeout=%d wait=%d", timeout_done, wait_done)
        end)
    end

    do
        skynet.name(".stress_named", target)
        assert(skynet.queryservice(".stress_named") == target, "queryservice mismatch")
        local uniq1 = skynet.uniqueservice("stress_worker")
        local uniq2 = skynet.uniqueservice("stress_worker")
        assert(uniq1 == uniq2, "uniqueservice mismatch")
    end
end

local function run_lifecycle_stress()
    local done = 0
    local errors = {}
    local active = {}

    for i = 1, lifecycle_count do
        skynet.fork(function()
            active[i] = "newservice"
            local ok, err = pcall(function()
                local handle = skynet.newservice("stress_worker", tostring(100000 + i))
                active[i] = "die-call " .. skynet.address(handle)
                local r, wid = skynet.call(handle, "lua", "die")
                assert(r == "bye", "die did not respond")
                assert(wid == 100000 + i, "die returned wrong worker")
            end)
            if not ok then
                errors[#errors + 1] = tostring(err)
            end
            active[i] = nil
            done = done + 1
        end)
    end

    wait_until("lifecycle stress", function()
        return done == lifecycle_count
    end, 3000, function()
        local pending = {}
        for i = 1, lifecycle_count do
            if active[i] then
                pending[#pending + 1] = i .. ":" .. active[i]
                if #pending >= 8 then
                    break
                end
            end
        end
        return string.format("done=%d/%d errors=%d pending=%s",
            done, lifecycle_count, #errors, table.concat(pending, ","))
    end)
    assert(#errors == 0, table.concat(errors, "\n"))
    skynet.error(string.format("[stress] lifecycle: %d spawn/call/exit cycles completed", lifecycle_count))
end

local function run_failed_connect_stress()
    local done = 0
    for i = 1, 64 do
        skynet.fork(function()
            local conn = socket.connect("127.0.0.1", 1)
            assert(conn == nil, "closed-port connect should fail")
            done = done + 1
        end)
    end
    wait_until("failed connect storm", function()
        return done == 64
    end, 1000, function()
        return "done=" .. done
    end)
end

local function run_socket_stress()
    local accepted = 0
    local closed = 0
    local echoed = 0
    local listener = socket.listen("127.0.0.1", socket_port, function(event)
        if event == "accept" then
            accepted = accepted + 1
        elseif event == "close" then
            closed = closed + 1
        end
    end)

    socket.ondata(listener, function(conn_id, data)
        socket.write(listener, conn_id, data)
    end)

    local done = 0
    local errors = {}
    local start_time = skynet.now()

    for c = 1, socket_clients do
        skynet.fork(function()
            local ok, err = pcall(function()
                local conn = socket.connect("127.0.0.1", socket_port)
                assert(conn, "socket.connect failed")
                for n = 1, socket_messages do
                    local payload = string.format("client=%d msg=%d %s\n", c, n, string.rep("x", 64))
                    assert(socket.send(conn, payload), "socket.send failed")
                    local got = socket.read(conn, #payload)
                    assert(got == payload, "echo mismatch")
                    echoed = echoed + 1
                end
                socket.close(conn)
            end)
            if not ok then
                errors[#errors + 1] = tostring(err)
            end
            done = done + 1
        end)
    end

    wait_until("socket stress", function()
        return done == socket_clients
    end, 1000, function()
        return string.format("done=%d/%d accepted=%d closed=%d echoed=%d errors=%d",
            done, socket_clients, accepted, closed, echoed, #errors)
    end)
    assert(#errors == 0, table.concat(errors, "\n"))
    assert(accepted == socket_clients, string.format("accepted mismatch: %d/%d", accepted, socket_clients))
    assert(echoed == socket_clients * socket_messages,
        string.format("echoed mismatch: %d/%d", echoed, socket_clients * socket_messages))
    wait_until("socket close count", function()
        return closed == socket_clients
    end, 1000, function()
        return string.format("accepted=%d closed=%d echoed=%d", accepted, closed, echoed)
    end)

    socket.close_listener(listener)

    local elapsed = math.max(1, skynet.now() - start_time)
    skynet.error(string.format(
        "[stress] socket: accepted=%d closed=%d echoed=%d in %.2fs, echo %.0f/s",
        accepted, closed, echoed, elapsed / 100, echoed * 100 / elapsed))
end

local function run_socket_modes()
    local port = socket_port + 1
    local listener = socket.listen("127.0.0.1", port, function() end)
    socket.ondata(listener, function(conn_id, data)
        socket.write(listener, conn_id, data)
    end)

    local conn = assert(socket.connect("127.0.0.1", port), "socket mode connect failed")

    assert(socket.send(conn, "exact-mode"), "exact send failed")
    assert(socket.read(conn, #"exact-mode") == "exact-mode", "exact read failed")

    assert(socket.send(conn, "line-mode\n"), "line send failed")
    assert(socket.readline(conn, "\n") == "line-mode", "readline failed")

    assert(socket.send(conn, "readall-mode"), "readall send failed")
    assert(socket.readall(conn) == "readall-mode", "readall failed")

    socket.close(conn)
    socket.close_listener(listener)

    local close_port = socket_port + 2
    local accepted_conn
    local close_listener = socket.listen("127.0.0.1", close_port, function(event, conn_id)
        if event == "accept" then
            accepted_conn = conn_id
            skynet.fork(function()
                skynet.sleep(1)
                socket.close(conn_id)
            end)
        end
    end)
    local close_conn = assert(socket.connect("127.0.0.1", close_port), "close connect failed")
    local pending = socket.read(close_conn, 4)
    assert(pending == nil, "pending read should wake with nil on close")
    socket.close_listener(close_listener)

    local paused_seen = 0
    local pause_port = socket_port + 3
    local pause_listener
    pause_listener = socket.listen("127.0.0.1", pause_port, function(event, conn_id)
        if event == "accept" then
            socket.pause(pause_listener, conn_id)
            skynet.fork(function()
                skynet.sleep(2)
                socket.resume(pause_listener, conn_id)
            end)
        end
    end)
    socket.ondata(pause_listener, function(conn_id, data)
        paused_seen = paused_seen + 1
        socket.write(pause_listener, conn_id, data)
    end)
    local pause_conn = assert(socket.connect("127.0.0.1", pause_port), "pause connect failed")
    assert(socket.send(pause_conn, "pause-resume"), "pause send failed")
    assert(socket.read(pause_conn, #"pause-resume") == "pause-resume", "pause/resume read failed")
    assert(paused_seen >= 1, "pause/resume data handler did not run")
    socket.close(pause_conn)
    socket.close_listener(pause_listener)

    local seen = {}
    local l1 = socket.listen("127.0.0.1", socket_port + 4, function(event, conn_id)
        if event == "accept" then
            seen.l1 = (seen.l1 or 0) + 1
            socket.close(conn_id)
        end
    end)
    local l2 = socket.listen("127.0.0.1", socket_port + 5, function(event, conn_id)
        if event == "accept" then
            seen.l2 = (seen.l2 or 0) + 1
            socket.close(conn_id)
        end
    end)
    local c1 = socket.connect("127.0.0.1", socket_port + 4)
    if c1 then socket.close(c1) end
    local c2 = socket.connect("127.0.0.1", socket_port + 5)
    if c2 then socket.close(c2) end
    wait_until("multi-listener route", function()
        return seen.l1 == 1 and seen.l2 == 1
    end, 500, function()
        return string.format("l1=%s l2=%s", tostring(seen.l1), tostring(seen.l2))
    end)
    socket.close_listener(l1)
    socket.close_listener(l2)
end

local function run_udp_stress()
    local a_seen = 0
    local b_seen = 0
    local udp_a = socket.udp("127.0.0.1", socket_port + 10, function(payload, addr, port)
        assert(payload:sub(1, 2) == "b:", "udp A payload mismatch")
        a_seen = a_seen + 1
    end)
    local udp_b = socket.udp("127.0.0.1", socket_port + 11, function(payload, addr, port)
        assert(payload:sub(1, 2) == "a:", "udp B payload mismatch")
        b_seen = b_seen + 1
    end)

    for i = 1, 100 do
        socket.udp_send(udp_a, "a:" .. i, "127.0.0.1", socket_port + 11)
        socket.udp_send(udp_b, "b:" .. i, "127.0.0.1", socket_port + 10)
    end
    wait_until("udp stress", function()
        return a_seen == 100 and b_seen == 100
    end, 1000, function()
        return string.format("a=%d b=%d", a_seen, b_seen)
    end)
end

local function run_cluster_case()
    local cluster = require "skynet.cluster"
    cluster.init()
    cluster.reload({
        stressnode = "127.0.0.1:" .. tostring(socket_port + 20),
        listen_alias = "127.0.0.1:" .. tostring(socket_port + 23),
    })
    local addr, port = cluster.open("127.0.0.1", socket_port + 20)
    assert(addr == "127.0.0.1" and port == socket_port + 20, "cluster open mismatch")
    local alias_addr, alias_port = cluster.open("listen_alias")
    assert(alias_addr == "127.0.0.1" and alias_port == socket_port + 23, "cluster alias open mismatch")

    cluster.register("stress_cluster", skynet.self())
    cluster.register("stress_cluster_alias", skynet.self())
    cluster.register("stress_cluster", skynet.self())
    cluster.unregister("missing_stress_cluster")
    assert(cluster.query("stressnode", "stress_cluster") == skynet.self(), "cluster query failed")
    assert(cluster._queryname("stress_cluster") == skynet.self(), "cluster local queryname failed")

    local tag, a, b = cluster.call("stressnode", "@stress_cluster", "cluster_echo", "alpha", 42)
    assert(tag == "cluster_echo" and a == "alpha" and b == 42, "cluster call by name failed")

    local large = string.rep("L", 1024)
    local ltag, len, head, tail = cluster.call("stressnode", "@stress_cluster", "cluster_large", large)
    assert(ltag == "cluster_large" and len == #large and head == "LLLLLLLL" and tail == "LLLLLLLL",
        "cluster large request failed")

    local before = cluster_fire_count
    cluster.send("stressnode", "@stress_cluster", "cluster_fire", "push")
    wait_until("cluster push", function()
        return cluster_fire_count == before + 1
    end, 500)

    local port2 = socket_port + 21
    cluster.reload({ stressnode2 = "127.0.0.1:" .. tostring(port2) })
    cluster.open("127.0.0.1", port2)
    before = cluster_fire_count
    cluster.send("stressnode2", "@stress_cluster", "cluster_fire", "queued-push")
    wait_until("cluster queued push", function()
        return cluster_fire_count == before + 1
    end, 500)
    local qtag, qv = cluster.call("stressnode2", "@stress_cluster", "cluster_echo", "queued-call")
    assert(qtag == "cluster_echo" and qv == "queued-call", "cluster queued call failed")
    assert(not pcall(cluster.call, "stressnode", "@missing_cluster_name", "cluster_echo"),
        "cluster missing remote name should fail")
    assert(not pcall(cluster.query, "stressnode", "missing_cluster_name"),
        "cluster missing query should fail")

    local any_addr, any_port = cluster.open(socket_port + 22)
    assert(any_addr == "0.0.0.0" and any_port == socket_port + 22, "cluster numeric open failed")

    assert(not pcall(cluster.register, 123), "cluster register argument check failed")
    assert(not pcall(cluster.unregister, 123), "cluster unregister argument check failed")
    assert(cluster._selftest() == true, "cluster selftest failed")
    local sender = cluster.get_sender("stressnode")
    assert(pcall(skynet.call, sender, "lua", "__test", "req_table"),
        "clustersender table response selftest failed")
    assert(skynet.call(sender, "lua", "__test", "req_bool") == true,
        "clustersender bool response selftest failed")
    assert(skynet.call(sender, "lua", "__test", "push_padding") == true,
        "clustersender padding selftest failed")
    skynet.call(sender, "lua", "__test", "changenode_close")
    skynet.call(sender, "lua", "__test", "changenode_open")
    cluster.unregister("stress_cluster")
end

local function run_socketchannel_case()
    local sc = require "skynet.socketchannel"
    assert(sc._selftest() == true, "socketchannel selftest failed")
    local base = socket_port + 40

    local order_listener
    local order_buffers = {}
    order_listener = socket.listen("127.0.0.1", base, function(event, conn_id)
        if event == "accept" then
            order_buffers[conn_id] = ""
        elseif event == "close" then
            order_buffers[conn_id] = nil
        end
    end)
    socket.ondata(order_listener, function(conn_id, data)
        local buf = (order_buffers[conn_id] or "") .. data
        while true do
            local pos = buf:find("\n", 1, true)
            if not pos then break end
            local line = buf:sub(1, pos - 1)
            buf = buf:sub(pos + 1)
            if line == "auth" then
                socket.write(order_listener, conn_id, "AUTHOK\n")
            elseif line == "multi" then
                socket.write(order_listener, conn_id, "part-a\npart-b\n")
            elseif line == "fire" then
                socket.write(order_listener, conn_id, "IGNORED\n")
            elseif line == "never" then
                -- Keep the request pending until the client closes the channel.
            else
                socket.write(order_listener, conn_id, "echo:" .. line .. "\n")
            end
        end
        order_buffers[conn_id] = buf
    end)

    local order = sc.channel {
        host = "127.0.0.1",
        port = base,
        auth = function(ch)
            local r = ch:request("auth\n", function(c)
                return true, c:readline("\n")
            end)
            assert(r == "AUTHOK", "socketchannel auth failed")
        end,
        nodelay = true,
    }
    assert(order:request({ "hel", "lo\n" }, function(ch)
        return true, ch:readline("\n")
    end) == "echo:hello", "socketchannel order response failed")
    local step = 0
    local multi = order:request("multi\n", function(ch)
        step = step + 1
        return true, ch:readline("\n"), step < 2
    end)
    assert(type(multi) == "table" and multi[1] == "part-a" and multi[2] == "part-b",
        "socketchannel order multipart failed")
    order:request("fire\n")

    local concurrent = sc.channel { host = "127.0.0.1", port = base, nodelay = true }
    local done, errors = 0, {}
    for i = 1, 5 do
        skynet.fork(function()
            local ok, err = pcall(function()
                local r = concurrent:request("concurrent-" .. i .. "\n", function(ch)
                    return true, ch:readline("\n")
                end)
                assert(r:find("echo:concurrent-", 1, true), "socketchannel concurrent mismatch")
            end)
            if not ok then errors[#errors + 1] = tostring(err) end
            done = done + 1
        end)
    end
    wait_until("socketchannel concurrent connect", function()
        return done == 5
    end, 500)
    assert(#errors == 0, table.concat(errors, "\n"))
    concurrent:close()

    order:close()
    socket.close_listener(order_listener)

    local session_listener
    local session_buffers = {}
    session_listener = socket.listen("127.0.0.1", base + 1, function(event, conn_id)
        if event == "accept" then
            session_buffers[conn_id] = ""
            skynet.fork(function()
                skynet.sleep(2)
                socket.write(session_listener, conn_id, "99:1:async:0\n")
            end)
        elseif event == "close" then
            session_buffers[conn_id] = nil
        end
    end)
    socket.ondata(session_listener, function(conn_id, data)
        local buf = (session_buffers[conn_id] or "") .. data
        while true do
            local pos = buf:find("\n", 1, true)
            if not pos then break end
            local line = buf:sub(1, pos - 1)
            buf = buf:sub(pos + 1)
            local sid, payload = line:match("^(%d+):(.+)$")
            sid = tonumber(sid)
            if payload == "multi" then
                socket.write(session_listener, conn_id,
                    string.format("%d:1:s1:1\n%d:1:s2:0\n", sid, sid))
            elseif payload == "hold" then
                -- Keep this session pending so channel close wakes it.
            else
                socket.write(session_listener, conn_id, string.format("%d:1:%s:0\n", sid, payload))
            end
        end
        session_buffers[conn_id] = buf
    end)

    local session_ch = sc.channel {
        host = "127.0.0.1",
        port = base + 1,
        response = function(ch)
            local line = ch:readline("\n")
            if not line then return nil end
            local sid, ok, payload, padding = line:match("^(%d+):(%d):([^:]*):(%d)$")
            return tonumber(sid), ok == "1", payload, padding == "1"
        end,
    }
    assert(session_ch:request("7:payload\n", 7) == "payload", "socketchannel session response failed")
    local smulti = session_ch:request("8:multi\n", 8)
    assert(type(smulti) == "table" and smulti[1] == "s1" and smulti[2] == "s2",
        "socketchannel session multipart failed")
    assert(session_ch:response(99) == "async", "socketchannel response wait failed")
    session_ch:changehost("127.0.0.1", base + 1)
    session_ch:connect(true)
    local session_done, session_ok, session_err = false, nil, nil
    skynet.fork(function()
        session_ok, session_err = pcall(function()
            return session_ch:request("10:hold\n", 10)
        end)
        session_done = true
    end)
    wait_until("socketchannel pending session queued", function()
        return session_ch.__thread[10] ~= nil
    end, 500)
    session_ch:close()
    wait_until("socketchannel pending session close", function()
        return session_done
    end, 500)
    assert(session_ok == false and tostring(session_err):find("channel closed", 1, true),
        "socketchannel pending session should fail on close")
    socket.close_listener(session_listener)

    local bad = sc.channel { host = "127.0.0.1", port = 1 }
    assert(not pcall(function() bad:read(1) end), "socketchannel read before connect should fail")
    assert(not pcall(function() bad:readline("\n") end), "socketchannel readline before connect should fail")
    assert(not pcall(function() bad:connect(true) end), "socketchannel failed connect should error")

    local auth_listener = socket.listen("127.0.0.1", base + 2, function() end)
    local auth_bad = sc.channel {
        host = "127.0.0.1",
        port = base + 2,
        auth = function()
            error("auth failed intentionally")
        end,
    }
    assert(not pcall(function() auth_bad:connect(true) end), "socketchannel auth failure should error")
    socket.close_listener(auth_listener)
end

local function run_debug_console_case()
    local console = skynet.newservice("debug_console")
    skynet.sleep(5)
    local function cmd(line)
        local out = skynet.call(console, "lua", "CMD", line)
        assert(type(out) == "table" and #out > 0, "debug console empty output for " .. line)
        return out
    end

    cmd("help")
    cmd("list")
    cmd("stat 1")
    cmd("mem 1")
    cmd("gc 1")
    cmd("ping " .. skynet.address(skynet.self()))
    cmd("ping invalid")
    cmd("info " .. skynet.address(skynet.self()))
    cmd("info invalid")
    cmd("inject " .. skynet.address(skynet.self()) .. " return 1+1")
    cmd("inject " .. skynet.address(skynet.self()))
    cmd("exit invalid")
    cmd("start stress_worker")
    cmd("kill :ffffffff")
    cmd("unknown_command")
    local ok, err = skynet.call(console, "lua", "BOGUS")
    assert(ok == false and type(err) == "string", "debug console unknown lua command should fail")
    local test_ok, count = skynet.call(console, "lua", "CMD", "__selftest")
    assert(test_ok == true and count > 0, "debug console selftest failed")

    local conn = socket.connect("127.0.0.1", 8000)
    if conn then
        socket.send(conn, "help\n\nunknown_command\n")
        skynet.sleep(2)
        socket.close(conn)
        skynet.sleep(2)
    end

    skynet.kill(console)
end

local function resp_bulk(v)
    if v == nil then return "$-1\r\n" end
    v = tostring(v)
    return "$" .. tostring(#v) .. "\r\n" .. v .. "\r\n"
end

local function resp_array(t)
    local out = { "*" .. tostring(#t) .. "\r\n" }
    for _, v in ipairs(t) do
        out[#out + 1] = resp_bulk(v)
    end
    return table.concat(out)
end

local function parse_resp_value(buf, pos)
    local typ = buf:sub(pos, pos)
    local line_end = buf:find("\r\n", pos, true)
    if not line_end then return nil, pos end
    local data = buf:sub(pos + 1, line_end - 1)
    pos = line_end + 2
    if typ == "*" then
        local n = tonumber(data)
        local arr = {}
        for i = 1, n do
            local v
            v, pos = parse_resp_value(buf, pos)
            if v == nil and pos > #buf then return nil, #buf + 1 end
            arr[i] = v
        end
        return arr, pos
    elseif typ == "$" then
        local n = tonumber(data)
        if n < 0 then return nil, pos end
        if #buf < pos + n + 1 then return nil, #buf + 1 end
        local v = buf:sub(pos, pos + n - 1)
        return v, pos + n + 2
    elseif typ == "+" or typ == "-" or typ == ":" then
        return data, pos
    end
    error("unsupported RESP type: " .. tostring(typ))
end

local function run_redis_case()
    local redis = require "skynet.db.redis"
    assert(redis._selftest() == true, "redis selftest failed")
    local docker_port = env_number("SKYNET_TEST_REDIS_PORT")
    if docker_port then
        skynet.error("[stress][redis] real docker redis")
        local db = redis.connect { host = "127.0.0.1", port = docker_port }
        assert(db:ping() == "PONG", "redis ping failed")
        assert(db:set("stress:k", "v") == "OK", "redis set failed")
        assert(db:get("stress:k") == "v", "redis get failed")
        db:del("stress:list", "stress:set")
        assert(db:rpush("stress:list", "a", "b", "c") == 3, "redis rpush failed")
        local arr = db:lrange({ "stress:list", 0, -1 })
        assert(type(arr) == "table" and arr[3] == "c", "redis lrange failed")
        assert(db:sadd("stress:set", "v") == 1, "redis sadd failed")
        assert(db:exists("stress:k") == true, "redis exists failed")
        assert(db:sismember("stress:set", "v") == true, "redis sismember failed")
        local resp = {}
        db:pipeline({
            { "SET", "stress:pipeline", "1" },
            { "GET", "stress:pipeline" },
            { "EXISTS", "stress:pipeline" },
        }, resp)
        assert(#resp == 3 and resp[2].out == "1", "redis pipeline failed")

        local watcher = redis.watch { host = "127.0.0.1", port = docker_port }
        watcher:subscribe("stress:chan")
        skynet.fork(function()
            skynet.sleep(2)
            db:publish("stress:chan", "hello")
        end)
        local data, channel = watcher:message()
        assert(data == "hello" and channel == "stress:chan", "redis subscribe failed")
        watcher:psubscribe("stress:*")
        skynet.fork(function()
            skynet.sleep(2)
            db:publish("stress:pchan", "world")
        end)
        local pdata, pattern, pchannel = watcher:message()
        assert(pdata == "world" and pattern == "stress:*" and pchannel == "stress:pchan",
            "redis psubscribe failed")
        watcher:unsubscribe("stress:chan")
        watcher:punsubscribe("stress:*")
        watcher:disconnect()
        db:disconnect()
    end

    skynet.error("[stress][redis] setup fake server")
    local port = socket_port + 60
    local buffers = {}
    local listener
    listener = socket.listen("127.0.0.1", port, function(event, conn_id)
        if event == "accept" then
            buffers[conn_id] = ""
        elseif event == "close" then
            buffers[conn_id] = nil
        end
    end)
    socket.ondata(listener, function(conn_id, data)
        local buf = (buffers[conn_id] or "") .. data
        while #buf > 0 do
            local req, next_pos = parse_resp_value(buf, 1)
            if not req then break end
            buf = buf:sub(next_pos)
            local cmd = tostring(req[1] or ""):upper()
            if cmd == "AUTH" or cmd == "SELECT" or cmd == "SET" then
                socket.write(listener, conn_id, "+OK\r\n")
            elseif cmd == "PING" then
                socket.write(listener, conn_id, "+PONG\r\n")
            elseif cmd == "GET" then
                if req[2] == "nil" then
                    socket.write(listener, conn_id, resp_bulk(nil))
                else
                    socket.write(listener, conn_id, resp_bulk("redis-value"))
                end
            elseif cmd == "EXISTS" then
                socket.write(listener, conn_id, ":1\r\n")
            elseif cmd == "SISMEMBER" then
                socket.write(listener, conn_id, ":0\r\n")
            elseif cmd == "LRANGE" then
                socket.write(listener, conn_id, resp_array({ "a", "b", "c" }))
            elseif cmd == "ERRCMD" then
                socket.write(listener, conn_id, "-ERR forced\r\n")
            elseif cmd == "SUBSCRIBE" then
                socket.write(listener, conn_id, resp_array({ "subscribe", req[2], "1" }))
                socket.write(listener, conn_id, resp_array({ "message", req[2], "hello" }))
            elseif cmd == "PSUBSCRIBE" then
                socket.write(listener, conn_id, resp_array({ "psubscribe", req[2], "1" }))
                socket.write(listener, conn_id, resp_array({ "pmessage", req[2], "chan:1", "world" }))
            elseif cmd == "UNSUBSCRIBE" then
                socket.write(listener, conn_id, resp_array({ "unsubscribe", req[2], "0" }))
            elseif cmd == "PUNSUBSCRIBE" then
                socket.write(listener, conn_id, resp_array({ "punsubscribe", req[2], "0" }))
            else
                socket.write(listener, conn_id, "+OK\r\n")
            end
        end
        buffers[conn_id] = buf
    end)

    skynet.error("[stress][redis] connect client")
    local db = redis.connect { host = "127.0.0.1", port = port, auth = "secret", username = "user", db = 1 }
    skynet.error("[stress][redis] basic commands")
    assert(db:ping() == "PONG", "redis ping failed")
    assert(db:set("k", "v") == "OK", "redis set failed")
    assert(db:get("k") == "redis-value", "redis get failed")
    assert(db:exists("k") == true, "redis exists failed")
    assert(db:sismember("s", "v") == false, "redis sismember failed")
    local arr = db:lrange({ "list", 0, -1 })
    assert(type(arr) == "table" and arr[3] == "c", "redis array failed")
    local resp = {}
    skynet.error("[stress][redis] pipeline with resp")
    local last = db:pipeline({
        { "SET", "k", "v" },
        { "GET", "k" },
        { "EXISTS", "k" },
    }, resp)
    assert(type(last) == "table" and #resp == 3 and resp[2].out == "redis-value",
        "redis pipeline resp failed")
    skynet.error("[stress][redis] pipeline error")
    assert(not pcall(function()
        db:pipeline({ { "GET", "k" }, { "ERRCMD" } })
    end), "redis error pipeline should fail")
    db:disconnect()

    skynet.error("[stress][redis] watch")
    local watcher = redis.watch { host = "127.0.0.1", port = port }
    watcher:subscribe("chan")
    skynet.error("[stress][redis] watch message")
    local data, channel = watcher:message()
    assert(data == "hello" and channel == "chan", "redis subscribe message failed")
    watcher:psubscribe("chan:*")
    skynet.error("[stress][redis] watch pmessage")
    local pdata, pattern, pchannel = watcher:message()
    assert(pdata == "world" and pattern == "chan:*" and pchannel == "chan:1", "redis pmessage failed")
    watcher:unsubscribe("chan")
    watcher:punsubscribe("chan:*")
    watcher:disconnect()

    socket.close_listener(listener)
    skynet.error("[stress][redis] done")
end

local function mysql_packet(seq, payload)
    return string.pack("<I3B", #payload, seq or 0) .. payload
end

local function mysql_lenstr(s)
    return string.char(#s) .. s
end

local function mysql_ok(seq, status)
    return mysql_packet(seq or 1, "\0\0\0" .. string.pack("<I2I2", status or 0, 0))
end

local function mysql_eof(seq, status)
    return mysql_packet(seq or 1, "\xfe" .. string.pack("<I2I2", 0, status or 0))
end

local function mysql_field(name, typ)
    return mysql_lenstr("def") .. mysql_lenstr("db") .. mysql_lenstr("t") .. mysql_lenstr("t") ..
        mysql_lenstr(name) .. mysql_lenstr(name) .. "\x0c" ..
        string.pack("<I2I4BI2", 33, 32, typ or 0x03, 0)
end

local function mysql_resultset()
    return table.concat({
        mysql_packet(1, "\1"),
        mysql_packet(2, mysql_field("n", 0x03)),
        mysql_eof(3, 0),
        mysql_packet(4, mysql_lenstr("42")),
        mysql_eof(5, 0),
    })
end

local function mysql_prepare_result()
    return table.concat({
        mysql_packet(1, "\0" .. string.pack("<I4I2I2BI2", 1234, 1, 4, 0, 0)),
        mysql_packet(2, mysql_field("p1", 0x03)),
        mysql_packet(3, mysql_field("p2", 0x0f)),
        mysql_packet(4, mysql_field("p3", 0x01)),
        mysql_packet(5, mysql_field("p4", 0x06)),
        mysql_eof(6, 0),
        mysql_packet(7, mysql_field("n", 0x03)),
        mysql_eof(8, 0),
    })
end

local function mysql_execute_result()
    return table.concat({
        mysql_packet(1, "\1"),
        mysql_packet(2, mysql_field("n", 0x03)),
        mysql_eof(3, 0),
        mysql_packet(4, "\0\0" .. string.pack("<i4", 7)),
        mysql_eof(5, 0),
    })
end

local function run_mysql_case()
    local mysql = require "skynet.db.mysql"
    assert(mysql._selftest() == true, "mysql selftest failed")
    local docker_port = env_number("SKYNET_TEST_MYSQL_PORT")
    if docker_port then
        skynet.error("[stress][mysql] real docker mysql")
        local db = mysql.connect {
            host = "127.0.0.1",
            port = docker_port,
            user = core.getenv("SKYNET_TEST_MYSQL_USER") or "root",
            password = core.getenv("SKYNET_TEST_MYSQL_PASSWORD") or "skynet",
            database = core.getenv("SKYNET_TEST_MYSQL_DATABASE") or "stress",
            charset = "utf8mb4",
        }
        assert(type(db:server_ver()) == "string", "mysql server_ver failed")
        db:query("DROP TABLE IF EXISTS stress_items")
        assert(db:query("CREATE TABLE stress_items(id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(32), n INT)").affected_rows == 0,
            "mysql create table failed")
        assert(db:query("INSERT INTO stress_items(name, n) VALUES('alpha', 1), ('beta', 2)").affected_rows == 2,
            "mysql insert failed")
        local rows = db:query("SELECT n FROM stress_items WHERE name='alpha'")
        assert(type(rows) == "table" and rows[1].n == 1, "mysql select failed")
        local stmt = db:prepare("SELECT ? AS n")
        local erows = db:execute(stmt, 9)
        assert(type(erows) == "table" and erows[1].n == 9, "mysql execute failed")
        db:stmt_close(stmt)
        assert(db:ping().affected_rows == 0, "mysql ping failed")
        db:disconnect()
    end

    local port = socket_port + 70
    local buffers = {}
    local listener
    listener = socket.listen("127.0.0.1", port, function(event, conn_id)
        if event == "accept" then
            buffers[conn_id] = ""
            local scramble1 = "12345678"
            local scramble2 = "abcdefghijkl"
            local payload = "\10" .. "5.7.0\0" .. string.pack("<I4", 99) .. scramble1 .. "\0" ..
                string.pack("<I2BI2B", 0xffff, 33, 2, 0xff) ..
                string.char(21) .. string.rep("\0", 10) .. scramble2 .. "\0"
            socket.write(listener, conn_id, mysql_packet(0, payload))
        elseif event == "close" then
            buffers[conn_id] = nil
        end
    end)
    socket.ondata(listener, function(conn_id, data)
        local buf = (buffers[conn_id] or "") .. data
        while #buf >= 4 do
            local len, seq = string.unpack("<I3B", buf)
            if #buf < len + 4 then break end
            local payload = buf:sub(5, len + 4)
            buf = buf:sub(len + 5)
            local cmd = payload:byte(1)
            if seq == 1 and cmd ~= 0x03 and cmd ~= 0x0e and cmd ~= 0x16 and cmd ~= 0x17 and cmd ~= 0x1a then
                socket.write(listener, conn_id, mysql_ok(2))
            elseif cmd == 0x03 then
                if payload:sub(2):find("SELECT", 1, true) then
                    socket.write(listener, conn_id, mysql_resultset())
                else
                    socket.write(listener, conn_id, mysql_ok(1))
                end
            elseif cmd == 0x0e or cmd == 0x1a then
                socket.write(listener, conn_id, mysql_ok(1))
            elseif cmd == 0x16 then
                socket.write(listener, conn_id, mysql_prepare_result())
            elseif cmd == 0x17 then
                socket.write(listener, conn_id, mysql_execute_result())
            end
        end
        buffers[conn_id] = buf
    end)

    local db = mysql.connect {
        host = "127.0.0.1",
        port = port,
        user = "root",
        password = "pw",
        database = "stress",
        charset = "utf8",
        on_connect = function(conn)
            conn._stress_connected = true
        end,
    }
    assert(db._stress_connected == true and type(db:server_ver()) == "string", "mysql login failed")
    local rows = db:query("SELECT 42")
    assert(type(rows) == "table" and rows[1].n == 42, "mysql query failed")
    local okres = db:query("UPDATE t SET n=1")
    assert(type(okres) == "table" and okres.affected_rows == 0, "mysql ok result failed")
    local stmt = db:prepare("SELECT ?")
    assert(stmt.prepare_id == 1234 and stmt.param_count == 4, "mysql prepare failed")
    local erows = db:execute(stmt, 7, "abc", true, nil)
    assert(type(erows) == "table" and erows[1].n == 7, "mysql execute failed")
    local erows2 = db:execute(stmt, 1.5, "abc", false, nil)
    assert(type(erows2) == "table" and erows2[1].n == 7, "mysql execute float failed")
    assert(db:ping().affected_rows == 0, "mysql ping failed")
    assert(db:stmt_reset(stmt).affected_rows == 0, "mysql stmt_reset failed")
    db:stmt_close(stmt)
    db:disconnect()

    local compact = mysql.connect {
        host = "127.0.0.1",
        port = port,
        user = "root",
        password = "",
        compact_arrays = true,
    }
    local compact_rows = compact:query("SELECT 42")
    assert(compact_rows[1][1] == 42, "mysql compact query failed")
    compact:disconnect()
    socket.close_listener(listener)
end

local function mongo_reply(reqid, doc)
    local bson = require "bson"
    local body_doc = bson.encode(doc)
    local body = string.pack("<i4B", 0, 0) .. body_doc
    return string.pack("<i4i4i4i4", 16 + #body, 9000 + reqid, reqid, 2013) .. body
end

local function run_mongo_case()
    local mongo = require "skynet.db.mongo"
    local bson = require "bson"
    assert(mongo._selftest() == true, "mongo selftest failed")
    local docker_port = env_number("SKYNET_TEST_MONGO_PORT")
    if docker_port then
        skynet.error("[stress][mongo] real docker mongo")
        local client = mongo.client { host = "127.0.0.1", port = docker_port }
        local db = client:getDB(core.getenv("SKYNET_TEST_MONGO_DATABASE") or "stress")
        local ping = db:runCommand("ping", 1)
        skynet.error("[stress][mongo] ping ok=" .. tostring(ping and ping.ok) ..
            " errmsg=" .. tostring(ping and ping.errmsg))
        assert(ping and (ping.ok == 1 or ping.ok == true), "mongo ping failed")
        local coll = db:getCollection("items")
        coll:drop()
        assert(coll:insert({ name = "Alice", n = 1 }).ok == 1, "mongo insert failed")
        assert(coll:safe_insert({ name = "Carol", n = 3 }).ok == 1, "mongo safe_insert failed")
        assert(coll:batch_insert({ { name = "Bob", n = 2 }, { name = "Dana", n = 4 } }).ok == 1,
            "mongo batch_insert failed")
        assert(coll:findOne({ name = "Alice" }).name == "Alice", "mongo findOne failed")
        assert(coll:update({ name = "Alice" }, { ["$set"] = { n = 11 } }, false, false).ok == 1,
            "mongo update failed")
        assert(coll:count({}) >= 4, "mongo count failed")
        local agg = coll:aggregate({ { ["$match"] = {} } })
        assert(type(agg) == "table" and #agg >= 1, "mongo aggregate failed")
        local cursor = coll:find({}):sort({ n = 1 }):limit(2)
        assert(cursor:hasNext() == true and cursor:next() ~= nil, "mongo cursor failed")
        cursor:close()
        assert(coll:delete({ name = "Dana" }, true).ok == 1, "mongo delete failed")
        client:disconnect()
    end

    local port = socket_port + 80
    local buffers = {}
    local listener
    listener = socket.listen("127.0.0.1", port, function(event, conn_id)
        if event == "accept" then
            buffers[conn_id] = ""
        elseif event == "close" then
            buffers[conn_id] = nil
        end
    end)
    socket.ondata(listener, function(conn_id, data)
        local buf = (buffers[conn_id] or "") .. data
        while #buf >= 4 do
            local len = string.unpack("<i4", buf)
            if #buf < len then break end
            local packet = buf:sub(1, len)
            buf = buf:sub(len + 1)
            local reqid = string.unpack("<i4", packet, 5)
            local doc = bson.decode(packet, 22)
            local cmd = doc.insert and "insert" or doc.find and "find" or doc.getMore and "getMore" or
                doc.update and "update" or doc.delete and "delete" or doc.findAndModify and "findAndModify" or
                doc.createIndexes and "createIndexes" or doc.drop and "drop" or doc.count and "count" or
                doc.aggregate and "aggregate" or doc.killCursors and "killCursors" or "ok"
            if cmd == "find" then
                socket.write(listener, conn_id, mongo_reply(reqid, {
                    ok = 1,
                    cursor = { id = bson.int64(222), firstBatch = { { name = "Alice", n = 1 } } },
                }))
            elseif cmd == "getMore" then
                socket.write(listener, conn_id, mongo_reply(reqid, {
                    ok = 1,
                    cursor = { id = bson.int64(0), nextBatch = { { name = "Bob", n = 2 } } },
                }))
            elseif cmd == "count" then
                socket.write(listener, conn_id, mongo_reply(reqid, { ok = 1, n = 3 }))
            elseif cmd == "aggregate" then
                socket.write(listener, conn_id, mongo_reply(reqid, {
                    ok = 1,
                    cursor = { id = bson.int64(0), firstBatch = { { total = 9 } } },
                }))
            else
                socket.write(listener, conn_id, mongo_reply(reqid, { ok = 1 }))
            end
        end
        buffers[conn_id] = buf
    end)

    local client = mongo.client { host = "127.0.0.1", port = port }
    local db = client:getDB("stress")
    assert(db:runCommand("ping", 1).ok == 1, "mongo runCommand failed")
    db:sendCommand("ping", 1)
    local coll = db:getCollection("items")
    assert(coll:insert({ name = "Alice" }).ok == 1, "mongo insert failed")
    assert(coll:safe_insert({ name = "Alice" }).ok == 1, "mongo safe_insert failed")
    assert(coll:batch_insert({ { n = 1 }, { n = 2 } }).ok == 1, "mongo batch_insert failed")
    assert(coll:findOne({ name = "Alice" }).name == "Alice", "mongo findOne failed")
    assert(coll:findOne({ name = "Alice" }, { name = 1 }).name == "Alice", "mongo findOne projection failed")
    assert(coll:update({ name = "Alice" }, { ["$set"] = { n = 2 } }, true, true).ok == 1,
        "mongo update failed")
    assert(coll:delete({ name = "Alice" }, true).ok == 1, "mongo delete failed")
    assert(coll:findAndModify({ query = {}, update = { ["$set"] = { n = 3 } } }).ok == 1,
        "mongo findAndModify failed")
    assert(coll:createIndex({ name = 1 }, { unique = true }).ok == 1, "mongo createIndex failed")
    assert(coll:drop().ok == 1, "mongo drop failed")
    assert(coll:count({}) == 3, "mongo count failed")
    assert(coll:aggregate({ { ["$match"] = {} } })[1].total == 9, "mongo aggregate failed")
    local cursor = coll:find({}):sort({ n = 1 }):skip(0):limit(2)
    assert(cursor:hasNext() == true and cursor:next().name == "Alice", "mongo cursor first failed")
    assert(cursor:hasNext() == true and cursor:next().name == "Bob", "mongo cursor getMore failed")
    assert(cursor:hasNext() == false, "mongo cursor end failed")
    cursor:close()
    local cursor2 = coll:find({}):limit(1)
    assert(cursor2:hasNext() == true, "mongo cursor2 start failed")
    cursor2:close()
    local arr = coll:find({}):toArray()
    assert(#arr >= 2, "mongo toArray failed")
    client.stress.items:findOne({})
    client:disconnect()
    socket.close_listener(listener)
end

local function run_module_stress()
    local profile = require "skynet.profile"
    profile.start()
    local sum = 0
    for i = 1, 10000 do
        sum = sum + i
    end
    assert(profile.stop() >= 0, "profile stop failed")

    assert(skynet.call(skynet.self(), "debug", "MEM") > 0, "debug MEM failed")
    assert(pcall(skynet.call, skynet.self(), "debug", "PING"), "debug PING failed")
    assert(type(skynet.call(skynet.self(), "debug", "STAT")) == "table", "debug STAT failed")

    local netpack = require "netpack"
    local p1 = netpack.pack("hello")
    local off, unpacked = netpack.unpack(p1)
    assert(off == #p1 + 1 and unpacked == "hello", "netpack unpack failed")
    local p2 = netpack.pack("world")
    local msgs, remain = netpack.filter("", p1 .. p2)
    assert(#msgs == 2 and msgs[1] == "hello" and msgs[2] == "world" and remain == "",
        "netpack filter failed")
    local partial_msgs, partial_remain = netpack.filter("", p1:sub(1, 3))
    assert(#partial_msgs == 0 and #partial_remain == 3, "netpack partial filter failed")

    local sharedata = require "sharedata"
    sharedata.new("stress_config", { name = "stress", sum = sum })
    local cfg = sharedata.query("stress_config")
    assert(cfg.name == "stress", "sharedata query failed")
    sharedata.update("stress_config", { name = "stress2", sum = sum + 1 })
    sharedata.flush()
    cfg = sharedata.query("stress_config")
    assert(cfg.name == "stress2", "sharedata update failed")
    sharedata.delete("stress_config")

    local multicast = require "skynet.multicast"
    local mc = multicast.new()
    local received = 0
    mc.dispatch = function(channel, source, value)
        if channel == mc.channel and value == "multicast-payload" then
            received = received + 1
        end
    end
    mc:subscribe()
    mc:publish("multicast-payload")
    wait_until("multicast publish", function()
        return received >= 1
    end, 500)
    mc:unsubscribe()
    mc:delete()

    local cluster_core = require "cluster.core"
    local packed = skynet.packstring("cluster", "payload")
    local req = cluster_core.packrequest(0x12345678, 9, packed, #packed)
    assert(cluster_core.header(req:sub(1, 2)) == #req - 2, "cluster header mismatch")
    local addr, session = cluster_core.unpackrequest(req:sub(3))
    assert(addr == 0x12345678 and session == 9, "cluster unpackrequest mismatch")
    local resp = cluster_core.packresponse(9, true, "ok")
    local rsession, rok, rdata = cluster_core.unpackresponse(resp:sub(3))
    assert(rsession == 9 and rok == true and rdata == "ok", "cluster unpackresponse mismatch")
    local push = cluster_core.packpush("@named", 10, "push", 4)
    local paddr, psession, pmsg, psz, ppadding, pis_push = cluster_core.unpackrequest(push:sub(3))
    assert(paddr == "@named" and psession == 0 and pmsg == "push" and psz == 4 and pis_push == true,
        "cluster packpush named mismatch")
    local parts = { 6 }
    cluster_core.append(parts, "abc")
    cluster_core.append(parts, "def")
    local concat, concat_sz = cluster_core.concat(parts)
    assert(concat == "abcdef" and concat_sz == 6, "cluster concat mismatch")
    assert(not pcall(cluster_core.header, "x"), "cluster header error path failed")
    assert(not pcall(cluster_core.unpackrequest, "x"), "cluster unpackrequest error path failed")
    assert(not pcall(cluster_core.packrequest, {}, 1, "bad"), "cluster packrequest error path failed")
    assert(cluster_core.isname("@stress") == true, "cluster isname failed")
    assert(type(cluster_core.nodename()) == "string", "cluster nodename failed")

    local bson = require "bson"
    local oid = bson.objectid()
    local doc = {
        name = "Alice",
        active = true,
        nested = { score = 99, tags = { "a", "b", "c" } },
        none = bson.null,
        oid = oid,
        big = bson.int64(123456789012345),
    }
    local encoded = bson.encode(doc)
    local decoded = bson.decode(encoded)
    assert(decoded.name == "Alice", "bson name mismatch")
    assert(decoded.nested.tags[3] == "c", "bson nested mismatch")
    assert(decoded.none == bson.null, "bson null mismatch")
    assert(decoded.big == 123456789012345, "bson int64 mismatch")

    local crypt = require "skynet.crypt"
    assert(crypt.hexencode(crypt.sha1("abc")) == "a9993e364706816aba3e25717850c26c9cd0d89d",
        "sha1 mismatch")
    assert(crypt.base64decode(crypt.base64encode("Hello")) == "Hello", "base64 mismatch")

    assert(pcall(require, "skynet.db.redis"), "redis module should load")
    assert(pcall(require, "skynet.db.mysql"), "mysql module should load")
    assert(pcall(require, "skynet.db.mongo"), "mongo module should load")
end

local function print_summary()
    skynet.error("[stress] === Summary ===")
    for _, item in ipairs(summary) do
        skynet.error(string.format("[stress] SUMMARY %s %s %.2fs",
            item.ok and "PASS" or "FAIL", item.name, item.elapsed / 100))
    end
end

skynet.start(function()
    install_stress_dispatch()
    skynet.error(string.format(
        "[stress] start workers=%d calls=%d fire=%d lifecycle=%d socket_clients=%d socket_messages=%d",
        worker_count, calls_per_worker, fire_per_worker, lifecycle_count, socket_clients, socket_messages))

    local workers
    run_case("actor rpc/fire", function()
        workers = run_actor_stress()
    end)
    run_case("session/timer/name/error", function()
        run_session_api_stress(workers)
    end)
    run_case("lifecycle", run_lifecycle_stress)
    run_case("failed connect", run_failed_connect_stress)
    run_case("tcp echo", run_socket_stress)
    run_case("socket modes", run_socket_modes)
    run_case("udp", run_udp_stress)
    run_case("cluster", run_cluster_case)
    run_case("socketchannel", run_socketchannel_case)
    run_case("debug console", run_debug_console_case)
    run_case("redis db", run_redis_case)
    run_case("mysql db", run_mysql_case)
    run_case("mongo db", run_mongo_case)
    run_case("modules", run_module_stress)

    for _, handle in ipairs(workers) do
        skynet.kill(handle)
    end

    print_summary()
    skynet.error("[stress] PASS: stress suite completed")
    skynet.sleep(10)
    skynet.shutdown()
end)
