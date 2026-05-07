-- debug_console.lua — TCP remote debug console for skynet-cpp
--
-- Listens on a port for telnet/netcat connections.
-- Supports commands: help, list, mem, gc, kill, exit, start, stat, ping, inject
--
-- Usage: skynet.newservice("debug_console", "8000")
--   or:  skynet.newservice("debug_console", "127.0.0.1 8000")

local skynet = require "skynet"
local socket = require "socket"

local arg = ...
local ip, port

-- The arg from loader.lua is the script path + optional params.
-- We look for a port number after the script name.
-- Format: "scriptpath" or "scriptpath ip port" or "scriptpath port"
local function parse_args(s)
    if not s then return nil, nil end
    -- Try to extract just numeric port from end of string
    local last_word = s:match("(%S+)%s*$")
    local p = last_word and tonumber(last_word)
    if p and p > 0 and p < 65536 then
        -- Check if there's an IP before the port
        local before = s:match("^(.-)%s+" .. last_word .. "%s*$")
        if before then
            local ip_maybe = before:match("(%S+)%s*$")
            if ip_maybe and ip_maybe:match("^%d+%.%d+%.%d+%.%d+$") then
                return ip_maybe, p
            end
        end
        return nil, p
    end
    return nil, nil
end

local parsed_ip, parsed_port = parse_args(arg)
ip = parsed_ip or "127.0.0.1"
port = parsed_port or 8000

local TIMEOUT = 300  -- 3 sec

local COMMAND = {}

-- ============================================================================
-- Helper functions
-- ============================================================================

