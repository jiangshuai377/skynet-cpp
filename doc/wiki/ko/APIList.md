# APIList
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 모든 모듈 API 빠른 참조표

---

## skynet ([LuaAPI](LuaAPI.md))

### 서비스 구축

| API | 설명 |
|---|---|
| `skynet.register_protocol(class)` | 메시지 처리 메커니즘 등록 |
| `skynet.start(func)` | 서비스 초기화 및 콜백 등록 |
| `skynet.dispatch(type, func)` | 메시지 처리 함수 설정 |
| `skynet.getenv(key)` | 환경 변수 읽기 |
| `skynet.setenv(key, value)` | 환경 변수 설정 |

### 프레임워크 구축

| API | 설명 |
|---|---|
| `skynet.newservice(name, ...)` | 새 Lua 서비스 시작 |
| `skynet.uniqueservice(name, ...)` | 유일한 서비스 시작 |
| `skynet.queryservice(name)` | 유일한 서비스 주소 조회 |
| `skynet.localname(name)` | 로컬 이름 조회 |
| `skynet.appendpath(path)` | Append a Lua module directory |
| `skynet.prependpath(path)` | Prepend a Lua module directory |
| `skynet.appendcpath(path)` | Append a C module directory with platform `.dll` / `.so` expansion |
| `skynet.appendservicepath(path)` | Append a service search directory |
| `skynet.getpath()` | Return the current global path snapshot |
| `skynet.getcwd()` | Return the process current working directory |
| `skynet.setpathbase(path)` | Set the relative path resolution base |
| `skynet.getpathbase()` | Return the current pathbase |
| `skynet.readfile(path)` | Resolve from pathbase and read a file |
| `skynet.writefile(path, data, append)` | Resolve from pathbase and write a file |
| `skynet.systemstat()` | Return process-level runtime statistics |

### 태스크 스케줄링

| API | 설명 |
|---|---|
| `skynet.sleep(ti)` | ti 센티초 동안 일시 중단 |
| `skynet.yield()` | CPU 양보 |
| `skynet.wait(token)` | 깨우기 대기 |
| `skynet.wakeup(token)` | 코루틴 깨우기 |
| `skynet.fork(func, ...)` | 새 코루틴 시작 |
| `skynet.timeout(ti, func)` | 타이머 실행 |
| `skynet.now()` | 프로세스 시작 후 경과 센티초 |
| `skynet.starttime()` | 프로세스 시작 UTC 시간 |
| `skynet.time()` | 현재 UTC 시간 (초) |
| `skynet.self()` | 현재 서비스 주소 |
| `skynet.address(addr)` | 주소 문자열 포맷 |
| `skynet.exit()` | 현재 서비스 종료 |

### 메시지 전달

| API | 설명 |
|---|---|
| `skynet.send(addr, type, ...)` | 비동기 전송 |
| `skynet.call(addr, type, ...)` | 동기 RPC 호출 |
| `skynet.rawsend(addr, type, msg, sz)` | 원시 전송 |
| `skynet.rawcall(addr, type, msg, sz)` | 원시 RPC |
| `skynet.ret(msg, sz)` | 메시지 응답 |
| `skynet.retpack(...)` | 패킹 후 응답 |
| `skynet.response([pack])` | 지연 응답 클로저 |
| `skynet.redirect(addr, src, type, session, ...)` | 위장 전송 |
| `skynet.error(...)` | 로그 전송 |
| `skynet.pack(...)` | 직렬화 |
| `skynet.unpack(msg, sz)` | 역직렬화 |
| `skynet.packstring(...)` | string으로 직렬화 |
| `skynet.tostring(msg, sz)` | lightuserdata → string |
| `skynet.trash(msg, sz)` | lightuserdata 해제 |

### 관리

| API | 설명 |
|---|---|
| `skynet.register(name)` | 서비스 이름 등록 |
| `skynet.name(name, addr)` | 주소에 이름 등록 |
| `skynet.kill(addr)` | 서비스 강제 종료 |
| `skynet.harbor(addr)` | 항상 0 반환 |
| `skynet.genid()` | 고유 session 생성 |

---

## skynet.cluster ([Cluster](Cluster.md))

| API | 설명 |
|---|---|
| `cluster.call(node, addr, ...)` | 원격 RPC 호출 |
| `cluster.send(node, addr, ...)` | 원격 비동기 푸시 |
| `cluster.open(addr, port)` | 클러스터 리스닝 시작 |
| `cluster.reload(cfg)` | 클러스터 설정 다시 로드 |
| `cluster.register(name, addr)` | 이름 등록 |
| `cluster.unregister(name)` | 이름 해제 |
| `cluster.query(node, name)` | 원격 이름 조회 |

---

## skynet.queue ([CriticalSection](CriticalSection.md))

| API | 설명 |
|---|---|
| `queue()` | 실행 큐 생성 |
| `cs(func, ...)` | 큐에서 직렬 실행 |

---

## skynet.sharedata ([ShareData](ShareData.md))

| API | 설명 |
|---|---|
| `sharedata.new(name, value)` | 공유 데이터 생성 |
| `sharedata.query(name)` | 공유 데이터 조회 |
| `sharedata.update(name, value)` | 공유 데이터 업데이트 |
| `sharedata.delete(name)` | 공유 데이터 삭제 |
| `sharedata.flush()` | 로컬 캐시 지우기 |
| `sharedata.deepcopy(name, ...)` | 딥카피 |

