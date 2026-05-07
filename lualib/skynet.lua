-- skynet.lua -- Skynet-cpp Lua service API
--
-- Provides the core skynet API: send, call, ret, dispatch, timeout, etc.
-- Simplified version of the original skynet.lua for skynet-cpp.

local c = require "skynet.core"
local coverage

if c.getenv("SKYNET_LUA_COVERAGE") then
    coverage = require "skynet.coverage"
    coverage.start(c.getenv("SKYNET_LUA_COVERAGE_DIR"))
end

local skynet = {
    -- Protocol types (compatible with original skynet)
    PTYPE_TEXT     = 0,
    PTYPE_RESPONSE = 1,
    PTYPE_MULTICAST = 2,
    PTYPE_CLIENT   = 3,
    PTYPE_SYSTEM   = 4,
    PTYPE_HARBOR   = 5,
    PTYPE_SOCKET   = 6,
    PTYPE_ERROR    = 7,
    PTYPE_TIMER    = 8,
    PTYPE_DEBUG    = 9,
    PTYPE_LUA      = 10,
    PTYPE_SNAX     = 11,
    PTYPE_TRACE    = 12,
}

local original_package_path = package.path
local original_package_cpath = package.cpath

-- Debug command registration (for external modules to add debug commands)
skynet.reg_debugcmd = nil  -- set after debug module init

-- Coroutine management
local coroutine_resume = coroutine.resume
local coroutine_yield  = coroutine.yield
local coroutine_create = coverage and coverage.create or coroutine.create

local tremove = table.remove

-- Session tracking
local session_id_coroutine = {}       -- session -> coroutine
local session_coroutine_id = {}       -- coroutine -> session
local session_coroutine_address = {}  -- coroutine -> source address

-- Protocol dispatch table: proto[type_id] = { name, id, pack, unpack, dispatch }
local proto = {}

-- Running thread
local running_thread

-- Fork queue
local fork_queue = { h = 1, t = 0 }

-- Requests received before start_func completes are delayed until the service
-- has registered its dispatch handlers.
local service_started = false
local pending_messages = {}

-- Coroutine pool for recycling
local coroutine_pool = setmetatable({}, { __mode = "kv" })

-- Wait/wakeup support
local sleep_session = {}        -- coroutine -> session (for wakeup to find)
local wakeup_queue = {}         -- set of coroutines to wakeup

