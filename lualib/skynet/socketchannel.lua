-- socketchannel.lua — TCP connection multiplexing channel
--
-- Multiplexes multiple request/response pairs on a single TCP connection.
-- Two modes:
--   Session mode: response callback extracts session ID from each response
--   Order mode:   FIFO matching of requests to responses
--
-- Used by cluster system, Redis, MySQL drivers, etc.

local skynet = require "skynet"
local socket = require "socket"

local socket_channel = {}
local channel_meta = { __index = {} }

local socket_error = setmetatable({}, {__tostring = function() return "[socketchannel] socket error" end})

local function close_channel_socket(self)
    if self.__conn_id then
        pcall(socket.close, self.__conn_id)
        self.__conn_id = nil
    end
end

local function wakeup_all(self, errmsg)
    if self.__response then
        -- session mode
        for session, co in pairs(self.__thread) do
            self.__result[co] = false
            self.__result_data[co] = errmsg
            skynet.wakeup(co)
        end
        self.__thread = {}
    else
        -- order mode
        for _, co in ipairs(self.__thread) do
            self.__result[co] = false
            self.__result_data[co] = errmsg
            skynet.wakeup(co)
        end
        self.__thread = {}
        self.__request = {}
    end
end

local function push_response(self, response, co)
    if self.__response then
        -- session mode: response is session id
        self.__thread[response] = co
    else
        -- order mode: response is function
        table.insert(self.__request, response)
        table.insert(self.__thread, co)
        if self.__wait_dispatch then
            skynet.wakeup(self.__wait_dispatch)
        end
    end
end

