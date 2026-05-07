# skynet-cpp Actor RPC 性能优化记录

日期：2026-05-03

本文记录 `skynet-cpp` 最近一轮 Actor RPC 性能优化全过程。目标很明确：在高并发场景下，actor RPC 和调度吞吐至少达到原生 skynet 的 90%，同时保持逻辑测试、压力测试和现有 Lua API 语义不破坏。

最终 Linux Docker actor-heavy benchmark 达成目标：

| 线程数 | skynet-cpp rpc/s | 原生 skynet rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 188,235.29 | 188,235.29 | 100.0% |
| 16 | 228,571.43 | 172,972.97 | 132.1% |
| 32 | 193,939.39 | 182,857.14 | 106.1% |

## 优化范围

本轮只聚焦 actor 消息发送、调度、RPC 和 Lua/C++ 边界：

- Lua `skynet.call`、`skynet.send`、`skynet.retpack`
- `skynet.core.send` / `genid` C 绑定边界
- C++ `ActorSystem::send`、`push_message`、`schedule_queue`
- actor registry 查找
- global queue 调度和 worker 唤醒
- LuaActor callback 分发
- Lua packed payload 传递和释放

Socket 在早期 Linux 对比里已经明显快于原生 skynet，因此后续没有继续把 socket 作为主攻方向。

## Benchmark 口径

性能测试从逻辑测试和压力测试中拆出，使用独立入口：

- `tests/perf/preload.lua`
- `tests/perf/test_perf.lua`
- `tests/perf/perf_worker.lua`
- `tools/run_perf_benchmark.ps1`
- `tools/run_linux_perf_in_docker.ps1`

actor-heavy profile 固定为：

- 64 个 worker 服务
- 每个 worker 1000 次 `skynet.call`
- 每个 worker 2000 次 fire-and-forget `skynet.send`
- 线程数：8、16、32
- Release 构建
- 第 1 轮作为 warmup，不计入 median

Linux 对比会在 Debian bookworm Docker 里同时构建：

- `skynet-cpp` Release
- `/work/resource/skynet` 下的原生 skynet

原生 skynet 构建命令：

```text
make linux MALLOC_STATICLIB= SKYNET_DEFINES=-DNOUSE_JEMALLOC
```

原因是本地 native skynet checkout 没有初始化 jemalloc submodule。因此该对比不是完整 jemalloc 生产构建，但足够作为本轮优化红线。

## 原生 skynet 参考点

原生 skynet 的 actor 调度路径很短：

- global queue 存服务消息队列，而不是服务 id
- 每个服务队列有状态位，避免重复进入 global queue
- worker 弹出队列后按权重处理一批消息，队列仍有消息则重新入队
- message queue 生命周期和 service context 生命周期分离
- Lua callback 分发在 `lua-skynet.c` 中路径紧凑
- message payload 是明确的 pointer/size，不走通用类型擦除容器

本轮最重要的结论不是简单“少加锁”，而是避免每个 batch 反复做 registry lookup、全局队列查找和内核唤醒。

## 初始 Baseline

早期高并发 actor benchmark 暴露明显差距：

- 64 workers、每 worker 1000 call + 2000 fire、8 runtime threads：早期 Windows baseline 一度 300 秒超时。
- 64 workers、每 worker 100 call、0 fire、8 runtime threads：重复 repro 中 20 秒超时。
- 16 workers、每 worker 1000 call、0 fire、8 runtime threads：约 47,058 rpc/s。

第一轮完整 Linux 原生对比显示 actor-heavy 明显落后：

| 线程数 | 原生 rpc/s | skynet-cpp rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 114,285.71 | 42,105.26 | 36.8% |
| 16 | 136,170.21 | 38,323.35 | 28.1% |
| 32 | 120,754.72 | 35,164.84 | 29.1% |

同时 socket-heavy 已经明显超过 native：

| profile | 线程数 | native | skynet-cpp | cpp/native |
| --- | ---: | ---: | ---: | ---: |
| socket-heavy | 8 | 7,619.05 | 20,983.61 | 275.4% |
| socket-heavy | 16 | 6,719.16 | 23,703.70 | 352.8% |
| socket-heavy | 32 | 7,013.70 | 22,654.87 | 323.0% |

