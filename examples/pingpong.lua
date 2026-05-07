-- pingpong.lua -- Lua PingPong service for skynet-cpp
--
-- Receives a message, replies with a counter, stops after 5 rounds.

local skynet = require "skynet"

local name = ...  -- passed as argument: "ping" or "pong"
name = name or "unknown"

local count = 0

skynet.start(function()
    skynet.error(string.format("[%s] started, handle = %s", name, skynet.address(skynet.self())))

    skynet.dispatch("lua", function(session, source, cmd, ...)
        count = count + 1
        skynet.error(string.format("[%s] round %d, got: %s from %s",
            name, count, tostring(cmd), skynet.address(source)))

        if count < 5 then
            -- Send back (fire-and-forget)
            skynet.send(source, "lua", name .. " replies #" .. tostring(count))
        else
            skynet.error(string.format("[%s] finished after %d rounds.", name, count))
        end
    end)

    -- Handle text messages from C++ bootstrap
    skynet.dispatch("text", function(session, source, msg)
        count = count + 1
        skynet.error(string.format("[%s] round %d, got text: %s from %s",
            name, count, tostring(msg), skynet.address(source)))

        if count < 5 then
            skynet.send(source, "lua", name .. " replies #" .. tostring(count))
        else
            skynet.error(string.format("[%s] finished after %d rounds.", name, count))
        end
    end)
end)
