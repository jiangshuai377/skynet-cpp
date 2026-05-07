local skynet = require "skynet"

local children = {}   -- handle -> { name = string, time = number }

-- Helper: broadcast a debug command to all children, collect results with timeout
local function broadcast_debug(cmd, ti)
    local result = {}
    local cos = {}
    for handle, info in pairs(children) do
        local co = skynet.fork(function()
            local ok, r = pcall(skynet.call, handle, "debug", cmd)
            if ok then
                result[skynet.address(handle) .. " " .. info.name] = r
            else
                result[skynet.address(handle) .. " " .. info.name] = tostring(r)
            end
        end)
        cos[#cos + 1] = co
    end
    -- Wait for a short timeout to let forks complete
    if ti then
        skynet.sleep(ti)
    else
        skynet.sleep(30) -- 0.3 sec default
    end
    return result
end

local function handle_launch(name)
    if not name then
        skynet.error("[launcher] LAUNCH: missing service name")
        skynet.retpack(nil)
        return
    end
    local ok, handle = pcall(skynet.newservice, name)
    if ok then
        children[handle] = { name = name, time = skynet.now() }
        skynet.error(string.format("[launcher] launched %s -> %s",
            name, skynet.address(handle)))
        skynet.retpack(handle)
    else
        skynet.error(string.format("[launcher] failed to launch %s: %s",
            name, tostring(handle)))
        skynet.retpack(nil)
    end
end

local function handle_list()
    local list = {}
    for handle, info in pairs(children) do
        list[#list + 1] = string.format("%s\t%s",
            skynet.address(handle), info.name)
    end
    skynet.retpack(table.concat(list, "\n"))
end

local function handle_query(name)
    for handle, info in pairs(children) do
        if info.name == name then
            skynet.retpack(handle)
            return
        end
    end
    skynet.retpack(nil)
end

local function handle_remove(handle)
    if handle and children[handle] then
        children[handle] = nil
        skynet.retpack(true)
    else
        skynet.retpack(false)
    end
end

local function handle_kill(addr)
    if type(addr) == "string" then
        addr = tonumber(addr:gsub("^:", ""), 16)
    end
    if addr and children[addr] then
        skynet.kill(addr)
        children[addr] = nil
        skynet.retpack(true)
    else
        skynet.retpack(false)
    end
end

local function handle_mem(ti)
    skynet.retpack(broadcast_debug("MEM", ti))
end

local function handle_gc(ti)
    for handle in pairs(children) do
        skynet.send(handle, "debug", "GC")
    end
    skynet.sleep(ti or 30)
    skynet.retpack(broadcast_debug("MEM", 30))
end

local function handle_stat(ti)
    skynet.retpack(broadcast_debug("STAT", ti))
end

local command = {
    LAUNCH = handle_launch,
    LIST = handle_list,
    QUERY = handle_query,
    REMOVE = handle_remove,
    KILL = handle_kill,
    MEM = handle_mem,
    GC = handle_gc,
    STAT = handle_stat,
}

skynet.start(function()
    skynet.register(".launcher")
    skynet.error("[launcher] started")

    skynet.dispatch("lua", function(session, source, cmd, ...)
        cmd = string.upper(cmd)
        local f = command[cmd]
        if not f then
            skynet.error("[launcher] unknown command: " .. cmd)
            skynet.retpack(nil)
            return
        end
        f(...)
    end)
end)
