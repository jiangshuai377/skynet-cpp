-- loader.lua -- Service loader for skynet-cpp
--
-- Called by LuaActor::on_init with the service script name as argument.
-- Sets up package paths, pre-loads skynet.core, then executes the service script.

local args = ...

-- 1. Set up package paths from the current ActorSystem path snapshot.
local bootstrap_lua_path = BOOTSTRAP_LUA_PATH
if bootstrap_lua_path and bootstrap_lua_path ~= "" then
    package.path = bootstrap_lua_path .. ";" .. package.path
end

local lua_path = LUA_PATH
if lua_path and lua_path ~= "" then
    package.path = lua_path .. ";" .. package.path
end

local lua_cpath = LUA_CPATH
if lua_cpath and lua_cpath ~= "" then
    package.cpath = lua_cpath .. ";" .. package.cpath
end

-- 2. Disable code cache (it causes issues with require in cloned closures)
if cache and cache.mode then
    cache.mode("OFF")
end

-- 3. Pre-load skynet.core as a built-in C module
--    (it's compiled into the executable, not a .so/.dll)
local core = require "skynet.core"
if core.getenv("SKYNET_LUA_COVERAGE") then
    local coverage = require "skynet.coverage"
    coverage.start(core.getenv("SKYNET_LUA_COVERAGE_DIR"))
end

-- 4. Determine the service script to load
if not args or args == "" then
    error("loader: no service script specified")
end

-- Split args into script path and extra arguments
-- Format: "path/to/script.lua arg1 arg2 ..."
local script, extra_args
local first_space = args:find(" ")
if first_space then
    script = args:sub(1, first_space - 1)
    extra_args = args:sub(first_space + 1)
else
    script = args
    extra_args = nil
end

-- Try to load as a file path first
local f, err = loadfile(script)
if not f then
    -- Try searching in LUA_SERVICE paths
    local lua_service = LUA_SERVICE or ""
    local search_name = script:gsub("%.lua$", "")
    for path in lua_service:gmatch("[^;]+") do
        local q = path:find("?", 1, true)
        local fullpath
        if q then
            fullpath = path:sub(1, q - 1) .. search_name .. path:sub(q + 1)
        else
            fullpath = path
        end
        f, err = loadfile(fullpath)
        if f then break end
    end
end

if not f then
    error(string.format("loader: cannot find service '%s': %s", script, err))
end

-- 5. Execute the service script, passing extra arguments
if extra_args then
    local arg_list = {}
    for a in extra_args:gmatch("%S+") do
        arg_list[#arg_list + 1] = a
    end
    f(table.unpack(arg_list))
else
    f()
end