local function co_create(f)
    local co = tremove(coroutine_pool)
    if co == nil then
        co = coroutine_create(function(...)
            f(...)
            while true do
                -- Cleanup
                local session = session_coroutine_id[co]
                if session and session ~= 0 then
                    skynet.error(string.format(
                        "Maybe forgot response session %s from %s",
                        session,
                        skynet.address(session_coroutine_address[co] or 0)))
                end
                session_coroutine_id[co] = nil
                session_coroutine_address[co] = nil

                -- Recycle
                f = nil
                coroutine_pool[#coroutine_pool + 1] = co
                f = coroutine_yield("SUSPEND")
                f(coroutine_yield())
            end
        end)
    else
        local running = running_thread
        coroutine_resume(co, f)
        running_thread = running
    end
    return co
end

-- ============================================================================
-- Suspend / wakeup machinery
-- ============================================================================

local function suspend(co, result, command)
    if not result then
        local err = command
        skynet.error(debug.traceback(co, tostring(err)))
        error(tostring(err))
    end

    if command == "SUSPEND" then
        return
    elseif command == "QUIT" then
        -- coroutine wants to stop
        return
    elseif command == "BREAK" then
        -- used by wakeup
        return
    elseif command == nil then
        -- coroutine finished
        return
    else
        skynet.error("Unknown command: " .. tostring(command))
    end
end

-- ============================================================================
-- Protocol registration
-- ============================================================================

function skynet.register_protocol(class)
    local name = class.name
    local id = class.id
    assert(name and id, "protocol must have name and id")
    proto[id] = class
    proto[name] = class
end

-- Register built-in protocols
skynet.register_protocol {
    name = "lua",
    id = skynet.PTYPE_LUA,
    pack = c.pack,
    unpack = c.unpacktrash,
    unpack_trashes = true,
}

skynet.register_protocol {
    name = "text",
    id = skynet.PTYPE_TEXT,
    pack = function(text) return text end,
    unpack = function(msg, sz) return c.tostring(msg, sz) end,
}

skynet.register_protocol {
    name = "response",
    id = skynet.PTYPE_RESPONSE,
}

skynet.register_protocol {
    name = "error",
    id = skynet.PTYPE_ERROR,
    unpack = function(...) return ... end,
}

-- ============================================================================
-- Core message dispatch
-- ============================================================================

local function trash_payload(msg, sz)
    if msg ~= nil and sz ~= nil and type(msg) ~= "string" then
        c.trash(msg, sz)
    end
end

local function unpack_payload(p, msg, sz)
    if not p.unpack then
        return msg, sz
    end

    if p.unpack_trashes then
        return p.unpack(msg, sz)
    end

    local ok, result = pcall(function()
        return table.pack(p.unpack(msg, sz))
    end)
    trash_payload(msg, sz)
    if not ok then
        error(result)
    end
    return table.unpack(result, 1, result.n)
end


local function raw_dispatch_message(prototype, msg, sz, session, source)
    if prototype == skynet.PTYPE_RESPONSE then
        -- Response to a previous call
        local co = session_id_coroutine[session]
        if co == "BREAK" then
            session_id_coroutine[session] = nil
        elseif co == nil then
            skynet.error(string.format("Unknown response session %d from %s",
                         session, skynet.address(source)))
        else
            session_id_coroutine[session] = nil
            suspend(co, coroutine_resume(co, true, msg, sz, session))
        end
    elseif prototype == skynet.PTYPE_ERROR then
        -- Error response
        local co = session_id_coroutine[session]
        if co then
            session_id_coroutine[session] = nil
            suspend(co, coroutine_resume(co, false))
        end
    else
        -- Incoming request
        local p = proto[prototype]
        if not service_started and (p == nil or p.dispatch == nil) then
            pending_messages[#pending_messages + 1] = {
                prototype, msg, sz, session, source
            }
            return
        end

        if p == nil then
            trash_payload(msg, sz)
            if session ~= 0 then
                c.send(source, 0, skynet.PTYPE_ERROR, session, "")
            else
                skynet.error(string.format(
                    "Unknown message type %d from %s session %d",
                    prototype, skynet.address(source), session))
            end
            return
        end

        local f = p.dispatch
        if f then
            local co = co_create(f)
            session_coroutine_id[co] = session
            session_coroutine_address[co] = source
            suspend(co, coroutine_resume(co, session, source,
                unpack_payload(p, msg, sz)))
        else
            trash_payload(msg, sz)
            skynet.error(string.format(
                "No dispatch function for type %d", prototype))
        end
    end
end

local function trash_pending_messages()
    for _, item in ipairs(pending_messages) do
        trash_payload(item[2], item[3])
    end
    pending_messages = {}
end

local function dispatch_pending_messages()
    local queue = pending_messages
    pending_messages = {}
    for _, item in ipairs(queue) do
        raw_dispatch_message(item[1], item[2], item[3], item[4], item[5])
    end
end

function skynet.dispatch_message(...)
    -- LuaActor::on_message already invokes this callback via lua_pcall, so the
    -- hot dispatch path does not need an extra Lua-level pcall around every
    -- message. Fork/wakeup continuations are still protected below.
    raw_dispatch_message(...)
    local succ, err = true, nil
    -- Process fork and wakeup queues until both are drained
    -- (processing one queue may add items to the other)
    while true do
        -- Process fork queue
        while fork_queue.h <= fork_queue.t do
            local h = fork_queue.h
            local co = fork_queue[h]
            fork_queue[h] = nil
            fork_queue.h = h + 1
            local fork_succ, fork_err = pcall(suspend, co, coroutine_resume(co))
            if not fork_succ then
                if succ then
                    succ = false
                    err = tostring(fork_err)
                else
                    err = err .. "\n" .. tostring(fork_err)
                end
            end
        end
        -- Process wakeup queue (collect keys first to avoid 'next' invalidation)
        local wakeup_list = {}
        for co in pairs(wakeup_queue) do
            wakeup_list[#wakeup_list + 1] = co
        end
        if #wakeup_list == 0 and fork_queue.h > fork_queue.t then
            break  -- both queues empty
        end
        for _, co in ipairs(wakeup_list) do
            wakeup_queue[co] = nil
            local session = sleep_session[co]
            if session then
                sleep_session[co] = nil
                session_id_coroutine[session] = "BREAK"
                suspend(co, coroutine_resume(co, false, "BREAK"))
            end
        end
    end
    assert(succ, tostring(err))
end

-- ============================================================================
-- Public API
-- ============================================================================

local function resolve_addr(addr)
    if type(addr) == "string" then
        local h = c.query(addr)
        if not h then
            error("Unknown service name: " .. addr)
        end
        return h
    end
    return addr
end

function skynet.localname(name)
    return c.query(name)
end

-- skynet.send(addr, typename, ...) -> session or nil
function skynet.send(addr, typename, ...)
    local p = proto[typename]
    if not p then
        error("Unknown protocol: " .. tostring(typename))
    end
    return c.send(resolve_addr(addr), 0, p.id, 0, p.pack(...))
end

-- skynet.rawsend(addr, typename, session, msg, sz)
function skynet.rawsend(addr, typename, session, msg, sz)
    if type(typename) == "string" then
        local p = proto[typename]
        if not p then error("Unknown protocol: " .. typename) end
        typename = p.id
    end
    return c.send(resolve_addr(addr), 0, typename, session, msg, sz)
end

function skynet.redirect(dest, source, typename, session, msg, sz)
    if type(typename) == "string" then
        local p = proto[typename]
        if not p then error("Unknown protocol: " .. typename) end
        typename = p.id
    end
    return c.redirect(resolve_addr(dest), source or 0, typename, session or 0, msg, sz)
end

-- skynet.call(addr, typename, ...) -> ...
-- Synchronous RPC: sends message, yields until response
function skynet.call(addr, typename, ...)
    local p = proto[typename]
    if not p then
        error("Unknown protocol: " .. tostring(typename))
    end

    local dest = resolve_addr(addr)
    local msg, sz = p.pack(...)
    local session = c.genid()
    session_id_coroutine[session] = coroutine.running()
    c.send(dest, 0, p.id, session, msg, sz)

    local succ, msg, sz = coroutine_yield("SUSPEND")
    if not succ then
        error("call failed")
    end

    return unpack_payload(p, msg, sz)
end

-- skynet.rawcall(addr, typename, msg, sz) -> msg, sz
-- Like skynet.call but with raw (already packed) message data
function skynet.rawcall(addr, typename, msg, sz)
    local p = proto[typename]
    if not p then
        error("Unknown protocol: " .. tostring(typename))
    end

    local dest = resolve_addr(addr)
    local session = c.genid()
    session_id_coroutine[session] = coroutine.running()
    c.send(dest, 0, p.id, session, msg, sz)

    local succ, rmsg, rsz = coroutine_yield("SUSPEND")
    if not succ then
        error("rawcall failed")
    end

    return rmsg, rsz
end

-- skynet.packstring(...) -> string
-- Pack arguments into a string (for deferred sending)
function skynet.packstring(...)
    local msg, sz = skynet.pack(...)
    local str = c.tostring(msg, sz)
    c.trash(msg, sz)
    return str
end

-- skynet.trash(msg, sz) -- free a lightuserdata buffer
function skynet.trash(msg, sz)
    c.trash(msg, sz)
end

-- skynet.ignoreret() -- mark current session as "no auto-return"
function skynet.ignoreret()
    session_coroutine_id[coroutine.running()] = nil
end

-- skynet.ret(msg, sz) -- respond to current request
function skynet.ret(msg, sz)
    msg = msg or ""
    local co_session = session_coroutine_id[coroutine.running()]
    if co_session == nil then
        error("No session to respond to")
    end
    session_coroutine_id[coroutine.running()] = nil

    if co_session == 0 then
        -- Fire-and-forget, no response needed
        if sz ~= nil and type(msg) ~= "string" then
            c.trash(msg, sz)
        end
        return false
    end

    local co_address = session_coroutine_address[coroutine.running()]
    c.send(co_address, 0, skynet.PTYPE_RESPONSE, co_session, msg, sz)
    return true
end

-- skynet.retpack(...) -- pack and respond
function skynet.retpack(...)
    return skynet.ret(skynet.pack(...))
end

-- skynet.pack = c.pack
skynet.pack = c.pack
skynet.unpack = c.unpack
skynet.tostring = c.tostring
skynet.trash = c.trash

-- skynet.self() -> handle
function skynet.self()
    return c.self()
end

-- skynet.address(addr) -> ":xxxxxxxx"
function skynet.address(addr)
    return string.format(":%08x", addr)
end

-- skynet.error(...) -- log error message
function skynet.error(...)
    local args = table.pack(...)
    local parts = {}
    for i = 1, args.n do
        parts[i] = tostring(args[i])
    end
    c.error(table.concat(parts, " "))
end

-- skynet.now() -> centiseconds
function skynet.now()
    return c.now()
end

-- skynet.timeout(ti, func) -- schedule delayed execution (ti in centiseconds)
function skynet.timeout(ti, func)
    local co = co_create(func)
    local session = c.genid()
    session_id_coroutine[session] = co
    c.timeout(ti, session)
end

-- skynet.sleep(ti) -- sleep in centiseconds, can be interrupted by wakeup
function skynet.sleep(ti)
    local co = coroutine.running()
    local session = c.genid()
    session_id_coroutine[session] = co
    sleep_session[co] = session
    c.timeout(ti, session)
    local succ, ret = coroutine_yield("SUSPEND")
    sleep_session[co] = nil
    if succ == false and ret == "BREAK" then
        return "BREAK"
    end
end

-- skynet.yield() -- yield current coroutine (resume on next tick)
function skynet.yield()
    return skynet.sleep(0)
end

-- skynet.exit() -- shutdown current service
function skynet.exit()
    if coverage then
        coverage.flush()
    end
    c.exit()
end

-- skynet.dispatch(typename, func)
-- Register a dispatch function for a protocol type
function skynet.dispatch(typename, func)
    local p = proto[typename]
    if not p then
        error("Unknown protocol: " .. tostring(typename))
    end
    p.dispatch = func
end

-- skynet.fork(func, ...) -- spawn a new coroutine within this service
function skynet.fork(func, ...)
    local args = table.pack(...)
    local co = co_create(function()
        func(table.unpack(args, 1, args.n))
    end)
    fork_queue.t = fork_queue.t + 1
    fork_queue[fork_queue.t] = co
    return co
end

-- skynet.register(name) -- register service name
function skynet.register(name)
    c.reg(name)
end

-- skynet.name(name, handle) -- register name for a handle
function skynet.name(name, handle)
    c.nameservice(name, handle)
end

-- skynet.newservice(name, ...) -- launch a new Lua service
-- Directly spawns via C binding, returns handle synchronously
function skynet.newservice(name, ...)
    local handle = c.newservice(name, ...)
    skynet.sleep(0)
    return handle
end

-- skynet.uniqueservice(name) -- launch or find a singleton service
-- If a service with name is already registered, return its handle.
-- Otherwise spawn it and register the name.
function skynet.uniqueservice(name)
    -- Try to find existing
    local handle = c.query(name)
    if handle then
        return handle
    end
    -- Spawn new and register name
    handle = c.newservice(name)
    c.nameservice(name, handle)
    return handle
end

-- skynet.queryservice(name) -- find a named service, returns handle or nil
function skynet.queryservice(name)
    return c.query(name)
end

-- skynet.kill(handle) -- kill a service by handle
function skynet.kill(handle)
    c.kill(handle)
end

function skynet.shutdown()
    if coverage then
        coverage.flush()
    end
    c.shutdown()
end

-- skynet.response(pack) -- create a delayed response function
-- Returns a function that can be called later to send the response.
-- The returned function: resp(ok, ...) where ok=true for success, false for error.
function skynet.response(pack)
    pack = pack or skynet.pack
    local co = coroutine.running()
    local co_session = session_coroutine_id[co]
    local co_address = session_coroutine_address[co]
    if co_session == nil or co_session == 0 then
        error("No session to respond to (fire-and-forget message)")
    end
    -- Clear the session so skynet.ret won't try to respond again
    session_coroutine_id[co] = nil
    session_coroutine_address[co] = nil

    local sent = false
    return function(ok, ...)
        if sent then
            error("Response already sent")
        end
        sent = true
        if ok then
            c.send(co_address, 0, skynet.PTYPE_RESPONSE, co_session, pack(...))
        else
            c.send(co_address, 0, skynet.PTYPE_ERROR, co_session, "")
        end
    end
end

-- skynet.wait(co) -- suspend current coroutine, to be woken by skynet.wakeup
-- If co is not provided, waits on the current coroutine
function skynet.wait(co)
    co = co or coroutine.running()
    local session = c.genid()
    session_id_coroutine[session] = co
    sleep_session[co] = session
    c.timeout(100000000, session) -- ~11.5 days in centiseconds (safe from int overflow)
    local succ, ret = coroutine_yield("SUSPEND")
    sleep_session[co] = nil
end

-- skynet.wakeup(co) -- wake a coroutine that is in skynet.wait or skynet.sleep
function skynet.wakeup(co)
    if sleep_session[co] then
        wakeup_queue[co] = true
        return true
    end
    return false
end

-- skynet.task(result_or_session) -- list coroutine tasks or query specific session
-- If result is a table, fills it with session->traceback entries.
-- If result is a number (session), returns the traceback for that session.
-- If result is nil, returns count of active tasks.
function skynet.task(result)
    if type(result) == "table" then
        for session, co in pairs(session_id_coroutine) do
            if type(co) == "thread" then
                result[session] = debug.traceback(co)
            end
        end
        return result
    elseif type(result) == "number" then
        local co = session_id_coroutine[result]
        if type(co) == "thread" then
            return debug.traceback(co)
        end
        return nil
    else
        local count = 0
        for _, co in pairs(session_id_coroutine) do
            if type(co) == "thread" then
                count = count + 1
            end
        end
        return count
    end
end

-- skynet.stat(what) -- get service statistics
-- what: "task" -> active coroutine count, "mqlen" -> 0, "cpu" -> 0, "message" -> 0
function skynet.stat(what)
    if what == "task" then
        return skynet.task()
    end
    -- mqlen, cpu, message not yet tracked
    return 0
end

-- skynet.traceproto(proto, flag) -- stub for trace protocol toggle
function skynet.traceproto(proto, flag)
    -- not implemented yet
end

-- skynet.start(func) -- entry point for Lua services
local export = {}
function skynet.start(start_func)
    -- Initialize debug module (registers PTYPE_DEBUG protocol)
    local dbg = require "skynet.debug"
    dbg.init(skynet, export)

    -- Register the main message callback
    c.callback(function(prototype, msg, sz, session, source)
        skynet.dispatch_message(prototype, msg, sz, session, source)
    end)

    -- Schedule start function via timeout(0) — runs on first timer tick
    skynet.timeout(0, function()
        local ok, err = xpcall(start_func, debug.traceback)
        if not ok then
            trash_pending_messages()
            error(err)
        end
        service_started = true
        dispatch_pending_messages()
    end)
end

local _env = {}

-- skynet.getenv(key) -- get config variable
function skynet.getenv(key)
    local value = _env[key]
    if value ~= nil then
        return value
    end
    return c.getenv(key)
end

-- skynet.setenv(key, value) -- set config variable
function skynet.setenv(key, value)
    _env[key] = value
end

local function normalize_separators(path)
    return path:gsub("\\", "/"):gsub("/+", "/"):gsub("/$", "")
end

local function is_absolute_path(path)
    return path:sub(1, 1) == "/" or path:match("^%a:")
end

local function collapse_path(path)
    path = normalize_separators(path)
    local prefix = ""
    if path:match("^%a:") then
        prefix = path:sub(1, 2)
        path = path:sub(3)
        if path:sub(1, 1) == "/" then
            prefix = prefix .. "/"
            path = path:sub(2)
        end
    elseif path:sub(1, 1) == "/" then
        prefix = "/"
        path = path:sub(2)
    end

    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == "." then
            -- skip
        elseif part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif prefix == "" then
                parts[#parts + 1] = part
            end
        else
            parts[#parts + 1] = part
        end
    end

    local body = table.concat(parts, "/")
    if prefix == "" then
        return body ~= "" and body or "."
    end
    if body == "" then
        return prefix
    end
    if prefix:sub(-1) == "/" then
        return prefix .. body
    end
    return prefix .. "/" .. body
end

local function resolve_path(base, path)
    assert(type(path) == "string" and path ~= "", "path must be a non-empty string")
    path = normalize_separators(path)
    if is_absolute_path(path) then
        return collapse_path(path)
    end
    return collapse_path(normalize_separators(base) .. "/" .. path)
end

local function normalize_path(path)
    return resolve_path(c.getpathbase(), path)
end

local function refresh_current_paths()
    local paths = c.getpath()
    if paths.path ~= "" then
        package.path = paths.path .. ";" .. original_package_path
    end
    if paths.cpath ~= "" then
        package.cpath = paths.cpath .. ";" .. original_package_cpath
    end
end

function skynet.appendpath(path)
    c.appendpath(normalize_path(path))
    refresh_current_paths()
end

function skynet.prependpath(path)
    c.prependpath(normalize_path(path))
    refresh_current_paths()
end

function skynet.appendcpath(path)
    c.appendcpath(normalize_path(path))
    refresh_current_paths()
end

function skynet.appendservicepath(path)
    c.appendservicepath(normalize_path(path))
end

function skynet.getcwd()
    return collapse_path(c.getcwd())
end

function skynet.setpathbase(path)
    c.setpathbase(resolve_path(c.getcwd(), path))
end

function skynet.getpathbase()
    return c.getpathbase()
end

function skynet.getpath()
    return c.getpath()
end

-- skynet.mem() -- Lua VM memory in KB
function skynet.mem()
    return c.mem()
end

-- skynet.gc() -- full GC, returns memory in KB after
function skynet.gc()
    return c.gc()
end

-- skynet.starttime() -- process start time in centiseconds since epoch
function skynet.starttime()
    return c.starttime()
end

return skynet
