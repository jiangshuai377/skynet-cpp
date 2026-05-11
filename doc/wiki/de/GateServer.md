# GateServer
## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; das Runtime-Repository behält nur minimale verify/package/package-smoke/Linux-coverage-smoke Tools, während Full Coverage, Perf, Docker DB, Soak und native Vergleiche in der übergeordneten `testa/tools`-Schicht liegen. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

> skynet-cpp Gateway Service Template

---

The gateway service (GateServer) is the access layer of an application. Its primary functions are managing client connections, splitting complete data packets, and forwarding them to logic services.

skynet-cpp provides a generic template at `lualib/gateserver.lua`.

---

## Usage

```lua
local gateserver = require "gateserver"

local handler = {}

function handler.connect(conn_id, addr, port)
    -- New client connected
end

function handler.disconnect(conn_id)
    -- Client disconnected
end

function handler.message(conn_id, data)
    -- Received a complete business packet (length header already stripped)
end

function handler.open(source, conf)
    -- Gate opens listening port
end

gateserver.start(handler)
```

Note: `gateserver.start` internally calls `skynet.start`.

---

## Handler Callbacks

| Callback | Signature | Description |
|---|---|---|
| `connect` | `(conn_id, addr, port)` | Called after a new client is accepted |
| `disconnect` | `(conn_id)` | Called when a connection is closed |
| `message` | `(conn_id, data)` | A complete business packet (already framed by netpack) has arrived |
| `error` | `(conn_id, msg)` | Connection error |
| `warning` | `(conn_id, bytes)` | Send buffer exceeds 1M warning |
| `open` | `(source, conf)` | Called when the listening port is opened |

---

## Framing Protocol

Each packet = **2-byte big-endian length header** + **data content**

A single data packet must not exceed 65535 bytes. If your business needs to transfer larger data blocks, handle it at the upper-layer protocol level.

### netpack API

```lua
local netpack = require "netpack"
```

| Function | Description |
|---|---|
| `netpack.pack(data)` | Packs data (adds 2-byte length header); returns framed string |
| `netpack.unpack(buffer, offset)` | Extracts one complete frame from buffer; returns (next_offset, payload) |
| `netpack.filter(buffer, new_data)` | Merges new data and extracts all complete frames |
| `netpack.tostring(msg, sz)` | Converts lightuserdata to Lua string |

---

## Control Commands

Other services can send the following commands to the gate via the lua protocol:

```lua
-- Open listener
skynet.call(gate, "lua", "OPEN", { port = 8888, address = "0.0.0.0" })

-- Send data with length header
skynet.call(gate, "lua", "SEND", conn_id, data)

-- Send raw data (without length header)
skynet.call(gate, "lua", "SENDRAW", conn_id, raw_data)

-- Close connection
skynet.call(gate, "lua", "CLOSE", conn_id)

-- Kick connection
skynet.call(gate, "lua", "KICK", conn_id)
```

---

## Differences from Original skynet

- The original gateserver is located at `lualib/snax/gateserver.lua`; skynet-cpp's is at `lualib/gateserver.lua`
- The original has `gateserver.openclient(fd)` / `gateserver.closeclient(fd)` for controlling message reception; in skynet-cpp, connections receive messages by default
- The original message callback passes a C pointer and length `(fd, msg, sz)`; skynet-cpp passes a Lua string `(conn_id, data)`
- The original cannot be mixed with the socket library in the same service; the same applies to skynet-cpp

