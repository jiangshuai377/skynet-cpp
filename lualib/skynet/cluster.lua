-- cluster.lua — Cluster public API
--
-- Provides cluster.call/send/open/register/query for cross-node RPC.
-- Lazily creates clustersender services (one per remote node) via clusterd.

local skynet = require "skynet"

local clusterd
local cluster = {}
local sender = {}
local task_queue = {}

local function repack(address, ...)
    return address, skynet.pack(...)
end

-- ============================================================================
-- Sender initialization (deferred, with task queue)
-- ============================================================================
local function request_sender(q, node)
    local ok, c = pcall(skynet.call, clusterd, "lua", "sender", node)
    if not ok then
        skynet.error(string.format("[cluster] get sender for [%s] failed: %s", node, tostring(c)))
        c = nil
    end
    -- Process queued tasks
    local confirm = coroutine.running()
    q.confirm = confirm
    q.sender = c
    for _, task in ipairs(q) do
        if type(task) == "string" then
            if c then
                skynet.send(c, "lua", "push", repack(skynet.unpack(task)))
            end
        else
            skynet.wakeup(task)
            skynet.wait(confirm)
        end
    end
    task_queue[node] = nil
    sender[node] = c
end

local function get_queue(t, node)
    local q = {}
    t[node] = q
    skynet.fork(request_sender, q, node)
    return q
end

setmetatable(task_queue, { __index = get_queue })

local function get_sender(node)
    local s = sender[node]
    if not s then
        local q = task_queue[node]
        local task = coroutine.running()
        table.insert(q, task)
        skynet.wait(task)
        skynet.wakeup(q.confirm)
        return q.sender
    end
    return s
end

cluster.get_sender = get_sender

-- ============================================================================
-- Public API
-- ============================================================================

--- Synchronous cross-node RPC call.
-- cluster.call(node, address, ...) → response values
function cluster.call(node, address, ...)
    local s = sender[node]
    if not s then
        local task = skynet.packstring(address, ...)
        return skynet.call(get_sender(node), "lua", "req", repack(skynet.unpack(task)))
    end
    return skynet.call(s, "lua", "req", address, skynet.pack(...))
end

--- Asynchronous cross-node push (no response).
-- cluster.send(node, address, ...)
function cluster.send(node, address, ...)
    local s = sender[node]
    if not s then
        table.insert(task_queue[node], skynet.packstring(address, ...))
    else
        skynet.send(s, "lua", "push", address, skynet.pack(...))
    end
end

--- Open a listening port for incoming cluster connections.
-- cluster.open(port) or cluster.open(addr, port)
function cluster.open(addr, port, maxclient)
    if type(addr) == "number" then
        return skynet.call(clusterd, "lua", "listen", "0.0.0.0", addr, nil)
    elseif type(addr) == "string" then
        if port then
            return skynet.call(clusterd, "lua", "listen", addr, port, maxclient)
        else
            return skynet.call(clusterd, "lua", "listen", addr, nil, maxclient)
        end
    end
end

--- Reload cluster configuration.
-- cluster.reload(config_table) or cluster.reload() to re-read from env
function cluster.reload(cfg)
    skynet.call(clusterd, "lua", "reload", cfg)
end

--- Register a local service name for remote access.
-- cluster.register(name [, addr])
function cluster.register(name, addr)
    assert(type(name) == "string")
    assert(addr == nil or type(addr) == "number")
    return skynet.call(clusterd, "lua", "register", name, addr)
end

--- Unregister a service name.
function cluster.unregister(name)
    assert(type(name) == "string")
    return skynet.call(clusterd, "lua", "unregister", name)
end

--- Query a remote node for a registered service name.
-- cluster.query(node, name) → handle
function cluster.query(node, name)
    return skynet.call(get_sender(node), "lua", "req", 0, skynet.pack(name))
end

-- ============================================================================
-- Initialization
-- ============================================================================

-- clusterd is created on first use (lazy init)
function cluster.init()
    if not clusterd then
        clusterd = skynet.newservice("clusterd")
        -- Wait for clusterd to finish initialization
        skynet.sleep(5)
    end
end

function cluster._selftest()
    cluster.init()
    return skynet.call(clusterd, "lua", "__test")
end

function cluster._queryname(name)
    cluster.init()
    return skynet.call(clusterd, "lua", "queryname", name)
end

return cluster
