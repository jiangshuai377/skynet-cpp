-- sharedata.lua — Shared data client library
--
-- Provides read-only shared data across services via sharedatad service.
-- Data is queried from the central service and cached locally.
-- A monitor coroutine watches for updates and refreshes the cache.

local skynet = require "skynet"

local service

local sharedata = {}
local cache = {}           -- name -> { data, version }

local function init_service()
    if not service then
        service = skynet.uniqueservice("sharedatad")
        skynet.sleep(5)
    end
end

local function monitor(name)
    while true do
        local entry = cache[name]
        if not entry then break end
        local data, version = skynet.call(service, "lua", "monitor", name, entry.version)
        if data == nil then
            -- Data was deleted
            cache[name] = nil
            break
        end
        entry.data = data
        entry.version = version
    end
end

function sharedata.query(name)
    init_service()
    if cache[name] then
        return cache[name].data
    end
    local data, version = skynet.call(service, "lua", "query", name)
    cache[name] = { data = data, version = version }
    skynet.fork(monitor, name)
    return data
end

function sharedata.new(name, v, ...)
    init_service()
    skynet.call(service, "lua", "new", name, v, ...)
end

function sharedata.update(name, v, ...)
    init_service()
    skynet.call(service, "lua", "update", name, v, ...)
    -- Also update local cache if we have it
    if cache[name] then
        cache[name] = nil  -- force re-query on next access
    end
end

function sharedata.delete(name)
    init_service()
    skynet.call(service, "lua", "delete", name)
    cache[name] = nil
end

function sharedata.flush()
    -- Re-query all cached data
    for name in pairs(cache) do
        cache[name] = nil
    end
end

function sharedata.deepcopy(name, ...)
    init_service()
    local data = skynet.call(service, "lua", "query", name)
    return data  -- already a deep copy from the service
end

return sharedata
