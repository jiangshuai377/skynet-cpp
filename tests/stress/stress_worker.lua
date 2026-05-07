local skynet = require "skynet"

local worker_id = tonumber((...) or "0") or 0
local received = 0

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        if cmd == "ping" then
            local seq, payload = ...
            received = received + 1
            skynet.retpack("pong", worker_id, seq, #tostring(payload or ""))

        elseif cmd == "fire" then
            received = received + 1
            if session ~= 0 then
                skynet.retpack("ok", received)
            end

        elseif cmd == "stats" then
            skynet.retpack(received)

        elseif cmd == "delayed" then
            local seq = ...
            local resp = skynet.response()
            skynet.fork(function()
                skynet.sleep(1)
                resp(true, "delayed", worker_id, seq)
            end)

        elseif cmd == "raw" then
            local seq, payload = ...
            skynet.retpack("raw", worker_id, seq, payload)

        elseif cmd == "die" then
            skynet.retpack("bye", worker_id, received)
            skynet.exit()

        else
            error("unknown stress_worker command: " .. tostring(cmd))
        end
    end)
end)
