# CodeCache
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었습니다. runtime 저장소는 최소 verify/package/package smoke/Linux coverage smoke 도구만 보관하고, full coverage, perf, Docker DB, soak, native 비교는 상위 `testa/tools` 계층에서 관리합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> Lua 5.5 코드 캐시 메커니즘

---

## 개요

skynet-cpp는 skynet 수정 버전 Lua 5.5.0을 사용하며, **codecache** 메커니즘을 포함합니다. 이 메커니즘은 다수의 Lua VM (즉, 다수의 서비스)이 컴파일된 Lua 함수 프로토타입 (Proto)을 공유할 수 있게 하여:

1. **메모리 절약**: 동일 스크립트의 바이트코드를 한 번만 컴파일
2. **시작 가속화**: 이후 VM이 동일 스크립트를 로드할 때 직접 재사용하여 재파싱 불필요

---

## 작동 원리

Lua 서비스가 `loadfile`을 통해 스크립트를 로드할 때:

1. **최초 로드**: 정상적으로 컴파일하고, 컴파일된 함수 프로토타입을 전역 캐시에 저장
2. **이후 로드**: 캐시에서 직접 함수 프로토타입을 클론하여 컴파일 단계 건너뛰기

핵심 C API 확장:
- `lua_clonefunction(L, proto)` — 공유 프로토타입에서 새 클로저 생성
- `lua_sharefunction(L, index)` — 함수 프로토타입을 공유 풀에 추가

---

## skynet-cpp에서의 사용

`loader.lua`에서 codecache는 기본적으로 비활성화되어 있습니다 (`cache.mode("OFF")`). 그 이유는:

- skynet-cpp의 각 `LuaActor`는 독립적인 `lua_State`를 가지며, 각 VM의 `_ENV`가 완전히 격리됨
- codecache가 활성화되면 다수의 VM이 동일한 컴파일된 Proto를 공유하지만, 각 VM의 전역 환경 (`_ENV`)이 다름. Proto에서 `require` 등의 전역 함수를 참조할 때 `_ENV`가 잘못된 VM을 가리키는 문제 발생
- codecache 비활성화 후 각 VM이 독립적으로 스크립트를 컴파일하여 `_ENV`가 올바르게 지정됨

```lua
-- loader.lua
local cache = require "cache"
cache.mode("OFF")  -- 공유 캐시 비활성화
```

---

## 수동 제어

특정 순수 함수 스크립트가 `_ENV`에 의존하지 않음을 확인한 경우 선택적으로 캐시를 활성화할 수 있습니다:

```lua
local cache = require "cache"

-- 현재 모드 조회
local mode = cache.mode()

-- 모드 설정: ON / OFF
cache.mode("ON")   -- 공유 캐시 활성화
cache.mode("OFF")  -- 공유 캐시 비활성화
```

---

## 원본 skynet과의 차이점

- 원본 skynet은 codecache가 기본 활성화이며, skynet-cpp는 기본 비활성화
- 원본은 `require "skynet.codecache"`로 제어 인터페이스를 얻지만, skynet-cpp는 `require "cache"`로 제어
- 원본은 `codecache.clear()`로 캐시 지우기를 제공하지만, skynet-cpp는 아직 미지원

