-- sharedatad.lua — Shared data management service
--
-- Central service that stores named data tables.
-- Clients query data and receive copies; monitors wait for updates.

local skynet = require "skynet"

local data_store = {}       -- name -> { data, version }
local monitors = {}         -- name -> { list of { source, session, response_func } }

local CMD = {}

-- Deep copy a table
local function deepcopy(orig, seen)
    if type(orig) ~= "table" then return orig end
    seen = seen or {}
    if seen[orig] then return seen[orig] end
    local copy = {}
    seen[orig] = copy
    for k, v in pairs(orig) do
        copy[deepcopy(k, seen)] = deepcopy(v, seen)
    end
    return setmetatable(copy, getmetatable(orig))
end

function CMD.new(source, name, v, ...)
    assert(data_store[name] == nil, "sharedata already exists: " .. name)
    if type(v) == "table" then
        data_store[name] = { data = v, version = 1 }
    elseif type(v) == "string" then
        -- Load from string (Lua code)
        local f = load("return " .. v)
        if f then
            data_store[name] = { data = f(), version = 1 }
        else
            error("sharedata: invalid data string for " .. name)
        end
    else
        error("sharedata: unsupported data type " .. type(v))
    end
    skynet.ret(skynet.pack(nil))
end

function CMD.delete(source, name)
    data_store[name] = nil
    -- Wake all monitors with nil to signal deletion
    local mon = monitors[name]
    if mon then
        for _, m in ipairs(mon) do
            m.response(true, nil)
        end
        monitors[name] = nil
    end
    skynet.ret(skynet.pack(nil))
end

function CMD.query(source, name)
    local entry = data_store[name]
    if not entry then
        error("sharedata not found: " .. name)
    end
    skynet.ret(skynet.pack(deepcopy(entry.data), entry.version))
end

function CMD.update(source, name, v, ...)
    local entry = data_store[name]
    if not entry then
        error("sharedata not found: " .. name)
    end
    if type(v) == "table" then
        entry.data = v
    elseif type(v) == "string" then
        local f = load("return " .. v)
        if f then
            entry.data = f()
        else
            error("sharedata: invalid data string for " .. name)
        end
    end
    entry.version = entry.version + 1
    -- Notify all monitors
    local mon = monitors[name]
    if mon then
        for _, m in ipairs(mon) do
            m.response(true, deepcopy(entry.data), entry.version)
        end
        monitors[name] = nil
    end
    skynet.ret(skynet.pack(nil))
end

function CMD.monitor(source, name, old_version)
    local entry = data_store[name]
    if not entry then
        -- Data deleted or doesn't exist
        skynet.ret(skynet.pack(nil))
        return
    end
    if entry.version ~= old_version then
        -- Data already updated since client last saw it
        skynet.ret(skynet.pack(deepcopy(entry.data), entry.version))
        return
    end
    -- Suspend until data changes
    local response = skynet.response()
    if not monitors[name] then
        monitors[name] = {}
    end
    table.insert(monitors[name], { source = source, response = response })
end

function CMD.__test(source)
    assert(not pcall(CMD.query, source, "missing-sharedata"))
    assert(not pcall(CMD.update, source, "missing-sharedata", {}))
    assert(not pcall(CMD.new, source, "bad-type", true))
    assert(not pcall(CMD.new, source, "bad-string", "function("))
    skynet.retpack(true)
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd], "Unknown sharedata command: " .. tostring(cmd))
        f(source, ...)
    end)
end)
