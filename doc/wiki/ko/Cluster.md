# Cluster
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 클러스터

---

```lua
local cluster = require "skynet.cluster"
```

skynet-cpp는 크로스 노드 RPC를 지원하기 위해 cluster 모드를 구현했습니다. 각 노드는 독립적인 skynet-cpp 프로세스이며, 노드 간에 TCP 연결을 통해 메시지를 전달합니다.

---

## 빠른 시작

### 노드 A: 리스닝 + 서비스 제공

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    local echo = skynet.newservice("echo")
    skynet.name(".echo", echo)

    -- 원격 접근을 위한 이름 등록
    cluster.register("echo", echo)

    -- 클러스터 설정 로드
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- 리스닝 포트 열기
    cluster.open("127.0.0.1", 19999)
end)
```

### 노드 B: 원격 호출

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- 노드 A의 echo 서비스에 RPC 호출
    local result = cluster.call("nodeA", ".echo", "hello")
    print(result)

    -- 등록된 이름 조회
    local addr = cluster.query("nodeA", "echo")
end)
```

---

## API

| 함수 | 설명 |
|---|---|
| `cluster.call(node, addr, ...)` | 원격 노드의 서비스에 동기 RPC 호출. 응답을 블로킹 대기 |
| `cluster.send(node, addr, ...)` | 원격 노드에 비동기 메시지 푸시 (응답 없음). 유실 위험 있음 |
| `cluster.open(addr, port)` | 리스닝 포트를 열어 인바운드 클러스터 연결 수락 |
| `cluster.reload(cfg)` | 클러스터 설정 다시 로드. cfg는 `{nodename = "host:port", ...}` 테이블 |
| `cluster.register(name, addr)` | 로컬 서비스 이름을 등록하여 원격에서 `@name`으로 접근 가능. addr 기본값은 자신 |
| `cluster.unregister(name)` | 등록된 이름 해제 |
| `cluster.query(node, name)` | 원격 노드에서 `cluster.register`로 등록한 서비스 주소 조회 |

### 주소 형식

`cluster.call`의 두 번째 파라미터 `addr`은 다음이 될 수 있습니다:

- **문자열 이름**: 예를 들어 `".echo"`, 대상 노드에서 해당 이름 조회
- **`@` 접두사 이름**: 예를 들어 `"@echo"`, `cluster.register`로 등록한 이름으로 조회
- **숫자 주소**: 원격 서비스의 handle을 이미 알고 있는 경우

---

## 아키텍처

cluster 시스템은 세 개의 서비스로 구성됩니다:

```
cluster.call("nodeB", ".svc", "CMD")
      │
      ▼
  clusterd ──sender──→ [TCP] ──→ clusteragent ──→ 로컬 서비스
  (관리자)   (아웃바운드)          (인바운드)          ↓
      ▲                                          응답
      │                                            │
      └────────────────────── [TCP] ←───────────────┘
```

| 서비스 | 수량 | 역할 |
|---|---|---|
| `clusterd` | 노드당 1개 | 중앙 관리자: 설정, sender/agent 생명주기, 이름 등록, 리스닝 |
| `clustersender` | 원격 노드당 1개 | 원격 노드로의 TCP 연결 유지, socketchannel을 통해 요청 전송 |
| `clusteragent` | 연결당 1개 | 인바운드 연결 처리, 요청 파싱 후 로컬 서비스로 분배, 응답 반환 |

---

## 클러스터 프로토콜

`cluster.core` C 모듈이 클러스터 와이어 프로토콜을 구현합니다:

- **패킷 형식**: 2바이트 빅엔디안 길이 헤더 + 페이로드
- **요청 패킷**: 타입 마커 + session + 대상 주소 + 직렬화된 메시지
- **응답 패킷**: session + 성공/실패 + 직렬화된 메시지
- **대형 메시지 분할**: 32KB를 초과하는 메시지는 자동으로 여러 조각으로 분할 전송

---

## 메시지 순서

cluster 간 요청은 대부분 호출 순서대로 정렬됩니다 (먼저 보낸 것이 먼저 도착). 그러나 단일 패킷이 32KB를 초과하면 패킷이 분할되어 전송되며, 큰 패킷이 작은 패킷보다 늦게 도착할 수 있습니다.

요청과 응답은 동일한 TCP 연결을 사용하므로 순서가 보장됩니다.

---

## 설정 업데이트

`cluster.reload(cfg)`를 통해 설정을 다시 로드합니다. 노드 주소를 변경하면 reload 이후의 새 요청이 새 주소로 전송됩니다. 이전에 완료되지 않은 요청은 여전히 이전 주소에서 대기합니다.

노드 주소를 `false`로 설정하여 노드를 오프라인으로 표시할 수 있습니다.

---

## 원본 skynet과의 차이점

- skynet-cpp는 master/slave (harbor) 모드를 **지원하지 않으며**, cluster만 지원
- 원본 cluster 설정은 파일을 통해 로드하지만, skynet-cpp는 `cluster.reload(table)`로 전달
- 원본에는 `cluster.proxy(node, addr)`로 로컬 프록시를 생성할 수 있으나, skynet-cpp는 아직 미구현
- 원본에는 `cluster.snax`로 원격 Snax 서비스를 지원하지만, skynet-cpp는 Snax 미지원
- 원본 설정은 `__nowaiting = true`를 지원하지만, skynet-cpp는 아직 미구현

