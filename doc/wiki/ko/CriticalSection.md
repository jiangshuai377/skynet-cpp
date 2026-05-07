# CriticalSection
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 메시지 직렬화 큐

---

```lua
local queue = require "skynet.queue"
```

동일한 skynet-cpp 서비스 내에서 하나의 메시지 처리 중에 블로킹 API (예: `skynet.call`)를 호출하면 일시 중단됩니다. 중단되는 동안 이 서비스는 다른 메시지에 응답할 수 있습니다. 이로 인해 순서 문제가 발생할 수 있으므로 매우 주의해서 처리해야 합니다.

다시 말해, 메시지 처리 과정에 외부 요청이 있으면 먼저 도착한 메시지가 반드시 먼저 처리 완료되는 것은 아닙니다. 각 블로킹 호출 후 서비스의 내부 상태가 호출 전과 달라질 수 있습니다.

`skynet.queue` 모듈은 이러한 의사 동시성으로 인한 복잡성을 회피하는 데 도움을 줍니다.

---

## 사용 방법

```lua
local queue = require "skynet.queue"

local cs = queue()  -- cs는 실행 큐

local CMD = {}

function CMD.foobar()
    cs(func1)  -- func1이 임계 구역에 진입
end

function CMD.foo()
    cs(func2)  -- func2가 임계 구역에 진입
end
```

`cs` 큐를 사용하면, `func1`과 `func2`는 실행 중에 서로 중단되지 않습니다.

서비스가 여러 `foobar` 또는 `foo` 메시지를 받으면, 하나를 완전히 처리한 후에야 다음을 처리합니다. `func1`이나 `func2` 안에 `skynet.call` 같은 블로킹 호출이 있더라도 마찬가지입니다.

---

## 재진입

func1 함수 내부에서 cs를 다시 호출하는 것은 합법적입니다 (데드락이 발생하지 않음):

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

foobar 메시지를 받을 때마다, 프로그램 흐름은 step 1 → 2 → 3 → 4 → 5 순서로 실행됩니다.

---

## 구현 원리

queue는 다음 메커니즘으로 FIFO 스케줄링을 구현합니다:

- `current_thread`: 현재 잠금을 보유한 코루틴 기록
- `ref` 참조 카운트: 동일 코루틴의 중첩 호출 지원 (재진입)
- `thread_queue` 대기 큐: 새 요청은 큐 끝에 추가
- `skynet.wait()` / `skynet.wakeup()`를 활용한 코루틴 간 중단 및 깨우기

---

## 원본 skynet과의 차이점

- API 완전히 동일
- 구현 방식 동일 (skynet.wait/wakeup 기반)

