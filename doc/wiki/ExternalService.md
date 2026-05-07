# ExternalService
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 外部服务驱动（Redis / MySQL / MongoDB）

---

我们应尽可能在同一个 skynet-cpp 进程内完成所有业务逻辑。但有时必须使用外部服务，如数据库。

skynet-cpp 提供了 Redis、MySQL、MongoDB 的驱动模块。这些驱动基于 [SocketChannel](SocketChannel.md) 实现，不会阻塞 skynet-cpp 的工作线程。

---

## Redis 驱动

```lua
local redis = require "skynet.db.redis"
```

### 连接

```lua
local db = redis.connect({
    host = "127.0.0.1",
    port = 6379,
    auth = "password",    -- 可选
    db = 0,               -- 可选，SELECT 数据库号
})
```

### 命令

所有 Redis 命令通过 metatable `__index` 动态生成：

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

### Pipeline 批量

```lua
local results = db:pipeline({
    {"set", "a", "1"},
    {"set", "b", "2"},
    {"get", "a"},
    {"get", "b"},
})
-- results = { "OK", "OK", "1", "2" }
```

### Pub/Sub (Watch 模式)

```lua
local watch = redis.watch({
    host = "127.0.0.1",
    port = 6379,
})

watch:subscribe("channel1", "channel2")

while true do
    local data, channel = watch:message()  -- 阻塞等待
    print(channel, data)
end
```

---

## MySQL 驱动

```lua
local mysql = require "skynet.db.mysql"
```

### 连接

```lua
local db = mysql.connect({
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "123456",
    database = "test",
    charset = "utf8mb4",  -- 可选
})
```

### 查询

```lua
-- 文本查询
local rows = db:query("SELECT * FROM users WHERE id = 1")
-- rows = { {id=1, name="alice"}, {id=2, name="bob"} }

-- 多结果集
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

### 认证

MySQL 驱动使用 SHA1 challenge-response 认证（MySQL 4.1+ native_password），基于 `skynet.crypt` 纯 Lua SHA1 实现。

---

## MongoDB 驱动

```lua
local mongo = require "skynet.db.mongo"
local bson = require "bson"
```

### 连接

```lua
local client = mongo.client({
    host = "127.0.0.1",
    port = 27017,
})
```

### 数据库与集合

```lua
local db = client:getDB("mydb")
local coll = db:getCollection("users")
```

### CRUD 操作

```lua
-- 插入
coll:insert({ name = "alice", age = 25 })
coll:batch_insert({
    { name = "bob", age = 30 },
    { name = "charlie", age = 35 },
})

-- 查询
local user = coll:findOne({ name = "alice" })
local cursor = coll:find({ age = { ["$gte"] = 25 } })
local all = cursor:sort({ age = 1 }):limit(10):toArray()

-- 更新
coll:update({ name = "alice" }, { ["$set"] = { age = 26 } })

-- 删除
coll:delete({ name = "charlie" })

-- 计数
local n = coll:count({ age = { ["$gte"] = 25 } })

-- 聚合
local results = coll:aggregate({
    { ["$match"] = { age = { ["$gte"] = 25 } } },
    { ["$group"] = { _id = "$name", total = { ["$sum"] = 1 } } },
})

-- 索引
coll:createIndex({ name = 1 }, { unique = true })

-- 删除集合
coll:drop()

client:disconnect()
```

### Cursor API

```lua
local cursor = coll:find(query)
cursor:sort({ field = 1 })   -- 排序
cursor:skip(10)               -- 跳过
cursor:limit(20)              -- 限制

while cursor:hasNext() do
    local doc = cursor:next()
end

cursor:close()
```

### BSON 类型

```lua
local bson = require "bson"

-- ObjectId
local oid = bson.objectid()           -- 自动生成
local oid = bson.objectid("507f1f77bcf86cd799439011")  -- 从 hex

-- 64 位整数
local big = bson.int64(1234567890123)

-- 特殊值
local n = bson.null      -- BSON null
local mn = bson.minkey   -- BSON minkey
local mx = bson.maxkey   -- BSON maxkey

-- 编解码
local binary = bson.encode({ name = "test", value = 42 })
local doc = bson.decode(binary)

-- 保序编码
local binary = bson.encode_order("name", "test", "value", 42)
```

---

## Crypt 工具

```lua
local crypt = require "skynet.crypt"
```

纯 Lua 密码学函数，用于 MySQL 认证等场景：

| 函数 | 说明 |
|---|---|
| `crypt.sha1(msg)` | SHA-1 哈希（返回 20 字节二进制） |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Base64 编码 |
| `crypt.base64decode(data)` | Base64 解码 |
| `crypt.hexencode(data)` | 十六进制编码 |
| `crypt.hexdecode(data)` | 十六进制解码 |

---

## 与原版 skynet 的差异

- 原版数据库驱动部分使用 C 模块（如 BSON 编解码），skynet-cpp 全部为纯 Lua 实现
- 原版有 `skynet.dns` 模块做非阻塞域名查询，skynet-cpp 暂未实现
- 原版 crypt 通过 C 模块提供更多功能（DES/AES/RSA 等），skynet-cpp 仅提供 SHA1/HMAC/Base64/Hex
- 原版 MongoDB 驱动支持集群模式（备用地址），skynet-cpp 暂不支持

