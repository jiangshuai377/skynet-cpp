# SocketChannel
## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; Coverage und Linux-Docker-Performance haben eigene Runner. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

> skynet-cpp Socket Connection Multiplexing

---

```lua
local socketchannel = require "skynet.socketchannel"
```

The request-response pattern is one of the most common patterns when interacting with external services. socketchannel provides a high-level wrapper that supports two protocol designs:

1. **Order Mode**: Each request has a corresponding response, with TCP guaranteeing ordering (e.g., Redis)
2. **Session Mode**: Each request carries a unique session, and the response includes the session for matching (e.g., MongoDB)

---

## Creating a Channel

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    -- Optional parameters:
    response = dispatch_func,   -- If provided, enters Session mode
    auth = auth_func,           -- Auth callback after connection is established
    nodelay = true,             -- TCP_NODELAY
}
```

A socket channel does not establish a connection immediately upon creation. The connection is deferred until the first `request`. After a disconnection, the next `request` will automatically reconnect.

---

## Order Mode

Suitable for protocols like Redis where each request must have a sequentially ordered response:

```lua
local resp = channel:request(req_string, function(sock)
    -- sock is a read object passed by the channel
    local line = sock:readline()
    return true, line  -- First return value: success?; Second: response content
end)
```

The first return value of the response function is a boolean:
- `true`: Protocol parsing succeeded
- `false`: Protocol error; the connection will be closed and request throws an error

---

## Session Mode

Suitable for protocols like MongoDB where responses can arrive out of order. A global `response` function must be provided at creation time:

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 27017,
    response = function(sock)
        -- Parse response packet
        local session = ...  -- Extract session from response
        local ok = true
        local data = ...     -- Parse response data
        return session, ok, data
    end,
}

-- Send request, passing session instead of response function
local resp = channel:request(req_string, session_id)
```

---

## Authentication

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    auth = function(sock)
        -- Automatically called after connection is established
        -- Can perform AUTH / SELECT and other operations
        sock:request("AUTH password\r\n", function(s)
            return true, s:readline()
        end)
    end,
}
```

The auth function is executed immediately after each connection is established. If authentication fails, throw an error within auth.

---

## Other APIs

| Method | Description |
|---|---|
| `channel:connect(once)` | Explicitly connect. once=true means try only once; throws on failure |
| `channel:close()` | Close the channel; wakes up all pending requests |
| `channel:changehost(host, port)` | Change the remote address and reconnect |
| `channel:read(sz)` | Read `sz` bytes from the channel |
| `channel:readline(sep)` | Read from the channel until the separator |
| `channel:response(func)` | Do not send a request; only wait to receive one response (for pub/sub) |

---

## Differences from Original skynet

- APIs are largely consistent
- The original has `padding` parameter and low-priority write (`socket.lwrite`); skynet-cpp has not implemented these yet
- The original has `backup` fallback addresses (designed for mongo clusters); skynet-cpp has not implemented this yet
- The original has `overload` callback; skynet-cpp has not implemented this yet

