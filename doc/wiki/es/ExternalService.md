# ExternalService
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Drivers de servicios externos de skynet-cpp (Redis / MySQL / MongoDB)

---

Debemos intentar completar toda la lógica de negocio dentro del mismo proceso skynet-cpp. Sin embargo, a veces es necesario utilizar servicios externos, como bases de datos.

skynet-cpp proporciona módulos de driver para Redis, MySQL y MongoDB. Estos drivers están basados en [SocketChannel](SocketChannel.md) y no bloquean los hilos de trabajo de skynet-cpp.

---

## Driver de Redis

```lua
local redis = require "skynet.db.redis"
```

### Conexión

```lua
local db = redis.connect({
    host = "127.0.0.1",
    port = 6379,
    auth = "password",    -- Opcional
    db = 0,               -- Opcional, número de base de datos SELECT
})
```

### Comandos

Todos los comandos de Redis se generan dinámicamente mediante metatable `__index`:

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

### Pipeline por lotes

```lua
local results = db:pipeline({
    {"set", "a", "1"},
    {"set", "b", "2"},
    {"get", "a"},
    {"get", "b"},
})
-- results = { "OK", "OK", "1", "2" }
```

### Pub/Sub (modo Watch)

```lua
local watch = redis.watch({
    host = "127.0.0.1",
    port = 6379,
})

watch:subscribe("channel1", "channel2")

while true do
    local data, channel = watch:message()  -- Bloquear esperando
    print(channel, data)
end
```

---

## Driver de MySQL

```lua
local mysql = require "skynet.db.mysql"
```

### Conexión

```lua
local db = mysql.connect({
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "123456",
    database = "test",
    charset = "utf8mb4",  -- Opcional
})
```

### Consultas

```lua
-- Consulta de texto
local rows = db:query("SELECT * FROM users WHERE id = 1")
-- rows = { {id=1, name="alice"}, {id=2, name="bob"} }

-- Múltiples conjuntos de resultados
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

### Autenticación

El driver de MySQL utiliza autenticación challenge-response SHA1 (MySQL 4.1+ native_password), basada en la implementación SHA1 en Lua puro de `skynet.crypt`.

---

## Driver de MongoDB

```lua
local mongo = require "skynet.db.mongo"
local bson = require "bson"
```

### Conexión

```lua
local client = mongo.client({
    host = "127.0.0.1",
    port = 27017,
})
```

### Base de datos y colecciones

```lua
local db = client:getDB("mydb")
local coll = db:getCollection("users")
```

### Operaciones CRUD

```lua
-- Insertar
coll:insert({ name = "alice", age = 25 })
coll:batch_insert({
    { name = "bob", age = 30 },
    { name = "charlie", age = 35 },
})

-- Consultar
local user = coll:findOne({ name = "alice" })
local cursor = coll:find({ age = { ["$gte"] = 25 } })
local all = cursor:sort({ age = 1 }):limit(10):toArray()

-- Actualizar
coll:update({ name = "alice" }, { ["$set"] = { age = 26 } })

-- Eliminar
coll:delete({ name = "charlie" })

-- Contar
local n = coll:count({ age = { ["$gte"] = 25 } })

-- Agregación
local results = coll:aggregate({
    { ["$match"] = { age = { ["$gte"] = 25 } } },
    { ["$group"] = { _id = "$name", total = { ["$sum"] = 1 } } },
})

-- Índice
coll:createIndex({ name = 1 }, { unique = true })

-- Eliminar colección
coll:drop()

client:disconnect()
```

### API de Cursor

```lua
local cursor = coll:find(query)
cursor:sort({ field = 1 })   -- Ordenar
cursor:skip(10)               -- Omitir
cursor:limit(20)              -- Limitar

while cursor:hasNext() do
    local doc = cursor:next()
end

cursor:close()
```

### Tipos BSON

```lua
local bson = require "bson"

-- ObjectId
local oid = bson.objectid()           -- Generar automáticamente
local oid = bson.objectid("507f1f77bcf86cd799439011")  -- Desde hex

-- Entero de 64 bits
local big = bson.int64(1234567890123)

-- Valores especiales
local n = bson.null      -- BSON null
local mn = bson.minkey   -- BSON minkey
local mx = bson.maxkey   -- BSON maxkey

-- Codificación/decodificación
local binary = bson.encode({ name = "test", value = 42 })
local doc = bson.decode(binary)

-- Codificación con orden preservado
local binary = bson.encode_order("name", "test", "value", 42)
```

---

## Herramientas Crypt

```lua
local crypt = require "skynet.crypt"
```

Funciones criptográficas en Lua puro, utilizadas para la autenticación de MySQL entre otros escenarios:

| Función | Descripción |
|---|---|
| `crypt.sha1(msg)` | Hash SHA-1 (devuelve 20 bytes binarios) |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Codificación Base64 |
| `crypt.base64decode(data)` | Decodificación Base64 |
| `crypt.hexencode(data)` | Codificación hexadecimal |
| `crypt.hexdecode(data)` | Decodificación hexadecimal |

---

## Diferencias con el skynet original

- Los drivers de base de datos del original usan parcialmente módulos en C (como codificación/decodificación BSON), en skynet-cpp todo está implementado en Lua puro
- El original tiene el módulo `skynet.dns` para consultas DNS no bloqueantes, skynet-cpp aún no lo ha implementado
- El crypt del original proporciona más funciones vía módulo C (DES/AES/RSA, etc.), skynet-cpp solo proporciona SHA1/HMAC/Base64/Hex
- El driver de MongoDB del original soporta modo clúster (direcciones de respaldo), skynet-cpp aún no lo soporta

