local skynet = require "skynet"

print("[logic preload] cwd =", skynet.getcwd())
skynet.setpathbase(".")
print("[logic preload] pathbase =", skynet.getpathbase())

skynet.appendpath("lualib")
skynet.appendpath("tests/logic")
skynet.appendservicepath("service")
skynet.appendservicepath("tests/logic")
skynet.appendservicepath("examples")
skynet.appendcpath("luaclib")

skynet.start(function()
    local launcher = skynet.newservice("launcher")
    skynet.call(launcher, "lua", "LIST")
    skynet.newservice("test_unit_coverage")
end)
