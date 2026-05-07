# Bootstrap

## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

## 개요

C++ 엔트리포인트는 최소 bootstrap만 수행합니다. `ActorSystem` 생성, logger 시작, 환경 변수 읽기, preload LuaActor 시작 후 worker/IO/monitor loop에 진입합니다. launcher는 C++에 하드코딩되지 않으며 preload 스크립트가 `skynet.newservice("launcher")`로 명시적으로 시작합니다.

## 환경 변수

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `SKYNET_THREAD` | `8` | worker thread 수 |
| `SKYNET_PRELOAD` | `examples/preload.lua` | preload script 경로 |

## 시작 흐름

```text
main()
  -> read SKYNET_THREAD / SKYNET_PRELOAD
  -> ActorSystem workers=N
  -> spawn<ServiceLogger>()
  -> spawn<LuaActor>(preload)
  -> preload configures paths and starts launcher
  -> preload starts example, logic, stress, perf, or application service
  -> system.run()
```

## preload 책임

preload는 유일한 시작 orchestration 엔트리입니다. 일반적으로 다음을 수행합니다.

- `skynet.appendpath` / `skynet.prependpath`로 Lua module path 설정.
- `skynet.appendcpath`로 C module path 설정.
- `skynet.appendservicepath`로 service search path 설정.
- `launcher` 시작.
- application, example, logic, stress, perf 진입 service 시작.

## 스레드 모델

| Thread | 수 | 역할 |
| --- | ---: | --- |
| Worker | `SKYNET_THREAD` | global queue에서 `ActorQueue`를 꺼내 weighted batch로 message dispatch |
| IO | 1 | network IO와 timer를 위한 `asio::io_context` 실행 |
| Monitor | 1 | 같은 message에서 오래 멈춘 worker 감지 |

## preload 예시

```lua
local skynet = require "skynet"

skynet.appendpath("lualib")
skynet.appendservicepath("service")
skynet.appendservicepath("examples")

skynet.start(function()
    skynet.newservice("launcher")
    skynet.newservice("main")
end)
```

## 관련 엔트리

- Example: `examples/preload.lua`
- Logic tests: `tests/logic/preload.lua`
- Stress tests: `tests/stress/preload.lua`
- Performance tests: `tests/perf/preload.lua`
