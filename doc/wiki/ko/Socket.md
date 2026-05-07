# Socket
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp Socket API

---

```lua
local socket = require "socket"
```

skynet-cpp는 TCP/UDP 읽기/쓰기를 위한 블로킹 모드 Lua API 세트를 제공합니다. 블로킹 모드라 함은 실제로 Lua의 coroutine 메커니즘을 활용한 것입니다. socket API를 호출하면 서비스가 일시 중단될 수 있으며 (타임 슬라이스를 다른 비즈니스 처리에 양보), 결과가 socket 메시지를 통해 반환되면 coroutine이 실행을 계속합니다.

---

## TCP API

### 서버 측

```lua
-- 포트 리스닝
local listener_id = socket.listen("0.0.0.0", 8888, function(event, conn_id, ...)
    if event == "accept" then
        -- 새 연결 수락
    elseif event == "close" then
        -- 연결 종료
    elseif event == "warning" then
        -- 전송 버퍼 경고
    end
end)

-- 데이터 콜백 설정
socket.ondata(listener_id, function(conn_id, data)
    -- 데이터 수신
end)
```

- `socket.listen(host, port, handler)` — 포트를 리스닝하며, handler는 accept/close/warning 이벤트를 수신, listener_id 반환
- `socket.ondata(listener_id, handler)` — 데이터 콜백 설정 `handler(conn_id, data)`
- `socket.write(listener_id, conn_id, data)` — listener의 연결에서 데이터 전송
- `socket.close_listener(listener_id)` — 리스닝 종료
- `socket.pause(listener_id, conn_id)` — 연결 읽기 일시 정지 (흐름 제어)
- `socket.resume(listener_id, conn_id)` — 연결 읽기 재개

### 클라이언트 측

```lua
local conn_id = socket.connect("127.0.0.1", 8888)
if conn_id then
    socket.send(conn_id, "hello\n")
    local line = socket.readline(conn_id, "\n")
    socket.close(conn_id)
end
```

- `socket.connect(host, port)` — 원격 호스트에 연결, 연결 완료 또는 실패까지 블로킹
- `socket.send(conn_id, data)` — 데이터 전송
- `socket.read(conn_id, sz)` — sz 바이트 읽기, 데이터 준비 또는 연결 종료까지 블로킹
- `socket.readline(conn_id, sep)` — 구분자까지 읽기 (기본값 `"\n"`), 구분자 미포함
- `socket.readall(conn_id)` — 사용 가능한 모든 데이터 읽기
- `socket.close(conn_id)` — 연결 종료

---

## UDP API

```lua
local udp_id = socket.udp("0.0.0.0", 9999, function(data, from_addr, from_port)
    -- UDP 데이터 패킷 수신
end)

socket.udp_send(udp_id, "hello", "127.0.0.1", 9999)
```

- `socket.udp(host, port, callback)` — UDP 소켓 생성, 콜백으로 데이터 패킷 수신
- `socket.udp_send(id, data, host, port)` — UDP 데이터 패킷 전송

---

## socketdriver (C 모듈)

`socket.lua`는 하위 레벨 C 모듈 `socketdriver`에 대한 코루틴 래핑입니다. `socketdriver`가 등록하는 함수:

| 함수 | 설명 |
|---|---|
| `socketdriver.listen(host, port, backlog)` | TCP 리스닝 생성 |
| `socketdriver.connect(host, port)` | TCP 연결 생성 (비동기) |
| `socketdriver.send(id, data)` | connector를 통해 데이터 전송 |
| `socketdriver.write(listener_id, conn_id, data)` | listener의 연결을 통해 전송 |
| `socketdriver.close(id, [conn_id])` | 소켓 또는 연결 종료 |
| `socketdriver.pause(listener_id, conn_id)` | 연결 읽기 일시 정지 |
| `socketdriver.resume(listener_id, conn_id)` | 연결 읽기 재개 |
| `socketdriver.udp(host, port)` | UDP 소켓 생성 |
| `socketdriver.udp_send(id, data, host, port)` | UDP 전송 |

---

## 원본 skynet과의 차이점

- 원본은 `socket.start(id)`를 사용하여 socket 제어권을 인계받지만 (다수 서비스가 socket id를 공유하므로), skynet-cpp의 listener/connector는 생성 서비스에 자연스럽게 바인딩됨
- 원본에는 `socket.abandon` (제어권 이전)이 있으나, skynet-cpp는 아직 미구현
- 원본에는 `socket.lwrite` (저우선순위 쓰기 큐)가 있으나, skynet-cpp는 아직 미구현
- 원본에는 `socket.block` (읽기 가능 대기)이 있으나, skynet-cpp는 아직 미구현

