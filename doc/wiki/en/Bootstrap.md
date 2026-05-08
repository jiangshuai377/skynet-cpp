# Bootstrap

## Current Implementation Status

The current runtime uses the preload bootstrap path: set `SKYNET_THREAD` for worker count and `SKYNET_PRELOAD` for the preload script. The preload script configures Lua path/cpath/service path, starts launcher, and selects the application entry. Test entrypoints are split into `tests/logic`, `tests/stress`, and `tests/perf`, with separate coverage and Linux Docker perf runners. Actor scheduling now uses `ActorQueue`, sharded registry, and atomic wakeup; Lua callback and `skynet.core` actor context are cached on the hot path.

## Overview

The C++ entrypoint performs only minimal bootstrap: create `ActorSystem`, start logger, read environment variables, start the preload LuaActor, and then enter the worker/IO/monitor event loop. Launcher is no longer hard-coded in C++; the preload script starts it explicitly with `skynet.newservice("launcher")`.

## Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `SKYNET_THREAD` | `8` | Worker thread count |
| `SKYNET_PRELOAD` | `examples/preload.lua` | Preload script path |

## Startup Flow

```text
main()
  -> read SKYNET_THREAD / SKYNET_PRELOAD
  -> ActorSystem workers=N
  -> spawn<ServiceLogger>()
  -> spawn<LuaActor>(preload)
  -> preload configures paths and starts launcher
  -> preload starts example, logic, stress, perf, or application service
  -> system.run()
```

## Preload Responsibilities

The preload script is the only startup orchestration entrypoint. It usually:

- Calls `skynet.appendpath` / `skynet.prependpath` for Lua module paths.
- Calls `skynet.appendcpath` for C module paths.
- Calls `skynet.appendservicepath` for service search paths.
- Starts `launcher`.
- Starts the application, example, logic, stress, or perf entry service.

## Pathbase and Package Layout

Relative `SKYNET_PRELOAD` values are resolved from the process cwd. Release packages should be launched from the install root, with `bin/`, `lualib/`, `service/`, `examples/`, and `doc/`; the default preload is `examples/preload.lua`. A preload script usually prints `skynet.getcwd()`, calls `skynet.setpathbase(".")`, and then all relative `appendpath` / `appendservicepath` / `appendcpath` inputs are resolved from `skynet.getpathbase()`. `setpathbase` does not change the OS cwd and does not affect third-party file IO.

## Thread Model

| Thread | Count | Responsibility |
| --- | ---: | --- |
| Worker | `SKYNET_THREAD` | Pop `ActorQueue` objects from global queue and dispatch messages in weighted batches |
| IO | 1 | Run `asio::io_context` for network IO and timers |
| Monitor | 1 | Detect workers stuck on the same message for too long |

## Example Preload

```lua
local skynet = require "skynet"

skynet.appendpath("lualib")
skynet.appendservicepath("service")
skynet.appendservicepath("examples")

skynet.start(function()
    skynet.newservice("launcher")
    skynet.newservice("main")
end)
```

## Related Entrypoints

- Example: `examples/preload.lua`
- Logic tests: `tests/logic/preload.lua`
- Stress tests: `tests/stress/preload.lua`
- Performance tests: `tests/perf/preload.lua`
