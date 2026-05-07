local skynet = require "skynet"
local socket = require "socket"
local core = require "skynet.core"

local function env_number(name, default)
    local value = core.getenv(name)
    if value and value ~= "" then
        local n = tonumber(value)
        if n then
            return n
        end
    end
    return default
end

local function env_string(name, default)
    local value = core.getenv(name)
    if value and value ~= "" then
        return value
    end
    return default
end

local function now()
    return skynet.now()
end

local function elapsed_seconds(start_time)
    return math.max(0.01, (now() - start_time) / 100)
end

local function wait_until(label, predicate, timeout_cs, detail)
    local deadline = now() + timeout_cs
    while now() < deadline do
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

local function metric(case_name, name, value)
    skynet.error(string.format("[perf] METRIC case=%s name=%s value=%.2f", case_name, name, value))
end

local worker_count = env_number("SKYNET_PERF_WORKERS", 64)
local calls_per_worker = env_number("SKYNET_PERF_CALLS", 1000)
local fire_per_worker = env_number("SKYNET_PERF_FIRE", 2000)
local lifecycle_count = env_number("SKYNET_PERF_LIFECYCLE", 1000)
local socket_clients = env_number("SKYNET_PERF_SOCKET_CLIENTS", 128)
local socket_messages = env_number("SKYNET_PERF_SOCKET_MESSAGES", 200)
local socket_port = env_number("SKYNET_PERF_SOCKET_PORT", 19291)
local cases = env_string("SKYNET_PERF_CASES", "actor,scheduler,lifecycle,socket,mixed")

local function has_case(name)
    if cases == "all" then
        return true
    end
    for part in string.gmatch(cases, "[^,]+") do
        if part == name then
            return true
        end
    end
    return false
end

local function run_actor(case_name, wc, calls, fires)
    local workers = {}
    for i = 1, wc do
        workers[i] = skynet.newservice("perf_worker", tostring(i))
    end

    local done = 0
    local errors = {}
    local start_time = now()

    for i, handle in ipairs(workers) do
        skynet.fork(function()
            local ok, err = pcall(function()
                for n = 1, calls do
                    local seq = i * 1000000 + n
                    local tag, wid, got = skynet.call(handle, "lua", "ping", seq)
                    assert(tag == "pong" and wid == i and got == seq, "bad ping response")
                end
                for n = 1, fires do
                    skynet.send(handle, "lua", "fire", i, n)
                end
            end)
            if not ok then
                errors[#errors + 1] = tostring(err)
            end
            done = done + 1
        end)
    end

    wait_until(case_name, function()
        return done == wc
    end, 60000, function()
        return string.format("done=%d/%d errors=%d", done, wc, #errors)
    end)
    assert(#errors == 0, table.concat(errors, "\n"))

    local seconds = elapsed_seconds(start_time)
    local rpc = wc * calls
    local fire = wc * fires
    metric(case_name, "rpc_per_sec", rpc / seconds)
    metric(case_name, "fire_per_sec", fire / seconds)
    metric(case_name, "dispatch_per_sec", (rpc * 2 + fire) / seconds)
    metric(case_name, "elapsed_sec", seconds)

    for _, handle in ipairs(workers) do
        skynet.kill(handle)
    end
end

local function run_lifecycle()
    local done = 0
    local errors = {}
    local start_time = now()

    for i = 1, lifecycle_count do
        skynet.fork(function()
            local ok, err = pcall(function()
                local handle = skynet.newservice("perf_worker", tostring(100000 + i))
                local tag = skynet.call(handle, "lua", "die")
                assert(tag == "bye", "bad die response")
            end)
            if not ok then
                errors[#errors + 1] = tostring(err)
            end
            done = done + 1
        end)
    end

    wait_until("lifecycle", function()
        return done == lifecycle_count
    end, 60000, function()
        return string.format("done=%d/%d errors=%d", done, lifecycle_count, #errors)
    end)
    assert(#errors == 0, table.concat(errors, "\n"))

    local seconds = elapsed_seconds(start_time)
    metric("lifecycle", "cycles_per_sec", lifecycle_count / seconds)
    metric("lifecycle", "elapsed_sec", seconds)
end

local function run_socket()
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
    local start_time = now()

    for c = 1, socket_clients do
        skynet.fork(function()
            local ok, err = pcall(function()
                local conn = assert(socket.connect("127.0.0.1", socket_port), "connect failed")
                for n = 1, socket_messages do
                    local payload = string.format("%d:%d:%s\n", c, n, string.rep("x", 64))
                    assert(socket.send(conn, payload), "send failed")
                    assert(socket.read(conn, #payload) == payload, "echo mismatch")
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

    wait_until("socket", function()
        return done == socket_clients
    end, 60000, function()
        return string.format("done=%d/%d accepted=%d closed=%d echoed=%d errors=%d",
            done, socket_clients, accepted, closed, echoed, #errors)
    end)
    assert(#errors == 0, table.concat(errors, "\n"))
    assert(accepted == socket_clients, "accepted mismatch")
    assert(echoed == socket_clients * socket_messages, "echoed mismatch")
    wait_until("socket close", function()
        return closed == socket_clients
    end, 60000, function()
        return string.format("closed=%d/%d", closed, socket_clients)
    end)
    socket.close_listener(listener)

    local seconds = elapsed_seconds(start_time)
    metric("socket", "echo_per_sec", echoed / seconds)
    metric("socket", "elapsed_sec", seconds)
end

local function run_case(name, fn)
    if not has_case(name) then
        return
    end
    skynet.error("[perf] CASE begin: " .. name)
    local start_time = now()
    local ok, err = xpcall(fn, debug.traceback)
    local seconds = elapsed_seconds(start_time)
    if not ok then
        error("[perf] CASE failed: " .. name .. "\n" .. tostring(err))
    end
    skynet.error(string.format("[perf] CASE pass: %s elapsed=%.2f", name, seconds))
end

skynet.start(function()
    skynet.error(string.format(
        "[perf] start cases=%s workers=%d calls=%d fire=%d lifecycle=%d socket_clients=%d socket_messages=%d",
        cases, worker_count, calls_per_worker, fire_per_worker, lifecycle_count,
        socket_clients, socket_messages))

    run_case("actor", function()
        run_actor("actor", worker_count, calls_per_worker, fire_per_worker)
    end)
    run_case("scheduler", function()
        run_actor("scheduler", worker_count * 2, math.max(1, math.floor(calls_per_worker / 5)), math.max(1, math.floor(fire_per_worker / 5)))
    end)
    run_case("lifecycle", run_lifecycle)
    run_case("socket", run_socket)
    run_case("mixed", function()
        run_actor("mixed", math.max(8, math.floor(worker_count / 2)), math.max(1, math.floor(calls_per_worker / 2)), math.max(1, math.floor(fire_per_worker / 2)))
        run_lifecycle()
        run_socket()
    end)

    skynet.error("[perf] PASS: perf suite completed")
    skynet.sleep(10)
    skynet.shutdown()
end)
