local skynet = require "skynet"
local socket = require "socket"
local core = require "skynet.core"

local summary = {}
local text_messages = {}
local timer_messages = 0
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
    assert(core.tostring("core-string") == "core-string", "core.tostring string failed")
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
    local text = assert(core.readfile(temp))
    assert(text == "ab", "core.readfile content failed")
    local missing, read_err = core.readfile("coverage-report/__missing_readfile_unit__.txt")
    assert(missing == nil and type(read_err) == "string", "core.readfile missing failed")

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
    local hash_key = { id = "table-key" }
    local hash_payload = {
        [true] = "bool-key",
        [1.5] = "double-key",
        [string.rep("K", 40)] = "long-string-key",
        [light] = "lightuserdata-key",
        [hash_key] = "table-key",
    }
    local hash_blob, hash_sz = skynet.pack(hash_payload)
    local hash_roundtrip = skynet.unpack(hash_blob, hash_sz)
    skynet.trash(hash_blob, hash_sz)
    assert(hash_roundtrip[true] == "bool-key", "seri boolean hash key failed")
    assert(hash_roundtrip[1.5] == "double-key", "seri double hash key failed")
    assert(hash_roundtrip[string.rep("K", 40)] == "long-string-key", "seri long string hash key failed")
    assert(hash_roundtrip[light] == "lightuserdata-key", "seri lightuserdata hash key failed")
    local found_table_key = false
    for k, v in pairs(hash_roundtrip) do
        if type(k) == "table" and v == "table-key" then
            found_table_key = true
            break
        end
    end
    assert(found_table_key, "seri table hash key failed")

    local large_array = {}
    for i = 1, 40 do
        large_array[i] = i
    end
    local large_blob, large_sz = skynet.pack(large_array)
    local large_roundtrip = skynet.unpack(large_blob, large_sz)
    skynet.trash(large_blob, large_sz)
    assert(#large_roundtrip == 40 and large_roundtrip[40] == 40, "large array roundtrip failed")

    local short_corrupt = table.pack(skynet.unpack(string.char(36)))
    assert(short_corrupt.n == 1 and short_corrupt[1] == nil, "corrupt short string should unpack as nil")
    local long_corrupt = table.pack(skynet.unpack(string.char(21)))
    assert(long_corrupt.n >= 1, "corrupt long string should not crash")
    local double_corrupt = table.pack(skynet.unpack(string.char(66)))
    assert(double_corrupt.n == 1 and double_corrupt[1] == 0, "corrupt double should unpack as zero")
    local default_corrupt = table.pack(skynet.unpack(string.char(7)))
    assert(default_corrupt.n == 1 and default_corrupt[1] == nil, "corrupt unknown type should unpack as nil")

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
    local nil_response = cluster.packresponse(13, true, nil)
    local nil_session, nil_ok, nil_data = cluster.unpackresponse(nil_response:sub(3))
    assert(nil_session == 13 and nil_ok == true and nil_data == "", "cluster nil response mismatch")
    local part_session, part_ok, part_data, part_padding =
        cluster.unpackresponse(string.char(99, 0, 0, 0, 3) .. "part")
    assert(part_session == 99 and part_ok == true and part_data == "part" and part_padding == true,
        "cluster partial response mismatch")
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
    local cont_addr, cont_session, cont_msg, cont_sz, cont_padding =
        cluster.unpackrequest(string.char(2, 7, 0, 0, 0) .. "mid")
    assert(cont_addr == false and cont_session == 7 and cont_msg == "mid" and cont_sz == 3 and cont_padding == true,
        "cluster request continuation mismatch")
    assert(cluster.isname("@node") == true, "cluster.isname should accept @ names")
    assert(cluster.isname("node") == nil and cluster.isname(123) == nil,
        "cluster.isname should reject non-names")
    assert(type(cluster.nodename()) == "string" and #cluster.nodename() > 0,
        "cluster.nodename should return node name")
    assert(not pcall(cluster.header, {}), "cluster.header should reject non-string packages")
    assert(not pcall(cluster.packrequest, 1, "addr", {}), "cluster.packrequest should reject unsupported payload")
    assert(not pcall(cluster.packresponse, 1, true, {}), "cluster.packresponse should reject unsupported payload")
    assert(not pcall(cluster.unpackrequest, string.char(0)), "cluster.unpackrequest should reject short numeric package")
    local concat_bad = { 4, "a", "b" }
    assert(cluster.concat(concat_bad) == nil, "cluster.concat should reject mismatched total")
    local append_nil = { 0 }
    cluster.append(append_nil, nil)
    assert(append_nil[1] == 0, "cluster.append nil payload should not change total")
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
    assert(not pcall(profile.start, {}), "profile.start should reject non-coroutine")
    assert(not pcall(profile.stop, {}), "profile.stop should reject non-coroutine")
    assert(not pcall(profile.resume, {}), "profile.resume should reject non-coroutine")
    assert(not pcall(profile.wrap, {}), "profile.wrap should reject non-function")

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

    local co2 = coroutine.create(function(a, b)
        return a, b, a + b
    end)
    local ok2, a, b, sum = profile.resume(co2, 2, 3)
    assert(ok2 == true and a == 2 and b == 3 and sum == 5, "profile.resume multiple return failed")
end

local function run_skynet_api_units()
    skynet.setenv("unit-key", "unit-value")
    assert_eq(skynet.getenv("unit-key"), "unit-value", "skynet getenv")
    assert(type(skynet.mem()) == "number", "skynet.mem failed")
    assert(type(skynet.gc()) == "number", "skynet.gc failed")
    assert(type(skynet.starttime()) == "number", "skynet.starttime failed")
    local system_stat = skynet.systemstat()
    assert(type(system_stat) == "table", "skynet.systemstat table failed")
    assert(type(system_stat.actor_count) == "number", "skynet.systemstat actor_count failed")
    assert(type(system_stat.worker_count) == "number", "skynet.systemstat worker_count failed")
    assert(skynet.stat("task") >= 0, "skynet.stat task failed")
    assert(skynet.stat("mqlen") == 0, "skynet.stat default failed")
    assert(skynet.localname(".launcher") == skynet.queryservice(".launcher"), "skynet.localname failed")
    local packed_string = skynet.packstring("packed-string", 42)
    local packed_values = table.pack(skynet.unpack(packed_string))
    assert(packed_values.n == 2 and packed_values[1] == "packed-string" and packed_values[2] == 42,
        "skynet.packstring failed")
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

    local waited = false
    local wait_co
    skynet.fork(function()
        wait_co = coroutine.running()
        skynet.wait()
        waited = true
    end)
    wait_until("wait coroutine ready", function()
        return wait_co ~= nil
    end, 100)
    assert(skynet.wakeup(wait_co) == true, "skynet.wakeup wait failed")
    wait_until("wait wakeup", function()
        return waited
    end, 100)

    local before_text = #text_messages
    skynet.send(skynet.self(), "text", "text-send")
    wait_until("text send dispatch", function()
        return #text_messages > before_text
    end, 100)
    before_text = #text_messages
    skynet.rawsend(skynet.self(), "text", 0, "text-rawsend")
    wait_until("text rawsend dispatch", function()
        return #text_messages > before_text
    end, 100)
    before_text = #text_messages
    skynet.redirect(skynet.self(), skynet.self(), "text", 0, "text-redirect")
    wait_until("text redirect dispatch", function()
        return #text_messages > before_text
    end, 100)
    local before_timer = timer_messages
    core.send(skynet.self(), 0, skynet.PTYPE_TIMER, 0, nil)
    wait_until("timer protocol dispatch", function()
        return timer_messages > before_timer
    end, 100)

    local raw_req, raw_sz = skynet.pack("echo", "raw-unit")
    local raw_resp, raw_resp_sz = skynet.rawcall(skynet.self(), "lua", raw_req, raw_sz)
    local raw_values = table.pack(skynet.unpack(raw_resp, raw_resp_sz))
    skynet.trash(raw_resp, raw_resp_sz)
    assert(raw_values.n == 1 and raw_values[1] == "raw-unit", "skynet.rawcall success failed")

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
    skynet.prependpath("tests/logic")

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
    skynet.appendpath("/tmp/../tmp/unit")
    local updated = skynet.getpath()
    assert(updated.path:find("/tests/logic/%?%.lua"), "normalized lua path missing")
    assert(updated.service_path:find("/tests/logic/%?%.lua"), "normalized service path missing")
    local preload_text = assert(skynet.readfile("tests/logic/preload.lua"))
    assert(preload_text:find("logic preload", 1, true), "skynet.readfile failed")
    assert(skynet.writefile("coverage-report/unit-skynet-write.txt", "w") == true,
        "skynet.writefile failed")
    assert(skynet.readfile("coverage-report/unit-skynet-write.txt") == "w",
        "skynet.writefile/readfile round-trip failed")

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
    local generated = core.send(svc, 0, skynet.PTYPE_TEXT, nil, "drop-text")
    assert(type(generated) == "number" and generated > 0, "core.send generated session failed")
    core.send(svc, 0, skynet.PTYPE_TEXT, 0, nil)
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
    local ok_health, status = skynet.call(launcher, "lua", "HEALTH")
    assert(ok_health == true and type(status) == "table", "launcher HEALTH failed")
    local launcher_status = skynet.call(launcher, "lua", "STATUS")
    assert(type(launcher_status) == "table" and type(launcher_status.children) == "table",
        "launcher STATUS failed")
    local echo_status_by_handle = skynet.call(launcher, "lua", "STATUS", echo)
    assert(type(echo_status_by_handle) == "table" and
        echo_status_by_handle.children[skynet.address(echo)].handle == skynet.address(echo),
        "launcher STATUS handle failed")
    local echo_status_by_name = skynet.call(launcher, "lua", "STATUS", "echo")
    assert(type(echo_status_by_name) == "table" and
        echo_status_by_name.children[skynet.address(echo)].handle == skynet.address(echo),
        "launcher STATUS name failed")
    local restart_hit = skynet.call(launcher, "lua", "LAUNCH", "echo")
    local restarted_hit = skynet.call(launcher, "lua", "RESTART", restart_hit)
    assert(type(restarted_hit) == "number" and restarted_hit ~= restart_hit,
        "launcher RESTART handle failed")
    skynet.sleep(5)
    assert(skynet.call(restarted_hit, "lua", "unit-echo") == "unit-echo",
        "launcher RESTART handle echo failed")
    assert(skynet.call(launcher, "lua", "KILL", restarted_hit) == true,
        "launcher KILL restarted handle failed")
    assert(skynet.call(launcher, "lua", "STOP", echo) == true, "launcher STOP hit failed")
    assert(skynet.call(launcher, "lua", "STOP", echo) == false, "launcher STOP miss failed")
    local restarted = skynet.call(launcher, "lua", "RESTART", "echo")
    assert(type(restarted) == "number", "launcher RESTART by name failed")
    skynet.sleep(5)
    assert(skynet.call(restarted, "lua", "unit-echo") == "unit-echo",
        "launcher RESTART echo failed")
    assert(skynet.call(launcher, "lua", "KILL", restarted) == true,
        "launcher KILL restarted failed")
    assert(not pcall(skynet.newservice, "missing_service_for_unit"),
        "missing service should fail spawn")
    local removable = skynet.call(launcher, "lua", "LAUNCH", "echo")
    assert(skynet.call(launcher, "lua", "REMOVE", removable) == true, "launcher REMOVE hit failed")
    assert(skynet.call(launcher, "lua", "REMOVE", removable) == false, "launcher REMOVE miss failed")
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

    local string_name = "unit_sharedata_string"
    sharedata.new(string_name, "{ version = 1, value = 'string' }")
    assert(sharedata.query(string_name).value == "string", "sharedata string new failed")
    local missing_data, missing_version = skynet.call(service, "lua", "monitor", "__missing_unit_sharedata__", 1)
    assert(missing_data == nil and missing_version == nil, "sharedatad missing monitor failed")
    local immediate_data, immediate_version = skynet.call(service, "lua", "monitor", name, 0)
    assert(type(immediate_data) == "table" and immediate_version == 2,
        "sharedatad immediate monitor failed")
    sharedata.update(name, { version = 3, nested = { value = "c" } })
    skynet.sleep(2)
    assert(sharedata.query(name).version == 3 and sharedata.query(name).nested.value == "c",
        "sharedata table update failed")

    local monitor_done = false
    skynet.fork(function()
        local data, version = skynet.call(service, "lua", "monitor", name, 3)
        assert(data == nil and version == nil, "sharedatad delete monitor failed")
        monitor_done = true
    end)
    skynet.sleep(2)
    sharedata.delete(name)
    wait_until("sharedata delete monitor", function()
        return monitor_done
    end, 200)
    sharedata.delete(string_name)
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
    skynet.register_protocol {
        name = "timer_unit",
        id = skynet.PTYPE_TIMER,
        pack = function()
            return nil
        end,
        unpack = function()
            return "timer-unit"
        end,
    }

    skynet.dispatch("text", function(session, source, text)
        text_messages[#text_messages + 1] = text
    end)

    skynet.dispatch("timer_unit", function(session, source, value)
        assert(value == "timer-unit", "timer protocol unpack failed")
        timer_messages = timer_messages + 1
    end)

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
