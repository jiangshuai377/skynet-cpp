local skynet = require "skynet"

local worker_id = tonumber((...) or "0") or 0
local received = 0

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "ping" then
            local seq = ...
            received = received + 1
            skynet.retpack("pong", worker_id, seq)
        elseif cmd == "fire" then
            received = received + 1
            if session ~= 0 then
                skynet.retpack("ok", received)
            end
        elseif cmd == "stats" then
            skynet.retpack(received)
        elseif cmd == "die" then
            skynet.retpack("bye", worker_id)
            skynet.exit()
        else
            error("unknown perf_worker command: " .. tostring(cmd))
        end
    end)
end)
