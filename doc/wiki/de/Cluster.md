# Cluster
## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; das Runtime-Repository behält nur minimale verify/package/package-smoke/Linux-coverage-smoke Tools, während Full Coverage, Perf, Docker DB, Soak und native Vergleiche in der übergeordneten `testa/tools`-Schicht liegen. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

> skynet-cpp Cluster

---

```lua
local cluster = require "skynet.cluster"
```

skynet-cpp implements a cluster mode to support cross-node RPC. Each node is an independent skynet-cpp process, and nodes communicate via TCP connections for message passing.

---

## Quick Start

### Node A: Listen + Provide Service

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    local echo = skynet.newservice("echo")
    skynet.name(".echo", echo)

    -- Register a name for remote access
    cluster.register("echo", echo)

    -- Load cluster configuration
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- Open listening port
    cluster.open("127.0.0.1", 19999)
end)
```

### Node B: Remote Call

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- RPC call to the echo service on node A
    local result = cluster.call("nodeA", ".echo", "hello")
    print(result)

    -- Query a registered name
    local addr = cluster.query("nodeA", "echo")
end)
```

---

## API

| Function | Description |
|---|---|
| `cluster.call(node, addr, ...)` | Synchronous RPC call to a service on a remote node. Blocks until a response is received |
| `cluster.send(node, addr, ...)` | Asynchronous push message to a remote node (no response). Risk of message loss |
| `cluster.open(addr, port)` | Open a listening port to accept inbound cluster connections |
| `cluster.reload(cfg)` | Reload cluster configuration. cfg is a `{nodename = "host:port", ...}` table |
| `cluster.register(name, addr)` | Register a local service name for remote access via `@name`. addr defaults to self |
| `cluster.unregister(name)` | Unregister a previously registered name |
| `cluster.query(node, name)` | Query the address of a service registered via `cluster.register` on a remote node |

### Address Format

The second parameter `addr` of `cluster.call` can be:

- **String name**: e.g. `".echo"`, looks up the name on the target node
- **`@` prefixed name**: e.g. `"@echo"`, looks up via `cluster.register` registered names
- **Numeric address**: if you already know the remote service handle

---

## Architecture

The cluster system consists of three services:

```
cluster.call("nodeB", ".svc", "CMD")
      │
      ▼
  clusterd ──sender──→ [TCP] ──→ clusteragent ──→ local service
  (manager)  (outbound)          (inbound)            ↓
      ▲                                          response
      │                                            │
      └────────────────────── [TCP] ←───────────────┘
```

| Service | Count | Responsibility |
|---|---|---|
| `clusterd` | 1 per node | Central manager: configuration, sender/agent lifecycle, name registration, listening |
| `clustersender` | 1 per remote node | Maintains TCP connection to a remote node, sends requests via socketchannel |
| `clusteragent` | 1 per connection | Handles inbound connections, parses requests, dispatches to local services, sends responses back |

---

## Cluster Protocol

The `cluster.core` C module implements the cluster wire protocol:

- **Packet format**: 2-byte big-endian length header + payload
- **Request packet**: type tag + session + target address + serialized message
- **Response packet**: session + success/failure + serialized message
- **Large message fragmentation**: messages exceeding 32KB are automatically split into multiple segments for transmission

---

## Message Ordering

Most inter-cluster requests are ordered by call sequence (first-sent, first-arrived). However, when a single packet exceeds 32KB, it is fragmented for transmission, and large packets may arrive after smaller ones.

Requests and responses use the same TCP connection, so ordering is guaranteed.

---

## Configuration Update

Reload configuration via `cluster.reload(cfg)`. If a node address is changed, new requests after reload will be sent to the new address. Previously pending requests will still wait on the old address.

You can set a node address to `false` to mark the node as offline.

---

## Differences from Original Skynet

- skynet-cpp **does not support** master/slave (harbor) mode, only cluster mode is supported
- The original cluster configuration is loaded from a file; skynet-cpp passes it via `cluster.reload(table)`
- The original has `cluster.proxy(node, addr)` to create a local proxy; skynet-cpp has not implemented this yet
- The original has `cluster.snax` for remote Snax services; skynet-cpp does not support Snax
- The original configuration supports `__nowaiting = true`; skynet-cpp has not implemented this yet

