# GettingStarted
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`；runtime 仓库只保留最小 verify/package/package smoke/Linux coverage smoke，full coverage、perf、Docker DB、soak 和 native 对比由父级 `testa/tools` 管理。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 入门指南

---

## 框架

skynet-cpp 是一个轻量级的 Actor 模型服务端框架。你可以把它理解为一个简单的操作系统，它可以用来调度数千个 Lua 虚拟机，让它们并行工作。每个 Lua 虚拟机都可以接收处理其它虚拟机发送过来的消息，以及对其它虚拟机发送消息。

skynet-cpp 内置了对外部网络数据输入和定时器的管理，会把这些转换为一致的消息输入给各个服务。

### 与原版 skynet 的关系

skynet-cpp 的设计理念和 API 语义完全来源于 [cloudwu/skynet](https://github.com/cloudwu/skynet)，但使用 C++20 重新实现了底层框架。对于 Lua 开发者来说，API 用法与原版 skynet 基本一致。

---

## 服务 (Service)

skynet-cpp 的服务使用 Lua 编写。只需要把符合规范的 `.lua` 文件放在 skynet-cpp 可以找到的路径下就可以由其它服务启动。每个服务拥有一个唯一的 32bit 地址（handle），由框架分配。

每个服务分三个运行阶段：

1. **加载阶段**：服务源文件被加载执行。此阶段**不可**调用任何阻塞 API。
2. **初始化阶段**：由 `skynet.start(func)` 注册的初始化函数执行。此阶段可以调用任何 skynet API。启动该服务的 `skynet.newservice` 会等待初始化完成。
3. **工作阶段**：初始化完成后，注册了消息处理函数的服务开始响应消息。

```lua
local skynet = require "skynet"

-- 加载阶段：设置模块级变量
local CMD = {}

function CMD.hello(...)
    return "world"
end

skynet.start(function()
    -- 初始化阶段：注册消息分发
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd])
        skynet.retpack(f(...))
    end)
end)
```

---

## 消息 (Message)

每条 skynet-cpp 消息由以下元素构成：

1. **session**：由发起请求的服务生成的唯一标识。回应方在回应时带回 session，发送方据此匹配请求与回应。session 为 0 表示不需要回应（单向推送）。
2. **source**：消息来源的服务地址（32bit handle）。
3. **type**：消息类别。最常用的是 `"lua"`，用于 Lua 服务间通讯。
4. **message + size**：消息内容（C 指针 + 长度），由序列化函数生成。

### 消息类型

| 类型 | 名称 | 用途 |
|---|---|---|
| 0 | `text` | 纯文本消息 |
| 1 | `response` | RPC 应答 |
| 6 | `socket` | 网络事件 |
| 7 | `error` | 错误通知 |
| 10 | `lua` | Lua 序列化消息（最常用）|

---

## 协程调度

从底层看，每个服务就是一个消息处理器。但在应用层，它利用 Lua 的 coroutine 工作。

当你的服务向另一个服务发送一个请求（`skynet.call`）后，当前协程会被挂起。待对方收到请求并做出回应后，框架会找到挂起的协程，把回应信息传入，延续之前未完的业务流程。从使用者角度看，更像是一个独立线程在处理业务。

**重入注意**：一个服务在某个业务流程被挂起后，仍然可以处理其他消息。所以，在 `skynet.call` 之前获得的服务内部状态，到返回后很可能已经改变。两次阻塞 API 调用之间的运行过程是原子的。可以使用 [CriticalSection](CriticalSection.md) 来减少伪并发带来的复杂性。

---

## 网络

skynet-cpp 内置了网络层，封装了 TCP 和 UDP 功能。不建议在服务中使用任何直接和系统网络 API 打交道的模块，因为一旦被网络 IO 阻塞，影响的是整个工作线程。

使用 skynet-cpp 内置的 [Socket](Socket.md) API 可以在网络 IO 阻塞时完全释放 CPU 处理能力。

推荐使用 [GateServer](GateServer.md) 网关服务来管理客户端接入。

---

## 外部服务

skynet-cpp 提供了 [Redis](ExternalService.md#redis-驱动)、[MySQL](ExternalService.md#mysql-驱动)、[MongoDB](ExternalService.md#mongodb-驱动) 的驱动模块。这些驱动模块都是基于 [SocketChannel](SocketChannel.md) 实现的，可以很好地与 skynet-cpp 协同工作。

---

## 集群

skynet-cpp 实现了 cluster 模式来支持跨节点 RPC。详见 [Cluster](Cluster.md)。

不同于原版 skynet，skynet-cpp **不支持** master/slave 模式（harbor 模式），推荐全部使用 cluster 模式。

---

## 与原版 skynet 的差异

- **不支持** master/slave (harbor) 模式
- **不支持** Snax 框架
- **不支持** Sproto 协议
- **不支持** DataCenter（已废弃）
- ShareData 使用消息传递深拷贝，而非 C 共享内存
- 使用 Lua 5.5.0（原版使用 Lua 5.4）
- 数据库驱动（BSON/SHA1）全部为纯 Lua 实现

