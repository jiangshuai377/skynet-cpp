# APIList
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Tabla de referencia rápida de API de todos los módulos de skynet-cpp

---

## skynet ([LuaAPI](LuaAPI.md))

### Construcción de servicios

| API | Descripción |
|---|---|
| `skynet.register_protocol(class)` | Registrar mecanismo de manejo de mensajes |
| `skynet.start(func)` | Inicializar servicio y registrar callback |
| `skynet.dispatch(type, func)` | Configurar función de manejo de mensajes |
| `skynet.getenv(key)` | Leer variable de entorno |
| `skynet.setenv(key, value)` | Establecer variable de entorno |

### Construcción del framework

| API | Descripción |
|---|---|
| `skynet.newservice(name, ...)` | Iniciar nuevo servicio Lua |
| `skynet.uniqueservice(name, ...)` | Iniciar servicio único |
| `skynet.queryservice(name)` | Consultar dirección de servicio único |
| `skynet.localname(name)` | Consultar nombre local |
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

### Planificación de tareas

| API | Descripción |
|---|---|
| `skynet.sleep(ti)` | Suspender ti centésimas de segundo |
| `skynet.yield()` | Ceder CPU |
| `skynet.wait(token)` | Esperar activación |
| `skynet.wakeup(token)` | Despertar corrutina |
| `skynet.fork(func, ...)` | Iniciar nueva corrutina |
| `skynet.timeout(ti, func)` | Ejecución temporizada |
| `skynet.now()` | Centésimas de segundo desde el inicio del proceso |
| `skynet.starttime()` | Tiempo UTC de inicio del proceso |
| `skynet.time()` | Tiempo UTC actual (segundos) |
| `skynet.self()` | Dirección del servicio actual |
| `skynet.address(addr)` | Formatear cadena de dirección |
| `skynet.exit()` | Salir del servicio actual |

### Transmisión de mensajes

| API | Descripción |
|---|---|
| `skynet.send(addr, type, ...)` | Envío asíncrono |
| `skynet.call(addr, type, ...)` | Llamada RPC síncrona |
| `skynet.rawsend(addr, type, msg, sz)` | Envío en crudo |
| `skynet.rawcall(addr, type, msg, sz)` | RPC en crudo |
| `skynet.ret(msg, sz)` | Responder mensaje |
| `skynet.retpack(...)` | Empaquetar y responder |
| `skynet.response([pack])` | Closure de respuesta diferida |
| `skynet.redirect(addr, src, type, session, ...)` | Envío suplantado |
| `skynet.error(...)` | Enviar log |
| `skynet.pack(...)` | Serializar |
| `skynet.unpack(msg, sz)` | Deserializar |
| `skynet.packstring(...)` | Serializar a string |
| `skynet.tostring(msg, sz)` | lightuserdata → string |
| `skynet.trash(msg, sz)` | Liberar lightuserdata |

### Gestión

| API | Descripción |
|---|---|
| `skynet.register(name)` | Registrar nombre de servicio |
| `skynet.name(name, addr)` | Registrar nombre para dirección |
| `skynet.kill(addr)` | Terminar servicio forzosamente |
| `skynet.harbor(addr)` | Siempre devuelve 0 |
| `skynet.genid()` | Generar session único |

---

## skynet.cluster ([Cluster](Cluster.md))

| API | Descripción |
|---|---|
| `cluster.call(node, addr, ...)` | Llamada RPC remota |
| `cluster.send(node, addr, ...)` | Envío asíncrono remoto |
| `cluster.open(addr, port)` | Abrir escucha del clúster |
| `cluster.reload(cfg)` | Recargar configuración del clúster |
| `cluster.register(name, addr)` | Registrar nombre |
| `cluster.unregister(name)` | Desregistrar nombre |
| `cluster.query(node, name)` | Consultar nombre remoto |

---

## skynet.queue ([CriticalSection](CriticalSection.md))

| API | Descripción |
|---|---|
| `queue()` | Crear cola de ejecución |
| `cs(func, ...)` | Ejecutar en serie en la cola |

---

## skynet.sharedata ([ShareData](ShareData.md))

| API | Descripción |
|---|---|
| `sharedata.new(name, value)` | Crear datos compartidos |
| `sharedata.query(name)` | Consultar datos compartidos |
| `sharedata.update(name, value)` | Actualizar datos compartidos |
| `sharedata.delete(name)` | Eliminar datos compartidos |
| `sharedata.flush()` | Limpiar caché local |
| `sharedata.deepcopy(name, ...)` | Copia profunda |

---

## skynet.multicast ([Multicast](Multicast.md))

| API | Descripción |
|---|---|
| `multicast.new(opts)` | Crear canal |
| `mc:subscribe()` | Suscribirse |
| `mc:unsubscribe()` | Cancelar suscripción |
| `mc:publish(...)` | Publicar mensaje |
| `mc:delete()` | Eliminar canal |

