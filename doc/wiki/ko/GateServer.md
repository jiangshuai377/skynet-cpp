# GateServer
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 게이트웨이 서비스 템플릿

---

게이트웨이 서비스 (GateServer)는 애플리케이션의 접속 레이어로, 기본 기능은 클라이언트 연결 관리, 완전한 데이터 패킷 분할, 로직 서비스로의 전달입니다.

skynet-cpp는 범용 템플릿 `lualib/gateserver.lua`를 제공합니다.

---

## 사용 방법

```lua
local gateserver = require "gateserver"

local handler = {}

function handler.connect(conn_id, addr, port)
    -- 새 클라이언트 접속
end

function handler.disconnect(conn_id)
    -- 클라이언트 연결 해제
end

function handler.message(conn_id, data)
    -- 완전한 비즈니스 데이터 패킷 수신 (길이 헤더 제거됨)
end

function handler.open(source, conf)
    -- Gate 리스닝 포트 열기
end

gateserver.start(handler)
```

참고: `gateserver.start` 내부에서 `skynet.start`를 호출합니다.

---

## Handler 콜백

| 콜백 | 시그니처 | 설명 |
|---|---|---|
| `connect` | `(conn_id, addr, port)` | 새 클라이언트 accept 후 호출 |
| `disconnect` | `(conn_id)` | 연결 해제 시 호출 |
| `message` | `(conn_id, data)` | 완전한 비즈니스 패킷 (netpack으로 분할됨) 도착 |
| `error` | `(conn_id, msg)` | 연결 이상 |
| `warning` | `(conn_id, bytes)` | 전송 버퍼 1M 초과 경고 |
| `open` | `(source, conf)` | 리스닝 포트 열릴 때 호출 |

---

## 패킷 분할 프로토콜

각 패킷 = **2바이트 빅엔디안 길이 헤더** + **데이터 내용**

단일 데이터 패킷의 최대 크기는 65535바이트입니다. 더 큰 데이터 블록을 전송해야 하는 경우 상위 프로토콜에서 해결하세요.

### netpack API

```lua
local netpack = require "netpack"
```

| 함수 | 설명 |
|---|---|
| `netpack.pack(data)` | 데이터 패킹 (2바이트 길이 헤더 추가), 프레임된 string 반환 |
| `netpack.unpack(buffer, offset)` | buffer에서 완전한 프레임 하나 추출, (next_offset, payload) 반환 |
| `netpack.filter(buffer, new_data)` | 새 데이터 병합 및 모든 완전한 프레임 추출 |
| `netpack.tostring(msg, sz)` | lightuserdata를 Lua string으로 변환 |

---

## 제어 명령

다른 서비스는 lua 프로토콜을 통해 gate에 다음 명령을 보낼 수 있습니다:

```lua
-- 리스닝 열기
skynet.call(gate, "lua", "OPEN", { port = 8888, address = "0.0.0.0" })

-- 길이 헤더가 포함된 데이터 전송
skynet.call(gate, "lua", "SEND", conn_id, data)

-- 원시 데이터 전송 (길이 헤더 없음)
skynet.call(gate, "lua", "SENDRAW", conn_id, raw_data)

-- 연결 종료
skynet.call(gate, "lua", "CLOSE", conn_id)

-- 연결 강제 종료
skynet.call(gate, "lua", "KICK", conn_id)
```

---

## 원본 skynet과의 차이점

- 원본의 gateserver는 `lualib/snax/gateserver.lua`에 위치하며, skynet-cpp는 `lualib/gateserver.lua`에 위치
- 원본에는 `gateserver.openclient(fd)` / `gateserver.closeclient(fd)`로 메시지 수신을 제어하지만, skynet-cpp의 연결은 기본적으로 메시지를 수신
- 원본 message 콜백은 C 포인터와 길이 `(fd, msg, sz)`를 전달하지만, skynet-cpp는 Lua string `(conn_id, data)`을 전달
- 원본은 동일 서비스에서 socket 라이브러리와 혼용 불가이며, skynet-cpp도 마찬가지

