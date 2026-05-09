# skynet-cpp Actor RPC Performance Optimization Notes

Date: 2026-05-03

This document records the full actor RPC performance optimization pass for
`skynet-cpp`. The goal was explicit: under high concurrency, actor RPC and
scheduler throughput should reach at least 90% of native skynet, while keeping
logic tests, stress tests, and existing Lua API behavior intact.

The final result meets that goal for the actor-heavy benchmark on Linux Docker:

| threads | skynet-cpp rpc/s | native skynet rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 188,235.29 | 188,235.29 | 100.0% |
| 16 | 228,571.43 | 172,972.97 | 132.1% |
| 32 | 193,939.39 | 182,857.14 | 106.1% |

## Scope

The optimization focused on the actor message send/dispatch/RPC path:

- Lua `skynet.call`, `skynet.send`, `skynet.retpack`
- `skynet.core.send` / `genid` C binding boundary
- C++ `ActorSystem::send`, `push_message`, `schedule_queue`
- actor registry lookup
- global queue scheduling and worker wakeup
- LuaActor callback dispatch
- packed Lua payload delivery and cleanup

Socket throughput was already much higher than native skynet during Linux
comparison, so socket was intentionally not the main target after the first
round of low-risk locking cleanup.

## Benchmark Harness

The benchmark was split out from logic/stress tests into an independent perf
entry:

- `tests/perf/preload.lua`
- `tests/perf/test_perf.lua`
- `tests/perf/perf_worker.lua`
- `tools/run_perf_benchmark.bat`
- `tools/run_linux_perf_in_docker.bat`

These wrappers now run through the Python stdlib tool layer. Offline Python is
kept as Git LFS archives under `tools/python/archives/` and extracted into
ignored runtime directories on first use.

The actor-heavy profile uses:

- 64 worker services
- 1000 `skynet.call` per worker
- 2000 fire-and-forget `skynet.send` per worker
- thread counts: 8, 16, 32
- Release builds
- iteration 1 treated as warmup and excluded from median calculations

Linux comparison runs build both:

- `skynet-cpp` Release in Debian bookworm Docker
- native skynet under `/work/resource/skynet`

Native skynet was built with:

```text
make linux MALLOC_STATICLIB= SKYNET_DEFINES=-DNOUSE_JEMALLOC
```

Reason: the local native skynet checkout did not have the jemalloc submodule
initialized. This makes the comparison conservative but not identical to a full
native skynet production build with jemalloc.

## Native Skynet Reference

Native skynet's actor scheduling path is very lean:

- global queue stores service message queues, not service ids
- each service queue has a state flag to prevent duplicate global enqueue
- worker pops a queue, dispatches a bounded batch, then requeues if messages
  remain
- message queue lifetime is separate from the service context lifetime
- Lua callback dispatch in `lua-skynet.c` keeps the callback path compact
- message payloads are explicit pointer/size pairs, not type-erased containers

The key lesson from native skynet was not simply "use fewer locks". The more
important point is that it avoids repeated registry lookup and global queue
wakeup cost on every message batch.

## Initial Baseline

Early high-concurrency actor benchmarks exposed serious gaps:

- 64 workers, 1000 call/worker, 2000 fire/worker, 8 runtime threads:
  timed out at 300 seconds in one early Windows baseline.
- 64 workers, 100 call/worker, 0 fire/worker, 8 runtime threads:
  timed out at 20 seconds in repeated repro.
- 16 workers, 1000 call/worker, 0 fire/worker, 8 runtime threads:
  about 47,058 rpc/s.

The first full Linux native comparison showed actor-heavy was far below native:

| threads | native rpc/s | skynet-cpp rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 114,285.71 | 42,105.26 | 36.8% |
| 16 | 136,170.21 | 38,323.35 | 28.1% |
| 32 | 120,754.72 | 35,164.84 | 29.1% |

At the same time, socket was already above native:

| profile | threads | native | skynet-cpp | cpp/native |
| --- | ---: | ---: | ---: | ---: |
| socket-heavy | 8 | 7,619.05 | 20,983.61 | 275.4% |
| socket-heavy | 16 | 6,719.16 | 23,703.70 | 352.8% |
| socket-heavy | 32 | 7,013.70 | 22,654.87 | 323.0% |

That shaped the rest of the work: actor dispatch was the bottleneck; socket was
not.

