# DebugConsole
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었습니다. runtime 저장소는 최소 verify/package/package smoke/Linux coverage smoke 도구만 보관하고, full coverage, perf, Docker DB, soak, native 비교는 상위 `testa/tools` 계층에서 관리합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 디버그 콘솔 및 디버그 프로토콜

---

## 디버그 프로토콜

모든 Lua 서비스는 자동으로 `PTYPE_DEBUG` 프로토콜을 등록하며, 다음 디버그 명령이 내장되어 있습니다:

| 명령 | 설명 |
|---|---|
| `MEM` | 현재 Lua VM 메모리 사용량 반환 (KB) |
| `GC` | 가비지 컬렉션 실행, 메모리 변화 보고 |
| `STAT` | 태스크 수, 메시지 큐 길이, CPU 통계 반환 |
| `TASK` | 태스크 코루틴 스택 정보 반환 |
| `INFO` | 서비스에 등록된 `info_func` 콜백을 호출하여 사용자 정의 정보 가져오기 |
| `EXIT` | 서비스 정상 종료 |
| `PING` | 생존 감지 (즉시 응답) |
| `RUN` | Lua 코드를 주입하여 실행 |

### 사용자 정의 디버그 명령 등록

```lua
local skynet = require "skynet"
require "skynet.debug"

-- 사용자 정의 INFO 콜백 등록
skynet.info_func(function(...)
    return { state = "running", connections = 42 }
end)

-- 사용자 정의 디버그 명령 등록
local debug = require "skynet.debug"
debug.reg_debugcmd("CUSTOM", function(...)
    return "custom result"
end)
```

---

## 디버그 콘솔

`debug_console.lua`는 TCP telnet 인터페이스를 제공하며, 연결 후 대화형으로 디버그 명령을 실행할 수 있습니다.

### 시작

```lua
-- preload.lua에서 디버그 콘솔 시작
local console = skynet.newservice("debug_console", "127.0.0.1", "8000")
```

### 연결

```bash
telnet 127.0.0.1 8000
```

### 콘솔 명령

| 명령 | 파라미터 | 설명 |
|---|---|---|
| `help` | — | 모든 명령 나열 |
| `list` | — | 실행 중인 모든 서비스 나열 |
| `mem` | [timeout] | 모든 서비스의 메모리 상태 조회 |
| `gc` | [timeout] | 모든 서비스에 GC 실행 |
| `stat` | [timeout] | 모든 서비스의 통계 정보 조회 |
| `ping` | address | 서비스 생존 여부 확인 |
| `info` | address, ... | 서비스 사용자 정의 정보 가져오기 |
| `exit` | address | 지정한 서비스 정상 종료 |
| `kill` | address | 지정한 서비스 강제 종료 |
| `start` | name, ... | 새 Lua 서비스 시작 |
| `inject` | address, code | 서비스에 Lua 코드 주입하여 실행 |

---

## Profile 성능 분석

```lua
local profile = require "skynet.profile"
```

`lua_profile.cpp` C 모듈을 통해 코루틴 수준의 CPU 타이밍을 제공합니다:

| 함수 | 설명 |
|---|---|
| `profile.start([co])` | 코루틴 타이밍 시작 (기본값: 현재 스레드) |
| `profile.stop([co])` | 타이밍 중지, CPU 시간 반환 (초) |
| `profile.resume(co, ...)` | 타이밍 포함 coroutine.resume |
| `profile.wrap(f)` | 타이밍 포함 코루틴 래퍼 생성 |

```lua
profile.start()
-- 계산 집약적 작업 수행
local cpu_time = profile.stop()
print(string.format("CPU time: %.6f seconds", cpu_time))
```

---

## 원본 skynet과의 차이점

- 디버그 프로토콜 명령 세트 기본적으로 동일
- 원본에는 `signal` 기능 (무한 루프 Lua 코드 중단)이 있으나, skynet-cpp는 아직 미구현
- 원본에는 `skynet.trace()` 메시지 추적 로그가 있으나, skynet-cpp는 아직 미구현

