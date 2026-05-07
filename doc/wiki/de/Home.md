# skynet-cpp Wiki
## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; Coverage und Linux-Docker-Performance haben eigene Runner. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

> **skynet-cpp** — A modern C++20 reimplementation of the [Skynet](https://github.com/cloudwu/skynet) Actor Framework

---

## Welcome

skynet-cpp is a lightweight Actor-model server framework with design philosophy and API semantics derived from [cloudwu/skynet](https://github.com/cloudwu/skynet). The framework preserves skynet's core abstraction — **each service is an independent Actor communicating via asynchronous messages** — while leveraging modern C++ features for type safety, RAII resource management, and platform independence.

If you know nothing about skynet-cpp, start by reading [GettingStarted](GettingStarted.md). Since skynet-cpp is not particularly complex, reading the source code is also recommended.

[Build](Build.md)ing skynet-cpp is very simple — compiling and playing with it is a great way to begin. To start with secondary development, begin by understanding the [Bootstrap](Bootstrap.md) process.

Although skynet-cpp's core is written in C++, basic usage does not require C++ knowledge. You need to understand the Actor pattern and split your business logic into cooperating services. Lua is the required development language — you only need to know Lua to use the [LuaAPI](LuaAPI.md) for inter-service communication. For shared data between services, besides message passing, see [ShareData](ShareData.md).

To serve external clients, use the [Socket](Socket.md) API, or the ready-made [GateServer](GateServer.md) template for high-volume client connections. [SocketChannel](SocketChannel.md) allows skynet-cpp to asynchronously dispatch external socket events. Accessing [external services](ExternalService.md) like databases is best done through SocketChannel wrappers.

See [APIList](APIList.md) for all available functionality.

---

## Documentation Index

### Getting Started

| Document | Description |
|---|---|
| [GettingStarted](GettingStarted.md) | Framework concepts, Actor model, message mechanism, quick start |
| [Build](Build.md) | Build steps (CMake + MSVC/GCC/Clang) |
| [Bootstrap](Bootstrap.md) | Startup flow: main.cpp → ActorSystem → preload |

### Core API

| Document | Description |
|---|---|
| [LuaAPI](LuaAPI.md) | skynet.lua complete API reference |
| [Socket](Socket.md) | TCP/UDP Socket API |
| [GateServer](GateServer.md) | TCP gateway template + netpack framing |
| [SocketChannel](SocketChannel.md) | TCP connection multiplexing |

### Cluster & Distributed

| Document | Description |
|---|---|
| [Cluster](Cluster.md) | Cross-node RPC cluster |

### Data & Inter-service Communication

| Document | Description |
|---|---|
| [ShareData](ShareData.md) | Shared read-only data |
| [CriticalSection](CriticalSection.md) | Message serialization queue (avoid pseudo-concurrency) |
| [Multicast](Multicast.md) | Publish/subscribe messaging |

### Debug & Tools

| Document | Description |
|---|---|
| [DebugConsole](DebugConsole.md) | Debug console + debug protocol |
| [CodeCache](CodeCache.md) | Lua 5.5 code cache mechanism |

### External Services

| Document | Description |
|---|---|
| [ExternalService](ExternalService.md) | Redis / MySQL / MongoDB drivers |

### Reference

| Document | Description |
|---|---|
| [APIList](APIList.md) | Complete API quick reference |

---

## Key Differences from Original skynet

| Dimension | Original Skynet (C + Lua) | skynet-cpp (C++20) |
|---|---|---|
| **Language** | Pure C | C++20 (RAII + `std::shared_ptr`) |
| **Platform** | Linux only (epoll) | Cross-platform (Asio: Windows/Linux/macOS) |
| **Type Safety** | `void*` messages | `std::any` + `msg.get<T>()` |
| **Concurrency** | Custom spinlock | `moodycamel::ConcurrentQueue` lock-free queue |
| **Async IO** | Custom socket server | Asio + `steady_timer` |
| **Lua Version** | Lua 5.4 | Lua 5.5.0 (with codecache) |
| **Build System** | Makefile (GCC) | CMake 3.20+ (MSVC/GCC/Clang) |
| **Harbor Mode** | master/slave supported | Not supported (cluster mode only) |
| **Snax** | Supported | Not supported |
| **Sproto** | Supported | Not supported |
| **DataCenter** | Supported | Not supported (deprecated) |
| **ShareData** | C shared memory | Message passing deep copy (functionally equivalent) |
| **DB Drivers** | Include C modules | Pure Lua implementation (BSON/SHA1 are pure Lua) |
# skynet-cpp Wiki

> **skynet-cpp** — A modern C++20 reimplementation of the [Skynet](https://github.com/cloudwu/skynet) Actor Framework

---

## Welcome

skynet-cpp is a lightweight Actor-model server framework with design philosophy and API semantics derived from [cloudwu/skynet](https://github.com/cloudwu/skynet). The framework preserves skynet's core abstraction — **each service is an independent Actor communicating via asynchronous messages** — while leveraging modern C++ features for type safety, RAII resource management, and platform independence.

If you know nothing about skynet-cpp, start by reading [GettingStarted](GettingStarted.md). Since skynet-cpp is not particularly complex, reading the source code is also recommended.

[Build](Build.md)ing skynet-cpp is very simple — compiling and playing with it is a great way to begin. To start with secondary development, begin by understanding the [Bootstrap](Bootstrap.md) process.

Although skynet-cpp's core is written in C++, basic usage does not require C++ knowledge. You need to understand the Actor pattern and split your business logic into cooperating services. Lua is the required development language — you only need to know Lua to use the [LuaAPI](LuaAPI.md) for inter-service communication. For shared data between services, besides message passing, see [ShareData](ShareData.md).

To serve external clients, use the [Socket](Socket.md) API, or the ready-made [GateServer](GateServer.md) template for high-volume client connections. [SocketChannel](SocketChannel.md) allows skynet-cpp to asynchronously dispatch external socket events. Accessing [external services](ExternalService.md) like databases is best done through SocketChannel wrappers.

See [APIList](APIList.md) for all available functionality.

---

## Documentation Index

### Getting Started

| Document | Description |
|---|---|
| [GettingStarted](GettingStarted.md) | Framework concepts, Actor model, message mechanism, quick start |
| [Build](Build.md) | Build steps (CMake + MSVC/GCC/Clang) |
| [Bootstrap](Bootstrap.md) | Startup flow: main.cpp → ActorSystem → preload |

### Core API

| Document | Description |
|---|---|
| [LuaAPI](LuaAPI.md) | skynet.lua complete API reference |
| [Socket](Socket.md) | TCP/UDP Socket API |
| [GateServer](GateServer.md) | TCP gateway template + netpack framing |
| [SocketChannel](SocketChannel.md) | TCP connection multiplexing |

### Cluster & Distributed

| Document | Description |
|---|---|
| [Cluster](Cluster.md) | Cross-node RPC cluster |

### Data & Inter-service Communication

| Document | Description |
|---|---|
| [ShareData](ShareData.md) | Shared read-only data |
| [CriticalSection](CriticalSection.md) | Message serialization queue (avoid pseudo-concurrency) |
| [Multicast](Multicast.md) | Publish/subscribe messaging |

### Debug & Tools

| Document | Description |
|---|---|
| [DebugConsole](DebugConsole.md) | Debug console + debug protocol |
| [CodeCache](CodeCache.md) | Lua 5.5 code cache mechanism |

### External Services

| Document | Description |
|---|---|
| [ExternalService](ExternalService.md) | Redis / MySQL / MongoDB drivers |

### Reference

| Document | Description |
|---|---|
| [APIList](APIList.md) | Complete API quick reference |

---

## Key Differences from Original skynet

| Dimension | Original Skynet (C + Lua) | skynet-cpp (C++20) |
|---|---|---|
| **Language** | Pure C | C++20 (RAII + `std::shared_ptr`) |
| **Platform** | Linux only (epoll) | Cross-platform (Asio: Windows/Linux/macOS) |
| **Type Safety** | `void*` messages | `std::any` + `msg.get<T>()` |
| **Concurrency** | Custom spinlock | `moodycamel::ConcurrentQueue` lock-free queue |
| **Async IO** | Custom socket server | Asio + `steady_timer` |
| **Lua Version** | Lua 5.4 | Lua 5.5.0 (with codecache) |
| **Build System** | Makefile (GCC) | CMake 3.20+ (MSVC/GCC/Clang) |
| **Harbor Mode** | master/slave supported | Not supported (cluster mode only) |
| **Snax** | Supported | Not supported |
| **Sproto** | Supported | Not supported |
| **DataCenter** | Supported | Not supported (deprecated) |
| **ShareData** | C shared memory | Message passing deep copy (functionally equivalent) |
| **DB Drivers** | Include C modules | Pure Lua implementation (BSON/SHA1 are pure Lua) |

