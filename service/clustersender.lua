-- clustersender.lua — Sends messages to a remote cluster node
--
-- Maintains a single TCP connection (via socketchannel) to one remote node.
-- Packs skynet messages into the cluster wire protocol and multiplexes
-- multiple concurrent requests using session IDs.

local skynet = require "skynet"
local sc = require "skynet.socketchannel"
local socket = require "socket"
local cluster = require "cluster.core"

local channel
local session = 1
local node, init_host, init_port = ...
init_port = tonumber(init_port)

local command = {}

-- ============================================================================
-- Send a request (with response expected)
-- ============================================================================
local function send_request(addr, msg, sz)
    local current_session = session
    local request, new_session, padding = cluster.packrequest(addr, session, msg, sz)
    session = new_session
    return channel:request(request, current_session, padding)
end

function command.req(addr, msg, sz)
    local ok, result = pcall(send_request, addr, msg, sz)
    if ok then
        if type(result) == "table" then
            skynet.ret(cluster.concat(result))
        else
            if type(result) == "string" then
                skynet.ret(result)
            else
                skynet.ret(skynet.pack(result))
            end
        end
    else
        skynet.error(string.format("clustersender req failed: %s", tostring(result)))
        skynet.response()(false)
    end
end

-- ============================================================================
-- Send a push (no response expected)
-- ============================================================================
function command.push(addr, msg, sz)
    local request, new_session, padding = cluster.packpush(addr, session, msg, sz)
    if padding then
        session = new_session
    end
    channel:request(request, nil, padding)
end

-- ============================================================================
-- Read response callback for socketchannel (session mode)
-- ============================================================================
local function read_response(sock)
    local header_data = sock:read(2)
    local sz = cluster.header(header_data)
    local msg = sock:read(sz)
    return cluster.unpackresponse(msg)  -- session, ok, data, padding
end

-- ============================================================================
-- Change remote node address
-- ============================================================================
function command.changenode(host, port)
    if not host then
        skynet.error(string.format("clustersender closing channel to %s", node))
        channel:close()
    else
        channel:changehost(host, tonumber(port))
        channel:connect(true)
    end
    skynet.ret(skynet.pack(nil))
end

function command.__test(mode)
    local old_channel = channel
    local fake = {
        close_called = false,
        changed = false,
        connected = false,
        padding_seen = false,
    }
    function fake:request(_, session_id, padding)
        if padding then
            self.padding_seen = true
        end
        if mode == "req_table" then
            local packed = skynet.packstring("clustersender_table")
            local mid = math.floor(#packed / 2)
            return { packed:sub(1, mid), packed:sub(mid + 1) }
        elseif mode == "req_bool" then
            return true
        end
        return session_id ~= nil
    end
    function fake:close()
        self.close_called = true
    end
    function fake:changehost(host, port)
        self.changed = host == "127.0.0.1" and port == 1
    end
    function fake:connect(once)
        self.connected = once == true
    end

    channel = fake
    local ok, err = pcall(function()
        if mode == "req_table" or mode == "req_bool" then
            local msg, sz = skynet.pack("clustersender_selftest")
            command.req(1, msg, sz)
        elseif mode == "push_padding" then
            command.push(1, string.rep("P", 70000), 70000)
            assert(fake.padding_seen, "clustersender push padding selftest failed")
            skynet.retpack(true)
        elseif mode == "changenode_close" then
            command.changenode(nil)
            assert(fake.close_called, "clustersender close selftest failed")
        elseif mode == "changenode_open" then
            command.changenode("127.0.0.1", 1)
            assert(fake.changed and fake.connected, "clustersender changenode selftest failed")
        else
            error("unknown clustersender selftest mode: " .. tostring(mode))
        end
    end)
    channel = old_channel
    if not ok then
        error(err)
    end
end

-- ============================================================================
-- Service start
-- ============================================================================

skynet.start(function()
    channel = sc.channel {
        host = init_host,
        port = init_port,
        response = read_response,
        nodelay = true,
    }
    skynet.dispatch("lua", function(_, source, cmd, ...)
        local f = assert(command[cmd], "Unknown clustersender command: " .. tostring(cmd))
        f(...)
    end)
end)
