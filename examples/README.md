# skynet-cpp examples

Example services that are useful for manual runs and smoke tests:

- `preload.lua`: default startup script when `SKYNET_PRELOAD` is not set.
- `main.lua`: default example service launched by `preload.lua`.
- `echo.lua`: simple Lua RPC echo service.
- `pingpong.lua`: Lua/text protocol demo service.

These files are on `LUA_SERVICE`, so tests can launch them by service name, but they are not counted as production service coverage.
