# Multicast
## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; Coverage und Linux-Docker-Performance haben eigene Runner. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

> skynet-cpp Publish/Subscribe

---

```lua
local multicast = require "skynet.multicast"
```

The Multicast module provides a channel-based publish/subscribe messaging mechanism within the same process.

---

## Usage

### Publisher

```lua
local multicast = require "skynet.multicast"

-- Create a new channel
local mc = multicast.new()
print("channel id:", mc.channel)

-- Publish a message (fire-and-forget)
mc:publish("event_name", { data = 123 })

-- Delete the channel
mc:delete()
```

### Subscriber

```lua
local multicast = require "skynet.multicast"

-- Use an existing channel ID
local mc = multicast.new({ channel = channel_id })

-- Set the receive callback
mc.dispatch = function(channel, source, ...)
    print("received from", source, ":", ...)
end

-- Subscribe
mc:subscribe()

-- Unsubscribe
mc:unsubscribe()
```

---

## API

| Method | Description |
|---|---|
| `multicast.new(opts)` | Create a channel object. opts can include `{channel=id}` to use an existing channel |
| `mc:subscribe()` | Subscribe the current service to this channel |
| `mc:unsubscribe()` | Unsubscribe from the channel |
| `mc:publish(...)` | Publish a message to all subscribers |
| `mc:delete()` | Delete this channel |
| `mc.dispatch` | Set to a callback function to receive published messages |

---

## Implementation Architecture

| Component | Description |
|---|---|
| `multicastd` service | Singleton service that manages channel ID allocation, subscriber lists, and message broadcasting |
| `multicast.lua` client | Registers the `PTYPE_MULTICAST` protocol type and provides an object-oriented API |

Message publishing flow:
1. The publisher calls `mc:publish(...)`
2. The message is sent to the `multicastd` service
3. `multicastd` iterates the subscriber list and sends a `PTYPE_MULTICAST` message to each subscriber
4. The subscriber's dispatch callback is triggered

---

## Differences from Original Skynet

- API is largely identical
- The original supports cross-node multicast (distributed via datacenter); skynet-cpp only supports same-process multicast