---

## skynet.multicast ([Multicast](Multicast.md))

| API | 설명 |
|---|---|
| `multicast.new(opts)` | 채널 생성 |
| `mc:subscribe()` | 구독 |
| `mc:unsubscribe()` | 구독 취소 |
| `mc:publish(...)` | 메시지 발행 |
| `mc:delete()` | 채널 삭제 |

---

## skynet.socket ([Socket](Socket.md))

| API | 설명 |
|---|---|
| `socket.listen(host, port, handler)` | TCP 포트 리스닝 |
| `socket.ondata(id, handler)` | 데이터 콜백 설정 |
| `socket.connect(host, port)` | TCP 연결 |
| `socket.send(id, data)` | 데이터 전송 |
| `socket.write(lid, cid, data)` | listener를 통해 전송 |
| `socket.read(id, sz)` | 데이터 읽기 |
| `socket.readline(id, sep)` | 구분자로 읽기 |
| `socket.readall(id)` | 전체 읽기 |
| `socket.close(id)` | 연결 종료 |
| `socket.close_listener(id)` | 리스닝 종료 |
| `socket.pause(lid, cid)` | 읽기 일시 정지 |
| `socket.resume(lid, cid)` | 읽기 재개 |
| `socket.udp(host, port, cb)` | UDP 생성 |
| `socket.udp_send(id, data, host, port)` | UDP 전송 |

---

## skynet.socketchannel ([SocketChannel](SocketChannel.md))

| API | 설명 |
|---|---|
| `socketchannel.channel(desc)` | channel 생성 |
| `channel:request(req, resp/session)` | 요청 전송 후 응답 대기 |
| `channel:response(func)` | 응답만 수신 |
| `channel:connect(once)` | 명시적 연결 |
| `channel:close()` | channel 종료 |
| `channel:changehost(host, port)` | 주소 변경 |
| `channel:read(sz)` | 바이트 읽기 |
| `channel:readline(sep)` | 구분자로 읽기 |

---

## skynet.db.redis ([ExternalService](ExternalService.md#redis-驱动))

| API | 설명 |
|---|---|
| `redis.connect(conf)` | Redis 연결 |
| `redis.watch(conf)` | pub/sub 리스닝 생성 |
| `db:*(...)` | 임의의 Redis 명령 |
| `db:pipeline(ops)` | 일괄 실행 |
| `db:disconnect()` | 연결 해제 |
| `watch:subscribe(...)` | 채널 구독 |
| `watch:message()` | 메시지 수신 |

---

## skynet.db.mysql ([ExternalService](ExternalService.md#mysql-驱动))

| API | 설명 |
|---|---|
| `mysql.connect(conf)` | MySQL 연결 |
| `db:query(sql)` | 쿼리 실행 |
| `db:prepare(sql)` | 프리페어드 스테이트먼트 |
| `stmt:execute()` | 프리페어드 실행 |
| `stmt:close()` | 스테이트먼트 닫기 |
| `db:disconnect()` | 연결 해제 |

---

## skynet.db.mongo ([ExternalService](ExternalService.md#mongodb-驱动))

| API | 설명 |
|---|---|
| `mongo.client(conf)` | MongoDB 연결 |
| `client:getDB(name)` | 데이터베이스 가져오기 |
| `db:getCollection(name)` | 컬렉션 가져오기 |
| `db:runCommand(...)` | 명령 실행 |
| `coll:insert(doc)` | 삽입 |
| `coll:find(query, proj)` | 조회 |
| `coll:findOne(query, proj)` | 단일 조회 |
| `coll:update(q, u, upsert, multi)` | 업데이트 |
| `coll:delete(query, single)` | 삭제 |
| `coll:count(query)` | 카운트 |
| `coll:aggregate(pipeline)` | 집계 |
| `coll:createIndex(keys, opts)` | 인덱스 생성 |
| `coll:drop()` | 컬렉션 삭제 |
| `cursor:sort/skip/limit/hasNext/next/close/toArray` | 커서 작업 |

---

## bson ([ExternalService](ExternalService.md#mongodb-驱动))

| API | 설명 |
|---|---|
| `bson.encode(doc)` | BSON 인코딩 |
| `bson.encode_order(k1, v1, ...)` | 순서 보존 인코딩 |
| `bson.decode(data)` | BSON 디코딩 |
| `bson.objectid(hex)` | ObjectId |
| `bson.int64(value)` | 64비트 정수 |
| `bson.null` | null 상수 |

---

## skynet.crypt ([ExternalService](ExternalService.md#crypt-工具))

| API | 설명 |
|---|---|
| `crypt.sha1(msg)` | SHA-1 해시 |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Base64 인코딩 |
| `crypt.base64decode(data)` | Base64 디코딩 |
| `crypt.hexencode(data)` | Hex 인코딩 |
| `crypt.hexdecode(data)` | Hex 디코딩 |

---

## skynet.profile ([DebugConsole](DebugConsole.md))

| API | 설명 |
|---|---|
| `profile.start([co])` | 타이밍 시작 |
| `profile.stop([co])` | 타이밍 중지 |
| `profile.resume(co, ...)` | 타이밍 포함 resume |
| `profile.wrap(f)` | 타이밍 래퍼 생성 |


