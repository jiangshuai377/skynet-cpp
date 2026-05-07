# skynet-cpp Wiki
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> **skynet-cpp** — 用现代 C++20 重新实现的 [Skynet](https://github.com/cloudwu/skynet) Actor 框架

---

## 欢迎

skynet-cpp 是一个轻量级的 Actor 模型服务端框架，其设计理念和 API 语义来源于 [cloudwu/skynet](https://github.com/cloudwu/skynet)。框架保持了 skynet 的核心抽象——**每个服务是一个独立 Actor，通过异步消息通信**，同时利用现代 C++ 的语言特性和跨平台生态带来类型安全、RAII 资源管理和平台无关性。

如果你对 skynet-cpp 毫无了解，那么可以先阅读 [GettingStarted](GettingStarted.md)。由于 skynet-cpp 本身并不复杂，同时建议你阅读一下源代码。

[Build](Build.md) skynet-cpp 非常简单，动手编译一个试着玩一下是个很好的开始。如果你想自己动手做二次开发，你可以从理解 [Bootstrap](Bootstrap.md) 开始。

虽然 skynet-cpp 的核心是由 C++ 编写，但如果只是简单使用，并不要求 C++ 基础。你需要理解 Actor 模式的工作方式，把你的业务拆分成多个服务来协同工作。Lua 是必要的开发语言，你只需要懂得 Lua 就可以使用 [LuaAPI](LuaAPI.md) 来完成服务间的通讯协作。关于服务间共享数据，除了用消息传递的方式外，还可以参考 [ShareData](ShareData.md)。

要做到给客户端提供服务，需要使用 [Socket](Socket.md) API，或者使用已经编写好的 [GateServer](GateServer.md) 模板解决大量客户端接入的问题。通过 [SocketChannel](SocketChannel.md) 可以让 skynet-cpp 异步调度外部 socket 事件。访问诸如数据库等 [外部服务](ExternalService.md)，最好通过 SocketChannel 封装。

skynet-cpp 已提供的功能可以参考 [APIList](APIList.md)。

---

## 文档索引

### 入门

| 文档 | 说明 |
|---|---|
| [GettingStarted](GettingStarted.md) | 框架概念、Actor 模型、消息机制、快速上手 |
| [Build](Build.md) | 构建步骤（CMake + MSVC/GCC/Clang） |
| [Bootstrap](Bootstrap.md) | 启动流程：main.cpp → ActorSystem → preload |

### 核心 API

| 文档 | 说明 |
|---|---|
| [LuaAPI](LuaAPI.md) | skynet.lua 完整 API 参考 |
| [Socket](Socket.md) | TCP/UDP Socket API |
| [GateServer](GateServer.md) | TCP 网关模板 + netpack 分包 |
| [SocketChannel](SocketChannel.md) | TCP 连接多路复用 |

### 集群与分布式

| 文档 | 说明 |
|---|---|
| [Cluster](Cluster.md) | 跨节点 RPC 集群 |

### 数据与服务间通信

| 文档 | 说明 |
|---|---|
| [ShareData](ShareData.md) | 共享只读数据 |
| [CriticalSection](CriticalSection.md) | 消息序列化队列（避免伪并发） |
| [Multicast](Multicast.md) | 发布/订阅消息 |

### 调试与工具

| 文档 | 说明 |
|---|---|
| [DebugConsole](DebugConsole.md) | 调试控制台 + 调试协议 |
| [CodeCache](CodeCache.md) | Lua 5.5 代码缓存机制 |

### 外部服务

| 文档 | 说明 |
|---|---|
| [ExternalService](ExternalService.md) | Redis / MySQL / MongoDB 驱动 |

### 参考

| 文档 | 说明 |
|---|---|
| [APIList](APIList.md) | 所有模块 API 速查表 |

---

## 与原版 skynet 的主要差异

| 维度 | 原版 Skynet (C + Lua) | skynet-cpp (C++20) |
|---|---|---|
| **语言** | 纯 C 实现 | C++20（RAII + `std::shared_ptr`） |
| **平台** | 仅 Linux（epoll） | 跨平台（Asio：Windows/Linux/macOS）|
| **类型安全** | `void*` 消息 | `std::any` + `msg.get<T>()` |
| **并发原语** | 自研 spinlock | `moodycamel::ConcurrentQueue` 无锁队列 |
| **异步 IO** | 自研 socket server | Asio + `steady_timer` |
| **Lua 版本** | Lua 5.4 | Lua 5.5.0（含 codecache） |
| **构建系统** | Makefile (GCC) | CMake 3.20+ (MSVC/GCC/Clang) |
| **harbor 模式** | 支持 master/slave | 不支持（仅 cluster 模式） |
| **Snax** | 支持 | 不支持 |
| **Sproto** | 支持 | 不支持 |
| **DataCenter** | 支持 | 不支持（已废弃） |
| **ShareData** | C 共享内存 | 消息传递深拷贝（功能等价） |
| **数据库驱动** | 含 C 模块 | 纯 Lua 实现（BSON/SHA1 均为纯 Lua） |