因此后续优化集中在 actor RPC 和调度路径。

## 优化过程

### 1. 低风险运行时清理

保留的低风险修改：

- `ActorSystem::error()` 缓存 logger handle，减少 names lock。
- 缩短 socket store 锁持有时间。
- socket write/close/pause/resume 尽量在锁外执行。

结果：socket 保持强势，actor RPC 仍未达标。

### 2. Actor Registry 分片

原先 actor 查找集中在单个 registry mutex/map 上，`send` 和 dispatch 都会争用同一个结构。

修改：

- 固定 shard registry。
- handle hash 决定 shard。
- `spawn`、`kill`、`grab_queue`、`actor_count` 只锁相关 shard。

结果：降低 registry 竞争，scheduler-heavy 改善，但 actor RPC 仍被 queue/wakeup 成本拖住。

### 3. ActorQueue 拆分

参考原生 skynet，把 mailbox 和调度状态从 Actor 对象中拆出。

修改：

- 新增内部 `ActorQueue`。
- mailbox、mailbox_count、overload threshold、accepting/releasing、schedule_state 都进入 `ActorQueue`。
- registry 存 `shared_ptr<ActorQueue>`。
- global queue 存 `ActorQueue`，不再存 handle。
- Actor owner 由 queue 安全引用。
- kill 从 registry 移除 queue，标记 releasing，由 worker 负责 drain/drop pending message。

ActorQueue 后 scheduler-heavy 已经接近或超过 native，但 actor-heavy 仍不足：

| 线程数 | native rpc/s | skynet-cpp rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 114,285.71 | 65,979.38 | 57.7% |
| 16 | 136,170.21 | 61,538.46 | 45.2% |
| 32 | 120,754.72 | 58,181.82 | 48.2% |

### 4. Raw Queue 和 MessagePayload 实验

尝试过：

- raw queue 变体
- `MessagePayload` / variant 风格 payload
- 更轻的消息数据包装

结论：收益小且不稳定，复杂度上升但没有命中主瓶颈，未作为最终方案保留。

### 5. Lua Dispatch Fast Path

保留修改：

- Lua 协议 payload 使用 `c.unpacktrash`。
- 移除每条消息上额外的 Lua 层 `pcall(raw_dispatch_message, ...)`。

原因：`LuaActor::on_message` 已经用 `lua_pcall` 调 callback，Lua 层每条消息再包一层 `pcall` 是重复开销。

### 6. LuaActor Callback Ref 缓存

旧路径每条消息会通过字符串从 registry 取 callback。新路径：

- `skynet.core.callback(func)` 把 callback 存成 Lua registry ref。
- `LuaActor::on_message` 使用 `lua_rawgeti` 取 callback ref。
- traceback function 也缓存成 registry ref。
- `on_destroy` 释放 callback 和 traceback ref。

结果：去掉每消息 registry 字符串查找。

### 7. Native-Like Keep-Current Queue 实验

尝试过 worker 持有当前 `ActorQueue`，global queue 空时继续处理当前 queue，减少 enqueue + wakeup。

结论：正确性通过，但性能退化，尤其 32 线程下并行度下降。最终没有保留。当前实现仍采用 batch 后 requeue，保持公平性和并行性。

### 8. Global Queue Wakeup 重构

修改：

- global queue 使用 `moodycamel::ConcurrentQueue<std::shared_ptr<ActorQueue>>`。
- 增加 `global_queue_epoch_`，使用 C++20 `atomic::wait/notify`。
- 增加 `sleeping_workers_`，只有有 sleeping worker 时才 notify。
- batch 后 queue 仍有消息则 requeue。

中间结果：

| 线程数 | skynet-cpp rpc/s | native rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 128,000.00 | 182,857.14 | 70.0% |
| 16 | 168,421.05 | 182,857.14 | 92.1% |
| 32 | 193,939.39 | 188,235.29 | 103.0% |

16/32 达标，8 线程仍未达标。

### 9. Native Weight Table 实验

尝试直接使用原生 skynet 的 worker weight 表。

结论：在当前 C++ runtime 中 16/32 线程变差，因此回退到 quarter-based 策略：

