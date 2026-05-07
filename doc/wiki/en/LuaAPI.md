# LuaAPI
## Current Implementation Status

The current runtime uses the preload bootstrap path: set `SKYNET_THREAD` for worker count and `SKYNET_PRELOAD` for the preload script. The preload script configures Lua path/cpath/service path, starts launcher, and selects the application entry. Test entrypoints are split into `tests/logic`, `tests/stress`, and `tests/perf`, with separate coverage and Linux Docker perf runners. Actor scheduling now uses `ActorQueue`, sharded registry, and atomic wakeup; Lua callback and `skynet.core` actor context are cached on the hot path.

> skynet Lua Service API Reference

---

```lua
local skynet = require "skynet"
```

Every skynet-cpp service needs to import the `skynet` module. This module cannot be used outside the skynet-cpp framework.

---

## Service Address

Each service has a 32-bit numeric address (handle).

- `skynet.self()` — Returns the current service address
- `skynet.address(addr)` — Converts an address to a human-readable string (`:xxxxxxxx` format)
- `skynet.register(name)` — Registers an alias for the current service (names starting with `.` are local)
- `skynet.name(name, handle)` — Registers an alias for the service with the specified handle
- `skynet.localname(name)` — Queries the address corresponding to a local name (non-blocking)

All API parameters that accept a service address can also accept a string alias.

---

## Message Dispatch and Response

### skynet.dispatch(type, func)

Registers a handler function for a specific message type. The most common usage:

```lua
local CMD = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    local f = assert(CMD[cmd])
    f(...)
end)
```

### skynet.register_protocol(class)

Registers a new message type. The class must provide `name`, `id`, `pack`, and `unpack` fields.

### skynet.ret(msg, sz)

Sends a response to the current request source. Can only be called once within the same message-handling coroutine.

### skynet.retpack(...)

Shortcut for `skynet.ret(skynet.pack(...))`.

### skynet.response([packfunc])

Creates a deferred response closure that can be called later in another coroutine.

```lua
local resp = skynet.response()
-- Call later elsewhere:
resp(true, result1, result2)   -- normal response
resp(false)                     -- throw exception to requester
```

---

## Message Push and Remote Call

### skynet.send(addr, typename, ...)

Sends a message of type `typename` to `addr`. Non-blocking API; the message is packed via the pack function.

### skynet.call(addr, typename, ...)

Sends a request to `addr` and blocks waiting for a response. The response is unpacked via unpack before being returned. **Note**: `skynet.call` only blocks the current coroutine — the service can still respond to other messages.

### skynet.rawsend(addr, typename, msg, sz)

Raw send without going through the pack function.

### skynet.rawcall(addr, typename, msg, sz)

Raw RPC call without going through pack/unpack.

### skynet.redirect(addr, source, typename, session, ...)

Sends a message to `addr` impersonating the `source` address.

---

## Clock and Threading

The internal clock precision is 1/100 second (centiseconds).

- `skynet.now()` — Returns the time elapsed since process startup (in centiseconds)
- `skynet.starttime()` — Returns the UTC time when the process started (in seconds)
- `skynet.time()` — Returns the current UTC time (in seconds, 10ms precision)

### skynet.sleep(ti)

Suspends the current coroutine for `ti` centiseconds. Returns `"BREAK"` if woken up by `wakeup`.

### skynet.yield()

Equivalent to `skynet.sleep(0)`. Yields CPU control.

### skynet.timeout(ti, func)

Executes `func` in a new coroutine after `ti` centiseconds. Non-blocking API.

### skynet.fork(func, ...)

Starts a new coroutine to execute `func`. More efficient than `timeout(0, ...)` (bypasses the timer).

### skynet.wait(token)

Suspends the current coroutine, waiting for `wakeup`. The token defaults to `coroutine.running()`.

### skynet.wakeup(token)

Wakes up a coroutine suspended by `sleep` or `wait`.

---

## Service Start and Exit

### skynet.start(func)

Registers the service startup function. **Must be called** — it is the entry point for a service.

### skynet.exit()

Exits the current service. Code after this call will not execute, and suspended coroutines will be interrupted.

### skynet.newservice(name, ...)

Starts a new Lua service. Blocking API — waits until the launched service's `start` function returns before returning.

### skynet.uniqueservice(name, ...)

Starts a unique service. Returns the existing address if one is already running.

### skynet.queryservice(name)

Queries the address of a unique service. Waits if it has not started yet.

## Path Configuration

These APIs are normally called from the preload script. Each argument is a plain directory path; the runtime normalizes `/`, `\`, duplicate separators, and trailing separators, then expands Lua/C module or service search rules internally. Newly created LuaActors inherit the current global path snapshot.

- `skynet.appendpath(path)` — Append a Lua module directory, expanded to `path/?.lua` and `path/?/init.lua`.
- `skynet.prependpath(path)` — Prepend a Lua module directory.
- `skynet.appendcpath(path)` — Append a C module directory, expanded to the platform `.dll` or `.so` search pattern.
- `skynet.appendservicepath(path)` — Append a service script directory, expanded to `path/?.lua`.
- `skynet.getpath()` — Return the current `{ path, cpath, service_path }` snapshot.

---

## Serialization

- `skynet.pack(...)` — Serializes Lua values into `(lightuserdata, size)`
- `skynet.unpack(msg, sz)` — Deserializes into Lua values
- `skynet.packstring(...)` — Serializes into a Lua string
- `skynet.tostring(msg, sz)` — Converts lightuserdata to Lua string
- `skynet.trash(msg, sz)` — Frees a lightuserdata buffer

Supported types: string, boolean, number, lightuserdata, table (without metatables).

---

## Logging

### skynet.error(...)

Concatenates arguments and sends them to the logger service. Output format: `[HH:MM:SS.mmm][HANDLE][ERROR] message`

---

## State Query

- `skynet.info_func(func)` — Registers an internal state query function, callable via the debug protocol
- `skynet.stat(what)` — Queries service internal state: `"endless"`, `"mqlen"`, `"message"`, `"cpu"`

---

## Others

- `skynet.getenv(key)` — Reads an environment variable
- `skynet.setenv(key, value)` — Sets an environment variable (cannot overwrite)
- `skynet.genid()` — Generates a unique session
- `skynet.harbor(addr)` — Always returns 0 (skynet-cpp does not support harbor)

---

## Differences from Original skynet

- `skynet.harbor()` always returns 0
- Does not support `skynet.forward_type` and `skynet.filter` (advanced message forwarding)
- `skynet.memlimit` must be called before `start`
- Environment variables are passed in via `ActorSystem` rather than a config file