local function dispatch_by_session(self)
    local conn_id = self.__conn_id
    while self.__conn_id == conn_id do
        local ok, session, result_ok, data, padding = pcall(self.__response, self)
        if not ok then
            close_channel_socket(self)
            wakeup_all(self, session)
            return
        end
        if not session then
            close_channel_socket(self)
            wakeup_all(self, "closed by remote")
            return
        end
        local co = self.__thread[session]
        if co then
            if padding then
                -- Multi-part response: accumulate
                local result = self.__result_data[co]
                if type(result) ~= "table" then
                    result = {}
                    self.__result_data[co] = result
                end
                result[#result + 1] = data
            else
                -- Final or single response
                self.__thread[session] = nil
                local prev = self.__result_data[co]
                if type(prev) == "table" then
                    prev[#prev + 1] = data
                    self.__result[co] = result_ok
                else
                    self.__result[co] = result_ok
                    self.__result_data[co] = data
                end
                skynet.wakeup(co)
            end
        end
    end
end

local function dispatch_by_order(self)
    local conn_id = self.__conn_id
    while self.__conn_id == conn_id do
        if #self.__request == 0 then
            -- No pending requests, wait
            self.__wait_dispatch = coroutine.running()
            skynet.wait()
            self.__wait_dispatch = nil
        end
        local func = table.remove(self.__request, 1)
        local co = table.remove(self.__thread, 1)
        if func and co then
            local ok, result_ok, data, padding = pcall(func, self)
            if not ok then
                close_channel_socket(self)
                self.__result[co] = false
                self.__result_data[co] = result_ok
                skynet.wakeup(co)
                wakeup_all(self, result_ok)
                return
            end
            if padding then
                local result = self.__result_data[co]
                if type(result) ~= "table" then
                    result = {}
                    self.__result_data[co] = result
                end
                result[#result + 1] = data
                -- Re-insert for more parts
                table.insert(self.__request, 1, func)
                table.insert(self.__thread, 1, co)
            else
                local prev = self.__result_data[co]
                if type(prev) == "table" then
                    prev[#prev + 1] = data
                    self.__result[co] = result_ok
                else
                    self.__result[co] = result_ok
                    self.__result_data[co] = data
                end
                skynet.wakeup(co)
            end
        end
    end
end

local function try_connect(self)
    local conn_id = socket.connect(self.__host, self.__port)
    if not conn_id then
        return false, "connect failed"
    end
    self.__conn_id = conn_id

    -- Start dispatch thread
    if self.__response then
        skynet.fork(dispatch_by_session, self)
    else
        skynet.fork(dispatch_by_order, self)
    end

    -- Run auth callback if provided
    if self.__auth then
        local ok, message = pcall(self.__auth, self)
        if not ok then
            close_channel_socket(self)
            return false, message
        end
    end

    return true
end

local function block_connect(self, once)
    if self.__conn_id then
        return true
    end
    if self.__connecting then
        -- Another coroutine is connecting, wait
        local co = coroutine.running()
        if not self.__waiting_connect then
            self.__waiting_connect = {}
        end
        table.insert(self.__waiting_connect, co)
        skynet.wait()
        return self.__conn_id ~= nil
    end

    self.__connecting = true
    local retry = 0
    local max_retry = once and 1 or 10
    local ok, err
    while retry < max_retry do
        ok, err = try_connect(self)
        if ok then break end
        retry = retry + 1
        if retry < max_retry then
            skynet.sleep(math.min(retry * 10, 300)) -- backoff: 100ms to 3s
        end
    end
    self.__connecting = false

    -- Wake up waiters
    if self.__waiting_connect then
        for _, co in ipairs(self.__waiting_connect) do
            skynet.wakeup(co)
        end
        self.__waiting_connect = nil
    end

    if not ok then
        error(string.format("[socketchannel] connect %s:%s failed: %s",
            tostring(self.__host), tostring(self.__port), tostring(err)))
    end
    return true
end

--- Read exactly sz bytes from channel's socket.
function channel_meta.__index:read(sz)
    if not self.__conn_id then
        error(socket_error)
    end
    local data = socket.read(self.__conn_id, sz)
    if not data then
        error(socket_error)
    end
    return data
end

--- Read a line from channel's socket (up to separator).
function channel_meta.__index:readline(sep)
    if not self.__conn_id then
        error(socket_error)
    end
    local data = socket.readline(self.__conn_id, sep)
    if not data then
        error(socket_error)
    end
    return data
end

--- Create a new socket channel.
-- desc = { host, port, response, auth, nodelay }
-- response: callback function(channel) -> session, ok, data, padding  (session mode)
-- auth: callback function(channel) called after connect for login/auth
function socket_channel.channel(desc)
    local self = setmetatable({}, channel_meta)
    self.__host = assert(desc.host, "need host")
    self.__port = assert(desc.port, "need port")
    self.__response = desc.response  -- session mode callback
    self.__auth = desc.auth          -- auth/login callback
    self.__nodelay = desc.nodelay
    self.__conn_id = nil
    self.__connecting = false

    -- Dispatch state
    self.__thread = {}       -- session -> coroutine (session mode) / list of coroutines (order mode)
    self.__request = {}      -- list of response functions (order mode only)
    self.__result = {}       -- co -> ok
    self.__result_data = {}  -- co -> data

    return self
end

--- Send request and optionally wait for response.
-- request: string or table of strings to send
-- session: session number (session mode) or response function (order mode), nil = no wait
-- padding: table of additional data parts to send
function channel_meta.__index:request(request, session, padding)
    block_connect(self)

    -- Send request data
    if type(request) == "table" then
        for _, part in ipairs(request) do
            socket.send(self.__conn_id, part)
        end
    elseif padding then
        socket.send(self.__conn_id, request)
        for _, part in ipairs(padding) do
            socket.send(self.__conn_id, part)
        end
    else
        socket.send(self.__conn_id, request)
    end

    if session == nil then
        return  -- fire-and-forget
    end

    local co = coroutine.running()
    push_response(self, session, co)
    skynet.wait()

    local ok = self.__result[co]
    local data = self.__result_data[co]
    self.__result[co] = nil
    self.__result_data[co] = nil

    if not ok then
        error(data or "socket error")
    end

    return data
end

--- Wait for a response without sending any data (for subscribe/watch mode).
-- response: response function (order mode) or session id (session mode)
function channel_meta.__index:response(response)
    block_connect(self)

    local co = coroutine.running()
    push_response(self, response, co)
    skynet.wait()

    local ok = self.__result[co]
    local data = self.__result_data[co]
    self.__result[co] = nil
    self.__result_data[co] = nil

    if not ok then
        error(data or "socket error")
    end

    return data
end

--- Explicitly connect (usually called automatically).
function channel_meta.__index:connect(once)
    close_channel_socket(self)
    block_connect(self, once)
end

--- Close the channel.
function channel_meta.__index:close()
    close_channel_socket(self)
    wakeup_all(self, "channel closed")
end

--- Change remote host/port.
function channel_meta.__index:changehost(host, port)
    self.__host = host
    if port then
        self.__port = port
    end
    close_channel_socket(self)
end

function socket_channel._selftest()
    local old_send = socket.send
    local old_read = socket.read
    local old_readline = socket.readline
    socket.send = function()
        return true
    end
    local ok, err = pcall(function()
        local ch = socket_channel.channel { host = "127.0.0.1", port = 1 }
        ch.__conn_id = 1
        ch:request("head", nil, { "body", "tail" })

        socket.read = function()
            return nil
        end
        socket.readline = function()
            return nil
        end
        assert(not pcall(function()
            ch:read(1)
        end), "socketchannel read nil path failed")
        assert(not pcall(function()
            ch:readline("\n")
        end), "socketchannel readline nil path failed")

        local current = coroutine.running()
        local session_ch = socket_channel.channel {
            host = "127.0.0.1",
            port = 1,
            response = function()
                return nil
            end,
        }
        session_ch.__thread[1] = current
        session_ch:close()

        local order_ch = socket_channel.channel { host = "127.0.0.1", port = 1 }
        order_ch.__thread[1] = current
        order_ch.__request[1] = function()
            return true
        end
        order_ch:close()
    end)
    socket.send = old_send
    socket.read = old_read
    socket.readline = old_readline
    if not ok then
        error(err)
    end
    return true
end

return socket_channel
