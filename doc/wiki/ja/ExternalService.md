# ExternalService
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離され、coverage と Linux Docker perf は専用 runner を持ちます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp 外部サービスドライバ（Redis / MySQL / MongoDB）

---

できる限り同一の skynet-cpp プロセス内ですべてのビジネスロジックを完結させるべきです。しかし、データベースなどの外部サービスを使用しなければならない場合もあります。

skynet-cpp は Redis、MySQL、MongoDB のドライバモジュールを提供しています。これらのドライバは [SocketChannel](SocketChannel.md) をベースに実装されており、skynet-cpp のワーカースレッドをブロックしません。

---

## Redis ドライバ

```lua
local redis = require "skynet.db.redis"
```

### 接続

```lua
local db = redis.connect({
    host = "127.0.0.1",
    port = 6379,
    auth = "password",    -- オプション
    db = 0,               -- オプション、SELECT データベース番号
})
```

### コマンド

すべての Redis コマンドは metatable `__index` により動的に生成されます：

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

### Pipeline バッチ処理

```lua
local results = db:pipeline({
    {"set", "a", "1"},
    {"set", "b", "2"},
    {"get", "a"},
    {"get", "b"},
})
-- results = { "OK", "OK", "1", "2" }
```

### Pub/Sub (Watch モード)

```lua
local watch = redis.watch({
    host = "127.0.0.1",
    port = 6379,
})

watch:subscribe("channel1", "channel2")

while true do
    local data, channel = watch:message()  -- ブロッキング待ち
    print(channel, data)
end
```

---

## MySQL ドライバ

```lua
local mysql = require "skynet.db.mysql"
```

### 接続

```lua
local db = mysql.connect({
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "123456",
    database = "test",
    charset = "utf8mb4",  -- オプション
})
```

### クエリ

```lua
-- テキストクエリ
local rows = db:query("SELECT * FROM users WHERE id = 1")
-- rows = { {id=1, name="alice"}, {id=2, name="bob"} }

-- 複数結果セット
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

### 認証

MySQL ドライバは SHA1 challenge-response 認証（MySQL 4.1+ native_password）を使用し、`skynet.crypt` の純 Lua SHA1 実装に基づいています。

---

## MongoDB ドライバ

```lua
local mongo = require "skynet.db.mongo"
local bson = require "bson"
```

### 接続

```lua
local client = mongo.client({
    host = "127.0.0.1",
    port = 27017,
})
```

### データベースとコレクション

```lua
local db = client:getDB("mydb")
local coll = db:getCollection("users")
```

### CRUD 操作

```lua
-- 挿入
coll:insert({ name = "alice", age = 25 })
coll:batch_insert({
    { name = "bob", age = 30 },
    { name = "charlie", age = 35 },
})

-- クエリ
local user = coll:findOne({ name = "alice" })
local cursor = coll:find({ age = { ["$gte"] = 25 } })
local all = cursor:sort({ age = 1 }):limit(10):toArray()

-- 更新
coll:update({ name = "alice" }, { ["$set"] = { age = 26 } })

-- 削除
coll:delete({ name = "charlie" })

-- カウント
local n = coll:count({ age = { ["$gte"] = 25 } })

-- 集約
local results = coll:aggregate({
    { ["$match"] = { age = { ["$gte"] = 25 } } },
    { ["$group"] = { _id = "$name", total = { ["$sum"] = 1 } } },
})

-- インデックス
coll:createIndex({ name = 1 }, { unique = true })

-- コレクションの削除
coll:drop()

client:disconnect()
```

### Cursor API

```lua
local cursor = coll:find(query)
cursor:sort({ field = 1 })   -- ソート
cursor:skip(10)               -- スキップ
cursor:limit(20)              -- 制限

while cursor:hasNext() do
    local doc = cursor:next()
end

cursor:close()
```

### BSON タイプ

```lua
local bson = require "bson"

-- ObjectId
local oid = bson.objectid()           -- 自動生成
local oid = bson.objectid("507f1f77bcf86cd799439011")  -- hex から

-- 64 ビット整数
local big = bson.int64(1234567890123)

-- 特殊値
local n = bson.null      -- BSON null
local mn = bson.minkey   -- BSON minkey
local mx = bson.maxkey   -- BSON maxkey

-- エンコード/デコード
local binary = bson.encode({ name = "test", value = 42 })
local doc = bson.decode(binary)

-- 順序保持エンコード
local binary = bson.encode_order("name", "test", "value", 42)
```

---

## Crypt ツール

```lua
local crypt = require "skynet.crypt"
```

MySQL 認証などのシナリオ用の純 Lua 暗号関数：

| 関数 | 説明 |
|---|---|
| `crypt.sha1(msg)` | SHA-1 ハッシュ（20 バイトバイナリを返す） |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Base64 エンコード |
| `crypt.base64decode(data)` | Base64 デコード |
| `crypt.hexencode(data)` | 16 進数エンコード |
| `crypt.hexdecode(data)` | 16 進数デコード |

---

## オリジナル skynet との差異

- オリジナルのデータベースドライバは一部 C モジュールを使用（例：BSON エンコード/デコード）、skynet-cpp はすべて純 Lua 実装
- オリジナルには `skynet.dns` モジュールでノンブロッキング DNS 照会が可能、skynet-cpp は未実装
- オリジナルの crypt は C モジュール経由でより多くの機能を提供（DES/AES/RSA 等）、skynet-cpp は SHA1/HMAC/Base64/Hex のみ提供
- オリジナルの MongoDB ドライバはクラスタモード対応（バックアップアドレス）、skynet-cpp は未サポート

