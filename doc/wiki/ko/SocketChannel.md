# SocketChannel
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었습니다. runtime 저장소는 최소 verify/package/package smoke/Linux coverage smoke 도구만 보관하고, full coverage, perf, Docker DB, soak, native 비교는 상위 `testa/tools` 계층에서 관리합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp Socket 연결 멀티플렉싱

---

```lua
local socketchannel = require "skynet.socketchannel"
```

요청-응답 패턴은 외부 서비스와 상호작용할 때 가장 많이 사용되는 패턴 중 하나입니다. socketchannel은 고수준 래핑을 제공하며, 두 가지 프로토콜 설계를 지원합니다:

1. **순서 모드 (Order Mode)**: 각 요청에 하나의 응답이 대응하며, TCP가 순서를 보장 (예: Redis)
2. **세션 모드 (Session Mode)**: 각 요청이 고유한 session을 가지며, 응답이 session을 반환하여 매칭 (예: MongoDB)

---

## Channel 생성

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    -- 이하 선택적 파라미터:
    response = dispatch_func,   -- 제공하면 Session 모드 진입
    auth = auth_func,           -- 연결 수립 후 인증 콜백
    nodelay = true,             -- TCP_NODELAY
}
```

socket channel은 생성 시 즉시 연결을 수립하지 않습니다. 연결은 첫 번째 `request` 시까지 지연됩니다. 연결 끊김 후 다음 `request` 시 자동으로 재연결됩니다.

---

## 순서 모드 (Order Mode)

Redis 등 각 요청에 반드시 순서대로 응답하는 프로토콜에 적합합니다:

```lua
local resp = channel:request(req_string, function(sock)
    -- sock은 channel이 전달한 읽기 객체
    local line = sock:readline()
    return true, line  -- 첫 번째 반환 값: 성공 여부; 두 번째: 응답 내용
end)
```

response 함수의 첫 번째 반환 값은 boolean입니다:
- `true`: 프로토콜 파싱 정상
- `false`: 프로토콜 오류, 연결이 끊기고 request에서 error 발생

---

## 세션 모드 (Session Mode)

MongoDB 등 비순서 응답이 가능한 프로토콜에 적합합니다. 생성 시 전역 `response` 함수를 제공해야 합니다:

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 27017,
    response = function(sock)
        -- 응답 패킷 파싱
        local session = ...  -- 응답에서 session 추출
        local ok = true
        local data = ...     -- 응답 데이터 파싱
        return session, ok, data
    end,
}

-- 요청 전송, response 함수 대신 session 전달
local resp = channel:request(req_string, session_id)
```

---

## 인증

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    auth = function(sock)
        -- 연결 수립 후 자동 호출
        -- AUTH / SELECT 등의 작업 가능
        sock:request("AUTH password\r\n", function(s)
            return true, s:readline()
        end)
    end,
}
```

auth 함수는 매번 연결이 수립된 직후 실행됩니다. 인증이 실패하면 auth에서 error를 발생시키면 됩니다.

---

## 기타 API

| 메서드 | 설명 |
|---|---|
| `channel:connect(once)` | 명시적 연결. once=true이면 한 번만 시도하며, 실패 시 에러 발생 |
| `channel:close()` | channel 종료, 대기 중인 모든 request 깨우기 |
| `channel:changehost(host, port)` | 원격 주소 변경 및 재연결 |
| `channel:read(sz)` | channel에서 sz 바이트 읽기 |
| `channel:readline(sep)` | channel에서 구분자로 읽기 |
| `channel:response(func)` | 요청을 보내지 않고 응답 하나만 대기하여 수신 (pub/sub 용) |

---

## 원본 skynet과의 차이점

- API 기본적으로 동일
- 원본에는 `padding` 파라미터와 저우선순위 쓰기 (`socket.lwrite`)가 있으나, skynet-cpp는 아직 미구현
- 원본에는 `backup` 백업 주소 (mongo 클러스터용)가 있으나, skynet-cpp는 아직 미구현
- 원본에는 `overload` 과부하 콜백이 있으나, skynet-cpp는 아직 미구현

