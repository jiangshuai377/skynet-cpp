-- gateserver.lua — High-level TCP gateway framework
--
-- Usage:
--   local gateserver = require "gateserver"
--   gateserver.start(handler)
--
-- handler is a table with optional callbacks:
--   handler.connect(conn_id, addr, port)  — new connection accepted
--   handler.disconnect(conn_id)           — connection closed
--   handler.message(conn_id, data)        — complete message received (after netpack)
--   handler.error(conn_id, msg)           — error
--   handler.warning(conn_id, bytes)       — send buffer warning
--   handler.open(source, conf)            — gate opened (conf = { port, ... })
--
-- The gateway handles TCP listening, connection management, and
-- length-prefixed message framing (2-byte big-endian header via netpack).

local skynet = require "skynet"
local socket = require "socket"
local netpack = require "netpack"

local gateserver = {}

function gateserver.start(handler)
    -- Per-connection state
    local connections = {}       -- conn_id -> { buffer, addr, port }
    local listener_id = nil

    local function on_socket_event(event, conn_id, ...)
        if event == "accept" then
            local addr, port = ...
            connections[conn_id] = {
                buffer = "",
                addr = addr,
                port = port,
            }
            if handler.connect then
                handler.connect(conn_id, addr, port)
            end

        elseif event == "close" then
            if connections[conn_id] then
                connections[conn_id] = nil
                if handler.disconnect then
                    handler.disconnect(conn_id)
                end
            end

        elseif event == "warning" then
            local bytes = ...
            if handler.warning then
                handler.warning(conn_id, bytes)
            end
        end
    end

    local function on_data(conn_id, data)
        local conn = connections[conn_id]
        if not conn then return end

        -- Use netpack to extract framed messages
        local msgs, remaining = netpack.filter(conn.buffer, data)
        conn.buffer = remaining

        for i = 1, #msgs do
            if handler.message then
                handler.message(conn_id, msgs[i])
            end
        end
    end

    local function handle_open(source, conf)
        local port = conf.port or 8888

        listener_id = socket.listen("0.0.0.0", port, on_socket_event)
        socket.ondata(listener_id, on_data)

        skynet.error(string.format("[gateserver] listening on port %d", port))

        if handler.open then
            handler.open(source, conf)
        end

        skynet.retpack("OK")
    end

    local function handle_close(_source, conn_id)
        if conn_id and listener_id then
            socket.write(listener_id, conn_id, "")  -- noop, just to verify
            socket.close(conn_id)
            connections[conn_id] = nil
        end
        skynet.retpack(true)
    end

    local function handle_kick(_source, conn_id)
        if conn_id and listener_id then
            socket.close(conn_id)
            connections[conn_id] = nil
        end
        skynet.retpack(true)
    end

    local function handle_send(_source, conn_id, data)
        if listener_id and conn_id and data then
            local packed = netpack.pack(data)
            socket.write(listener_id, conn_id, packed)
        end
        skynet.retpack(true)
    end

    local function handle_sendraw(_source, conn_id, data)
        if listener_id and conn_id and data then
            socket.write(listener_id, conn_id, data)
        end
        skynet.retpack(true)
    end

    local command = {
        OPEN = handle_open,
        CLOSE = handle_close,
        KICK = handle_kick,
        SEND = handle_send,
        SENDRAW = handle_sendraw,
    }

    -- Register Lua protocol dispatch for gate commands
    skynet.dispatch("lua", function(session, source, cmd, ...)
        cmd = string.upper(cmd)
        local f = command[cmd]
        if not f then
            skynet.error("[gateserver] unknown command: " .. cmd)
            skynet.retpack(nil)
            return
        end
        f(source, ...)
    end)
end

return gateserver
