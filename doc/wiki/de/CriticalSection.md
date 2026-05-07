# CriticalSection
## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; Coverage und Linux-Docker-Performance haben eigene Runner. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

> skynet-cpp Message Serialization Queue

---

```lua
local queue = require "skynet.queue"
```

Within a single skynet-cpp service, if a blocking API (such as `skynet.call`) is invoked during message processing, the current handler will be suspended. While suspended, the service can respond to other messages. This can easily cause ordering issues and must be handled with great care.

In other words, once your message processing involves external requests, messages that arrive first are not necessarily processed before those that arrive later. After each blocking call, the internal state of the service may no longer be consistent with what it was before the call.

The `skynet.queue` module helps you avoid the complexity introduced by this pseudo-concurrency.

---

## Usage

```lua
local queue = require "skynet.queue"

local cs = queue()  -- cs is an execution queue

local CMD = {}

function CMD.foobar()
    cs(func1)  -- func1 enters the critical section
end

function CMD.foo()
    cs(func2)  -- func2 enters the critical section
end
```

If you use the `cs` queue, `func1` and `func2` will not be interrupted by each other during execution.

If the service receives multiple `foobar` or `foo` messages, each one is fully processed before the next, even if `func1` or `func2` contain blocking calls like `skynet.call`.

---

## Reentrancy

Calling cs from within func1 is legal (it will not deadlock):

```lua
local function func2()
    -- step 3
end

local function func1()
    -- step 2
    cs(func2)
    -- step 4
end

function CMD.foobar()
    -- step 1
    cs(func1)
    -- step 5
end
```

Each time a foobar message is received, the program flow executes in order: step 1 → 2 → 3 → 4 → 5.

---

## Implementation Principle

The queue achieves FIFO scheduling through the following mechanism:

- `current_thread`: records the coroutine currently holding the lock
- `ref` reference count: supports nested calls from the same coroutine (reentrancy)
- `thread_queue` wait queue: new requests are enqueued at the tail
- Uses `skynet.wait()` / `skynet.wakeup()` to suspend and wake up coroutines

---

## Differences from Original Skynet

- API is fully identical
- Implementation is identical (based on skynet.wait/wakeup)

