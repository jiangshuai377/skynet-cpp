# ExternalService
## État Actuel de l'Implémentation

Le runtime actuel utilise le bootstrap par preload : `SKYNET_THREAD` définit le nombre de workers et `SKYNET_PRELOAD` choisit le script preload. Le preload configure Lua path/cpath/service path, démarre le launcher et choisit l'entrée applicative. Les points d'entrée de test sont séparés en `tests/logic`, `tests/stress` et `tests/perf`, avec des runners dédiés pour coverage et perf Linux Docker. L'ordonnancement actor utilise `ActorQueue`, registry shardé et atomic wakeup ; le callback Lua et le contexte actor de `skynet.core` sont mis en cache sur le hot path.

> Pilotes de services externes de skynet-cpp (Redis / MySQL / MongoDB)

---

Nous devons autant que possible accomplir toute la logique métier au sein du même processus skynet-cpp. Mais parfois il est nécessaire d'utiliser des services externes, comme les bases de données.

skynet-cpp fournit des modules pilotes pour Redis, MySQL et MongoDB. Ces pilotes sont basés sur [SocketChannel](SocketChannel.md) et ne bloquent pas les threads de travail de skynet-cpp.

---

## Pilote Redis

```lua
local redis = require "skynet.db.redis"
```

### Connexion

```lua
local db = redis.connect({
    host = "127.0.0.1",
    port = 6379,
    auth = "password",    -- optionnel
    db = 0,               -- optionnel, numéro de base SELECT
})
```

### Commandes

Toutes les commandes Redis sont générées dynamiquement via le metatable `__index` :

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

### Pipeline (lot)

```lua
local results = db:pipeline({
    {"set", "a", "1"},
    {"set", "b", "2"},
    {"get", "a"},
    {"get", "b"},
})
-- results = { "OK", "OK", "1", "2" }
```

### Pub/Sub (mode Watch)

```lua
local watch = redis.watch({
    host = "127.0.0.1",
    port = 6379,
})

watch:subscribe("channel1", "channel2")

while true do
    local data, channel = watch:message()  -- Attente bloquante
    print(channel, data)
end
```

---

## Pilote MySQL

```lua
local mysql = require "skynet.db.mysql"
```

### Connexion

```lua
local db = mysql.connect({
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "123456",
    database = "test",
    charset = "utf8mb4",  -- optionnel
})
```

### Requêtes

```lua
-- Requête textuelle
local rows = db:query("SELECT * FROM users WHERE id = 1")
-- rows = { {id=1, name="alice"}, {id=2, name="bob"} }

-- Ensembles de résultats multiples
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

### Authentification

Le pilote MySQL utilise l'authentification challenge-response SHA1 (MySQL 4.1+ native_password), basée sur l'implémentation SHA1 en Lua pur de `skynet.crypt`.

---

## Pilote MongoDB

```lua
local mongo = require "skynet.db.mongo"
local bson = require "bson"
```

### Connexion

```lua
local client = mongo.client({
    host = "127.0.0.1",
    port = 27017,
})
```

### Base de données et collection

```lua
local db = client:getDB("mydb")
local coll = db:getCollection("users")
```

### Opérations CRUD

```lua
-- Insertion
coll:insert({ name = "alice", age = 25 })
coll:batch_insert({
    { name = "bob", age = 30 },
    { name = "charlie", age = 35 },
})

-- Requête
local user = coll:findOne({ name = "alice" })
local cursor = coll:find({ age = { ["$gte"] = 25 } })
local all = cursor:sort({ age = 1 }):limit(10):toArray()

-- Mise à jour
coll:update({ name = "alice" }, { ["$set"] = { age = 26 } })

-- Suppression
coll:delete({ name = "charlie" })

-- Comptage
local n = coll:count({ age = { ["$gte"] = 25 } })

-- Agrégation
local results = coll:aggregate({
    { ["$match"] = { age = { ["$gte"] = 25 } } },
    { ["$group"] = { _id = "$name", total = { ["$sum"] = 1 } } },
})

-- Index
coll:createIndex({ name = 1 }, { unique = true })

-- Supprimer la collection
coll:drop()

client:disconnect()
```

### API Cursor

```lua
local cursor = coll:find(query)
cursor:sort({ field = 1 })   -- Tri
cursor:skip(10)               -- Saut
cursor:limit(20)              -- Limite

while cursor:hasNext() do
    local doc = cursor:next()
end

cursor:close()
```

### Types BSON

```lua
local bson = require "bson"

-- ObjectId
local oid = bson.objectid()           -- Génération automatique
local oid = bson.objectid("507f1f77bcf86cd799439011")  -- Depuis hex

-- Entier 64 bits
local big = bson.int64(1234567890123)

-- Valeurs spéciales
local n = bson.null      -- BSON null
local mn = bson.minkey   -- BSON minkey
local mx = bson.maxkey   -- BSON maxkey

-- Encodage/décodage
local binary = bson.encode({ name = "test", value = 42 })
local doc = bson.decode(binary)

-- Encodage avec ordre préservé
local binary = bson.encode_order("name", "test", "value", 42)
```

---

## Outils Crypt

```lua
local crypt = require "skynet.crypt"
```

Fonctions cryptographiques en Lua pur, utilisées pour l'authentification MySQL et autres :

| Fonction | Description |
|---|---|
| `crypt.sha1(msg)` | Hachage SHA-1 (retourne 20 octets binaires) |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Encodage Base64 |
| `crypt.base64decode(data)` | Décodage Base64 |
| `crypt.hexencode(data)` | Encodage hexadécimal |
| `crypt.hexdecode(data)` | Décodage hexadécimal |

---

## Différences avec le skynet original

- Les pilotes de base de données originaux utilisent partiellement des modules C (comme l'encodage/décodage BSON), skynet-cpp est entièrement en Lua pur
- L'original a le module `skynet.dns` pour la résolution de noms non bloquante, non encore implémenté dans skynet-cpp
- Le module crypt original fournit plus de fonctionnalités via un module C (DES/AES/RSA etc.), skynet-cpp ne fournit que SHA1/HMAC/Base64/Hex
- Le pilote MongoDB original supporte le mode cluster (adresses de secours), non encore supporté par skynet-cpp

