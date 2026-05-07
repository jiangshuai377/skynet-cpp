local skynet = require "skynet"

print("[perf preload] cwd =", skynet.getcwd())
skynet.setpathbase(".")
print("[perf preload] pathbase =", skynet.getpathbase())

skynet.appendpath("lualib")
skynet.appendpath("tests/perf")
skynet.appendservicepath("service")
skynet.appendservicepath("tests/perf")
skynet.appendcpath("luaclib")

skynet.start(function()
    local launcher = skynet.newservice("launcher")
    skynet.call(launcher, "lua", "LIST")
    skynet.newservice("test_perf")
end)
