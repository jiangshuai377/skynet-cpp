# DebugConsole
## Current Implementation Status

The current runtime uses the preload bootstrap path: set `SKYNET_THREAD` for worker count and `SKYNET_PRELOAD` for the preload script. The preload script configures Lua path/cpath/service path, starts launcher, and selects the application entry. Test entrypoints are split into `tests/logic`, `tests/stress`, and `tests/perf`; the runtime repository keeps only minimal verify/package/package smoke/Linux coverage smoke tools, while full coverage, perf, Docker DB, soak, and native comparisons live in the parent `testa/tools` layer. Actor scheduling now uses `ActorQueue`, sharded registry, and atomic wakeup; Lua callback and `skynet.core` actor context are cached on the hot path.

> skynet-cpp Debug Console and Debug Protocol

---

## Debug Protocol

Every Lua service automatically registers the `PTYPE_DEBUG` protocol with the following built-in debug commands:

| Command | Description |
|---|---|
| `MEM` | Returns the current Lua VM memory usage (KB) |
| `GC` | Triggers garbage collection and reports memory changes |
| `STAT` | Returns task count, message queue length, and CPU statistics |
| `TASK` | Returns task coroutine stack information |
| `INFO` | Calls the service's registered `info_func` callback to retrieve custom information |
| `EXIT` | Gracefully exits the service |
| `PING` | Liveness check (responds immediately) |
| `RUN` | Injects and executes a snippet of Lua code |

### Registering Custom Debug Commands

```lua
local skynet = require "skynet"
require "skynet.debug"

-- Register a custom INFO callback
skynet.info_func(function(...)
    return { state = "running", connections = 42 }
end)

-- Register a custom debug command
local debug = require "skynet.debug"
debug.reg_debugcmd("CUSTOM", function(...)
    return "custom result"
end)
```

---

## Debug Console

`debug_console.lua` provides a TCP telnet interface that allows interactive execution of debug commands after connecting.

### Starting

```lua
-- Start the debug console in preload.lua
local console = skynet.newservice("debug_console", "127.0.0.1", "8000")
```

### Connecting

```bash
telnet 127.0.0.1 8000
```

### Console Commands

| Command | Parameters | Description |
|---|---|---|
| `help` | — | List all commands |
| `list` | — | List all running services |
| `mem` | [timeout] | Query memory status of all services |
| `gc` | [timeout] | Trigger GC on all services |
| `stat` | [timeout] | Query statistics for all services |
| `ping` | address | Check if a service is alive |
| `info` | address, ... | Get custom information from a service |
| `exit` | address | Gracefully exit the specified service |
| `kill` | address | Forcefully terminate the specified service |
| `start` | name, ... | Start a new Lua service |
| `inject` | address, code | Inject and execute Lua code in a service |

---

## Profile Performance Analysis

```lua
local profile = require "skynet.profile"
```

Provides coroutine-level CPU timing via the `lua_profile.cpp` C module:

| Function | Description |
|---|---|
| `profile.start([co])` | Start timing for a coroutine (defaults to current thread) |
| `profile.stop([co])` | Stop timing and return CPU time (seconds) |
| `profile.resume(co, ...)` | coroutine.resume with timing |
| `profile.wrap(f)` | Create a coroutine wrapper with timing |

```lua
profile.start()
-- Perform some compute-intensive operations
local cpu_time = profile.stop()
print(string.format("CPU time: %.6f seconds", cpu_time))
```

---

## Differences from Original Skynet

- Debug protocol command set is largely identical
- The original has a `signal` feature (to interrupt Lua code stuck in an infinite loop); skynet-cpp has not implemented this yet
- The original has `skynet.trace()` for message tracing logs; skynet-cpp has not implemented this yet

