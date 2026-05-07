local skynet = require "skynet"

local worker_id = tonumber((...) or "0") or 0

skynet.start(function()
    skynet.sleep(5)

    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "ready" then
            skynet.retpack("ready", worker_id)
        else
            error("unknown stress_slowstart command: " .. tostring(cmd))
        end
    end)
end)