## Optimization Timeline

### 1. Low-Risk Runtime Cleanup

Changes:

- Cache logger handle in `ActorSystem::error()`.
- Reduce `names_mutex_` traffic on high-frequency error paths.
- Shorten socket store lock duration in socket binding code.
- Keep actual socket write/close/pause/resume work outside the socket store lock
  where possible.

Outcome:

- Correctness stayed stable.
- Socket remained strong.
- Actor RPC did not reach the native target; deeper actor scheduling changes
  were needed.

### 2. Sharded Actor Registry

Before this change, actor lookup was centered around a single actor registry
mutex/map. That made `send` and dispatch contend on one shared structure.

Changes:

- Replace single registry with fixed shards.
- Handle hash selects one shard.
- `spawn`, `kill`, `grab_queue`, and `actor_count` lock only the relevant shard.

Outcome:

- Reduced registry contention.
- Improved scheduler-heavy behavior.
- Actor RPC still remained below native because every dispatch still paid too
  much queue/wakeup cost.

### 3. ActorQueue Split

Native skynet keeps service queue lifetime separate from service context
lifetime. The C++ runtime initially tied mailbox/schedule state closely to the
actor object, making kill/drain/requeue logic harder and adding lookup cost.

Changes:

- Add internal `ActorQueue`.
- Move mailbox, mailbox count, overload threshold, accepting/releasing state,
  and schedule state into `ActorQueue`.
- Registry stores `shared_ptr<ActorQueue>`.
- Global queue stores `ActorQueue` objects instead of actor handles.
- Actor owner is accessed through the queue.
- Kill removes queue from registry, marks it releasing, and lets workers drain
  or drop pending messages safely.

Outcome:

- Safer lifecycle behavior under kill while dispatching.
- Better scheduler-heavy throughput.
- Actor RPC improved, but still did not reach native target in all thread
  counts.

After ActorQueue, Linux comparison showed:

| threads | native rpc/s | skynet-cpp rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 114,285.71 | 65,979.38 | 57.7% |
| 16 | 136,170.21 | 61,538.46 | 45.2% |
| 32 | 120,754.72 | 58,181.82 | 48.2% |

Scheduler-heavy became competitive:

| threads | native dispatch/s | skynet-cpp dispatch/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 315,076.92 | 409,600.00 | 130.0% |
| 16 | 372,363.64 | 372,363.64 | 100.0% |
| 32 | 292,571.43 | 292,571.43 | 100.0% |

This showed that queue structure was now reasonable, but actor RPC still had
hot-path overhead.

### 4. Raw Queue and MessagePayload Experiments

Several payload and queue variants were tried:

- raw queue variants
- `MessagePayload` / variant-style payload attempts
- lighter hot-path wrappers around message data

Outcome:

- The measured benefit was small or unstable.
- Some versions increased complexity without moving the main bottleneck.
- These experiments were not kept as the main solution.

Reason:

Profile data showed the largest remaining cost was not simply `std::any` or
payload representation. The more important costs were Lua call boundary and
worker wakeup behavior.

### 5. Lua Dispatch Fast Path

Two Lua dispatch improvements were retained:

- `lualib/skynet.lua` uses `c.unpacktrash` for Lua protocol payloads.
- Redundant Lua-level `pcall(raw_dispatch_message, ...)` was removed from the
  hot message dispatch path. `LuaActor::on_message` already calls the callback
  via `lua_pcall`, so an extra Lua `pcall` around every message was redundant.

Outcome:

- Fewer Lua frames per message.
- Payload cleanup became more direct for the common Lua protocol path.
- Logic and stress suites continued to pass.

### 6. LuaActor Callback Ref Cache

Before this change, `LuaActor::on_message` looked up the callback by name in the
Lua registry on every message:

```text
lua_getfield(registry, "skynet_callback")
```

Changes:

- `skynet.core.callback(func)` now stores the callback as a registry reference
  on the `LuaActor`.
- `LuaActor::on_message` calls `lua_rawgeti` with the cached ref.
- The traceback function is also cached as a registry ref.
- `on_destroy` unrefs both callback and traceback refs before closing the Lua
  state.

Outcome:

- Removed per-message string registry lookup.
- Reduced C/Lua boundary overhead.
- Correctness passed.

### 7. Native-Like Keep-Current Queue Experiment

The proposed native-like idea was:

