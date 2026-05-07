# CodeCache
## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; Coverage und Linux-Docker-Performance haben eigene Runner. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

> Lua 5.5 Code Cache Mechanism

---

## Overview

skynet-cpp uses a modified version of Lua 5.5.0 from skynet, which includes a **codecache** mechanism. This mechanism allows multiple Lua VMs (i.e., multiple services) to share compiled Lua function prototypes (Proto), thereby:

1. **Saving memory**: the same script is compiled into bytecode only once
2. **Speeding up startup**: subsequent VMs loading the same script can reuse it directly, without re-parsing

---

## How It Works

When a Lua service loads a script via `loadfile`:

1. **First load**: compiles normally and stores the compiled function prototype in the global cache
2. **Subsequent loads**: clones the function prototype directly from the cache, skipping the compilation step

Key C API extensions:
- `lua_clonefunction(L, proto)` — creates a new closure from a shared prototype
- `lua_sharefunction(L, index)` — adds a function prototype to the shared pool

---

## Usage in skynet-cpp

In `loader.lua`, codecache is disabled by default (`cache.mode("OFF")`), for the following reasons:

- Each `LuaActor` in skynet-cpp owns an independent `lua_State`, with completely isolated `_ENV` for each VM
- If codecache is enabled, multiple VMs share the same compiled Proto, but each VM has a different global environment (`_ENV`). When the Proto references global functions like `require`, it causes `_ENV` to point to the wrong VM
- With codecache disabled, each VM compiles scripts independently, and `_ENV` points correctly

```lua
-- loader.lua
local cache = require "cache"
cache.mode("OFF")  -- Disable shared cache
```

---

## Manual Control

If you are certain that some pure function scripts do not depend on `_ENV`, you can selectively enable caching:

```lua
local cache = require "cache"

-- Query the current mode
local mode = cache.mode()

-- Set mode: ON / OFF
cache.mode("ON")   -- Enable shared cache
cache.mode("OFF")  -- Disable shared cache
```

---

## Differences from Original Skynet

- The original skynet enables codecache by default; skynet-cpp disables it by default
- The original uses `require "skynet.codecache"` for the control interface; skynet-cpp uses `require "cache"`
- The original provides `codecache.clear()` to clear the cache; skynet-cpp does not support this yet

