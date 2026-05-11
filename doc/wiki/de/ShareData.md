# ShareData
## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; das Runtime-Repository behält nur minimale verify/package/package-smoke/Linux-coverage-smoke Tools, während Full Coverage, Perf, Docker DB, Soak und native Vergleiche in der übergeordneten `testa/tools`-Schicht liegen. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

> skynet-cpp Shared Data

---

```lua
local sharedata = require "sharedata"
```

When you split your business logic across multiple services, sharing data becomes the most common challenge. The sharedata module is used to share read-only structured data among multiple services within the same process, with the typical use case being configuration table distribution.

---

## Usage

### Data Provider

```lua
-- Create shared data
sharedata.new("game_config", {
    max_level = 100,
    exp_table = {100, 200, 400, 800},
})

-- Update data
sharedata.update("game_config", {
    max_level = 120,
    exp_table = {100, 200, 400, 800, 1600},
})

-- Delete data
sharedata.delete("game_config")
```

### Data Consumer

```lua
-- Query data (the first query starts a monitor coroutine to track updates)
local config = sharedata.query("game_config")
print(config.max_level)  -- 100

-- After data is updated, the next access automatically gets the new version
-- Get a deep copy (one-time use, more efficient)
local copy = sharedata.deepcopy("game_config")
```

---

## API

| Function | Description |
|---|---|
| `sharedata.new(name, value)` | Create shared data. value can be any Lua table |
| `sharedata.query(name)` | Query shared data. The first query starts a monitor coroutine that automatically tracks updates |
| `sharedata.update(name, value)` | Update shared data. All holders' monitors will be notified |
| `sharedata.delete(name)` | Delete shared data |
| `sharedata.flush()` | Clear local cache; the next query will re-fetch from the server |
| `sharedata.deepcopy(name, ...)` | Get a deep copy of the data. Extra arguments serve as a key chain to index sub-tables |

---

## Implementation Architecture

```
sharedatad (singleton service)              sharedata client (each consumer)
├─ data_store[name]                         ├─ local_cache[name]
│   ├─ data (Lua table)                     │   ├─ data
│   └─ version (incrementing integer)       │   └─ version
└─ commands:                                └─ monitor coroutine:
    new/delete/query/update/monitor            long-polls sharedatad for version changes
```

**Data Flow**:
1. Service A calls `sharedata.new("cfg", data)` → sharedatad stores the data
2. Service B calls `sharedata.query("cfg")` → fetches data from sharedatad + starts a monitor
3. Service A calls `sharedata.update("cfg", new_data)` → sharedatad updates + notifies all monitors
4. Service B's monitor receives notification → automatically updates local cache

---

## Differences from Original Skynet

- The original sharedata uses C shared memory, allowing multiple Lua VMs to directly read the same memory block. skynet-cpp uses message passing to deep-copy data — functionally equivalent but without shared memory
- The original has a `sharetable` module (based on `lua_clonefunction`); skynet-cpp does not support this
- In the original, queried objects can be read like normal tables (via `__index` metamethod); skynet-cpp directly returns plain tables
- The original has STM / ShareMap modules; skynet-cpp does not support these