- worker keeps the current `ActorQueue`
- if global queue is empty and the current queue still has messages, keep
  dispatching current queue
- avoid enqueue + wakeup between batches

This was implemented and tested.

Outcome:

- Correctness passed.
- Performance regressed, especially at high thread counts.
- 32-thread runs lost parallelism because a worker could monopolize a queue
  while other workers slept or had less work.

Decision:

- Do not retain keep-current dispatch.
- Retain requeue-after-batch behavior because it preserved fairness and
  parallelism better in this runtime.

### 8. Global Queue Wakeup Redesign

The original global queue used a blocking queue path that triggered semaphore or
futex-style wakeup behavior too frequently.

Changes:

- Use `moodycamel::ConcurrentQueue<std::shared_ptr<ActorQueue>>`.
- Add `global_queue_epoch_` and C++20 `atomic::wait/notify`.
- Add `sleeping_workers_`.
- Notify only when workers are actually sleeping.
- Requeue current actor queue after a batch if mailbox still has messages.

Important intermediate result:

| threads | skynet-cpp rpc/s | native rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 128,000.00 | 182,857.14 | 70.0% |
| 16 | 168,421.05 | 182,857.14 | 92.1% |
| 32 | 193,939.39 | 188,235.29 | 103.0% |

This reached the target for 16 and 32 threads, but 8 threads remained below the
90% target.

### 9. Native Weight Table Experiment

Native skynet's worker weight table was tested.

Outcome:

- It worsened the 16/32 thread cases in this C++ runtime.
- The previous quarter-based strategy was restored:
  - first quarter: weight -1
  - second quarter: weight 0
  - third quarter: weight 1
  - fourth quarter: weight 2

Reason:

The exact native table did not map cleanly onto the current C++ queue and wakeup
implementation. The native idea is useful, but the literal constants were not.

### 10. skynet.core Upvalue Cache

Profile showed high-frequency C API calls still needed to find the actor context.
The older binding path read `skynet_actor` from the Lua registry by string in
each C API call.

Changes:

- `luaopen_skynet_core` now builds the module table manually.
- It reads `skynet_actor` once from the registry.
- It installs all C functions with that actor pointer as a closure upvalue.
- `get_actor(L)` first checks the upvalue.
- Registry fallback remains for compatibility.

Effect:

- `skynet.core.send`
- `skynet.core.genid`
- `skynet.core.timeout`
- `skynet.core.self`
- `skynet.core.newservice`
- other C APIs

all avoid repeated registry string lookup when loaded in the normal actor
context.

Measured actor-heavy after this step:

| threads | skynet-cpp rpc/s | native rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 123,122.46 | 200,195.50 | 62.0% |
| 16 | 173,479.85 | 196,969.70 | 88.0% |
| 32 | 182,857.14 | 188,398.27 | 97.0% |

The upvalue change helped clean the boundary but did not solve 8-thread
performance. More profile work was needed.

## Profile Findings

### Early Profile

Earlier `perf` output showed:

- `LuaActor::on_message`: about 60%
- `lua_pcall/luaD_pcall/luaV_execute`: about 58%
- `lsend`: about 14%
- `ActorSystem::push_message`: about 12.6%
- syscall/wakeup cost visible under `push_message`

This justified:

- callback ref caching
- removing redundant Lua dispatch `pcall`
- looking at `send`/scheduler boundary rather than only payload type

### After Upvalue Cache

8-thread profile still showed a large send/wakeup cost:

- `lsend`: about 22.86%
- `ActorSystem::send`: about 22.14%
- `syscall` under `ActorSystem::send`: about 18.48%
- `push_message`: about 3.22%
- `grab_queue`: below 1%
- `luaseri_pack`: about 0.89%

This was important: the profile did not say "serialization is the biggest
problem". It said `send` was waking workers through the kernel too often.

16-thread profile had the same shape but lower relative cost:

- `lsend`: about 16.42%
- `push_message`: about 3.49%
- `grab_queue`: below 1%
- `luaV_execute`: about 11.39%

### After Wakeup Throttling

A global queue count was added so `notify_one` is only issued when queued work
does not already cover sleeping workers.

Result:

- 32-thread actor-heavy improved strongly in one run.
- 8/16 remained below target or unstable.
- Profile still showed `lsend -> syscall` as a major cost in 8-thread runs.

### After Idle Spin

