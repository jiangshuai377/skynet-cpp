-- clusteragent.lua — Handles incoming requests from a remote cluster node
--
-- Each accepted TCP connection gets one clusteragent instance.
-- Reads cluster protocol packets, dispatches to local services, sends responses.

local skynet = require "skynet"
local socket = require "socket"
local cluster = require "cluster.core"

local clusterd_handle, conn_id = ...
clusterd_handle = tonumber(clusterd_handle)
conn_id = tonumber(conn_id)

local large_request = {}     -- session -> { addr, is_push, parts... }
local register_name = {}     -- "@name" -> address (cached)
local inquery_name = {}      -- name -> { waiting coroutines }

local register_name_mt = { __index =
    function(self, name)
        local waitco = inquery_name[name]
        if waitco then
            -- Another coroutine is already querying this name; wait
            local co = coroutine.running()
            table.insert(waitco, co)
            skynet.wait(co)
            return rawget(self, name)
        else
            waitco = {}
            inquery_name[name] = waitco
            -- name must be "@xxxx"
            local addr = skynet.call(clusterd_handle, "lua", "queryname", name:sub(2))
            if addr then
                self[name] = addr
            end
            inquery_name[name] = nil
            for _, co in ipairs(waitco) do
                skynet.wakeup(co)
            end
            return addr
        end
    end
}

setmetatable(register_name, register_name_mt)

-- ============================================================================
-- Dispatch a single request
-- ============================================================================
local function dispatch_request(addr, session_id, msg, sz, padding, is_push)
    if padding then
        -- Multi-part: accumulate
        local req = large_request[session_id] or { addr = addr, is_push = is_push }
        large_request[session_id] = req
        if msg then
            cluster.append(req, msg, sz)
        end
        return
    else
        local req = large_request[session_id]
        if req then
            large_request[session_id] = nil
            if msg then
                cluster.append(req, msg, sz)
            end
            msg, sz = cluster.concat(req)
            addr = req.addr
            is_push = req.is_push
        end
        if not msg then
            local response = cluster.packresponse(session_id, false, "Invalid large req")
            socket.send(conn_id, response)
            return
        end
    end

    local ok, response_msg, response_sz

    if addr == 0 then
        -- Name query: addr=0 means "lookup this name"
        local name = skynet.unpack(msg, sz)
        skynet.trash(msg, sz)
        local resolved = register_name["@" .. name]
        if resolved then
            ok = true
            response_msg = skynet.packstring(resolved)
            response_sz = nil
        else
            ok = false
            response_msg = "name not found"
        end
    else
        -- Resolve string address if needed
        if cluster.isname(addr) then
            addr = register_name[addr]
        end
        if addr then
            if is_push then
                skynet.rawsend(addr, "lua", 0, msg, sz)
                return  -- no response for push
            else
                ok, response_msg, response_sz = pcall(skynet.rawcall, addr, "lua", msg, sz)
            end
        else
            ok = false
            response_msg = "Invalid name"
        end
    end

    if ok then
        local response = cluster.packresponse(session_id, true, response_msg, response_sz)
        if type(response) == "table" then
            for _, v in ipairs(response) do
                socket.send(conn_id, v)
            end
        else
            socket.send(conn_id, response)
        end
    else
        local response = cluster.packresponse(session_id, false, tostring(response_msg))
        socket.send(conn_id, response)
    end
end

-- ============================================================================
-- Read loop: reads cluster protocol packets from the connection
-- ============================================================================
local function read_loop()
    while true do
        -- Read 2-byte big-endian header
        local header = socket.read(conn_id, 2)
        if not header then break end  -- connection closed

        local sz = cluster.header(header)
        if sz == 0 then break end

        local data = socket.read(conn_id, sz)
        if not data then break end

        -- Unpack and dispatch in a fork so we don't block the read loop
        local addr, session_id, msg, msg_sz, padding, is_push = cluster.unpackrequest(data)
        skynet.fork(dispatch_request, addr, session_id, msg, msg_sz, padding, is_push)
    end

    skynet.error(string.format("[clusteragent] connection %d closed", conn_id))
    socket.close(conn_id)
end

local function handle_exit()
    socket.close(conn_id)
    skynet.exit()
end

local function handle_namechange()
    register_name = setmetatable({}, register_name_mt)
end

local command = {
    exit = handle_exit,
    namechange = handle_namechange,
}

-- ============================================================================
-- Service start
-- ============================================================================

skynet.start(function()
    skynet.dispatch("lua", function(_, source, cmd, ...)
        local f = command[cmd]
        if not f then
            skynet.error(string.format("[clusteragent] Unknown command: %s", cmd))
            return
        end
        f(...)
    end)

    skynet.fork(read_loop)
end)