---

## skynet.socket ([Socket](Socket.md))

| API | Descripción |
|---|---|
| `socket.listen(host, port, handler)` | Escuchar puerto TCP |
| `socket.ondata(id, handler)` | Configurar callback de datos |
| `socket.connect(host, port)` | Conexión TCP |
| `socket.send(id, data)` | Enviar datos |
| `socket.write(lid, cid, data)` | Enviar a través de listener |
| `socket.read(id, sz)` | Leer datos |
| `socket.readline(id, sep)` | Leer por separador |
| `socket.readall(id)` | Leer todo |
| `socket.close(id)` | Cerrar conexión |
| `socket.close_listener(id)` | Cerrar listener |
| `socket.pause(lid, cid)` | Pausar lectura |
| `socket.resume(lid, cid)` | Reanudar lectura |
| `socket.udp(host, port, cb)` | Crear UDP |
| `socket.udp_send(id, data, host, port)` | Enviar UDP |

---

## skynet.socketchannel ([SocketChannel](SocketChannel.md))

| API | Descripción |
|---|---|
| `socketchannel.channel(desc)` | Crear channel |
| `channel:request(req, resp/session)` | Enviar solicitud y esperar respuesta |
| `channel:response(func)` | Solo recibir respuesta |
| `channel:connect(once)` | Conectar explícitamente |
| `channel:close()` | Cerrar channel |
| `channel:changehost(host, port)` | Cambiar dirección |
| `channel:read(sz)` | Leer bytes |
| `channel:readline(sep)` | Leer por separador |

---

## skynet.db.redis ([ExternalService](ExternalService.md#redis-驱动))

| API | Descripción |
|---|---|
| `redis.connect(conf)` | Conectar a Redis |
| `redis.watch(conf)` | Crear listener pub/sub |
| `db:*(...)` | Cualquier comando de Redis |
| `db:pipeline(ops)` | Ejecución por lotes |
| `db:disconnect()` | Desconectar |
| `watch:subscribe(...)` | Suscribirse a canal |
| `watch:message()` | Recibir mensaje |

---

## skynet.db.mysql ([ExternalService](ExternalService.md#mysql-驱动))

| API | Descripción |
|---|---|
| `mysql.connect(conf)` | Conectar a MySQL |
| `db:query(sql)` | Ejecutar consulta |
| `db:prepare(sql)` | Sentencia precompilada |
| `stmt:execute()` | Ejecutar precompilada |
| `stmt:close()` | Cerrar sentencia |
| `db:disconnect()` | Desconectar |

---

## skynet.db.mongo ([ExternalService](ExternalService.md#mongodb-驱动))

| API | Descripción |
|---|---|
| `mongo.client(conf)` | Conectar a MongoDB |
| `client:getDB(name)` | Obtener base de datos |
| `db:getCollection(name)` | Obtener colección |
| `db:runCommand(...)` | Ejecutar comando |
| `coll:insert(doc)` | Insertar |
| `coll:find(query, proj)` | Consultar |
| `coll:findOne(query, proj)` | Consultar registro único |
| `coll:update(q, u, upsert, multi)` | Actualizar |
| `coll:delete(query, single)` | Eliminar |
| `coll:count(query)` | Contar |
| `coll:aggregate(pipeline)` | Agregar |
| `coll:createIndex(keys, opts)` | Crear índice |
| `coll:drop()` | Eliminar colección |
| `cursor:sort/skip/limit/hasNext/next/close/toArray` | Operaciones de cursor |

---

## bson ([ExternalService](ExternalService.md#mongodb-驱动))

| API | Descripción |
|---|---|
| `bson.encode(doc)` | Codificar BSON |
| `bson.encode_order(k1, v1, ...)` | Codificación con orden preservado |
| `bson.decode(data)` | Decodificar BSON |
| `bson.objectid(hex)` | ObjectId |
| `bson.int64(value)` | Entero de 64 bits |
| `bson.null` | Constante null |

---

## skynet.crypt ([ExternalService](ExternalService.md#crypt-工具))

| API | Descripción |
|---|---|
| `crypt.sha1(msg)` | Hash SHA-1 |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Codificación Base64 |
| `crypt.base64decode(data)` | Decodificación Base64 |
| `crypt.hexencode(data)` | Codificación Hex |
| `crypt.hexdecode(data)` | Decodificación Hex |

---

## skynet.profile ([DebugConsole](DebugConsole.md))

| API | Descripción |
|---|---|
| `profile.start([co])` | Iniciar cronometraje |
| `profile.stop([co])` | Detener cronometraje |
| `profile.resume(co, ...)` | Resume con cronometraje |
| `profile.wrap(f)` | Crear envoltorio con cronometraje |