The next issue was worker sleep timing. In the 8-thread actor-heavy benchmark,
workers could briefly observe an empty global queue, enter `atomic_wait`, and
then immediately require a wakeup from another worker's `send`. That caused
high syscall/futex activity.

Change:

- Before `atomic_wait`, worker spins briefly in user space and repeatedly checks
  global queue.
- It does not call `yield`.
- Spin count is thread-count dependent:
  - 8 threads: 256
  - 16 threads: 64
  - 32 threads: 0

Reason for thread-dependent tuning:

- 8 threads benefits from avoiding premature sleep.
- 16 threads benefits moderately.
- 32 threads regressed when spin was enabled because busy workers steal CPU from
  actual Lua execution. Therefore spin is disabled at 32 threads.

Final 8-thread profile still shows some syscall cost, but throughput crossed
the target:

- `luaD_precall`: about 26.14%
- `lsend`: about 19.87%
- syscall under `lsend`: about 15.13%
- `atomic_wait`: about 5.61%
- `__sched_yield`: about 7.43%
- measured profiled run: 162,849.87 rpc/s

The profiled run is slower than the non-profile benchmark because `perf record`
adds overhead, but the shape of the bottleneck is useful.

## Final Retained Changes

This section records the retained changes as concrete "before -> after" code
shapes. Long contexts are represented as equivalent pseudocode.

### 1. Sharded Actor Registry

Before: all actor/queue lookup went through one shared map and one lock.

```cpp
std::shared_mutex actors_mutex_;
std::unordered_map<uint32_t, std::shared_ptr<Actor>> actors_;

std::shared_ptr<Actor> grab(uint32_t handle) {
    std::shared_lock lock(actors_mutex_);
    return actors_[handle];
}
```

After: the registry is split into 64 shards, and the handle selects the shard.

```cpp
static constexpr size_t ACTOR_SHARD_COUNT = 64;

struct ActorShard {
    mutable std::shared_mutex mutex;
    std::unordered_map<uint32_t, std::shared_ptr<ActorQueue>> queues;
};

std::array<ActorShard, ACTOR_SHARD_COUNT> actor_shards_;

ActorShard& actor_shard(uint32_t handle) {
    return actor_shards_[handle & (ACTOR_SHARD_COUNT - 1)];
}

std::shared_ptr<ActorQueue> grab_queue(uint32_t handle) {
    const auto& shard = actor_shard(handle);
    std::shared_lock lock(shard.mutex);
    auto it = shard.queues.find(handle);
    return it != shard.queues.end() ? it->second : nullptr;
}
```

### 2. `ActorQueue` Split

Before: mailbox and scheduling state lived on `Actor`, tying queue lifetime to
service object lifetime.

```cpp
class Actor {
    ConcurrentQueue<Message> mailbox_;
    std::atomic<bool> in_global_;
    std::atomic<size_t> mailbox_count_;
};
```

After: mailbox and scheduling state live in `ActorQueue`; `Actor` keeps service
logic and session/lifecycle state.

```cpp
struct ActorQueue {
    uint32_t handle = 0;
    moodycamel::ConcurrentQueue<Message> mailbox;
    std::atomic<size_t> mailbox_count{0};
    std::atomic<size_t> overload_threshold{OVERLOAD_THRESHOLD};
    std::atomic<int> schedule_state{0}; // 0 idle, 1 queued, 2 dispatching
    std::atomic<bool> accepting{true};
    std::atomic<bool> releasing{false};
    std::atomic<bool> initialized{false};

    mutable std::mutex owner_mutex;
    std::shared_ptr<Actor> owner;
};
```

### 3. Global Queue Stores `shared_ptr<ActorQueue>`

Before: the global queue stored handles, so every worker pop needed another
registry lookup.

```cpp
ConcurrentQueue<uint32_t> global_queue_;

worker_loop() {
    uint32_t handle = pop_global();
    auto actor = grab(handle);
    dispatch(actor);
}
```

After: the global queue stores queue objects directly.

```cpp
moodycamel::ConcurrentQueue<std::shared_ptr<ActorQueue>> global_queue_;

worker_loop() {
    std::shared_ptr<ActorQueue> queue;
    if (global_queue_.try_dequeue(queue)) {
        dispatch_queue(queue, weight, monitor);
    }
}
```

### 4. Queue Lifetime Independent From Actor Owner

