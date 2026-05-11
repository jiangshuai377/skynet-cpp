# Multicast
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었습니다. runtime 저장소는 최소 verify/package/package smoke/Linux coverage smoke 도구만 보관하고, full coverage, perf, Docker DB, soak, native 비교는 상위 `testa/tools` 계층에서 관리합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 발행/구독

---

```lua
local multicast = require "skynet.multicast"
```

Multicast 모듈은 동일 프로세스 내에서 채널 방식의 발행/구독 메시지 메커니즘을 제공합니다.

---

## 사용 방법

### 발행자

```lua
local multicast = require "skynet.multicast"

-- 새 채널 생성
local mc = multicast.new()
print("channel id:", mc.channel)

-- 메시지 발행 (fire-and-forget)
mc:publish("event_name", { data = 123 })

-- 채널 삭제
mc:delete()
```

### 구독자

```lua
local multicast = require "skynet.multicast"

-- 기존 채널 ID 사용
local mc = multicast.new({ channel = channel_id })

-- 수신 콜백 설정
mc.dispatch = function(channel, source, ...)
    print("received from", source, ":", ...)
end

-- 구독
mc:subscribe()

-- 구독 취소
mc:unsubscribe()
```

---

## API

| 메서드 | 설명 |
|---|---|
| `multicast.new(opts)` | 채널 객체 생성. opts에 `{channel=id}`를 포함하면 기존 채널 사용 |
| `mc:subscribe()` | 현재 서비스를 이 채널에 구독 |
| `mc:unsubscribe()` | 구독 취소 |
| `mc:publish(...)` | 모든 구독자에게 메시지 발행 |
| `mc:delete()` | 이 채널 삭제 |
| `mc.dispatch` | 콜백 함수로 설정하여 발행된 메시지를 수신 |

---

## 구현 아키텍처

| 구성 요소 | 설명 |
|---|---|
| `multicastd` 서비스 | 유일 서비스, 채널 ID 할당, 구독자 목록, 메시지 브로드캐스트 관리 |
| `multicast.lua` 클라이언트 | `PTYPE_MULTICAST` 프로토콜 타입 등록, 객체 지향 API 제공 |

메시지 발행 흐름:
1. 발행자가 `mc:publish(...)` 호출
2. 메시지가 `multicastd` 서비스로 전송
3. `multicastd`가 구독자 목록을 순회하며 각 구독자에게 `PTYPE_MULTICAST` 메시지 전송
4. 구독자의 dispatch 콜백이 트리거됨

---

## 원본 skynet과의 차이점

- API 기본적으로 동일
- 원본은 크로스 노드 멀티캐스트를 지원하지만 (datacenter를 통해 분배), skynet-cpp는 동일 프로세스 내에서만 지원

