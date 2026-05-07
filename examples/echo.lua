-- echo.lua -- Lua echo service for skynet-cpp
--
-- Receives PTYPE_LUA messages and echoes them back to sender.

local skynet = require "skynet"

skynet.start(function()
    skynet.error("[echo.lua] started, handle = " .. skynet.address(skynet.self()))

    skynet.dispatch("lua", function(session, source, ...)
        skynet.error(string.format("[echo.lua] got message from %s session=%d: %s",
            skynet.address(source), session, table.concat({...}, ", ")))

        if session ~= 0 then
            skynet.retpack(...)
        end
    end)

    skynet.error("[echo.lua] dispatch registered")
end)