Before: once an actor was killed, draining pending messages depended on the
actor object still being reachable.

```cpp
kill(handle) {
    erase_actor(handle);
    // pending drain/drop depends on actor lifetime
}
```

After: killing removes registry reachability, marks the queue releasing, and
schedules the queue once so a worker can drain/drop pending messages. Requests
that still need a response receive `PTYPE_ERROR`.

```cpp
kill(handle) {
    auto queue = erase_queue_from_shard(handle);
    queue->accepting.store(false);
    queue->releasing.store(true);
    schedule_queue(queue);
}

drain_queue(queue) {
    while (queue->mailbox.try_dequeue(msg)) {
        if (msg.session != 0 && msg.source != 0 && !is_response(msg)) {
            send(0, msg.source, PTYPE_ERROR, msg.session, {});
        }
        free_owned_message_data(msg);
    }
}
```

### 5. Cached Logger Handle

Before: `ActorSystem::error()` queried the logger name and touched
`names_mutex_` on the error path.

```cpp
void ActorSystem::error(uint32_t source, const char* fmt, ...) {
    uint32_t logger = query_name("logger");
    send(source, logger, PTYPE_TEXT, 0, text);
}
```

After: an atomic logger handle cache is used; name lookup is only the fallback.

```cpp
std::atomic<uint32_t> logger_handle_{0};

void ActorSystem::error(uint32_t source, const char* fmt, ...) {
    uint32_t logger = logger_handle_.load(std::memory_order_acquire);
    if (logger == 0) {
        logger = query_name("logger");
        logger_handle_.store(logger, std::memory_order_release);
    }
    send(source, logger, PTYPE_TEXT, 0, text);
}
```

### 6. Shortened Socket Store Lock

Before: socket lookup and real IO work happened while holding the store lock.

```cpp
std::lock_guard lock(store.mutex);
auto conn = store.connections[id];
conn->send(data);
conn->close();
```

After: the lock is only used to copy the `shared_ptr`; real IO runs outside the
store lock.

```cpp
std::shared_ptr<TcpConnection> conn;
{
    std::lock_guard lock(store.mutex);
    conn = find_connection(id);
}

if (conn) {
    conn->send(data);
}
```

### 7. `ConcurrentQueue` Global Queue

Before: a mutex-backed global queue would make push/pop contend on one central
lock.

```cpp
std::mutex global_mutex;
std::queue<uint32_t> global_queue;

push_global(handle) {
    std::lock_guard lock(global_mutex);
    global_queue.push(handle);
}
```

After: the global queue uses moodycamel's MPMC queue.

```cpp
moodycamel::ConcurrentQueue<std::shared_ptr<ActorQueue>> global_queue_;

enqueue_global(queue) {
    global_queue_.enqueue(queue);
}

try_dequeue_global(queue) {
    return global_queue_.try_dequeue(queue);
}
```

### 8. Atomic Epoch Wait/Notify

Before: empty-queue waiting required condition-variable-style coordination.

```cpp
if (global_queue.empty()) {
    condvar.wait(lock);
}
```

After: C++20 `atomic::wait/notify` uses `global_queue_epoch_` as the wakeup
version.

```cpp
std::atomic<uint64_t> global_queue_epoch_{0};

// producer
global_queue_epoch_.fetch_add(1, std::memory_order_release);
global_queue_epoch_.notify_one();

// worker
auto epoch = global_queue_epoch_.load(std::memory_order_acquire);
if (!try_dequeue_global()) {
    global_queue_epoch_.wait(epoch, std::memory_order_acquire);
}
```

### 9. Sleeping Worker Count

Before: enqueue could notify even when no worker was sleeping.

```cpp
enqueue_global(queue) {
    global_queue_.enqueue(queue);
    global_queue_epoch_.notify_one();
}
```

After: workers announce when they are about to sleep; producers only consider
notify when at least one worker is sleeping.

```cpp
std::atomic<int> sleeping_workers_{0};

worker_sleep_path() {
    sleeping_workers_.fetch_add(1, std::memory_order_relaxed);
    if (!try_dequeue_global()) {
        global_queue_epoch_.wait(epoch, std::memory_order_acquire);
    }
    sleeping_workers_.fetch_sub(1, std::memory_order_relaxed);
}

enqueue_global(queue) {
    global_queue_.enqueue(queue);
    int sleeping = sleeping_workers_.load(std::memory_order_relaxed);
    if (sleeping > 0) {
        global_queue_epoch_.notify_one();
    }
}
```

