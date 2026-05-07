local skynet = require "skynet"

print("[example preload] cwd =", skynet.getcwd())
skynet.setpathbase(".")
print("[example preload] pathbase =", skynet.getpathbase())

skynet.appendpath("lualib")
skynet.appendservicepath("service")
skynet.appendservicepath("examples")
skynet.appendcpath("luaclib")

skynet.start(function()
    local launcher = skynet.newservice("launcher")
    skynet.call(launcher, "lua", "LIST")
    skynet.newservice("main")
end)
