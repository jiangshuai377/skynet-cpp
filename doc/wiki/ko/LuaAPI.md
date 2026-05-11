# LuaAPI
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었습니다. runtime 저장소는 최소 verify/package/package smoke/Linux coverage smoke 도구만 보관하고, full coverage, perf, Docker DB, soak, native 비교는 상위 `testa/tools` 계층에서 관리합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet Lua 서비스 API 레퍼런스

---

```lua
local skynet = require "skynet"
```

모든 skynet-cpp 서비스는 `skynet` 모듈을 임포트해야 합니다. 이 모듈은 skynet-cpp 프레임워크 외부에서는 사용할 수 없습니다.

---

## 서비스 주소

각 서비스는 32bit 숫자 주소 (handle)를 가집니다.

- `skynet.self()` — 현재 서비스 주소 반환
- `skynet.address(addr)` — 주소를 읽기 쉬운 문자열로 변환 (`:xxxxxxxx` 형식)
- `skynet.register(name)` — 현재 서비스에 별칭 등록 (`.`으로 시작하면 로컬 이름)
- `skynet.name(name, handle)` — 지정한 handle의 서비스에 별칭 등록
- `skynet.localname(name)` — 로컬 이름에 대응하는 주소 조회 (논블로킹)

서비스 주소를 받는 모든 API 파라미터에 문자열 별칭을 전달할 수 있습니다.

---

## 메시지 디스패치 및 응답

### skynet.dispatch(type, func)

특정 타입 메시지의 처리 함수를 등록합니다. 가장 일반적인 사용법:

```lua
local CMD = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    local f = assert(CMD[cmd])
    f(...)
end)
```

### skynet.register_protocol(class)

새로운 메시지 카테고리를 등록합니다. class는 `name`, `id`, `pack`, `unpack` 필드를 제공해야 합니다.

### skynet.ret(msg, sz)

현재 요청 소스에 메시지를 응답합니다. 동일한 메시지 처리 coroutine에서 한 번만 호출할 수 있습니다.

### skynet.retpack(...)

`skynet.ret(skynet.pack(...))`의 단축 형태입니다.

### skynet.response([packfunc])

지연 응답 클로저를 생성하며, 이후 다른 코루틴에서 호출할 수 있습니다.

```lua
local resp = skynet.response()
-- 이후 다른 곳에서 호출:
resp(true, result1, result2)   -- 정상 응답
resp(false)                     -- 요청자에게 예외 발생
```

---

## 메시지 푸시 및 원격 호출

### skynet.send(addr, typename, ...)

addr에 typename 타입의 메시지를 전송합니다. 논블로킹 API이며, 메시지는 pack 함수로 패킹됩니다.

### skynet.call(addr, typename, ...)

addr에 요청을 보내고 응답을 블로킹 대기합니다. 응답은 unpack으로 언패킹된 후 반환됩니다. **주의**: `skynet.call`은 현재 코루틴만 블로킹하며, 서비스는 다른 메시지에 계속 응답할 수 있습니다.

### skynet.rawsend(addr, typename, msg, sz)

원시 전송, pack 패킹을 거치지 않습니다.

### skynet.rawcall(addr, typename, msg, sz)

원시 RPC 호출, pack/unpack을 거치지 않습니다.

### skynet.redirect(addr, source, typename, session, ...)

source 주소로 위장하여 addr에 메시지를 전송합니다.

---

## 시간 및 스레드

내부 시계 정밀도는 1/100초 (센티초)입니다.

- `skynet.now()` — 프로세스 시작 후 경과 시간 반환 (센티초)
- `skynet.starttime()` — 프로세스 시작 UTC 시간 반환 (초)
- `skynet.time()` — 현재 UTC 시간 반환 (초, 정밀도 10ms)

### skynet.sleep(ti)

현재 코루틴을 ti 센티초 동안 일시 중단합니다. `"BREAK"` 반환은 `wakeup`에 의해 깨어났음을 의미합니다.

### skynet.yield()

`skynet.sleep(0)`과 동일합니다. CPU 제어권을 양보합니다.

### skynet.timeout(ti, func)

ti 센티초 후 새 코루틴에서 func을 실행합니다. 논블로킹 API입니다.

### skynet.fork(func, ...)