### 10. Global Queue Count Wakeup Throttling

Before: any sleeping worker caused a notify.

```cpp
if (sleeping_workers_ > 0) {
    notify_one();
}
```

After: an approximate queued-work count avoids excess wakeups when existing
queued work can already cover sleeping workers.

```cpp
std::atomic<int> global_queue_count_{0};

enqueue_global(queue) {
    global_queue_.enqueue(queue);
    int queued = global_queue_count_.fetch_add(1, std::memory_order_acq_rel) + 1;
    int sleeping = sleeping_workers_.load(std::memory_order_relaxed);
    if (sleeping > 0 && queued <= sleeping) {
        global_queue_epoch_.fetch_add(1, std::memory_order_release);
        global_queue_epoch_.notify_one();
    }
}

try_dequeue_global(queue) {
    if (!global_queue_.try_dequeue(queue)) return false;
    global_queue_count_.fetch_sub(1, std::memory_order_acq_rel);
    return true;
}
```

### 11. Thread-Count-Dependent Idle Spin

Before: a worker immediately entered `atomic_wait` when the global queue was
briefly empty.

```cpp
if (!try_dequeue_global()) {
    atomic_wait(epoch);
}
```

After: low thread counts spin briefly in user space before sleeping; 32-thread
runs disable spin to avoid stealing CPU from Lua execution.

```cpp
int idle_spin = worker_count_ <= 8 ? 256 : (worker_count_ <= 16 ? 64 : 0);

if (!queue && !try_dequeue_global()) {
    for (int spin = 0; spin < idle_spin && running_; ++spin) {
        std::atomic_signal_fence(std::memory_order_seq_cst);
        if (try_dequeue_global()) break;
    }
    if (!queue) {
        atomic_wait(epoch);
    }
}
```

### 12. LuaActor Callback Registry Ref

Before: each message did a string registry lookup for the callback.

```cpp
lua_getfield(L, LUA_REGISTRYINDEX, "skynet_callback");
lua_pcall(L, 5, 0, trace);
```

After: `skynet.core.callback(func)` stores a registry ref on the `LuaActor`.

```cpp
void LuaActor::set_callback_ref(int ref) {
    if (callback_ref_ != LUA_NOREF) {
        luaL_unref(L_, LUA_REGISTRYINDEX, callback_ref_);
    }
    callback_ref_ = ref;
    has_callback_ = callback_ref_ != LUA_NOREF;
}

lua_rawgeti(L_, LUA_REGISTRYINDEX, callback_ref_);
lua_pcall(L_, 5, 0, trace);
```

### 13. LuaActor Traceback Registry Ref

Before: traceback setup had to be reconstructed or looked up for dispatch.

```cpp
lua_pushcfunction(L, traceback);
// arrange traceback stack slot during dispatch
```

After: traceback is stored once as a registry ref and loaded by integer ref.

```cpp
lua_pushcfunction(L_, traceback);
traceback_ref_ = luaL_ref(L_, LUA_REGISTRYINDEX);

lua_rawgeti(L_, LUA_REGISTRYINDEX, traceback_ref_);
int trace = lua_gettop(L_);
```

### 14. `skynet.core` Actor Pointer Closure Upvalue

Before: every C API call looked up `skynet_actor` from the registry by string.

```cpp
static LuaActor* get_actor(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, "skynet_actor");
    auto* actor = static_cast<LuaActor*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return actor;
}
```

After: `skynet.core` functions are installed as closures with the actor pointer
as an upvalue; registry lookup remains only as a compatibility fallback.

```cpp
static LuaActor* get_actor(lua_State* L) {
    if (lua_type(L, lua_upvalueindex(1)) == LUA_TLIGHTUSERDATA) {
        return static_cast<LuaActor*>(lua_touserdata(L, lua_upvalueindex(1)));
    }
    lua_getfield(L, LUA_REGISTRYINDEX, "skynet_actor");
    auto* actor = static_cast<LuaActor*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return actor;
}

// module setup pseudocode
lua_pushlightuserdata(L, actor);
lua_pushcclosure(L, lsend, 1);
lua_setfield(L, module, "send");
```

### 15. `c.unpacktrash` Hot-Path Payload Unpack

