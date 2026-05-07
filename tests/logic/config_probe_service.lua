local skynet = require "skynet"
local probe = require "config_probe"

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd)
        if cmd == "probe" then
            skynet.retpack(probe.value, skynet.getpath())
        else
            error("unknown config_probe_service command: " .. tostring(cmd))
        end
    end)
end)
