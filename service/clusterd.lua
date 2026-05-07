-- clusterd.lua — Cluster manager service
--
-- Central coordination for cluster communication.
-- Manages node address configuration, sender/agent lifecycle, and name registry.
-- One instance per skynet-cpp process.

local skynet = require "skynet"
local socket = require "socket"

local node_address = {}       -- node_name -> "host:port" or false
local node_sender = {}        -- node_name -> sender service handle
local node_channel = {}       -- node_name -> sender handle (cached after open)
local register_name = {}      -- name -> addr, addr -> name
local cluster_agent = {}      -- conn_id -> agent handle or false
local connecting = {}         -- node_name -> { list of waiting coroutines }
local config = {}
local command = {}
local cluster = require "cluster.core"

-- Connection handling (inline cluster agent logic)
local large_request = {}     -- conn_id -> { session -> parts }
local register_name_cache = setmetatable({}, { __index =
    function(self, name)
        -- name must be "@xxxx", query the registered name
        local addr = register_name[name:sub(2)]
        if addr then
            self[name] = addr
        end
        return addr
    end
})

local function dispatch_request(conn_id, addr, session_id, msg, sz, padding, is_push)
    local large = large_request[conn_id]
    if not large then
        large = {}
        large_request[conn_id] = large
    end

    if padding then
        local req = large[session_id] or { addr = addr, is_push = is_push }
        large[session_id] = req
        if msg then
            cluster.append(req, msg, sz)
        end
        return
    else
        local req = large[session_id]
        if req then
            large[session_id] = nil
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
        -- Name query
        local name = skynet.unpack(msg, sz)
        skynet.trash(msg, sz)
        local resolved = register_name_cache["@" .. name]
        if resolved then
            ok = true
            response_msg = skynet.packstring(resolved)
            response_sz = nil
        else
            ok = false
            response_msg = "name not found"
        end
    else
        if cluster.isname(addr) then
            addr = register_name_cache[addr]
        end
        if addr then
            if is_push then
                skynet.rawsend(addr, "lua", 0, msg, sz)
                return
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

local function read_loop(conn_id)
    while true do
        local header = socket.read(conn_id, 2)
        if not header then break end

        local sz = cluster.header(header)
        if sz == 0 then break end

        local data = socket.read(conn_id, sz)
        if not data then break end

        local addr, session_id, msg, msg_sz, padding, is_push = cluster.unpackrequest(data)
        skynet.fork(dispatch_request, conn_id, addr, session_id, msg, msg_sz, padding, is_push)
    end

    large_request[conn_id] = nil
    socket.close(conn_id)
end

-- Parse "host:port" address string
local function parse_address(addr_str)
    local host, port = addr_str:match("^(.+):(%d+)$")
    if host and port then
        return host, tonumber(port)
    end
    return nil, nil
end

-- ============================================================================
-- Open channel (get or create sender for a node)
-- ============================================================================
local function open_channel(t, key)
    local ct = connecting[key]
    if ct then
        -- Another coroutine is already connecting to this node; wait
        local co = coroutine.running()
        table.insert(ct, co)
        skynet.wait(co)
        return node_channel[key]
    end

    ct = {}
    connecting[key] = ct

    local address = node_address[key]
    if not address then
        connecting[key] = nil
        for _, co in ipairs(ct) do
            skynet.wakeup(co)
        end
        error(string.format("cluster node [%s] is absent", key))
    end

    if address == false then
        connecting[key] = nil
        for _, co in ipairs(ct) do
            skynet.wakeup(co)
        end
        error(string.format("cluster node [%s] is down", key))
    end

    local host, port = parse_address(address)
    if not host then
        connecting[key] = nil
        for _, co in ipairs(ct) do
            skynet.wakeup(co)
        end
        error(string.format("invalid address for node [%s]: %s", key, address))
    end

    -- Get or create sender service
    local c = node_sender[key]
    if not c then
        c = skynet.newservice("clustersender", key, host, tostring(port))
        if node_sender[key] then
            skynet.kill(c)
            c = node_sender[key]
        else
            node_sender[key] = c
        end
        -- Wait for sender to initialize
        skynet.sleep(5)
    else
        -- Update address if changed
        skynet.call(c, "lua", "changenode", host, port)
    end

    t[key] = c
    connecting[key] = nil

    for _, co in ipairs(ct) do
        skynet.wakeup(co)
    end

    return c
end

setmetatable(node_channel, { __index = open_channel })

