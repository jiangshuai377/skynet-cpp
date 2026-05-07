local skynet = require "skynet"

skynet.start(function()
    skynet.sleep(50)
    skynet.dispatch("lua", function(session, source, cmd)
        if cmd == "fire" then
            if session ~= 0 then
                skynet.retpack("ok")
            end
        elseif cmd == "ready" then
            skynet.retpack("ready")
        else
            error("unknown test_unit_slow command: " .. tostring(cmd))
        end
    end)
end)
