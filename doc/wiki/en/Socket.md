# Socket
## Current Implementation Status

The current runtime uses the preload bootstrap path: set `SKYNET_THREAD` for worker count and `SKYNET_PRELOAD` for the preload script. The preload script configures Lua path/cpath/service path, starts launcher, and selects the application entry. Test entrypoints are split into `tests/logic`, `tests/stress`, and `tests/perf`, with separate coverage and Linux Docker perf runners. Actor scheduling now uses `ActorQueue`, sharded registry, and atomic wakeup; Lua callback and `skynet.core` actor context are cached on the hot path.

> skynet-cpp Socket API

---

```lua
local socket = require "socket"
```

skynet-cpp provides a set of blocking-mode Lua APIs for TCP/UDP reading and writing. The so-called blocking mode actually leverages Lua's coroutine mechanism. When you call a socket API, the service may be suspended (yielding its time slice to other tasks). Once the result arrives via a socket message, the coroutine resumes execution.

---

## TCP API

### Server

```lua
-- Listen on a port
local listener_id = socket.listen("0.0.0.0", 8888, function(event, conn_id, ...)
    if event == "accept" then
        -- New connection accepted
    elseif event == "close" then
        -- Connection closed
    elseif event == "warning" then
        -- Send buffer warning
    end
end)

-- Set data callback
socket.ondata(listener_id, function(conn_id, data)
    -- Data received
end)
```

- `socket.listen(host, port, handler)` — Listens on a port; handler receives accept/close/warning events; returns listener_id
- `socket.ondata(listener_id, handler)` — Sets the data callback `handler(conn_id, data)`
- `socket.write(listener_id, conn_id, data)` — Sends data on a listener's connection
- `socket.close_listener(listener_id)` — Closes the listener
- `socket.pause(listener_id, conn_id)` — Pauses reading on a connection (flow control)
- `socket.resume(listener_id, conn_id)` — Resumes reading on a connection

### Client

```lua
local conn_id = socket.connect("127.0.0.1", 8888)
if conn_id then
    socket.send(conn_id, "hello\n")
    local line = socket.readline(conn_id, "\n")
    socket.close(conn_id)
end
```

- `socket.connect(host, port)` — Connects to a remote host; blocks until the connection is established or fails
- `socket.send(conn_id, data)` — Sends data
- `socket.read(conn_id, sz)` — Reads `sz` bytes; blocks until data is ready or the connection closes
- `socket.readline(conn_id, sep)` — Reads until the separator (default `"\n"`); does not include the separator
- `socket.readall(conn_id)` — Reads all available data
- `socket.close(conn_id)` — Closes the connection

---

## UDP API

```lua
local udp_id = socket.udp("0.0.0.0", 9999, function(data, from_addr, from_port)
    -- UDP packet received
end)

socket.udp_send(udp_id, "hello", "127.0.0.1", 9999)
```

- `socket.udp(host, port, callback)` — Creates a UDP socket; callback receives packets
- `socket.udp_send(id, data, host, port)` — Sends a UDP packet

---

## socketdriver (C Module)

`socket.lua` is a coroutine wrapper around the underlying C module `socketdriver`. The functions registered by `socketdriver` include:

| Function | Description |
|---|---|
| `socketdriver.listen(host, port, backlog)` | Creates a TCP listener |
| `socketdriver.connect(host, port)` | Creates a TCP connection (async) |
| `socketdriver.send(id, data)` | Sends data via a connector |
| `socketdriver.write(listener_id, conn_id, data)` | Sends data via a listener's connection |
| `socketdriver.close(id, [conn_id])` | Closes a socket or connection |
| `socketdriver.pause(listener_id, conn_id)` | Pauses reading on a connection |
| `socketdriver.resume(listener_id, conn_id)` | Resumes reading on a connection |
| `socketdriver.udp(host, port)` | Creates a UDP socket |
| `socketdriver.udp_send(id, data, host, port)` | Sends a UDP packet |

---

## Differences from Original skynet

- The original uses `socket.start(id)` to take over socket control (because multiple services share socket IDs); in skynet-cpp, listener/connector are inherently bound to the creating service
- The original has `socket.abandon` (transfer control); skynet-cpp has not implemented this yet
- The original has `socket.lwrite` (low-priority write queue); skynet-cpp has not implemented this yet
- The original has `socket.block` (wait for readable); skynet-cpp has not implemented this yet

