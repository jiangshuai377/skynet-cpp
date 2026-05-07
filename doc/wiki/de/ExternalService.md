# ExternalService
## Aktueller Implementierungsstand

Die aktuelle Runtime verwendet den Preload-Bootstrap: `SKYNET_THREAD` setzt die Worker-Anzahl und `SKYNET_PRELOAD` wählt das Preload-Skript. Das Preload-Skript konfiguriert Lua path/cpath/service path, startet den launcher und wählt den Anwendungseinstieg. Test-Einstiege sind in `tests/logic`, `tests/stress` und `tests/perf` getrennt; Coverage und Linux-Docker-Performance haben eigene Runner. Actor-Scheduling nutzt jetzt `ActorQueue`, sharded registry und atomic wakeup; Lua callback und `skynet.core` actor context sind im Hot Path gecacht.

> skynet-cpp External Service Drivers (Redis / MySQL / MongoDB)

---

We should try to complete all business logic within the same skynet-cpp process whenever possible. However, sometimes external services such as databases are necessary.

skynet-cpp provides driver modules for Redis, MySQL, and MongoDB. These drivers are built on [SocketChannel](SocketChannel.md) and will not block skynet-cpp's worker threads.

---

## Redis Driver

```lua
local redis = require "skynet.db.redis"
```

### Connection

```lua
local db = redis.connect({
    host = "127.0.0.1",
    port = 6379,
    auth = "password",    -- optional
    db = 0,               -- optional, SELECT database number
})
```

### Commands

All Redis commands are dynamically generated via metatable `__index`:

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

### Pipeline Batch

```lua
local results = db:pipeline({
    {"set", "a", "1"},
    {"set", "b", "2"},
    {"get", "a"},
    {"get", "b"},
})
-- results = { "OK", "OK", "1", "2" }
```

### Pub/Sub (Watch Mode)

```lua
local watch = redis.watch({
    host = "127.0.0.1",
    port = 6379,
})

watch:subscribe("channel1", "channel2")

while true do
    local data, channel = watch:message()  -- blocks waiting
    print(channel, data)
end
```

---

## MySQL Driver

```lua
local mysql = require "skynet.db.mysql"
```

### Connection

```lua
local db = mysql.connect({
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "123456",
    database = "test",
    charset = "utf8mb4",  -- optional
})
```

### Queries

```lua
-- Text query
local rows = db:query("SELECT * FROM users WHERE id = 1")
-- rows = { {id=1, name="alice"}, {id=2, name="bob"} }

-- Multiple result sets
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

### Authentication

The MySQL driver uses SHA1 challenge-response authentication (MySQL 4.1+ native_password), based on a pure Lua SHA1 implementation in `skynet.crypt`.

---

## MongoDB Driver

```lua
local mongo = require "skynet.db.mongo"
local bson = require "bson"
```

### Connection

```lua
local client = mongo.client({
    host = "127.0.0.1",
    port = 27017,
})
```

### Database and Collection

```lua
local db = client:getDB("mydb")
local coll = db:getCollection("users")
```

### CRUD Operations

```lua
-- Insert
coll:insert({ name = "alice", age = 25 })
coll:batch_insert({
    { name = "bob", age = 30 },
    { name = "charlie", age = 35 },
})

-- Query
local user = coll:findOne({ name = "alice" })
local cursor = coll:find({ age = { ["$gte"] = 25 } })
local all = cursor:sort({ age = 1 }):limit(10):toArray()

-- Update
coll:update({ name = "alice" }, { ["$set"] = { age = 26 } })

-- Delete
coll:delete({ name = "charlie" })

-- Count
local n = coll:count({ age = { ["$gte"] = 25 } })

-- Aggregate
local results = coll:aggregate({
    { ["$match"] = { age = { ["$gte"] = 25 } } },
    { ["$group"] = { _id = "$name", total = { ["$sum"] = 1 } } },
})

-- Index
coll:createIndex({ name = 1 }, { unique = true })

-- Drop collection
coll:drop()

client:disconnect()
```

### Cursor API

```lua
local cursor = coll:find(query)
cursor:sort({ field = 1 })   -- sort
cursor:skip(10)               -- skip
cursor:limit(20)              -- limit

while cursor:hasNext() do
    local doc = cursor:next()
end

cursor:close()
```

### BSON Types

```lua
local bson = require "bson"

-- ObjectId
local oid = bson.objectid()           -- auto-generate
local oid = bson.objectid("507f1f77bcf86cd799439011")  -- from hex

-- 64-bit integer
local big = bson.int64(1234567890123)

-- Special values
local n = bson.null      -- BSON null
local mn = bson.minkey   -- BSON minkey
local mx = bson.maxkey   -- BSON maxkey

-- Encode/Decode
local binary = bson.encode({ name = "test", value = 42 })
local doc = bson.decode(binary)

-- Order-preserving encoding
local binary = bson.encode_order("name", "test", "value", 42)
```

---

## Crypt Utilities

```lua
local crypt = require "skynet.crypt"
```

Pure Lua cryptographic functions, used for MySQL authentication and similar scenarios:

| Function | Description |
|---|---|
| `crypt.sha1(msg)` | SHA-1 hash (returns 20-byte binary) |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Base64 encoding |
| `crypt.base64decode(data)` | Base64 decoding |
| `crypt.hexencode(data)` | Hexadecimal encoding |
| `crypt.hexdecode(data)` | Hexadecimal decoding |

---

## Differences from Original Skynet

- Some of the original database drivers use C modules (e.g., BSON encode/decode); skynet-cpp is entirely pure Lua
- The original has a `skynet.dns` module for non-blocking DNS resolution; skynet-cpp has not implemented this yet
- The original crypt provides more features via C modules (DES/AES/RSA, etc.); skynet-cpp only provides SHA1/HMAC/Base64/Hex
- The original MongoDB driver supports cluster mode (backup addresses); skynet-cpp does not support this yet

