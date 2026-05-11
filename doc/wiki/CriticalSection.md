# CriticalSection
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`；runtime 仓库只保留最小 verify/package/package smoke/Linux coverage smoke，full coverage、perf、Docker DB、soak 和 native 对比由父级 `testa/tools` 管理。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 消息序列化队列

---

```lua
local queue = require "skynet.queue"
```

同一个 skynet-cpp 服务中的一条消息处理中，如果调用了一个阻塞 API（如 `skynet.call`），那么它会被挂起。挂起过程中，这个服务可以响应其它消息。这很可能造成时序问题，要非常小心处理。

换句话说，一旦你的消息处理过程有外部请求，那么先到的消息未必比后到的先处理完。每个阻塞调用之后，服务的内部状态都未必和调用前一致。

`skynet.queue` 模块可以帮助你回避这些伪并发引起的复杂性。

---

## 使用方法

```lua
local queue = require "skynet.queue"

local cs = queue()  -- cs 是一个执行队列

local CMD = {}

function CMD.foobar()
    cs(func1)  -- func1 进入临界区
end

function CMD.foo()
    cs(func2)  -- func2 进入临界区
end
```

如果你使用 `cs` 这个队列，那么 `func1` 和 `func2` 不会在执行过程中相互被打断。

如果服务收到多条 `foobar` 或 `foo` 消息，一定是处理完一条后才处理下一条，即使 `func1` 或 `func2` 中有 `skynet.call` 这类的阻塞调用。

---

## 可重入

在 func1 函数内部再调用 cs 是合法的（不会死锁）：

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

每次收到 foobar 消息后，程序流程会按 step 1 → 2 → 3 → 4 → 5 执行。

---

## 实现原理

queue 通过以下机制实现 FIFO 调度：

- `current_thread`：记录当前持有锁的协程
- `ref` 引用计数：支持同一协程的嵌套调用（可重入）
- `thread_queue` 等待队列：新请求排入队列尾部
- 利用 `skynet.wait()` / `skynet.wakeup()` 实现协程间的挂起和唤醒

---

## 与原版 skynet 的差异

- API 完全一致
- 实现方式一致（基于 skynet.wait/wakeup）