local function format_table(t)
    if type(t) ~= "table" then
        return tostring(t)
    end
    local index = {}
    for k in pairs(t) do
        index[#index + 1] = k
    end
    table.sort(index, function(a, b) return tostring(a) < tostring(b) end)
    local result = {}
    for _, v in ipairs(index) do
        result[#result + 1] = string.format("%s:%s", tostring(v), tostring(t[v]))
    end
    return table.concat(result, "\t")
end

local function dump_list(print_fn, list)
    if type(list) ~= "table" then
        print_fn(tostring(list))
        return
    end
    local index = {}
    for k in pairs(list) do
        index[#index + 1] = k
    end
    table.sort(index, function(a, b) return tostring(a) < tostring(b) end)
    for _, v in ipairs(index) do
        local val = list[v]
        if type(val) == "table" then
            print_fn(tostring(v), format_table(val))
        else
            print_fn(tostring(v), tostring(val))
        end
    end
end

local function split_cmdline(cmdline)
    local split = {}
    for w in cmdline:gmatch("%S+") do
        split[#split + 1] = w
    end
    return split
end

local function adjust_address(address)
    if not address then return nil end
    local prefix = address:sub(1, 1)
    if prefix == ':' then
        return tonumber(address:sub(2), 16)
    elseif prefix == '.' then
        return skynet.queryservice(address)
    else
        return tonumber("0x" .. address)
    end
end

local function docmd(cmdline, print_fn)
    local split = split_cmdline(cmdline)
    local command = split[1]
    if not command then return end
    command = command:lower()

    local cmd = COMMAND[command]
    if not cmd then
        print_fn("Invalid command, type help for command list")
        return
    end

    local ok, list = pcall(cmd, table.unpack(split, 2))
    if ok then
        if list then
            if type(list) == "string" then
                print_fn(list)
            else
                dump_list(print_fn, list)
            end
        end
        print_fn("<CMD OK>")
    else
        print_fn(tostring(list))
        print_fn("<CMD Error>")
    end
end

-- ============================================================================
-- Commands
-- ============================================================================

function COMMAND.help()
    return {
        help  = "This help message",
        list  = "List all services",
        stat  = "Dump all stats",
        info  = "info address : get service information",
        exit  = "exit address : gracefully exit a service",
        kill  = "kill address : kill a service",
        mem   = "mem : show memory status",
        gc    = "gc : force all lua services to garbage collect",
        start = "start name : launch a new lua service",
        ping  = "ping address : check if service is alive",
        inject = "inject address code : inject lua code",
    }
end

function COMMAND.list()
    return skynet.call(".launcher", "lua", "LIST")
end

local function timeout(ti)
    if ti then
        ti = tonumber(ti)
        if ti and ti <= 0 then
            ti = nil
        end
    else
        ti = TIMEOUT
    end
    return ti
end

function COMMAND.stat(ti)
    return skynet.call(".launcher", "lua", "STAT", timeout(ti))
end

function COMMAND.mem(ti)
    return skynet.call(".launcher", "lua", "MEM", timeout(ti))
end

function COMMAND.gc(ti)
    return skynet.call(".launcher", "lua", "GC", timeout(ti))
end

function COMMAND.kill(address)
    return skynet.call(".launcher", "lua", "KILL", address)
end

function COMMAND.exit(address)
    local addr = adjust_address(address)
    if addr then
        skynet.send(addr, "debug", "EXIT")
        return "Signal sent"
    end
    return "Invalid address"
end

function COMMAND.start(...)
    local ok, addr = pcall(skynet.newservice, ...)
    if ok then
        if addr then
            return { [skynet.address(addr)] = table.concat({...}, " ") }
        else
            return "Exit"
        end
    else
        return "Failed: " .. tostring(addr)
    end
end

function COMMAND.ping(address)
    local addr = adjust_address(address)
    if not addr then
        return "Invalid address"
    end
    local ok = pcall(skynet.call, addr, "debug", "PING")
    if ok then
        return "PONG"
    else
        return "TIMEOUT or ERROR"
    end
end

function COMMAND.inject(address, ...)
    local addr = adjust_address(address)
    if not addr then
        return "Invalid address"
    end
    local code = table.concat({...}, " ")
    if code == "" then
        return "Usage: inject address lua_code"
    end
    local ok, output = skynet.call(addr, "debug", "RUN", code, "inject")
    if ok then
        return "OK: " .. tostring(output)
    else
        return "Error: " .. tostring(output)
    end
end

function COMMAND.info(address, ...)
    local addr = adjust_address(address)
    if not addr then
        return "Invalid address"
    end
    local ok, info = pcall(skynet.call, addr, "debug", "INFO", ...)
    if ok then
        return info
    else
        return "Error: " .. tostring(info)
    end
end

-- ============================================================================
-- Main loop
-- ============================================================================

local function console_main_loop(conn_id, print_fn, addr)
    print_fn("Welcome to skynet-cpp debug console")
    skynet.error(string.format("[debug_console] %s connected", addr or "unknown"))

    local ok, err = pcall(function()
        while true do
            local line = socket.readline(conn_id, "\n")
            if not line then break end
            line = line:gsub("\r$", "")
            if line ~= "" then
                docmd(line, print_fn)
            end
        end
    end)

    if not ok then
        skynet.error(string.format("[debug_console] error: %s", tostring(err)))
    end
    skynet.error(string.format("[debug_console] %s disconnected", addr or "unknown"))
    socket.close(conn_id)
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd ~= "CMD" then
            skynet.retpack(false, "Unknown debug_console command: " .. tostring(cmd))
            return
        end
        local cmdline = ...
        if cmdline == "__selftest" then
            local ip1, port1 = parse_args("debug_console.lua 127.0.0.1 19000")
            local ip2, port2 = parse_args("debug_console.lua 19001")
            local ip3, port3 = parse_args("debug_console.lua")
            assert(ip1 == "127.0.0.1" and port1 == 19000)
            assert(ip2 == nil and port2 == 19001)
            assert(ip3 == nil and port3 == nil)
            assert(format_table("plain") == "plain")
            assert(format_table({ b = 2, a = 1 }):find("a:1", 1, true))
            local output = {}
            local function collect(...)
                local t = { ... }
                for k, v in ipairs(t) do
                    t[k] = tostring(v)
                end
                output[#output + 1] = table.concat(t, "\t")
            end
            dump_list(collect, "list-as-string")
            dump_list(collect, { z = { n = 1 }, a = 2 })
            docmd("info invalid", collect)
            docmd("inject invalid return 1", collect)
            skynet.retpack(true, #output)
            return
        end
        local output = {}
        local function collect(...)
            local t = { ... }
            for k, v in ipairs(t) do
                t[k] = tostring(v)
            end
            output[#output + 1] = table.concat(t, "\t")
        end
        docmd(cmdline, collect)
        skynet.retpack(output)
    end)

    socket.listen(ip, port, function(event, conn_id, addr, p)
        if event ~= "accept" then return end

        local function print_fn(...)
            local t = { ... }
            for k, v in ipairs(t) do
                t[k] = tostring(v)
            end
            socket.send(conn_id, table.concat(t, "\t") .. "\n")
        end

        skynet.fork(console_main_loop, conn_id, print_fn, addr)
    end)

    skynet.error(string.format("[debug_console] listening on %s:%d", ip, port))
end)
