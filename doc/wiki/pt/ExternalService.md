# ExternalService
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`; o repositório runtime mantém apenas ferramentas mínimas de verify/package/package smoke/Linux coverage smoke, enquanto full coverage, perf, Docker DB, soak e comparação nativa ficam na camada pai `testa/tools`. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Drivers de serviços externos do skynet-cpp (Redis / MySQL / MongoDB)

---

Devemos tentar ao máximo completar toda a lógica de negócio dentro do mesmo processo skynet-cpp. Porém, às vezes é necessário usar serviços externos, como bancos de dados.

O skynet-cpp fornece módulos de driver para Redis, MySQL e MongoDB. Estes drivers são baseados no [SocketChannel](SocketChannel.md) e não bloqueiam as threads de trabalho do skynet-cpp.

---

## Driver Redis

```lua
local redis = require "skynet.db.redis"
```

### Conexão

```lua
local db = redis.connect({
    host = "127.0.0.1",
    port = 6379,
    auth = "password",    -- opcional
    db = 0,               -- opcional, número do banco de dados SELECT
})
```

### Comandos

Todos os comandos Redis são gerados dinamicamente via metatable `__index`:

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

### Pipeline em lote

```lua
local results = db:pipeline({
    {"set", "a", "1"},
    {"set", "b", "2"},
    {"get", "a"},
    {"get", "b"},
})
-- results = { "OK", "OK", "1", "2" }
```

### Pub/Sub (Modo Watch)

```lua
local watch = redis.watch({
    host = "127.0.0.1",
    port = 6379,
})

watch:subscribe("channel1", "channel2")

while true do
    local data, channel = watch:message()  -- bloqueia aguardando
    print(channel, data)
end
```

---

## Driver MySQL

```lua
local mysql = require "skynet.db.mysql"
```

### Conexão

```lua
local db = mysql.connect({
    host = "127.0.0.1",
    port = 3306,
    user = "root",
    password = "123456",
    database = "test",
    charset = "utf8mb4",  -- opcional
})
```

### Consultas

```lua
-- Consulta de texto
local rows = db:query("SELECT * FROM users WHERE id = 1")
-- rows = { {id=1, name="alice"}, {id=2, name="bob"} }

-- Múltiplos conjuntos de resultados
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

### Autenticação

O driver MySQL usa autenticação challenge-response SHA1 (MySQL 4.1+ native_password), baseada na implementação de SHA1 em Lua puro do `skynet.crypt`.

---

## Driver MongoDB

```lua
local mongo = require "skynet.db.mongo"
local bson = require "bson"
```

### Conexão

```lua
local client = mongo.client({
    host = "127.0.0.1",
    port = 27017,
})
```

### Base de dados e coleções

```lua
local db = client:getDB("mydb")
local coll = db:getCollection("users")
```

### Operações CRUD

```lua
-- Inserir
coll:insert({ name = "alice", age = 25 })
coll:batch_insert({
    { name = "bob", age = 30 },
    { name = "charlie", age = 35 },
})

-- Consultar
local user = coll:findOne({ name = "alice" })
local cursor = coll:find({ age = { ["$gte"] = 25 } })
local all = cursor:sort({ age = 1 }):limit(10):toArray()

-- Atualizar
coll:update({ name = "alice" }, { ["$set"] = { age = 26 } })

-- Deletar
coll:delete({ name = "charlie" })

-- Contar
local n = coll:count({ age = { ["$gte"] = 25 } })

-- Agregar
local results = coll:aggregate({
    { ["$match"] = { age = { ["$gte"] = 25 } } },
    { ["$group"] = { _id = "$name", total = { ["$sum"] = 1 } } },
})

-- Índice
coll:createIndex({ name = 1 }, { unique = true })

-- Deletar coleção
coll:drop()

client:disconnect()
```

### API Cursor

```lua
local cursor = coll:find(query)
cursor:sort({ field = 1 })   -- Ordenar
cursor:skip(10)               -- Pular
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
local oid = bson.objectid()           -- gerado automaticamente
local oid = bson.objectid("507f1f77bcf86cd799439011")  -- a partir de hex

-- Inteiro de 64 bits
local big = bson.int64(1234567890123)

-- Valores especiais
local n = bson.null      -- BSON null
local mn = bson.minkey   -- BSON minkey
local mx = bson.maxkey   -- BSON maxkey

-- Codificação e decodificação
local binary = bson.encode({ name = "test", value = 42 })
local doc = bson.decode(binary)

-- Codificação com ordem preservada
local binary = bson.encode_order("name", "test", "value", 42)
```

---

## Ferramentas criptográficas

```lua
local crypt = require "skynet.crypt"
```

Funções criptográficas em Lua puro, usadas para autenticação MySQL entre outros cenários:

| Função | Descrição |
|---|---|
| `crypt.sha1(msg)` | Hash SHA-1 (retorna 20 bytes binários) |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Codificação Base64 |
| `crypt.base64decode(data)` | Decodificação Base64 |
| `crypt.hexencode(data)` | Codificação hexadecimal |
| `crypt.hexdecode(data)` | Decodificação hexadecimal |

---

## Diferenças em relação ao skynet original

- Os drivers de banco de dados originais usam parcialmente módulos C (como codificação/decodificação BSON), o skynet-cpp é totalmente implementado em Lua puro
- O original tem módulo `skynet.dns` para resolução de nomes de domínio não bloqueante, o skynet-cpp ainda não implementou
- O crypt original fornece mais funcionalidades via módulo C (DES/AES/RSA etc.), o skynet-cpp fornece apenas SHA1/HMAC/Base64/Hex
- O driver MongoDB original suporta modo cluster (endereços de backup), o skynet-cpp ainda não suporta