- 前 1/4 worker：weight -1
- 第二 1/4：weight 0
- 第三 1/4：weight 1
- 最后 1/4：weight 2

### 10. skynet.core Upvalue 缓存

旧 C API 每次调用都从 registry 通过字符串取 `skynet_actor`。新实现：

- `luaopen_skynet_core` 手动创建 module table。
- 加载模块时读取一次 `skynet_actor`。
- 所有 C 函数安装为带 actor pointer upvalue 的 closure。
- `get_actor(L)` 优先读 upvalue，保留 registry fallback。

结果：`send/genid/timeout/self/newservice` 等高频 C API 避免重复 registry 字符串查找。

### 11. Wakeup Throttling 和 Idle Spin

profile 显示 8 线程主要热点变成：

- `lsend -> ActorSystem::send -> syscall`
- worker 过早进入 `atomic_wait`
- 发送端频繁 futex wakeup

修改：

- 增加 `global_queue_count_` 近似计数。
- 只有 queued work 数量不足以覆盖 sleeping workers 时才 `notify_one`。
- worker 真正 `atomic_wait` 前做短暂用户态 spin。
- spin 按线程数调节：
  - 8 threads：256
  - 16 threads：64
  - 32 threads：0

原因：

- 8 线程最容易因短暂空队列进入睡眠，spin 能避免内核 wakeup。
- 16 线程有中等收益。
- 32 线程开启 spin 会抢占真实 Lua 执行 CPU，因此关闭。

## Profile 关键结论

早期 profile：

- `LuaActor::on_message`：约 60%
- `lua_pcall/luaD_pcall/luaV_execute`：约 58%
- `lsend`：约 14%
- `push_message`：约 12.6%

upvalue 缓存后 8 线程 profile：

- `lsend`：约 22.86%
- `ActorSystem::send`：约 22.14%
- `send` 下 syscall：约 18.48%
- `push_message`：约 3.22%
- `grab_queue`：低于 1%
- `luaseri_pack`：约 0.89%

最终 8 线程 profile：

- `luaD_precall`：约 26.14%
- `lsend`：约 19.87%
- `lsend` 下 syscall：约 15.13%
- `atomic_wait`：约 5.61%
- `__sched_yield`：约 7.43%

结论：最终主要成本已转为 Lua VM/coroutine 执行和残余 send/wakeup 成本，不再是单个 registry lock、callback 字符串查找或 global queue handle lookup。

## 最终保留的修改

C++ runtime 保留了以下修改。每一项都列出“修改前 → 修改后”的代码形态；上下文过长的地方使用等价伪代码。

### 1. Actor registry 分片

修改前：所有 actor/queue 查找集中在单个 map 和一把锁上，`send`、`kill`、`actor_count` 都争用同一处。

```cpp
std::shared_mutex actors_mutex_;
std::unordered_map<uint32_t, std::shared_ptr<Actor>> actors_;

std::shared_ptr<Actor> grab(uint32_t handle) {
    std::shared_lock lock(actors_mutex_);
    return actors_[handle];
}
```

修改后：registry 固定分成 64 个 shard，handle 决定落点，只锁目标 shard。

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

### 2. `ActorQueue` 拆分

修改前：mailbox、是否进全局队列、调度状态都绑在 `Actor` 上，生命周期和服务对象耦合。

```cpp
class Actor {
    ConcurrentQueue<Message> mailbox_;
    std::atomic<bool> in_global_;
    std::atomic<size_t> mailbox_count_;
};
```

修改后：mailbox 和调度状态独立成 `ActorQueue`，`Actor` 只保留服务逻辑和 session/lifecycle 状态。

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

### 3. Global queue 存 `shared_ptr<ActorQueue>`

修改前：global queue 存 handle，worker 每次弹出后还要重新查 registry。

```cpp
ConcurrentQueue<uint32_t> global_queue_;

worker_loop() {
    uint32_t handle = pop_global();
    auto actor = grab(handle);      // 每个 batch 都查 registry
    dispatch(actor);
}
```

修改后：global queue 直接存 queue 对象，worker 弹出后可直接 dispatch。

