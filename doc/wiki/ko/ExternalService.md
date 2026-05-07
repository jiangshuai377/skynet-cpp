# ExternalService
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 외부 서비스 드라이버 (Redis / MySQL / MongoDB)

---

모든 비즈니스 로직을 가능한 한 동일한 skynet-cpp 프로세스 내에서 완료해야 합니다. 하지만 데이터베이스와 같은 외부 서비스를 사용해야 할 때가 있습니다.

skynet-cpp는 Redis, MySQL, MongoDB 드라이버 모듈을 제공합니다. 이러한 드라이버는 [SocketChannel](SocketChannel.md)을 기반으로 구현되어 skynet-cpp의 워커 스레드를 블로킹하지 않습니다.

---

## Redis 드라이버

```lua
local redis = require "skynet.db.redis"
```

### 연결

```lua
local db = redis.connect({
    host = "127.0.0.1",
    port = 6379,
    auth = "password",    -- 선택 사항
    db = 0,               -- 선택 사항, SELECT 데이터베이스 번호
})
```

### 명령

모든 Redis 명령은 metatable `__index`를 통해 동적으로 생성됩니다:

```lua
db:set("key", "value")
local val = db:get("key")
db:lpush("list", "a", "b", "c")
local list = db:lrange("list", 0, -1)
db:hset("hash", "field", "value")
local all = db:hgetall("hash")
db:del("key")
db:disconnect()
```

### Pipeline 일괄 처리

```lua
local results = db:pipeline({
    {"set", "a", "1"},
    {"set", "b", "2"},
    {"get", "a"},
    {"get", "b"},
})
-- results = { "OK", "OK", "1", "2" }
```

### Pub/Sub (Watch 모드)

```lua
local watch = redis.watch({
    host = "127.0.0.1",
    port = 6379,
})

watch:subscribe("channel1", "channel2")

while true do
    local data, channel = watch:message()  -- 블로킹 대기
    print(channel, data)
end
```

---

## MySQL 드라이버

```lua
local mysql = require "skynet.db.mysql"
```

### 연결

```lua
local db = mysql.connect({
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "123456",
    database = "test",
    charset = "utf8mb4",  -- 선택 사항
})
```

### 쿼리

```lua
-- 텍스트 쿼리
local rows = db:query("SELECT * FROM users WHERE id = 1")
-- rows = { {id=1, name="alice"}, {id=2, name="bob"} }

-- 다중 결과 세트
local results = db:query("CALL get_users(); SELECT 1")
-- results.multiresultset = true

db:disconnect()
```

### Prepared Statement

```lua
local stmt = db:prepare("INSERT INTO users (name, age) VALUES (?, ?)")
stmt:bind_param("alice", 25)
local result = stmt:execute()
stmt:close()
```

### 인증

MySQL 드라이버는 SHA1 challenge-response 인증 (MySQL 4.1+ native_password)을 사용하며, `skynet.crypt` 순수 Lua SHA1 구현에 기반합니다.

---

## MongoDB 드라이버

```lua
local mongo = require "skynet.db.mongo"
local bson = require "bson"
```

### 연결

```lua
local client = mongo.client({
    host = "127.0.0.1",
    port = 27017,
})
```

### 데이터베이스와 컬렉션

```lua
local db = client:getDB("mydb")
local coll = db:getCollection("users")
```

### CRUD 작업

```lua
-- 삽입
coll:insert({ name = "alice", age = 25 })
coll:batch_insert({
    { name = "bob", age = 30 },
    { name = "charlie", age = 35 },
})

-- 조회
local user = coll:findOne({ name = "alice" })
local cursor = coll:find({ age = { ["$gte"] = 25 } })
local all = cursor:sort({ age = 1 }):limit(10):toArray()

-- 업데이트
coll:update({ name = "alice" }, { ["$set"] = { age = 26 } })

-- 삭제
coll:delete({ name = "charlie" })

-- 카운트
local n = coll:count({ age = { ["$gte"] = 25 } })

-- 집계
local results = coll:aggregate({
    { ["$match"] = { age = { ["$gte"] = 25 } } },
    { ["$group"] = { _id = "$name", total = { ["$sum"] = 1 } } },
})

-- 인덱스
coll:createIndex({ name = 1 }, { unique = true })

-- 컬렉션 삭제
coll:drop()

client:disconnect()
```

### Cursor API

```lua
local cursor = coll:find(query)
cursor:sort({ field = 1 })   -- 정렬
cursor:skip(10)               -- 건너뛰기
cursor:limit(20)              -- 제한

while cursor:hasNext() do
    local doc = cursor:next()
end

cursor:close()
```

### BSON 타입

```lua
local bson = require "bson"

-- ObjectId
local oid = bson.objectid()           -- 자동 생성
local oid = bson.objectid("507f1f77bcf86cd799439011")  -- hex에서

-- 64비트 정수
local big = bson.int64(1234567890123)

-- 특수 값
local n = bson.null      -- BSON null
local mn = bson.minkey   -- BSON minkey
local mx = bson.maxkey   -- BSON maxkey

-- 인코딩/디코딩
local binary = bson.encode({ name = "test", value = 42 })
local doc = bson.decode(binary)

-- 순서 보존 인코딩
local binary = bson.encode_order("name", "test", "value", 42)
```

---

## Crypt 유틸리티

```lua
local crypt = require "skynet.crypt"
```

MySQL 인증 등의 시나리오에 사용되는 순수 Lua 암호화 함수:

| 함수 | 설명 |
|---|---|
| `crypt.sha1(msg)` | SHA-1 해시 (20바이트 바이너리 반환) |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Base64 인코딩 |
| `crypt.base64decode(data)` | Base64 디코딩 |
| `crypt.hexencode(data)` | 16진수 인코딩 |
| `crypt.hexdecode(data)` | 16진수 디코딩 |

---

## 원본 skynet과의 차이점

- 원본 데이터베이스 드라이버는 일부 C 모듈을 사용 (예: BSON 인코딩/디코딩)하지만, skynet-cpp는 전부 순수 Lua 구현
- 원본에는 `skynet.dns` 모듈로 논블로킹 DNS 조회가 있으나, skynet-cpp는 아직 미구현
- 원본 crypt는 C 모듈을 통해 더 많은 기능을 제공 (DES/AES/RSA 등)하지만, skynet-cpp는 SHA1/HMAC/Base64/Hex만 제공
- 원본 MongoDB 드라이버는 클러스터 모드 (백업 주소)를 지원하지만, skynet-cpp는 아직 미지원

