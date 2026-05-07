-- skynet/debug.lua — Debug protocol handler for skynet-cpp
--
-- Registers PTYPE_DEBUG (9) protocol. Each service automatically handles
-- debug commands: MEM, GC, STAT, TASK, EXIT, PING, INFO, RUN.
-- Used by debug_console to inspect/control individual services.

local table = table
local extern_dbgcmd = {}

local function init(skynet, export)
    local internal_info_func

    function skynet.info_func(func)
        internal_info_func = func
    end

    local dbgcmd

    local function init_dbgcmd()
        dbgcmd = {}

        function dbgcmd.MEM()
            local kb = collectgarbage "count"
            skynet.ret(skynet.pack(kb))
        end

        local gcing = false
        function dbgcmd.GC()
            if gcing then
                return
            end
            gcing = true
            local before = collectgarbage "count"
            local before_time = skynet.now()
            collectgarbage "collect"
            skynet.yield()
            local after = collectgarbage "count"
            local after_time = skynet.now()
            skynet.error(string.format("GC %.2f Kb -> %.2f Kb, cost %.2f sec",
                before, after, (after_time - before_time) / 100))
            gcing = false
        end

        function dbgcmd.STAT()
            local stat = {}
            stat.task = skynet.task()
            stat.mqlen = 0  -- no direct mqlen access in skynet-cpp yet
            stat.cpu = 0
            stat.message = 0
            skynet.ret(skynet.pack(stat))
        end

        function dbgcmd.TASK(session)
            if session then
                skynet.ret(skynet.pack(skynet.task(session)))
            else
                local task = {}
                skynet.task(task)
                skynet.ret(skynet.pack(task))
            end
        end

        function dbgcmd.INFO(...)
            if internal_info_func then
                skynet.ret(skynet.pack(internal_info_func(...)))
            else
                skynet.ret(skynet.pack(nil))
            end
        end

        function dbgcmd.EXIT()
            skynet.exit()
        end

        function dbgcmd.RUN(source, filename, ...)
            -- Simple code injection: load and execute a string
            local args = table.pack(...)
            local func, err = load(source, filename, "t")
            if not func then
                skynet.ret(skynet.pack(false, err))
                return
            end
            local ok, result = pcall(func, table.unpack(args, 1, args.n))
            collectgarbage "collect"
            if ok then
                skynet.ret(skynet.pack(true, tostring(result)))
            else
                skynet.ret(skynet.pack(false, tostring(result)))
            end
        end

        function dbgcmd.PING()
            return skynet.ret()
        end

        return dbgcmd
    end

    local function _debug_dispatch(session, address, cmd, ...)
        dbgcmd = dbgcmd or init_dbgcmd()
        local f = dbgcmd[cmd] or extern_dbgcmd[cmd]
        if f then
            f(...)
        else
            skynet.error("Unknown debug command: " .. tostring(cmd))
            skynet.ret(skynet.pack(false, "Unknown command: " .. tostring(cmd)))
        end
    end

    skynet.register_protocol {
        name = "debug",
        id = assert(skynet.PTYPE_DEBUG),
        pack = assert(skynet.pack),
        unpack = assert(skynet.unpack),
        dispatch = _debug_dispatch,
    }
end

local function reg_debugcmd(name, fn)
    extern_dbgcmd[name] = fn
end

return {
    init = init,
    reg_debugcmd = reg_debugcmd,
}
