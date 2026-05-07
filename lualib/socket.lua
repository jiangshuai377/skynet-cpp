-- socket.lua — Coroutine-based socket API for skynet-cpp
--
-- Wraps the low-level socketdriver C module with coroutine suspend/resume.
-- Socket events arrive as PTYPE_SOCKET messages; this module registers
-- a dispatch handler to parse them and wake the appropriate coroutines.

local skynet = require "skynet"
local driver = require "socketdriver"

local socket = {}

-- Internal state
local socket_listeners = {}         -- listener_id -> { conn_handler }
local socket_connections = {}       -- conn_id -> { listener_id, buffer, read_co, ... }
local socket_connecting = {}        -- conn_id -> coroutine (waiting for connect result)
local socket_udp_callbacks = {}     -- udp_id -> callback function

-- ============================================================================
-- Socket event dispatch (PTYPE_SOCKET)
-- ============================================================================

local function parse_socket_event(msg)
    -- msg format: "subtype arg1 arg2 ..."
    -- For "data" subtype, payload follows after "data connid "
    local space1 = msg:find(" ")
    if not space1 then return msg end

    local subtype = msg:sub(1, space1 - 1)

    if subtype == "data" then
        local space2 = msg:find(" ", space1 + 1)
        local space3 = space2 and msg:find(" ", space2 + 1)
        if not space2 then return subtype, 0, tonumber(msg:sub(space1 + 1)) end
        if not space3 then
            return subtype, 0, tonumber(msg:sub(space1 + 1, space2 - 1)), msg:sub(space2 + 1)
        end
        local listener_id = tonumber(msg:sub(space1 + 1, space2 - 1)) or 0
        local conn_id = tonumber(msg:sub(space2 + 1, space3 - 1))
        local payload = msg:sub(space3 + 1)
        return subtype, listener_id, conn_id, payload
    elseif subtype == "udp" then
        -- "udp socket_id addr port <payload>"
        local space2 = msg:find(" ", space1 + 1)
        local space3 = space2 and msg:find(" ", space2 + 1)
        local space4 = space3 and msg:find(" ", space3 + 1)
        if not space4 then return subtype end
        local socket_id = tonumber(msg:sub(space1 + 1, space2 - 1))
        local addr = msg:sub(space2 + 1, space3 - 1)
        local port = tonumber(msg:sub(space3 + 1, space4 - 1))
        local payload = msg:sub(space4 + 1)
        return subtype, socket_id, addr, port, payload
    else
        -- "accept listener_id conn_id addr port" / "open conn_id addr port" /
        -- "close listener_id conn_id" / "warning listener_id conn_id bytes"
        local parts = {}
        for w in msg:gmatch("%S+") do
            parts[#parts + 1] = w
        end
        if parts[1] == "accept" then
            return parts[1], tonumber(parts[2]) or 0, tonumber(parts[3]), parts[4], tonumber(parts[5])
        elseif parts[1] == "close" then
            return parts[1], tonumber(parts[2]) or 0, tonumber(parts[3])
        elseif parts[1] == "warning" then
            return parts[1], tonumber(parts[2]) or 0, tonumber(parts[3]), tonumber(parts[4])
        end
        return parts[1], tonumber(parts[2]), parts[3], tonumber(parts[4])
    end
end

local function dispatch_socket_event(session, source, subtype, a1, a2, a3, a4)
    if subtype == "accept" then
        local listener_id, conn_id, addr, port = a1, a2, a3, a4
        local info = socket_listeners[listener_id]
        if info and info.handler then
            socket_connections[conn_id] = {
                listener_id = listener_id,
                buffer = "",
                read_co = nil,
                read_sz = nil,
                closed = false,
            }
            info.handler("accept", conn_id, addr, port)
        end

    elseif subtype == "data" then
        local listener_id, conn_id, payload = a1, a2, a3
        local conn = socket_connections[conn_id]
        if conn then
            conn.buffer = conn.buffer .. (payload or "")
            -- If a coroutine is waiting for data, check if we can satisfy it
            if conn.read_co then
                local co = conn.read_co
                local sz = conn.read_sz
                if sz then
                    -- Read exact N bytes
                    if #conn.buffer >= sz then
                        local result = conn.buffer:sub(1, sz)
                        conn.buffer = conn.buffer:sub(sz + 1)
                        conn.read_co = nil
                        conn.read_sz = nil
                        skynet.wakeup(co)
                        conn.read_result = result
                    end
                else
                    -- Read line or readall — readall wakes on any data
                    local sep = conn.read_sep
                    if sep then
                        local pos = conn.buffer:find(sep, 1, true)
                        if pos then
                            local line = conn.buffer:sub(1, pos - 1)
                            conn.buffer = conn.buffer:sub(pos + #sep)
                            conn.read_co = nil
                            conn.read_sep = nil
                            skynet.wakeup(co)
                            conn.read_result = line
                        end
                    else
                        -- readall mode
                        local result = conn.buffer
                        conn.buffer = ""
                        conn.read_co = nil
                        skynet.wakeup(co)
                        conn.read_result = result
                    end
                end
            end
            -- Also notify listener handler
            local info = socket_listeners[listener_id]
            if info and info.data_handler then
                info.data_handler(conn_id, payload)
            end
        end

    elseif subtype == "close" then
        local listener_id, conn_id = a1, a2
        local connecting = socket_connecting[conn_id]
        if connecting then
            socket_connecting[conn_id] = nil
            skynet.wakeup(connecting)
        end
        local conn = socket_connections[conn_id]
        if conn then
            conn.closed = true
            -- Wake any waiting reader
            if conn.read_co then
                conn.read_result = nil
                skynet.wakeup(conn.read_co)
                conn.read_co = nil
            end
        end
        -- Notify listener handler
        local info = socket_listeners[listener_id]
        if info and info.handler then
            info.handler("close", conn_id)
        end
        socket_connections[conn_id] = nil

    elseif subtype == "open" then
        local conn_id, addr, port = a1, a2, a3
        -- Connect completed
        local co = socket_connecting[conn_id]
        if co then
            socket_connecting[conn_id] = nil
            socket_connections[conn_id] = {
                listener_id = nil,
                buffer = "",
                read_co = nil,
                read_sz = nil,
                closed = false,
                connect_result = true,
                connect_addr = addr,
                connect_port = port,
            }
            skynet.wakeup(co)
        end

    elseif subtype == "warning" then
        local listener_id, conn_id, bytes = a1, a2, a3
        local info = socket_listeners[listener_id]
        if info and info.handler then
            info.handler("warning", conn_id, bytes)
        end

    elseif subtype == "udp" then
        local socket_id, addr, port, payload = a1, a2, a3, a4
        local cb = socket_udp_callbacks[socket_id]
        if cb then
            cb(payload, addr, port)
        end
    end
end

-- Register PTYPE_SOCKET protocol
skynet.register_protocol {
    name = "socket",
    id = skynet.PTYPE_SOCKET,
    unpack = function(msg, sz)
        if type(msg) == "string" then
            return parse_socket_event(msg)
        end
        return driver.unpackevent(msg)
    end,
    unpack_trashes = true,
    dispatch = dispatch_socket_event,
}

-- ============================================================================
-- Public API
-- ============================================================================

--- Listen on a TCP port.
--- handler(event, conn_id, ...) is called for accept/close/warning events.
--- Returns listener_id.
function socket.listen(host, port, handler)
    local id = driver.listen(host, port)
    socket_listeners[id] = {
        handler = handler,
        data_handler = nil,
    }
    return id
end

--- Set a data handler for a listener (called with conn_id, data for each chunk).
function socket.ondata(listener_id, handler)
    local info = socket_listeners[listener_id]
    if info then
        info.data_handler = handler
    end
end

--- Connect to a remote host (blocks current coroutine until connected).
--- Returns conn_id on success, nil on failure.
function socket.connect(host, port)
    local id = driver.connect(host, port)
    socket_connecting[id] = coroutine.running()
    skynet.wait()
    local conn = socket_connections[id]
    if conn and conn.connect_result then
        return id
    end
    return nil
end

--- Send data on a connector's connection.
function socket.send(conn_id, data)
    local conn = socket_connections[conn_id]
    if conn and conn.listener_id then
        -- It's a listener connection — use write(listener_id, conn_id, data)
        return driver.write(conn.listener_id, conn_id, data)
    else
        -- It's a connector connection
        return driver.send(conn_id, data)
    end
end

--- Write data to a connection within a listener.
function socket.write(listener_id, conn_id, data)
    return driver.write(listener_id, conn_id, data)
end

--- Read exactly sz bytes (blocks current coroutine).
--- Returns data string, or nil if connection closed.
function socket.read(conn_id, sz)
    local conn = socket_connections[conn_id]
    if not conn then return nil end

    -- Check if buffer already has enough
    if #conn.buffer >= sz then
        local result = conn.buffer:sub(1, sz)
        conn.buffer = conn.buffer:sub(sz + 1)
        return result
    end

    if conn.closed then return nil end

    -- Wait for more data
    conn.read_co = coroutine.running()
    conn.read_sz = sz
    conn.read_result = nil
    skynet.wait()
    return conn.read_result
end

--- Read until separator (blocks current coroutine).
--- Returns line without separator, or nil if connection closed.
function socket.readline(conn_id, sep)
    sep = sep or "\n"
    local conn = socket_connections[conn_id]
    if not conn then return nil end

    -- Check buffer first
    local pos = conn.buffer:find(sep, 1, true)
    if pos then
        local line = conn.buffer:sub(1, pos - 1)
        conn.buffer = conn.buffer:sub(pos + #sep)
        return line
    end

    if conn.closed then
        if #conn.buffer > 0 then
            local result = conn.buffer
            conn.buffer = ""
            return result
        end
        return nil
    end

    -- Wait for more data
    conn.read_co = coroutine.running()
    conn.read_sep = sep
    conn.read_result = nil
    skynet.wait()
    return conn.read_result
end

--- Read all available data (blocks until at least some data arrives).
--- Returns data string, or nil if connection closed.
function socket.readall(conn_id)
    local conn = socket_connections[conn_id]
    if not conn then return nil end

    if #conn.buffer > 0 then
        local result = conn.buffer
        conn.buffer = ""
        return result
    end

    if conn.closed then return nil end

    conn.read_co = coroutine.running()
    conn.read_result = nil
    skynet.wait()
    return conn.read_result
end

--- Close a connection.
function socket.close(conn_id)
    local conn = socket_connections[conn_id]
    if conn and conn.listener_id then
        driver.close(conn.listener_id, conn_id)
    else
        driver.close(conn_id)
    end
    socket_connections[conn_id] = nil
end

--- Close a listener.
function socket.close_listener(listener_id)
    driver.close(listener_id)
    socket_listeners[listener_id] = nil
end

--- Pause reading on a connection.
function socket.pause(listener_id, conn_id)
    driver.pause(listener_id, conn_id)
end

--- Resume reading on a connection.
function socket.resume(listener_id, conn_id)
    driver.resume(listener_id, conn_id)
end

--- Create a UDP socket.
function socket.udp(host, port, callback)
    local id = driver.udp(host, port)
    if callback then
        socket_udp_callbacks[id] = callback
    end
    return id
end

--- Send UDP data.
function socket.udp_send(id, data, host, port)
    driver.udp_send(id, data, host, port)
end

return socket
