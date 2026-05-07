local skynet = require "skynet"
local socket = require "socket"
local core = require "skynet.core"

local summary = {}
local port_base = 19291

local function wait_until(label, predicate, timeout_cs)
    local deadline = skynet.now() + timeout_cs
    while skynet.now() < deadline do
        if predicate() then
            return
        end
        skynet.sleep(1)
    end
    error(label .. " timed out")
end

local function run_case(name, fn)
    skynet.error("[unit] CASE begin: " .. name)
    local started = skynet.now()
    local ok, err = xpcall(fn, debug.traceback)
    summary[#summary + 1] = { name = name, ok = ok, elapsed = skynet.now() - started, err = err }
    if not ok then
        error("[unit] CASE failed: " .. name .. "\n" .. tostring(err))
    end
    skynet.error(string.format("[unit] CASE pass: %s in %.2fs", name, (skynet.now() - started) / 100))
end

local function assert_eq(a, b, label)
    assert(a == b, string.format("%s: got %s expected %s", label, tostring(a), tostring(b)))
end

local function run_core_cpp_units()
    assert(type(core.self()) == "number", "core.self failed")
    assert(type(core.now()) == "number", "core.now failed")
    assert(type(core.starttime()) == "number", "core.starttime failed")
    assert(type(core.mem()) == "number", "core.mem failed")
    assert(type(core.gc()) == "number", "core.gc failed")
    assert(type(core.memused()) == "number", "core.memused failed")
    local old_limit = core.memlimit()
    assert(type(old_limit) == "number", "core.memlimit query failed")
    core.memlimit(0)
    local blob = string.rep("m", 9 * 1024 * 1024)
    assert(#blob == 9 * 1024 * 1024, "large allocation failed")
    blob = nil
    collectgarbage("collect")
    core.memlimit(old_limit)

    assert(core.getenv("PATH") ~= nil or core.getenv("Path") ~= nil, "core.getenv failed")
    local ok, err = core.writefile(".", "x")
    assert(ok == nil and type(err) == "string", "core.writefile error path failed")
    local temp = "coverage-report/unit-core-write.txt"
    assert(core.writefile(temp, "a") == true, "core.writefile create failed")
    assert(core.writefile(temp, "b", true) == true, "core.writefile append failed")

    local h1, h2 = core.harbor(1)
    assert(h1 == 0 and h2 == 0, "core.harbor failed")
    assert(core.reg() == skynet.address(skynet.self()), "core.reg no-name failed")
    assert(not pcall(core.tostring, {}), "core.tostring invalid type should fail")
    assert(not pcall(core.send, skynet.self(), 0, skynet.PTYPE_LUA, 0, {}), "core.send invalid msg should fail")
end

local function run_netpack_cluster_seri_units()
    local netpack = require "netpack"
    local cluster = require "cluster.core"

    local frame = netpack.pack("abc")
    local next_offset, payload = netpack.unpack(frame)
    assert(next_offset == #frame + 1 and payload == "abc", "netpack unpack failed")
    assert(netpack.unpack(frame, #frame + 1) == nil, "netpack offset eof failed")
    assert(netpack.unpack(frame:sub(1, 1)) == nil, "netpack short header failed")
    assert(netpack.unpack(frame:sub(1, 3)) == nil, "netpack incomplete payload failed")
    local messages, remain = netpack.filter("", netpack.pack("a") .. netpack.pack("b") .. "\0")
    assert(#messages == 2 and messages[1] == "a" and messages[2] == "b" and remain == "\0",
        "netpack filter failed")
    assert(netpack.tostring("raw") == "raw", "netpack tostring string failed")
    assert(not pcall(netpack.tostring, {}), "netpack tostring invalid type should fail")
    assert(not pcall(netpack.pack, string.rep("x", 70000)), "netpack oversized frame should fail")

    local up = 42
    local function with_upvalue()
        return up
    end
    local light = debug.upvalueid(with_upvalue, 1)
    local packed, packed_sz = skynet.pack(nil, true, false, 0, 1, 255, 65535, -1,
        0x100000000, 1.25, "", string.rep("s", 40), string.rep("l", 70000),
        { 1, 2, 3, k = "v", [40] = "sparse" }, light)
    local values = table.pack(skynet.unpack(packed, packed_sz))
    skynet.trash(packed, packed_sz)
    assert(values.n >= 15 and values[2] == true and values[12] == string.rep("s", 40),
        "skynet seri round-trip failed")
    local deep = {}
    local cursor = deep
    for _ = 1, 34 do
        cursor[1] = {}
        cursor = cursor[1]
    end
    assert(not pcall(skynet.pack, deep), "skynet seri deep table should fail")
    assert(not pcall(skynet.pack, function() end), "skynet seri unsupported type should fail")

    local req, ns = cluster.packrequest(123, 2147483647, nil)
    assert(ns == 1 and cluster.header(req:sub(1, 2)) == #req - 2, "cluster session wrap failed")
    local addr, session, msg, sz = cluster.unpackrequest(req:sub(3))
    assert(addr == 123 and session == 2147483647 and msg == "" and sz == 0, "cluster nil msg failed")

    local big = string.rep("B", 70000)
    local mreq, _, mpad = cluster.packrequest("@unit_name", 2, big)
    assert(type(mpad) == "table" and #mpad > 1, "cluster string multipart request failed")
    local naddr, nsession, _, total, padding = cluster.unpackrequest(mreq:sub(3))
    assert(naddr == "@unit_name" and nsession == 2 and total == #big and padding == true,
        "cluster string multipart unpack failed")
    local push, _, ppad = cluster.packpush("@unit_name", 3, big)
    assert(type(ppad) == "table", "cluster push padding failed")
    local _, _, _, _, _, is_push = cluster.unpackrequest(push:sub(3))
    assert(is_push == true, "cluster multipart push flag failed")

    local resp_table = cluster.packresponse(9, true, big)
    assert(type(resp_table) == "table" and #resp_table > 1, "cluster multipart response failed")
    local rs, rok, rtotal, rpadding = cluster.unpackresponse(resp_table[1]:sub(3))
    assert(rs == 9 and rok == true and rtotal == #big and rpadding == true,
        "cluster multipart response begin failed")
    local err_resp = cluster.packresponse(10, false, big)
    local es, eok, edata = cluster.unpackresponse(err_resp:sub(3))
    assert(es == 10 and eok == false and #edata == 0x8000, "cluster error truncation failed")

    local pmsg, psz = skynet.pack("ptr")
    local preq = cluster.packrequest(123, 11, pmsg, psz)
    assert(type(preq) == "string", "cluster lightuserdata request failed")
    local rmsg, rsz = skynet.pack("resp")
    local presp = cluster.packresponse(12, true, rmsg, rsz)
    assert(type(presp) == "string", "cluster lightuserdata response failed")
    local amsg, asz = skynet.pack("append")
    local encoded_append = core.tostring(amsg, asz)
    local parts = { 3 + #encoded_append }
    cluster.append(parts, "abc")
    cluster.append(parts, amsg, asz)
    local combined, combined_sz = cluster.concat(parts)
    assert(combined_sz == 3 + #encoded_append and combined == "abc" .. encoded_append,
        "cluster concat lightuserdata failed")
    assert(cluster.concat({ "bad" }) == nil, "cluster concat bad table failed")
    assert(not pcall(cluster.append, {}, {}), "cluster append invalid type should fail")
    assert(not pcall(cluster.packrequest, "bad", 0, "x"), "cluster invalid session should fail")
    assert(not pcall(cluster.packrequest, string.rep("n", 300), 1, "x"), "cluster long name should fail")
    assert(not pcall(cluster.unpackrequest, ""), "cluster unpack empty should fail")
    assert(cluster.unpackresponse("bad") == nil, "cluster short response should return nil")
end

local function run_profile_units()
    local profile = require "skynet.profile"
    assert(not pcall(profile.stop), "profile.stop before start should fail")
    profile.start()
    assert(not pcall(profile.start), "profile double start should fail")
    local elapsed = profile.stop()
    assert(type(elapsed) == "number", "profile.stop failed")

    local co = coroutine.create(function(v)
        coroutine.yield("yielded", v)
        return "done"
    end)
    profile.start(co)
    local ok, tag, value = profile.resume(co, 7)
    assert(ok and tag == "yielded" and value == 7, "profile.resume yield failed")
    ok, tag = profile.resume(co)
    assert(ok and tag == "done", "profile.resume done failed")
    assert(type(profile.stop(co)) == "number", "profile.stop coroutine failed")

    local bad = coroutine.create(function()
        error("profile boom")
    end)
    local bok, berr = profile.resume(bad)
    assert(bok == false and tostring(berr):find("profile boom", 1, true), "profile.resume error failed")
    local wrapped = profile.wrap(function(a, b)
        return a + b
    end)
    assert(wrapped(2, 3) == 5, "profile.wrap failed")
    local wrapped_bad = profile.wrap(function()
        error("profile wrapped boom")
    end)
    assert(not pcall(wrapped_bad), "profile.wrap error should fail")
end

local function run_skynet_api_units()
    skynet.setenv("unit-key", "unit-value")
    assert_eq(skynet.getenv("unit-key"), "unit-value", "skynet getenv")
    assert(type(skynet.mem()) == "number", "skynet.mem failed")
    assert(type(skynet.gc()) == "number", "skynet.gc failed")
    assert(type(skynet.starttime()) == "number", "skynet.starttime failed")
    assert(skynet.stat("task") >= 0, "skynet.stat task failed")
    assert(skynet.stat("mqlen") == 0, "skynet.stat default failed")
    skynet.traceproto("lua", true)

    assert(not pcall(skynet.send, skynet.self(), "missing-proto"), "skynet.send bad proto should fail")
    assert(not pcall(skynet.rawsend, skynet.self(), "missing-proto", 0, ""), "skynet.rawsend bad proto should fail")
    assert(not pcall(skynet.redirect, skynet.self(), 0, "missing-proto", 0, ""), "skynet.redirect bad proto should fail")
    assert(not pcall(skynet.call, skynet.self(), "missing-proto"), "skynet.call bad proto should fail")
    assert(not pcall(skynet.rawcall, skynet.self(), "missing-proto", ""), "skynet.rawcall bad proto should fail")
    assert(not pcall(skynet.ret), "skynet.ret outside session should fail")
    assert(not pcall(skynet.response), "skynet.response outside session should fail")
    assert(not pcall(skynet.send, ".missing-unit-name", "lua", "x"), "unknown named service should fail")

    local woke = false
    local co
    skynet.fork(function()
        co = coroutine.running()
        assert(skynet.sleep(1000) == "BREAK", "skynet.sleep wakeup should break")
        woke = true
    end)
    wait_until("sleep coroutine ready", function()
        return co ~= nil
    end, 100)
    assert(skynet.wakeup(co) == true, "skynet.wakeup failed")
    wait_until("sleep coroutine woke", function()
        return woke
    end, 100)
    assert(skynet.wakeup(co) == false, "skynet.wakeup non-waiting should be false")

    local tasks = {}
    skynet.task(tasks)
    for session in pairs(tasks) do
        assert(type(skynet.task(session)) == "string", "skynet.task(session) failed")
        break
    end
    assert(skynet.task(-1) == nil, "skynet.task missing session failed")

    local slow = skynet.newservice("test_unit_slow")
    for i = 1, 1200 do
        skynet.send(slow, "lua", "fire", "overload", i)
    end
    skynet.sleep(30)
    skynet.kill(slow)
end

local function run_debug_units()
    local debuglib = require "skynet.debug"
    debuglib.reg_debugcmd("UNIT", function(...)
        skynet.retpack("unit-debug", ...)
    end)
    skynet.info_func(function(...)
        return "unit-info", ...
    end)

    local mem = skynet.call(skynet.self(), "debug", "MEM")
    assert(type(mem) == "number", "debug MEM failed")
    local stat = skynet.call(skynet.self(), "debug", "STAT")
    assert(type(stat) == "table", "debug STAT failed")
    local tasks = skynet.call(skynet.self(), "debug", "TASK")
    assert(type(tasks) == "table", "debug TASK all failed")
    local task_missing = skynet.call(skynet.self(), "debug", "TASK", -1)
    assert(task_missing == nil, "debug TASK missing failed")
    local info, arg = skynet.call(skynet.self(), "debug", "INFO", "arg")
    assert(info == "unit-info" and arg == "arg", "debug INFO failed")
    local ok, value = skynet.call(skynet.self(), "debug", "RUN", "return (...)", "=(unit)", "run-value")
    assert(ok == true and value == "run-value", "debug RUN success failed")
    ok = skynet.call(skynet.self(), "debug", "RUN", "return function(", "=(bad)")
    assert(ok == false, "debug RUN load failure failed")
    ok = skynet.call(skynet.self(), "debug", "RUN", "error('unit-run-error')", "=(bad)")
    assert(ok == false, "debug RUN runtime failure failed")
    local tag, extra = skynet.call(skynet.self(), "debug", "UNIT", "extra")
    assert(tag == "unit-debug" and extra == "extra", "debug external command failed")
    ok = skynet.call(skynet.self(), "debug", "NO_SUCH_DEBUG")
    assert(ok == false, "debug unknown command failed")
    skynet.send(skynet.self(), "debug", "GC")
    skynet.yield()
end

local function run_config_units()
    local probe = require "config_probe"
    assert(probe.value == "config-probe", "appendpath module lookup failed")

    local cwd = skynet.getcwd()
    assert(type(cwd) == "string" and cwd ~= "", "getcwd returned empty path")
    assert(skynet.getpathbase() == cwd, "default pathbase should match cwd after preload")
    skynet.setpathbase("..\\")
    local parent_base = skynet.getpathbase()
    assert(parent_base ~= cwd and not parent_base:find("%.%.", 1, true),
        "relative pathbase was not normalized")
    skynet.setpathbase(cwd)

    local paths = skynet.getpath()
    assert(paths.path_base == cwd, "path snapshot missing pathbase")
    assert(type(paths.path) == "string" and paths.path:find("tests/logic/%?%.lua"),
        "lua path snapshot missing tests/logic")
    assert(type(paths.service_path) == "string" and paths.service_path:find("tests/logic/%?%.lua"),
        "service path snapshot missing tests/logic")
    assert(type(paths.cpath) == "string" and
        (paths.cpath:find(".dll", 1, true) or paths.cpath:find(".so", 1, true)),
        "cpath snapshot missing platform module suffix")

    skynet.appendpath("tests\\logic\\")
    skynet.appendservicepath("tests//logic//")
    local updated = skynet.getpath()
    assert(updated.path:find("/tests/logic/%?%.lua"), "normalized lua path missing")
    assert(updated.service_path:find("/tests/logic/%?%.lua"), "normalized service path missing")

    local svc = skynet.newservice("config_probe_service")
    local value, child_paths = skynet.call(svc, "lua", "probe")
    assert(value == "config-probe", "appendservicepath lookup failed")
    assert(type(child_paths.path) == "string" and child_paths.path:find("tests/logic/%?%.lua"),
        "child actor did not inherit path snapshot")
    skynet.kill(svc)
end

local function run_no_callback_units()
    local svc = skynet.newservice("no_callback")
    skynet.send(svc, "lua", "drop-payload", string.rep("x", 64))
    skynet.sleep(1)
    skynet.kill(svc)
end

local function run_launcher_units()
    local launcher = skynet.queryservice(".launcher")
    if not launcher then
        launcher = skynet.newservice("launcher")
        wait_until("launcher register", function()
            return skynet.queryservice(".launcher") ~= nil
        end, 100)
    end
    assert(skynet.call(launcher, "lua", "LAUNCH") == nil, "launcher missing name failed")
    local echo = skynet.call(launcher, "lua", "LAUNCH", "echo")
    assert(type(echo) == "number", "launcher LAUNCH echo failed")
    skynet.sleep(5)
    assert(skynet.call(echo, "lua", "unit-echo") == "unit-echo", "echo service failed")
    local list = skynet.call(launcher, "lua", "LIST")
    assert(type(list) == "string" and list:find("echo", 1, true), "launcher LIST failed")
    assert(skynet.call(launcher, "lua", "QUERY", "echo") == echo, "launcher QUERY hit failed")
    assert(skynet.call(launcher, "lua", "QUERY", "missing") == nil, "launcher QUERY miss failed")
    assert(type(skynet.call(launcher, "lua", "MEM", 1)) == "table", "launcher MEM failed")
    assert(type(skynet.call(launcher, "lua", "STAT", 1)) == "table", "launcher STAT failed")
    assert(type(skynet.call(launcher, "lua", "GC", 1)) == "table", "launcher GC failed")
    assert(not pcall(skynet.newservice, "missing_service_for_unit"),
        "missing service should fail spawn")
    assert(skynet.call(launcher, "lua", "REMOVE", echo) == true, "launcher REMOVE hit failed")
    assert(skynet.call(launcher, "lua", "REMOVE", echo) == false, "launcher REMOVE miss failed")
    local doomed = skynet.call(launcher, "lua", "LAUNCH", "echo")
    assert(skynet.call(launcher, "lua", "KILL", skynet.address(doomed)) == true, "launcher KILL string failed")
    assert(skynet.call(launcher, "lua", "KILL", doomed) == false, "launcher KILL miss failed")
    assert(skynet.call(launcher, "lua", "UNKNOWN") == nil, "launcher unknown command failed")
end

local function run_sharedata_units()
    local sharedata = require "sharedata"
    local name = "unit_sharedata"
    sharedata.new(name, { version = 1, nested = { value = "a" } })
    local first = sharedata.query(name)
    local second = sharedata.query(name)
    assert(first == second and first.nested.value == "a", "sharedata cache failed")
    sharedata.update(name, "{ version = 2, nested = { value = 'b' } }")
    skynet.sleep(2)
    local updated = sharedata.query(name)
    assert(updated.version == 2 and updated.nested.value == "b", "sharedata string update failed")
    local copied = sharedata.deepcopy(name)
    copied.version = 99
    assert(sharedata.query(name).version == 2, "sharedata deepcopy failed")

    local service = skynet.queryservice("sharedatad")
    assert(type(service) == "number", "sharedatad service missing")
    assert(skynet.call(service, "lua", "__test") == true, "sharedatad selftest failed")

    local monitor_done = false
    skynet.fork(function()
        local data, version = skynet.call(service, "lua", "monitor", name, 2)
        assert(data == nil and version == nil, "sharedatad delete monitor failed")
        monitor_done = true
    end)
    skynet.sleep(2)
    sharedata.delete(name)
    wait_until("sharedata delete monitor", function()
        return monitor_done
    end, 200)
    sharedata.flush()
end

local function run_queue_units()
    local queue = require "skynet.queue"
    local q = queue()
    local order = {}
    local done = 0
    for i = 1, 3 do
        skynet.fork(function()
            q(function()
                order[#order + 1] = i
                skynet.sleep(1)
            end)
            done = done + 1
        end)
    end
    wait_until("queue workers", function()
        return done == 3
    end, 300)
    assert(#order == 3, "queue serialized workers failed")
    assert(q(function(v)
        return v + 1
    end, 4) == 5, "queue return value failed")
    assert(not pcall(function()
        q(function()
            error("queue error")
        end)
    end), "queue error path failed")
end

local function run_gateserver_units()
    local netpack = require "netpack"
    local gate = skynet.newservice("test_unit_gate")
    local port = port_base + 1
    assert(skynet.call(gate, "lua", "OPEN", { port = port }) == "OK", "gateserver OPEN failed")
    local conn = socket.connect("127.0.0.1", port)
    assert(conn, "gateserver client connect failed")
    wait_until("gateserver accept", function()
        return skynet.queryservice(".unit_gate_conn") ~= nil
    end, 300)
    local server_conn = skynet.queryservice(".unit_gate_conn")
    socket.send(conn, netpack.pack("gate-message"))
    wait_until("gateserver message", function()
        return skynet.queryservice(".unit_gate_msg") == server_conn
    end, 300)
    assert(skynet.queryservice(".unit_gate_msg_len") == #"gate-message", "gateserver message len failed")
    assert(skynet.call(gate, "lua", "SEND", server_conn, "gate-reply") == true, "gateserver SEND failed")
    local header = socket.read(conn, 2)
    local len = header:byte(1) * 256 + header:byte(2)
    assert(socket.read(conn, len) == "gate-reply", "gateserver SEND payload failed")
    assert(skynet.call(gate, "lua", "SENDRAW", server_conn, "raw-reply") == true, "gateserver SENDRAW failed")
    assert(socket.read(conn, #"raw-reply") == "raw-reply", "gateserver SENDRAW payload failed")
    skynet.call(gate, "lua", "SENDRAW", server_conn, string.rep("w", 2 * 1024 * 1024))
    skynet.sleep(10)
    assert(skynet.call(gate, "lua", "CLOSE", server_conn) == true, "gateserver CLOSE failed")
    socket.close(conn)
    assert(skynet.call(gate, "lua", "KICK", server_conn) == true, "gateserver KICK failed")
    assert(skynet.call(gate, "lua", "UNKNOWN") == nil, "gateserver unknown command failed")
    skynet.kill(gate)
end

local function run_demo_service_units()
    local ping = skynet.newservice("pingpong", "unit-ping")
    skynet.send(ping, "lua", "hello")
    skynet.send(ping, "text", "hello-text")
    skynet.sleep(5)
    skynet.kill(ping)
end

local function run_coverage_units()
    local coverage = require "skynet.coverage"
    if coverage.enabled() then
        assert(coverage._selftest() == true, "coverage selftest failed")
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "echo" then
            skynet.retpack(...)
        elseif cmd == "ret_fire" then
            skynet.retpack("ignored")
        elseif cmd == "ignore" then
            skynet.ignoreret()
        elseif cmd == "double_response" then
            local response = skynet.response()
            response(true, "first")
            assert(not pcall(response, true, "second"), "double response should fail")
        elseif cmd == "error_response" then
            local response = skynet.response()
            response(false)
        elseif type(cmd) == "string" and cmd:find("replies #", 1, true) then
            if session ~= 0 then
                skynet.retpack("reply-ignored")
            end
        else
            error("unknown unit command: " .. tostring(cmd))
        end
    end)

    skynet.fork(function()
        run_case("core cpp bindings", run_core_cpp_units)
        run_case("netpack cluster seri cpp", run_netpack_cluster_seri_units)
        run_case("profile cpp", run_profile_units)
        run_case("config api", run_config_units)
        run_case("no callback cleanup", run_no_callback_units)
        run_case("skynet api", function()
            run_skynet_api_units()
            assert(skynet.call(skynet.self(), "lua", "echo", "unit") == "unit", "self echo failed")
            skynet.send(skynet.self(), "lua", "ret_fire")
            skynet.send(skynet.self(), "lua", "ignore")
            assert(skynet.call(skynet.self(), "lua", "double_response") == "first", "double response command failed")
            assert(not pcall(skynet.call, skynet.self(), "lua", "error_response"), "error response should fail call")
        end)
        run_case("debug api", run_debug_units)
        run_case("launcher", run_launcher_units)
        run_case("sharedata", run_sharedata_units)
        run_case("queue", run_queue_units)
        run_case("gateserver", run_gateserver_units)
        run_case("demo services", run_demo_service_units)
        run_case("coverage runtime", run_coverage_units)

        skynet.error("[unit] === Summary ===")
        for _, row in ipairs(summary) do
            skynet.error(string.format("[unit] SUMMARY %s %s %.2fs",
                row.ok and "PASS" or "FAIL", row.name, row.elapsed / 100))
        end
        skynet.error("[unit] PASS: unit coverage suite completed")
        skynet.sleep(10)
        skynet.shutdown()
    end)
end)