-- ============================================================================
-- Load cluster configuration
-- ============================================================================
local function loadconfig(cfg)
    if cfg == nil then
        -- Try loading from env
        local cluster_cfg = skynet.getenv("cluster")
        if cluster_cfg then
            -- Parse as Lua table string: "{ node1 = 'host:port', ... }"
            local f = load("return " .. cluster_cfg)
            if f then
                cfg = f()
            end
        end
        if not cfg then
            cfg = {}
        end
    end

    local reload = {}
    for name, address in pairs(cfg) do
        if name:sub(1, 2) == "__" then
            local opt = name:sub(3)
            config[opt] = address
        else
            assert(address == false or type(address) == "string")
            if node_address[name] ~= address then
                if node_sender[name] then
                    node_channel[name] = nil
                    table.insert(reload, name)
                end
                node_address[name] = address
            end
        end
    end
    for _, name in ipairs(reload) do
        skynet.fork(open_channel, node_channel, name)
    end
end

-- ============================================================================
-- Commands
-- ============================================================================

function command.reload(source, cfg)
    loadconfig(cfg)
    skynet.ret(skynet.pack(nil))
end

function command.sender(source, node)
    local ch = node_channel[node]
    skynet.ret(skynet.pack(ch))
end

function command.listen(source, addr, port, maxclient)
    if port == nil and type(addr) == "string" then
        -- addr is node name, look up its address
        local address = assert(node_address[addr], addr .. " is down")
        local host, p = parse_address(address)
        addr = host
        port = p
    end
    port = tonumber(port)

    -- Listen for incoming cluster connections
    local listener_id = socket.listen(addr, port, function(event, conn_id, remote_addr, remote_port)
        if event == "accept" then
            skynet.fork(read_loop, conn_id)
        elseif event == "close" then
            large_request[conn_id] = nil
        end
    end)

    skynet.ret(skynet.pack(addr, port))
end

function command.register(source, name, addr)
    assert(type(name) == "string")
    addr = addr or source
    local old_name = register_name[addr]
    if old_name then
        register_name[old_name] = nil
    end
    register_name[addr] = name
    register_name[name] = addr
    skynet.ret(nil)
end

function command.unregister(source, name)
    if not register_name[name] then
        return skynet.ret(nil)
    end
    local addr = register_name[name]
    register_name[addr] = nil
    register_name[name] = nil
    skynet.ret(nil)
end

function command.queryname(source, name)
    skynet.ret(skynet.pack(register_name[name]))
end

function command.__test(source)
    local host, port = parse_address("127.0.0.1:19191")
    assert(host == "127.0.0.1" and port == 19191)
    assert(parse_address("bad-address") == nil)
    loadconfig({ __heartbeat = 10, absent_unit = nil, down_unit = false, bad_unit = "bad-address" })
    assert(pcall(open_channel, node_channel, "missing_unit") == false)
    assert(pcall(open_channel, node_channel, "down_unit") == false)
    assert(pcall(open_channel, node_channel, "bad_unit") == false)

    local old_send = socket.send
    local sent = {}
    socket.send = function(_, data)
        sent[#sent + 1] = data
        return true
    end
    local ok, err = pcall(function()
        local msg, sz = skynet.pack("cluster_echo", "multipart")
        dispatch_request(0x7ffff001, source, 1001, msg, sz, true, false)
        dispatch_request(0x7ffff001, source, 1001, nil, nil, false, false)
        assert(#sent >= 1, "cluster multipart dispatch selftest failed")

        sent = {}
        dispatch_request(0x7ffff002, source, 1002, nil, nil, false, false)
        assert(#sent == 1, "cluster invalid large request selftest failed")

        sent = {}
        local huge_msg, huge_sz = skynet.pack("cluster_huge_return")
        dispatch_request(0x7ffff003, source, 1003, huge_msg, huge_sz, false, false)
        assert(#sent > 1, "cluster large response selftest failed")

        local before_count = #sent
        local push_msg, push_sz = skynet.pack("cluster_fire", "clusterd-selftest-push")
        dispatch_request(0x7ffff004, source, 1004, push_msg, push_sz, false, true)
        assert(#sent == before_count, "cluster push dispatch should not send a response")

    end)
    socket.send = old_send
    if not ok then
        error(err)
    end
    skynet.retpack(true)
end

-- ============================================================================
-- Service start
-- ============================================================================

skynet.start(function()
    loadconfig()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(command[cmd], "Unknown cluster command: " .. tostring(cmd))
        f(source, ...)
    end)
end)
