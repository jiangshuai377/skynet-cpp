# ShareData
## Current Implementation Status

The current runtime uses the preload bootstrap path: set `SKYNET_THREAD` for worker count and `SKYNET_PRELOAD` for the preload script. The preload script configures Lua path/cpath/service path, starts launcher, and selects the application entry. Test entrypoints are split into `tests/logic`, `tests/stress`, and `tests/perf`; the runtime repository keeps only minimal verify/package/package smoke/Linux coverage smoke tools, while full coverage, perf, Docker DB, soak, and native comparisons live in the parent `testa/tools` layer. Actor scheduling now uses `ActorQueue`, sharded registry, and atomic wakeup; Lua callback and `skynet.core` actor context are cached on the hot path.

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