```cpp
moodycamel::ConcurrentQueue<std::shared_ptr<ActorQueue>> global_queue_;

worker_loop() {
    std::shared_ptr<ActorQueue> queue;
    if (global_queue_.try_dequeue(queue)) {
        dispatch_queue(queue, weight, monitor);
    }
}
```

### 4. Queue 生命周期独立于 actor owner

修改前：actor 被 kill 后，如果 global queue 或 mailbox 中仍有消息，需要依赖 actor 对象继续存在，否则容易出现悬空生命周期或丢失错误回应。

```cpp
kill(handle) {
    erase_actor(handle);
    // pending message 的 drain/drop 依赖 actor 是否还活着
}
```

修改后：registry 移除的是 queue 的可达性；queue 自己标记 releasing，worker 负责 drain/drop pending message。需要回应的 request 会给 source 回 `PTYPE_ERROR`。

```cpp
kill(handle) {
    auto queue = erase_queue_from_shard(handle);
    queue->accepting.store(false);
    queue->releasing.store(true);
    schedule_queue(queue);          // 让 worker 做最终 drain/drop
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

### 5. Logger handle cache

修改前：每次 `ActorSystem::error()` 都通过名字表找 logger，错误路径会碰 `names_mutex_`。

```cpp
void ActorSystem::error(uint32_t source, const char* fmt, ...) {
    uint32_t logger = query_name("logger"); // names_mutex_
    send(source, logger, PTYPE_TEXT, 0, text);
}
```

修改后：logger handle 用 atomic 缓存；只有第一次或缓存未命中时才回到名字表。

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

### 6. Socket store 锁缩短

修改前：socket 表锁内完成查表和真实 IO 操作，慢 IO 会拉长锁持有时间。

```cpp
std::lock_guard lock(store.mutex);
auto conn = store.connections[id];
conn->send(data);       // 锁内做实际 send
conn->close();          // 锁内做实际 close
```

修改后：锁内只复制 `shared_ptr` 或状态，实际 send/close/pause/resume 放到锁外执行。

```cpp
std::shared_ptr<TcpConnection> conn;
{
    std::lock_guard lock(store.mutex);
    conn = find_connection(id);
}

if (conn) {
    conn->send(data);   // 锁外执行
}
```

### 7. `ConcurrentQueue` global queue

修改前：global queue 如果用 mutex/condition_variable 或普通队列，会在高并发 push/pop 上形成中心锁。

```cpp
std::mutex global_mutex;
std::queue<uint32_t> global_queue;

push_global(handle) {
    std::lock_guard lock(global_mutex);
    global_queue.push(handle);
}
```

修改后：global queue 使用 moodycamel MPMC queue，push/pop 热路径无全局互斥锁。

```cpp
moodycamel::ConcurrentQueue<std::shared_ptr<ActorQueue>> global_queue_;

enqueue_global(queue) {
    global_queue_.enqueue(queue);
}

try_dequeue_global(queue) {
    return global_queue_.try_dequeue(queue);
}
```

### 8. Atomic epoch wait/notify

修改前：worker 空转或使用条件变量等待，唤醒路径需要额外 mutex/condvar 协作。

```cpp
if (global_queue.empty()) {
    condvar.wait(lock);
}
```

修改后：使用 C++20 `atomic::wait/notify`，以 `global_queue_epoch_` 作为唤醒版本号。

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

### 9. Sleeping worker count

修改前：enqueue 时无法知道是否真的有 worker 在睡眠，容易每次投递都 notify，产生无效 futex wakeup。

```cpp
enqueue_global(queue) {
    global_queue_.enqueue(queue);
    global_queue_epoch_.notify_one(); // 不管有没有 sleeping worker
}
```

修改后：worker 睡前递增 `sleeping_workers_`，enqueue 只有发现有人睡眠时才考虑 notify。

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

### 10. Global queue count wakeup throttling

修改前：只要有 sleeping worker 就 notify，短时间内多个 producer 会制造过多 wakeup。

```cpp
if (sleeping_workers_ > 0) {
    notify_one();
}
```

修改后：维护近似 `global_queue_count_`，只有 queued work 数量不足以覆盖 sleeping worker 时才唤醒。

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

### 11. 按线程数调节 idle spin

修改前：global queue 短暂为空时 worker 立即进入 `atomic_wait`，8 线程 actor RPC 容易频繁进入内核等待/唤醒。

```cpp
if (!try_dequeue_global()) {
    atomic_wait(epoch);
}
```

修改后：少线程时睡前做短暂用户态 spin；32 线程关闭 spin，避免抢占 Lua 执行 CPU。

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

### 12. LuaActor callback registry ref

修改前：每条消息通过字符串从 registry 取 callback。

```cpp
lua_getfield(L, LUA_REGISTRYINDEX, "skynet_callback");
lua_pcall(L, 5, 0, trace);
```

修改后：`skynet.core.callback(func)` 注册时保存 registry ref；每条消息用整数 ref 读取。

```cpp
void LuaActor::set_callback_ref(int ref) {
    if (callback_ref_ != LUA_NOREF) {
        luaL_unref(L_, LUA_REGISTRYINDEX, callback_ref_);
    }
    callback_ref_ = ref;
    has_callback_ = callback_ref_ != LUA_NOREF;
}

