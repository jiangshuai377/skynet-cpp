# GettingStarted
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 입문 가이드

---

## 프레임워크

skynet-cpp는 경량 Actor 모델 서버 프레임워크입니다. 간단한 운영체제로 이해할 수 있으며, 수천 개의 Lua 가상 머신을 스케줄링하여 병렬로 작동하게 합니다. 각 Lua 가상 머신은 다른 가상 머신에서 보낸 메시지를 수신하고 처리할 수 있으며, 다른 가상 머신에 메시지를 보낼 수도 있습니다.

skynet-cpp는 외부 네트워크 데이터 입력과 타이머 관리를 내장하고 있으며, 이를 일관된 메시지 입력으로 변환하여 각 서비스에 전달합니다.

### 원본 skynet과의 관계

skynet-cpp의 설계 철학과 API 의미론은 완전히 [cloudwu/skynet](https://github.com/cloudwu/skynet)에서 비롯되었지만, C++20으로 하위 프레임워크를 재구현했습니다. Lua 개발자에게는 API 사용법이 원본 skynet과 기본적으로 동일합니다.

---

## 서비스 (Service)

skynet-cpp의 서비스는 Lua로 작성됩니다. 규격에 맞는 `.lua` 파일을 skynet-cpp가 찾을 수 있는 경로에 놓기만 하면 다른 서비스에서 시작할 수 있습니다. 각 서비스는 프레임워크가 할당하는 고유한 32bit 주소(handle)를 가집니다.

각 서비스는 세 가지 실행 단계로 나뉩니다:

1. **로딩 단계**: 서비스 소스 파일이 로드되어 실행됩니다. 이 단계에서는 블로킹 API를 호출할 수 **없습니다**.
2. **초기화 단계**: `skynet.start(func)`로 등록한 초기화 함수가 실행됩니다. 이 단계에서는 모든 skynet API를 호출할 수 있습니다. 해당 서비스를 시작한 `skynet.newservice`는 초기화가 완료될 때까지 대기합니다.
3. **작업 단계**: 초기화 완료 후, 메시지 처리 함수가 등록된 서비스는 메시지에 응답하기 시작합니다.

```lua
local skynet = require "skynet"

-- 로딩 단계: 모듈 레벨 변수 설정
local CMD = {}

function CMD.hello(...)
    return "world"
end

skynet.start(function()
    -- 초기화 단계: 메시지 디스패치 등록
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd])
        skynet.retpack(f(...))
    end)
end)
```

---

## 메시지 (Message)

각 skynet-cpp 메시지는 다음 요소로 구성됩니다:

1. **session**: 요청을 시작한 서비스가 생성한 고유 식별자. 응답 측에서 응답 시 session을 함께 반환하며, 발신 측은 이를 사용하여 요청과 응답을 매칭합니다. session이 0이면 응답이 필요 없음을 의미합니다 (단방향 푸시).
2. **source**: 메시지 출처의 서비스 주소 (32bit handle).
3. **type**: 메시지 카테고리. 가장 많이 사용되는 것은 `"lua"`로, Lua 서비스 간 통신에 사용됩니다.
4. **message + size**: 메시지 내용 (C 포인터 + 길이), 직렬화 함수에 의해 생성됩니다.

### 메시지 타입

| 타입 | 이름 | 용도 |
|---|---|---|
| 0 | `text` | 순수 텍스트 메시지 |
| 1 | `response` | RPC 응답 |
| 6 | `socket` | 네트워크 이벤트 |
| 7 | `error` | 오류 알림 |
| 10 | `lua` | Lua 직렬화 메시지 (가장 많이 사용) |

---

## 코루틴 스케줄링

하위 레벨에서 보면 각 서비스는 하나의 메시지 처리기입니다. 하지만 애플리케이션 레벨에서는 Lua의 coroutine을 활용하여 작동합니다.

서비스가 다른 서비스에 요청을 보낸 후 (`skynet.call`), 현재 코루틴은 일시 중단됩니다. 상대방이 요청을 받고 응답한 후, 프레임워크는 중단된 코루틴을 찾아 응답 정보를 전달하고 이전에 완료하지 못한 비즈니스 흐름을 계속합니다. 사용자 관점에서 보면 독립적인 스레드가 비즈니스를 처리하는 것처럼 보입니다.

**재진입 주의**: 서비스가 특정 비즈니스 흐름에서 일시 중단된 후에도 다른 메시지를 계속 처리할 수 있습니다. 따라서 `skynet.call` 이전에 획득한 서비스 내부 상태가 반환 후에는 이미 변경되었을 수 있습니다. 두 번의 블로킹 API 호출 사이의 실행 과정은 원자적입니다. [CriticalSection](CriticalSection.md)을 사용하여 의사 동시성으로 인한 복잡성을 줄일 수 있습니다.

---

## 네트워크

skynet-cpp는 네트워크 레이어를 내장하고 있으며, TCP와 UDP 기능을 래핑합니다. 서비스에서 시스템 네트워크 API와 직접 상호작용하는 모듈을 사용하는 것은 권장하지 않습니다. 네트워크 IO에 의해 블로킹되면 전체 워커 스레드에 영향을 미치기 때문입니다.

skynet-cpp 내장 [Socket](Socket.md) API를 사용하면 네트워크 IO 블로킹 시 CPU 처리 능력을 완전히 해방할 수 있습니다.

클라이언트 접속 관리에는 [GateServer](GateServer.md) 게이트웨이 서비스 사용을 권장합니다.

---

## 외부 서비스

skynet-cpp는 [Redis](ExternalService.md#redis-驱动), [MySQL](ExternalService.md#mysql-驱动), [MongoDB](ExternalService.md#mongodb-驱动) 드라이버 모듈을 제공합니다. 이 드라이버 모듈들은 모두 [SocketChannel](SocketChannel.md)을 기반으로 구현되어 skynet-cpp와 잘 협업할 수 있습니다.

---

## 클러스터

skynet-cpp는 크로스 노드 RPC를 지원하기 위해 cluster 모드를 구현했습니다. 자세한 내용은 [Cluster](Cluster.md)를 참조하세요.

원본 skynet과 달리 skynet-cpp는 master/slave 모드 (harbor 모드)를 **지원하지 않으며**, 전부 cluster 모드를 사용하는 것을 권장합니다.

---

## 원본 skynet과의 차이점

- master/slave (harbor) 모드 **미지원**
- Snax 프레임워크 **미지원**
- Sproto 프로토콜 **미지원**
- DataCenter **미지원** (폐기됨)
- ShareData는 C 공유 메모리가 아닌 메시지 전달 딥카피 사용
- Lua 5.5.0 사용 (원본은 Lua 5.4 사용)
- 데이터베이스 드라이버 (BSON/SHA1) 모두 순수 Lua 구현

