local skynet = require "skynet"

print("[stress preload] cwd =", skynet.getcwd())
skynet.setpathbase(".")
print("[stress preload] pathbase =", skynet.getpathbase())

skynet.appendpath("lualib")
skynet.appendpath("tests/stress")
skynet.appendservicepath("service")
skynet.appendservicepath("tests/stress")
skynet.appendservicepath("examples")
skynet.appendcpath("luaclib")

skynet.start(function()
    local launcher = skynet.newservice("launcher")
    skynet.call(launcher, "lua", "LIST")
    skynet.newservice("test_stress")
end)
