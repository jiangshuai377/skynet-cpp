# APIList
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`; o repositório runtime mantém apenas ferramentas mínimas de verify/package/package smoke/Linux coverage smoke, enquanto full coverage, perf, Docker DB, soak e comparação nativa ficam na camada pai `testa/tools`. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Tabela de referência rápida de todas as APIs dos módulos do skynet-cpp

---

## skynet ([LuaAPI](LuaAPI.md))

### Construção de serviço

| API | Descrição |
|---|---|
| `skynet.register_protocol(class)` | Registra mecanismo de tratamento de mensagens |
| `skynet.start(func)` | Inicializa serviço e registra callback |
| `skynet.dispatch(type, func)` | Define função de tratamento de mensagens |
| `skynet.getenv(key)` | Lê variável de ambiente |
| `skynet.setenv(key, value)` | Define variável de ambiente |

### Construção do framework

| API | Descrição |
|---|---|
| `skynet.newservice(name, ...)` | Inicia novo serviço Lua |
| `skynet.uniqueservice(name, ...)` | Inicia serviço único |
| `skynet.queryservice(name)` | Consulta endereço de serviço único |
| `skynet.localname(name)` | Consulta nome local |
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

### Agendamento de tarefas

| API | Descrição |
|---|---|
| `skynet.sleep(ti)` | Suspende por ti centissegundos |
| `skynet.yield()` | Cede a CPU |
| `skynet.wait(token)` | Aguarda ativação |
| `skynet.wakeup(token)` | Acorda corrotina |
| `skynet.fork(func, ...)` | Inicia nova corrotina |
| `skynet.timeout(ti, func)` | Execução temporizada |
| `skynet.now()` | Centissegundos desde início do processo |
| `skynet.starttime()` | Tempo UTC de início do processo |
| `skynet.time()` | Tempo UTC atual (segundos) |
| `skynet.self()` | Endereço do serviço atual |
| `skynet.address(addr)` | Formata string de endereço |
| `skynet.exit()` | Encerra serviço atual |

### Passagem de mensagens

| API | Descrição |
|---|---|
| `skynet.send(addr, type, ...)` | Envio assíncrono |
| `skynet.call(addr, type, ...)` | Chamada RPC síncrona |
| `skynet.rawsend(addr, type, msg, sz)` | Envio bruto |
| `skynet.rawcall(addr, type, msg, sz)` | RPC bruto |
| `skynet.ret(msg, sz)` | Responde mensagem |
| `skynet.retpack(...)` | Empacota e responde |
| `skynet.response([pack])` | Closure de resposta atrasada |
| `skynet.redirect(addr, src, type, session, ...)` | Envio disfarçado |
| `skynet.error(...)` | Envia log |
| `skynet.pack(...)` | Serializa |
| `skynet.unpack(msg, sz)` | Desserializa |
| `skynet.packstring(...)` | Serializa para string |
| `skynet.tostring(msg, sz)` | lightuserdata → string |
| `skynet.trash(msg, sz)` | Libera lightuserdata |

### Gerenciamento

| API | Descrição |
|---|---|
| `skynet.register(name)` | Registra nome do serviço |
| `skynet.name(name, addr)` | Registra nome para endereço |
| `skynet.kill(addr)` | Termina serviço forçosamente |
| `skynet.harbor(addr)` | Sempre retorna 0 |
| `skynet.genid()` | Gera session único |

---

## skynet.cluster ([Cluster](Cluster.md))

| API | Descrição |
|---|---|
| `cluster.call(node, addr, ...)` | Chamada RPC remota |
| `cluster.send(node, addr, ...)` | Push assíncrono remoto |
| `cluster.open(addr, port)` | Abre escuta do cluster |
| `cluster.reload(cfg)` | Recarrega configuração do cluster |
| `cluster.register(name, addr)` | Registra nome |
| `cluster.unregister(name)` | Cancela registro do nome |
| `cluster.query(node, name)` | Consulta nome remoto |

---

## skynet.queue ([CriticalSection](CriticalSection.md))

| API | Descrição |
|---|---|
| `queue()` | Cria fila de execução |
| `cs(func, ...)` | Executa serialmente na fila |

---

## skynet.sharedata ([ShareData](ShareData.md))

| API | Descrição |
|---|---|
| `sharedata.new(name, value)` | Cria dados compartilhados |
| `sharedata.query(name)` | Consulta dados compartilhados |
| `sharedata.update(name, value)` | Atualiza dados compartilhados |
| `sharedata.delete(name)` | Deleta dados compartilhados |
| `sharedata.flush()` | Limpa cache local |
| `sharedata.deepcopy(name, ...)` | Cópia profunda |

---

## skynet.multicast ([Multicast](Multicast.md))

| API | Descrição |
|---|---|
| `multicast.new(opts)` | Cria canal |
| `mc:subscribe()` | Assina |
| `mc:unsubscribe()` | Cancela assinatura |
| `mc:publish(...)` | Publica mensagem |
| `mc:delete()` | Deleta canal |

---

## skynet.socket ([Socket](Socket.md))

| API | Descrição |
|---|---|
| `socket.listen(host, port, handler)` | Escuta porta TCP |
| `socket.ondata(id, handler)` | Define callback de dados |
| `socket.connect(host, port)` | Conexão TCP |
| `socket.send(id, data)` | Envia dados |
| `socket.write(lid, cid, data)` | Envia via listener |
| `socket.read(id, sz)` | Lê dados |
| `socket.readline(id, sep)` | Lê por separador |
| `socket.readall(id)` | Lê tudo |
| `socket.close(id)` | Fecha conexão |
| `socket.close_listener(id)` | Fecha escuta |
| `socket.pause(lid, cid)` | Pausa leitura |
| `socket.resume(lid, cid)` | Retoma leitura |
| `socket.udp(host, port, cb)` | Cria UDP |
| `socket.udp_send(id, data, host, port)` | Envia UDP |

---

## skynet.socketchannel ([SocketChannel](SocketChannel.md))

| API | Descrição |
|---|---|
| `socketchannel.channel(desc)` | Cria channel |
| `channel:request(req, resp/session)` | Envia solicitação e aguarda resposta |
| `channel:response(func)` | Apenas recebe resposta |
| `channel:connect(once)` | Conexão explícita |
| `channel:close()` | Fecha channel |
| `channel:changehost(host, port)` | Altera endereço |
| `channel:read(sz)` | Lê bytes |
| `channel:readline(sep)` | Lê por separador |

---

## skynet.db.redis ([ExternalService](ExternalService.md#redis-驱动))

| API | Descrição |
|---|---|
| `redis.connect(conf)` | Conecta ao Redis |
| `redis.watch(conf)` | Cria listener pub/sub |
| `db:*(...)` | Qualquer comando Redis |
| `db:pipeline(ops)` | Execução em lote |
| `db:disconnect()` | Desconecta |
| `watch:subscribe(...)` | Assina canais |
| `watch:message()` | Recebe mensagens |

---

## skynet.db.mysql ([ExternalService](ExternalService.md#mysql-驱动))

| API | Descrição |
|---|---|
| `mysql.connect(conf)` | Conecta ao MySQL |
| `db:query(sql)` | Executa consulta |
| `db:prepare(sql)` | Prepared Statement |
| `stmt:execute()` | Executa prepared |
| `stmt:close()` | Fecha statement |
| `db:disconnect()` | Desconecta |

---

## skynet.db.mongo ([ExternalService](ExternalService.md#mongodb-驱动))

| API | Descrição |
|---|---|
| `mongo.client(conf)` | Conecta ao MongoDB |
| `client:getDB(name)` | Obtém banco de dados |
| `db:getCollection(name)` | Obtém coleção |
| `db:runCommand(...)` | Executa comando |
| `coll:insert(doc)` | Insere |
| `coll:find(query, proj)` | Consulta |
| `coll:findOne(query, proj)` | Consulta único |
| `coll:update(q, u, upsert, multi)` | Atualiza |
| `coll:delete(query, single)` | Deleta |
| `coll:count(query)` | Conta |
| `coll:aggregate(pipeline)` | Agrega |
| `coll:createIndex(keys, opts)` | Cria índice |
| `coll:drop()` | Deleta coleção |
| `cursor:sort/skip/limit/hasNext/next/close/toArray` | Operações de cursor |

---

## bson ([ExternalService](ExternalService.md#mongodb-驱动))

| API | Descrição |
|---|---|
| `bson.encode(doc)` | Codifica BSON |
| `bson.encode_order(k1, v1, ...)` | Codificação com ordem preservada |
| `bson.decode(data)` | Decodifica BSON |
| `bson.objectid(hex)` | ObjectId |
| `bson.int64(value)` | Inteiro de 64 bits |
| `bson.null` | Constante null |

---

## skynet.crypt ([ExternalService](ExternalService.md#crypt-工具))

| API | Descrição |
|---|---|
| `crypt.sha1(msg)` | Hash SHA-1 |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Codificação Base64 |
| `crypt.base64decode(data)` | Decodificação Base64 |
| `crypt.hexencode(data)` | Codificação Hex |
| `crypt.hexdecode(data)` | Decodificação Hex |

---

## skynet.profile ([DebugConsole](DebugConsole.md))

| API | Descrição |
|---|---|
| `profile.start([co])` | Inicia cronometragem |
| `profile.stop([co])` | Para cronometragem |
| `profile.resume(co, ...)` | resume com cronometragem |
| `profile.wrap(f)` | Cria wrapper com cronometragem |