// on_message
lua_rawgeti(L_, LUA_REGISTRYINDEX, callback_ref_);
lua_pcall(L_, 5, 0, trace);
```

### 13. LuaActor traceback registry ref

修改前：traceback function 也需要重复构造或查找。

```cpp
lua_pushcfunction(L, traceback);
// 每次 dispatch 临时整理 traceback 栈位置
```

修改后：初始化时把 traceback 保存为 registry ref，dispatch 时直接 `lua_rawgeti`。

```cpp
lua_pushcfunction(L_, traceback);
traceback_ref_ = luaL_ref(L_, LUA_REGISTRYINDEX);

// on_message
lua_rawgeti(L_, LUA_REGISTRYINDEX, traceback_ref_);
int trace = lua_gettop(L_);
```

### 14. `skynet.core` actor pointer closure upvalue

修改前：每个 C API 调用都通过字符串从 registry 取当前 `LuaActor*`。

```cpp
static LuaActor* get_actor(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, "skynet_actor");
    auto* actor = static_cast<LuaActor*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return actor;
}
```

修改后：加载 `skynet.core` 时创建带 actor pointer upvalue 的 closure；`get_actor` 优先读 upvalue，registry 只作为 fallback。

```cpp
static LuaActor* get_actor(lua_State* L) {
    if (lua_type(L, lua_upvalueindex(1)) == LUA_TLIGHTUSERDATA) {
        return static_cast<LuaActor*>(lua_touserdata(L, lua_upvalueindex(1)));
    }
    // fallback for compatibility
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

Lua runtime 保留了以下修改。

### 15. `c.unpacktrash` hot-path payload unpack

修改前：Lua 协议先 unpack，再由其他路径释放 lightuserdata，热路径多一次显式清理责任。

```lua
local lua_protocol = {
    name = "lua",
    id = PTYPE_LUA,
    unpack = c.unpack,
    dispatch = dispatch,
}
```

修改后：Lua 协议使用 `unpacktrash`，解包后立即释放 payload。

```lua
local lua_protocol = {
    name = "lua",
    id = PTYPE_LUA,
    unpack = c.unpacktrash,
    dispatch = dispatch,
}
```

### 16. 移除每条消息额外 Lua `pcall`

修改前：C++ `LuaActor::on_message` 已经 `lua_pcall` 调 callback，Lua 层又对每条消息包一层 `pcall`。

```lua
function skynet.dispatch_message(...)
    local ok, err = pcall(raw_dispatch_message, ...)
    if not ok then
        skynet.error(err)
    end
end
```

修改后：每条消息直接进入 raw dispatch；错误边界保留在 C++ `lua_pcall`。

```lua
function skynet.dispatch_message(...)
    raw_dispatch_message(...)
end
```

### 17. 公开 Lua API 语义保持不变

修改前后用户层 API 不变，优化只发生在内部 pack/unpack、callback 和 C API 获取 actor context 的路径上。

```lua
-- 修改前后业务代码都保持一致
local r = skynet.call(worker, "lua", "ping", 1)
skynet.send(worker, "lua", "fire", 2)
skynet.rawsend(worker, "lua", msg, sz)
skynet.retpack("ok", r)
```

对应的内部变化是：

```text
public API same
  -> fewer Lua frames
  -> cached callback/traceback refs
  -> cached actor pointer upvalue
  -> direct unpacktrash for Lua payload
```

没有保留：

- keep-current queue dispatch
- 原生 worker weight table 的字面移植
- 未命中瓶颈的 raw queue / payload rewrite

## 最终 Actor-Heavy 数据

Label：`after-final-rpc-actor-linux`

环境：

- Debian bookworm Docker
- Release build
- native skynet 使用 `-DNOUSE_JEMALLOC`
- actor-heavy only
- 4 轮，丢弃第 1 轮 warmup
- median 使用第 2/3/4 轮

| impl | 线程数 | 轮次 | rpc/s | 结果 |
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

最终 median：

| 线程数 | skynet-cpp rpc/s | native skynet rpc/s | cpp/native |
| ---: | ---: | ---: | ---: |
| 8 | 188,235.29 | 188,235.29 | 100.0% |
| 16 | 228,571.43 | 172,972.97 | 132.1% |
| 32 | 193,939.39 | 182,857.14 | 106.1% |

## 正确性验证

Windows 验证：

- Debug build：PASS
- logic suite：PASS
- stress suite：PASS

Linux perf actor-heavy：

- cpp 8/16/32：PASS
- native 8/16/32：PASS

本轮性能收尾没有重新跑 full coverage gate。

## 重要取舍

### Idle Spin 会消耗 CPU

最终实现故意在 worker 进入睡眠前消耗少量用户态 CPU：

```text
8 threads  -> spin 256
16 threads -> spin 64
32 threads -> spin 0
```

这对 actor-heavy RPC 有利，但不是免费优化：

- 低流量下 idle CPU 可能升高。
- 如果未来主要 workload 是长时间阻塞 IO，应重新评估。
- 如果线程数远大于 CPU core，spin 应降低或关闭。

### Native 对比不是完全等价

原生 skynet 使用 `-DNOUSE_JEMALLOC`。如果需要严格生产对比，应初始化 native skynet 的 jemalloc submodule 后重新跑。

### 数据有波动

Actor-heavy 数据有可见波动，原因包括：

- Docker 调度噪声
- 未 pin CPU affinity
- Lua 侧计时是 centisecond 粒度
- 最终轮次较少，主要用于优化 checkpoint

发布级性能门禁建议跑更多轮并固定 CPU affinity。

## 后续可选优化

只有在出现新性能目标或回归时再做：

1. 固定 CPU affinity，让 benchmark 更稳定。
2. 继续分析 Lua coroutine fast path。
3. 考虑 fused `core.retpack`，减少 RPC response 的 Lua/C 边界。
4. 将固定 idle spin 改成自适应策略。
5. 初始化 native skynet jemalloc 后重跑对比。
6. 增加 10-20 轮 perf gate，统计 median 和 p95。

## 复现命令

Windows Debug build：

```powershell
cmake --build build --config Debug --parallel
```

Windows logic suite：

```powershell
$env:SKYNET_PRELOAD='tests/logic/preload.lua'
$env:SKYNET_THREAD='8'
.\build\Debug\skynet-cpp.exe
```

Windows stress suite：

```powershell
$env:SKYNET_PRELOAD='tests/stress/preload.lua'
$env:SKYNET_THREAD='8'
.\build\Debug\skynet-cpp.exe
```

Linux full perf runner：

```powershell
.\tools\run_linux_perf_in_docker.ps1 `
  -Label linux-perf `
  -ThreadCounts 8,16,32 `
  -Iterations 5 `
  -TimeoutSeconds 600
```

## 总结

本轮优化成功的关键是按 profile 数据推进，而不是机械照搬原生 skynet。

有效的方向：

- 走向 native-like 的 queue ownership 和 schedule state
- 移除高频 registry 字符串查找
- callback ref 缓存
- 减少 global queue wakeup syscall
- 避免低线程 RPC 场景下 worker 过早睡眠

无效或未保留的方向：

- worker 持有当前 queue 不 requeue
- 字面照搬 native worker weight table
- 在 wakeup 问题修复前重写 payload

当前 Docker benchmark 下，actor-heavy 8/16/32 线程都达到或超过原生 skynet 90% 目标。