새 코루틴을 시작하여 func을 실행합니다. `timeout(0, ...)`보다 효율적입니다 (타이머를 거치지 않음).

### skynet.wait(token)

현재 코루틴을 일시 중단하고 `wakeup` 깨우기를 대기합니다. token의 기본값은 `coroutine.running()`입니다.

### skynet.wakeup(token)

`sleep` 또는 `wait`로 일시 중단된 코루틴을 깨웁니다.

---

## 서비스 시작 및 종료

### skynet.start(func)

서비스 시작 함수를 등록합니다. **반드시 호출해야** 하며, 서비스의 진입점입니다.

### skynet.exit()

현재 서비스를 종료합니다. 이후 코드는 실행되지 않으며, 일시 중단된 코루틴도 중단됩니다.

### skynet.newservice(name, ...)

새로운 Lua 서비스를 시작합니다. 블로킹 API로, 시작된 서비스의 `start` 함수가 반환된 후에야 반환됩니다.

### skynet.uniqueservice(name, ...)

유일한 서비스를 시작합니다. 이미 시작되어 있으면 기존 주소를 반환합니다.

### skynet.queryservice(name)

유일한 서비스 주소를 조회합니다. 아직 시작되지 않았으면 대기합니다.

## Path Configuration

These APIs are normally called from the preload script. Each argument is a plain directory path; the runtime normalizes `/`, `\`, duplicate separators, and trailing separators, then expands Lua/C module or service search rules internally. Newly created LuaActors inherit the current global path snapshot.

- `skynet.appendpath(path)` — Append a Lua module directory, expanded to `path/?.lua` and `path/?/init.lua`.
- `skynet.prependpath(path)` — Prepend a Lua module directory.
- `skynet.appendcpath(path)` — Append a C module directory, expanded to the platform `.dll` or `.so` search pattern.
- `skynet.appendservicepath(path)` — Append a service script directory, expanded to `path/?.lua`.
- `skynet.getpath()` — Return the current `{ path, cpath, service_path }` snapshot.
- `skynet.getcwd()` — Return the process current working directory for preload logging and path debugging.
- `skynet.setpathbase(path)` — Set the relative base used by path APIs without changing the OS cwd.
- `skynet.getpathbase()` — Return the current pathbase.
- `skynet.readfile(path)` / `skynet.writefile(path, data, append)` — Controlled file read/write helpers that resolve paths from pathbase.
- `skynet.systemstat()` — Return process-level runtime stats such as actor count, global queue backlog, and worker count.

---

## 직렬화

- `skynet.pack(...)` — Lua 값을 `(lightuserdata, size)`로 직렬화
- `skynet.unpack(msg, sz)` — Lua 값으로 역직렬화
- `skynet.packstring(...)` — Lua string으로 직렬화
- `skynet.tostring(msg, sz)` — lightuserdata를 Lua string으로 변환
- `skynet.trash(msg, sz)` — lightuserdata 버퍼 해제

지원 타입: string, boolean, number, lightuserdata, table (메타테이블 제외).

---

## 로깅

### skynet.error(...)

파라미터를 연결한 후 logger 서비스로 전송합니다. 출력 형식: `[HH:MM:SS.mmm][HANDLE][ERROR] message`

---

## 상태 조회

- `skynet.info_func(func)` — 내부 상태 조회 함수를 등록하며, debug 프로토콜 호출에 사용
- `skynet.stat(what)` — 서비스 내부 상태 조회: `"endless"`, `"mqlen"`, `"message"`, `"cpu"`

---

## 기타

- `skynet.getenv(key)` — 환경 변수 읽기
- `skynet.setenv(key, value)` — 환경 변수 설정 (덮어쓰기 불가)
- `skynet.genid()` — 고유 session 생성
- `skynet.harbor(addr)` — 항상 0 반환 (skynet-cpp는 harbor 미지원)

---

## 원본 skynet과의 차이점

- `skynet.harbor()`는 항상 0 반환
- `skynet.forward_type` 및 `skynet.filter` 미지원 (고급 메시지 포워딩)
- `skynet.memlimit`는 `start` 이전에 호출해야 함
- 환경 변수는 설정 파일이 아닌 `ActorSystem`을 통해 전달