Before: Lua protocol payloads were unpacked first and freed through a separate
cleanup path.

```lua
local lua_protocol = {
    name = "lua",
    id = PTYPE_LUA,
    unpack = c.unpack,
    dispatch = dispatch,
}
```

After: Lua protocol uses `unpacktrash`, which unpacks and frees the payload.

```lua
local lua_protocol = {
    name = "lua",
    id = PTYPE_LUA,
    unpack = c.unpacktrash,
    dispatch = dispatch,
}
```

### 16. Remove Redundant Lua-Level `pcall`

Before: `LuaActor::on_message` already called the callback through
`lua_pcall`, and Lua wrapped every message in another `pcall`.

```lua
function skynet.dispatch_message(...)
    local ok, err = pcall(raw_dispatch_message, ...)
    if not ok then
        skynet.error(err)
    end
end
```

After: dispatch directly enters the raw dispatcher; the error boundary remains
in C++.

```lua
function skynet.dispatch_message(...)
    raw_dispatch_message(...)
end
```

### 17. Public Lua API Behavior Preserved

The user-facing API did not change. The optimization only changed internal
pack/unpack, callback, and actor-context access paths.

```lua
local r = skynet.call(worker, "lua", "ping", 1)
skynet.send(worker, "lua", "fire", 2)
skynet.rawsend(worker, "lua", msg, sz)
skynet.retpack("ok", r)
```

Internally:

```text
public API same
  -> fewer Lua frames
  -> cached callback/traceback refs
  -> cached actor pointer upvalue
  -> direct unpacktrash for Lua payload
```

Not retained:

- native-like keep-current queue dispatch
- literal native worker weight table
- raw queue / payload rewrites that did not move the measured bottleneck

## Final Actor-Heavy Data

Label: `after-final-rpc-actor-linux`

Environment:

- Debian bookworm Docker
- Release build
- native skynet with `-DNOUSE_JEMALLOC`
- actor-heavy only
- 4 iterations
- iteration 1 warmup discarded
- median calculated from iterations 2, 3, 4

| impl | threads | iter | rpc/s | pass |
| --- | ---: | ---: | ---: | --- |
| cpp | 8 | 1 | 213,333.33 | PASS |
| cpp | 8 | 2 | 206,451.61 | PASS |
| cpp | 8 | 3 | 177,777.78 | PASS |
| cpp | 8 | 4 | 188,235.29 | PASS |
| native | 8 | 1 | 200,000.00 | PASS |
| native | 8 | 2 | 182,857.14 | PASS |
| native | 8 | 3 | 200,000.00 | PASS |
| native | 8 | 4 | 188,235.29 | PASS |
| cpp | 16 | 1 | 220,689.66 | PASS |
| cpp | 16 | 2 | 228,571.43 | PASS |
| cpp | 16 | 3 | 246,153.85 | PASS |
| cpp | 16 | 4 | 177,777.78 | PASS |
| native | 16 | 1 | 188,235.29 | PASS |
| native | 16 | 2 | 188,235.29 | PASS |
| native | 16 | 3 | 172,972.97 | PASS |
| native | 16 | 4 | 172,972.97 | PASS |
| cpp | 32 | 1 | 206,451.61 | PASS |
| cpp | 32 | 2 | 193,939.39 | PASS |
| cpp | 32 | 3 | 220,689.66 | PASS |
| cpp | 32 | 4 | 164,102.56 | PASS |
| native | 32 | 1 | 188,235.29 | PASS |
| native | 32 | 2 | 182,857.14 | PASS |
| native | 32 | 3 | 168,421.05 | PASS |
| native | 32 | 4 | 193,939.39 | PASS |

Final median comparison:

| threads | skynet-cpp rpc/s | native skynet rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 188,235.29 | 188,235.29 | 100.0% |
| 16 | 228,571.43 | 172,972.97 | 132.1% |
| 32 | 193,939.39 | 182,857.14 | 106.1% |

## Correctness Verification

Windows verification completed after the final retained changes:

- Debug build: PASS
- logic suite: PASS
- stress suite: PASS

Representative stress actor line after final changes:

```text
[stress] actor: 6400 rpc + 16000 fire messages in 0.16s, rpc 40000/s
```

Representative successful suite endings:

```text
[unit] PASS: unit coverage suite completed
[stress] PASS: stress suite completed
```

