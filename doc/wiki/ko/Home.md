# skynet-cpp Wiki
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> **skynet-cpp** — 현대 C++20으로 재구현한 [Skynet](https://github.com/cloudwu/skynet) Actor 프레임워크

---

## 환영합니다

skynet-cpp는 경량 Actor 모델 서버 프레임워크로, 설계 철학과 API 의미론은 [cloudwu/skynet](https://github.com/cloudwu/skynet)에서 비롯되었습니다. 프레임워크는 skynet의 핵심 추상화 — **각 서비스는 독립적인 Actor이며 비동기 메시지를 통해 통신** — 를 유지하면서, 현대 C++의 언어 기능과 크로스 플랫폼 생태계를 활용하여 타입 안전성, RAII 리소스 관리 및 플랫폼 독립성을 제공합니다.

skynet-cpp에 대해 전혀 모르신다면 먼저 [GettingStarted](GettingStarted.md)를 읽어보세요. skynet-cpp 자체가 복잡하지 않으므로 소스 코드도 함께 읽어보시길 권장합니다.

[Build](Build.md) skynet-cpp는 매우 간단하며, 직접 컴파일해서 실행해 보는 것이 좋은 시작입니다. 직접 2차 개발을 하고 싶다면 [Bootstrap](Bootstrap.md)을 이해하는 것부터 시작할 수 있습니다.

skynet-cpp의 핵심은 C++로 작성되었지만, 단순히 사용하기만 한다면 C++ 기초가 필요하지 않습니다. Actor 패턴의 작동 방식을 이해하고 비즈니스 로직을 여러 서비스로 분할하여 협업하면 됩니다. Lua가 필수 개발 언어이며, Lua만 알면 [LuaAPI](LuaAPI.md)를 사용하여 서비스 간 통신 협력을 완료할 수 있습니다. 서비스 간 데이터 공유는 메시지 전달 방식 외에도 [ShareData](ShareData.md)를 참조할 수 있습니다.

클라이언트에 서비스를 제공하려면 [Socket](Socket.md) API를 사용하거나, 이미 작성된 [GateServer](GateServer.md) 템플릿을 사용하여 대량의 클라이언트 접속 문제를 해결할 수 있습니다. [SocketChannel](SocketChannel.md)을 통해 skynet-cpp가 외부 소켓 이벤트를 비동기적으로 스케줄링할 수 있습니다. 데이터베이스 등의 [외부 서비스](ExternalService.md)에 접근할 때는 SocketChannel로 래핑하는 것이 가장 좋습니다.

skynet-cpp가 이미 제공하는 기능은 [APIList](APIList.md)를 참조하세요.

---

## 문서 색인

### 입문

| 문서 | 설명 |
|---|---|
| [GettingStarted](GettingStarted.md) | 프레임워크 개념, Actor 모델, 메시지 메커니즘, 빠른 시작 |
| [Build](Build.md) | 빌드 단계 (CMake + MSVC/GCC/Clang) |
| [Bootstrap](Bootstrap.md) | 시작 흐름: main.cpp → ActorSystem → preload |

### 핵심 API

| 문서 | 설명 |
|---|---|
| [LuaAPI](LuaAPI.md) | skynet.lua 전체 API 레퍼런스 |
| [Socket](Socket.md) | TCP/UDP Socket API |
| [GateServer](GateServer.md) | TCP 게이트웨이 템플릿 + netpack 패킷 분할 |
| [SocketChannel](SocketChannel.md) | TCP 연결 멀티플렉싱 |

### 클러스터 및 분산

| 문서 | 설명 |
|---|---|
| [Cluster](Cluster.md) | 크로스 노드 RPC 클러스터 |

### 데이터 및 서비스 간 통신

| 문서 | 설명 |
|---|---|
| [ShareData](ShareData.md) | 공유 읽기 전용 데이터 |
| [CriticalSection](CriticalSection.md) | 메시지 직렬화 큐 (의사 동시성 방지) |
| [Multicast](Multicast.md) | 발행/구독 메시지 |

### 디버그 및 도구

| 문서 | 설명 |
|---|---|
| [DebugConsole](DebugConsole.md) | 디버그 콘솔 + 디버그 프로토콜 |
| [CodeCache](CodeCache.md) | Lua 5.5 코드 캐시 메커니즘 |

### 외부 서비스

| 문서 | 설명 |
|---|---|
| [ExternalService](ExternalService.md) | Redis / MySQL / MongoDB 드라이버 |

### 참조

| 문서 | 설명 |
|---|---|
| [APIList](APIList.md) | 모든 모듈 API 빠른 참조표 |

---

## 원본 skynet과의 주요 차이점

| 차원 | 원본 Skynet (C + Lua) | skynet-cpp (C++20) |
|---|---|---|
| **언어** | 순수 C 구현 | C++20 (RAII + `std::shared_ptr`) |
| **플랫폼** | Linux 전용 (epoll) | 크로스 플랫폼 (Asio: Windows/Linux/macOS) |
| **타입 안전성** | `void*` 메시지 | `std::any` + `msg.get<T>()` |
| **동시성 원어** | 자체 spinlock | `moodycamel::ConcurrentQueue` 락프리 큐 |
| **비동기 IO** | 자체 socket server | Asio + `steady_timer` |
| **Lua 버전** | Lua 5.4 | Lua 5.5.0 (codecache 포함) |
| **빌드 시스템** | Makefile (GCC) | CMake 3.20+ (MSVC/GCC/Clang) |
| **harbor 모드** | master/slave 지원 | 미지원 (cluster 모드만 지원) |
| **Snax** | 지원 | 미지원 |
| **Sproto** | 지원 | 미지원 |
| **DataCenter** | 지원 | 미지원 (폐기됨) |
| **ShareData** | C 공유 메모리 | 메시지 전달 딥카피 (기능 동등) |
| **데이터베이스 드라이버** | C 모듈 포함 | 순수 Lua 구현 (BSON/SHA1 모두 순수 Lua) |

