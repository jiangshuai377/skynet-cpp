local skynet = require "skynet"

local children = {}   -- handle -> { name = string, time = number, restart = number }

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

local function launch_service(name, restart)
    if not name then
        skynet.error("[launcher] LAUNCH: missing service name")
        return nil
    end
    local ok, handle = pcall(skynet.newservice, name)
    if ok then
        children[handle] = {
            name = name,
            time = skynet.now(),
            restart = restart or 0,
        }
        skynet.error(string.format("[launcher] launched %s -> %s",
            name, skynet.address(handle)))
        return handle
    else
        skynet.error(string.format("[launcher] failed to launch %s: %s",
            name, tostring(handle)))
        return nil
    end
end

local function parse_address(addr)
    if type(addr) == "string" then
        local hex = addr:match("^:(%x+)$")
        if hex then
            return tonumber(hex, 16)
        end
        return tonumber(addr)
    end
    return addr
end

local function find_child_by_name(name)
    for handle, info in pairs(children) do
        if info.name == name then
            return handle, info
        end
    end
    return nil, nil
end

local function child_status(handle, info)
    return {
        handle = skynet.address(handle),
        name = info.name,
        start_time = info.time,
        uptime_cs = skynet.now() - info.time,
        restart = info.restart or 0,
    }
end

local function handle_launch(name)
    skynet.retpack(launch_service(name))
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
    local handle = find_child_by_name(name)
    skynet.retpack(handle)
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
    addr = parse_address(addr)
    if addr and children[addr] then
        skynet.kill(addr)
        children[addr] = nil
        skynet.retpack(true)
    else
        skynet.retpack(false)
    end
end

local function handle_status(target)
    local status = {
        now = skynet.now(),
        system = skynet.systemstat(),
        children = {},
    }

    if target ~= nil then
        local handle = parse_address(target)
        local info = handle and children[handle]
        if not info and type(target) == "string" then
            handle, info = find_child_by_name(target)
        end
        if handle and info then
            status.children[skynet.address(handle)] = child_status(handle, info)
        end
        skynet.retpack(status)
        return
    end

    for handle, info in pairs(children) do
        status.children[skynet.address(handle)] = child_status(handle, info)
    end
    skynet.retpack(status)
end

local function handle_health()
    local status = {
        now = skynet.now(),
        system = skynet.systemstat(),
        child_count = 0,
    }
    for _ in pairs(children) do
        status.child_count = status.child_count + 1
    end
    skynet.retpack(true, status)
end

local function handle_restart(target)
    local handle = parse_address(target)
    local info = handle and children[handle]
    local name = info and info.name or nil
    local restart = info and ((info.restart or 0) + 1) or 0

    if not name and type(target) == "string" then
        local found_handle, found_info = find_child_by_name(target)
        if found_handle and found_info then
            handle = found_handle
            info = found_info
            name = found_info.name
            restart = (found_info.restart or 0) + 1
        else
            name = target
        end
    end

    if handle and children[handle] then
        skynet.kill(handle)
        children[handle] = nil
    end

    skynet.retpack(launch_service(name, restart))
end

local function handle_shutdown()
    skynet.retpack(true)
    skynet.fork(function()
        skynet.sleep(0)
        skynet.shutdown()
    end)
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
    STOP = handle_kill,
    STATUS = handle_status,
    HEALTH = handle_health,
    RESTART = handle_restart,
    SHUTDOWN = handle_shutdown,
    MEM = handle_mem,
    GC = handle_gc,
    STAT = handle_stat,
}

skynet.start(function()
    skynet.register(".launcher")
    skynet.error("[launcher] started")

    skynet.dispatch("lua", function(session, source, cmd, ...)
        cmd = type(cmd) == "string" and string.upper(cmd) or tostring(cmd)
        local f = command[cmd]
        if not f then
            skynet.error("[launcher] unknown command: " .. cmd)
            skynet.retpack(nil)
            return
        end
        f(...)
    end)
end)