Linux perf actor-heavy completed successfully:

- cpp 8/16/32: PASS
- native 8/16/32: PASS

Full coverage gate was not rerun in the final performance-only pass.

## Important Tradeoffs

### Idle Spin Uses CPU

The final optimization intentionally spends some user-space CPU before sleeping:

```text
8 threads  -> spin 256
16 threads -> spin 64
32 threads -> spin 0
```

This is good for actor-heavy RPC because it avoids repeated futex wakeups. It is
not universally free:

- idle CPU usage can increase under low traffic
- if future workloads are mostly long-blocking I/O, spin should be revisited
- if thread count is much higher than CPU core count, spin should likely be
  reduced or disabled

The current values are benchmark-driven, not theoretical constants.

### Native Comparison Is Not Perfectly Apples-to-Apples

The native skynet comparison used `-DNOUSE_JEMALLOC`. A native build with
jemalloc may move the baseline. If strict production comparison is required,
rerun after initializing native skynet jemalloc.

### Full-Matrix Variance

Actor-heavy numbers have visible run-to-run variance. This is expected because:

- Docker scheduling adds noise
- native and cpp are run in the same Docker environment but not pinned to cores
- benchmark timing uses coarse Lua-side centisecond time
- iteration count is small to keep iteration time practical

For final release qualification, run more iterations and pin CPU affinity.

## Current Bottlenecks

After this pass, the remaining actor RPC cost is mostly:

- Lua VM call/coroutine execution (`luaD_precall`, `luaV_execute`,
  `luaB_coresume`)
- `skynet.core.send` C boundary
- residual syscall/futex wakeup under 8-thread RPC pressure

The bottleneck is no longer:

- single actor registry lock
- callback registry string lookup
- redundant Lua dispatch `pcall`
- global queue handle lookup per dispatch
- socket store lock

## Future Optimization Candidates

Only pursue these if new benchmark data shows regression or a higher target is
required.

1. CPU affinity and benchmark stabilization

   Pin Docker/native/cpp runs to fixed cores before making smaller decisions.

2. Lua coroutine fast path

   The remaining profile is dominated by Lua VM dispatch and coroutine resume.
   This is harder to optimize without changing semantics.

3. Specialized C API for packed Lua response

   `skynet.retpack(...)` currently goes through Lua pack then `c.send`. A fused
   `core.retpack` style API might save one Lua/C boundary for RPC responses.
   This should be measured carefully because serialization itself was not the
   top cost in the current profile.

4. Adaptive idle spin

   Replace fixed `8 -> 256`, `16 -> 64`, `32 -> 0` with adaptive spin based on
   recent queue hit rate and sleep/wakeup frequency.

5. Native jemalloc comparison

   Initialize native skynet's jemalloc submodule and rerun the same benchmark.

6. Longer perf gate

   Run 10 or 20 iterations, discard warmup, compare median and p95. The current
   4-iteration final actor pass is sufficient for this optimization checkpoint
   but not a full release performance gate.

## Reproduction Commands

Windows Debug build:

```bat
cmake --build build --config Debug --parallel
```

Windows logic suite:

```bat
set SKYNET_PRELOAD=tests/logic/preload.lua
set SKYNET_THREAD=8
build\Debug\skynet-cpp.exe
```

Windows stress suite:

```bat
set SKYNET_PRELOAD=tests/stress/preload.lua
set SKYNET_THREAD=8
build\Debug\skynet-cpp.exe
```

Linux full perf runner:

```bat
tools\run_linux_perf_in_docker.bat ^
  --label linux-perf ^
  --thread-counts 8,16,32 ^
  --iterations 5 ^
  --timeout-seconds 600
```

The final actor-only comparison was run with the same Docker build pattern but
limited to actor-heavy to shorten iteration time.

## Summary

The optimization succeeded because it followed profile data rather than just
copying native skynet literally.

What worked:

- move toward native-like queue ownership and scheduling state
- remove high-frequency registry string lookup
- cache Lua callback refs
- reduce global queue wakeup syscalls
- avoid premature worker sleep in low thread-count RPC benchmarks

What did not work:

- keeping the current actor queue instead of requeueing
- literal native worker weight table
- payload rewrites before wakeup behavior was fixed

Final actor-heavy throughput is at or above the 90% native target for 8, 16, and
32 threads under the current Docker benchmark.
