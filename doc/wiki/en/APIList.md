# APIList
## Current Implementation Status

The current runtime uses the preload bootstrap path: set `SKYNET_THREAD` for worker count and `SKYNET_PRELOAD` for the preload script. The preload script configures Lua path/cpath/service path, starts launcher, and selects the application entry. Test entrypoints are split into `tests/logic`, `tests/stress`, and `tests/perf`; the runtime repository keeps only minimal verify/package/package smoke/Linux coverage smoke tools, while full coverage, perf, Docker DB, soak, and native comparisons live in the parent `testa/tools` layer. Actor scheduling now uses `ActorQueue`, sharded registry, and atomic wakeup; Lua callback and `skynet.core` actor context are cached on the hot path.

> skynet-cpp All Module API Quick Reference

---

## skynet ([LuaAPI](LuaAPI.md))

### Service Construction

| API | Description |
|---|---|
| `skynet.register_protocol(class)` | Register a message handling mechanism |
| `skynet.start(func)` | Initialize the service and register callbacks |
| `skynet.dispatch(type, func)` | Set the message handler function |
| `skynet.getenv(key)` | Read an environment variable |
| `skynet.setenv(key, value)` | Set an environment variable |

### Framework Construction

| API | Description |
|---|---|
| `skynet.newservice(name, ...)` | Start a new Lua service |
| `skynet.uniqueservice(name, ...)` | Start a unique service |
| `skynet.queryservice(name)` | Query a unique service address |
| `skynet.localname(name)` | Query a local name |
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

### Task Scheduling

| API | Description |
|---|---|
| `skynet.sleep(ti)` | Suspend for ti centiseconds |
| `skynet.yield()` | Yield the CPU |
| `skynet.wait(token)` | Wait for wakeup |
| `skynet.wakeup(token)` | Wake up a coroutine |
| `skynet.fork(func, ...)` | Start a new coroutine |
| `skynet.timeout(ti, func)` | Execute after a delay |
| `skynet.now()` | Centiseconds elapsed since process start |
| `skynet.starttime()` | Process start UTC time |
| `skynet.time()` | Current UTC time (seconds) |
| `skynet.self()` | Current service address |
| `skynet.address(addr)` | Format address as string |
| `skynet.exit()` | Exit the current service |

### Message Passing

| API | Description |
|---|---|
| `skynet.send(addr, type, ...)` | Asynchronous send |
| `skynet.call(addr, type, ...)` | Synchronous RPC call |
| `skynet.rawsend(addr, type, msg, sz)` | Raw send |
| `skynet.rawcall(addr, type, msg, sz)` | Raw RPC |
| `skynet.ret(msg, sz)` | Respond to a message |
| `skynet.retpack(...)` | Pack and respond |
| `skynet.response([pack])` | Deferred response closure |
| `skynet.redirect(addr, src, type, session, ...)` | Send with spoofed source |
| `skynet.error(...)` | Send log message |
| `skynet.pack(...)` | Serialize |
| `skynet.unpack(msg, sz)` | Deserialize |
| `skynet.packstring(...)` | Serialize to string |
| `skynet.tostring(msg, sz)` | lightuserdata → string |
| `skynet.trash(msg, sz)` | Free lightuserdata |

### Management

| API | Description |
|---|---|
| `skynet.register(name)` | Register a service name |
| `skynet.name(name, addr)` | Register a name for an address |
| `skynet.kill(addr)` | Forcefully terminate a service |
| `skynet.harbor(addr)` | Always returns 0 |
| `skynet.genid()` | Generate a unique session ID |

---

## skynet.cluster ([Cluster](Cluster.md))

| API | Description |
|---|---|
| `cluster.call(node, addr, ...)` | Remote RPC call |
| `cluster.send(node, addr, ...)` | Remote asynchronous push |
| `cluster.open(addr, port)` | Open cluster listener |
| `cluster.reload(cfg)` | Reload cluster configuration |
| `cluster.register(name, addr)` | Register a name |
| `cluster.unregister(name)` | Unregister a name |
| `cluster.query(node, name)` | Query a remote name |

---

## skynet.queue ([CriticalSection](CriticalSection.md))

| API | Description |
|---|---|
| `queue()` | Create an execution queue |
| `cs(func, ...)` | Execute serially in the queue |

---

## skynet.sharedata ([ShareData](ShareData.md))

| API | Description |
|---|---|
| `sharedata.new(name, value)` | Create shared data |
| `sharedata.query(name)` | Query shared data |
| `sharedata.update(name, value)` | Update shared data |
| `sharedata.delete(name)` | Delete shared data |
| `sharedata.flush()` | Clear local cache |
| `sharedata.deepcopy(name, ...)` | Deep copy |

---

## skynet.multicast ([Multicast](Multicast.md))

| API | Description |
|---|---|
| `multicast.new(opts)` | Create a channel |
| `mc:subscribe()` | Subscribe |
| `mc:unsubscribe()` | Unsubscribe |
| `mc:publish(...)` | Publish a message |
| `mc:delete()` | Delete a channel |

---

## skynet.socket ([Socket](Socket.md))

| API | Description |
|---|---|
| `socket.listen(host, port, handler)` | Listen on a TCP port |
| `socket.ondata(id, handler)` | Set data callback |
| `socket.connect(host, port)` | TCP connect |
| `socket.send(id, data)` | Send data |
| `socket.write(lid, cid, data)` | Send through a listener |
| `socket.read(id, sz)` | Read data |
| `socket.readline(id, sep)` | Read by delimiter |
| `socket.readall(id)` | Read all |
| `socket.close(id)` | Close connection |
| `socket.close_listener(id)` | Close listener |
| `socket.pause(lid, cid)` | Pause reading |
| `socket.resume(lid, cid)` | Resume reading |
| `socket.udp(host, port, cb)` | Create UDP |
| `socket.udp_send(id, data, host, port)` | Send UDP |

---

## skynet.socketchannel ([SocketChannel](SocketChannel.md))

| API | Description |
|---|---|
| `socketchannel.channel(desc)` | Create a channel |
| `channel:request(req, resp/session)` | Send request and wait for response |
| `channel:response(func)` | Receive response only |
| `channel:connect(once)` | Explicitly connect |
| `channel:close()` | Close channel |
| `channel:changehost(host, port)` | Change address |
| `channel:read(sz)` | Read bytes |
| `channel:readline(sep)` | Read by delimiter |

---

## skynet.db.redis ([ExternalService](ExternalService.md#redis-driver))

| API | Description |
|---|---|
| `redis.connect(conf)` | Connect to Redis |
| `redis.watch(conf)` | Create a pub/sub watcher |
| `db:*(...)` | Any Redis command |
| `db:pipeline(ops)` | Batch execution |
| `db:disconnect()` | Disconnect |
| `watch:subscribe(...)` | Subscribe to channels |
| `watch:message()` | Receive a message |

---

## skynet.db.mysql ([ExternalService](ExternalService.md#mysql-driver))

| API | Description |
|---|---|
| `mysql.connect(conf)` | Connect to MySQL |
| `db:query(sql)` | Execute a query |
| `db:prepare(sql)` | Prepare a statement |
| `stmt:execute()` | Execute prepared statement |
| `stmt:close()` | Close statement |
| `db:disconnect()` | Disconnect |

---

## skynet.db.mongo ([ExternalService](ExternalService.md#mongodb-driver))

| API | Description |
|---|---|
| `mongo.client(conf)` | Connect to MongoDB |
| `client:getDB(name)` | Get database |
| `db:getCollection(name)` | Get collection |
| `db:runCommand(...)` | Execute command |
| `coll:insert(doc)` | Insert |
| `coll:find(query, proj)` | Query |
| `coll:findOne(query, proj)` | Query single document |
| `coll:update(q, u, upsert, multi)` | Update |
| `coll:delete(query, single)` | Delete |
| `coll:count(query)` | Count |
| `coll:aggregate(pipeline)` | Aggregate |
| `coll:createIndex(keys, opts)` | Create index |
| `coll:drop()` | Drop collection |
| `cursor:sort/skip/limit/hasNext/next/close/toArray` | Cursor operations |

---

## bson ([ExternalService](ExternalService.md#mongodb-driver))

| API | Description |
|---|---|
| `bson.encode(doc)` | Encode BSON |
| `bson.encode_order(k1, v1, ...)` | Order-preserving encode |
| `bson.decode(data)` | Decode BSON |
| `bson.objectid(hex)` | ObjectId |
| `bson.int64(value)` | 64-bit integer |
| `bson.null` | null constant |

---

## skynet.crypt ([ExternalService](ExternalService.md#crypt-utilities))

| API | Description |
|---|---|
| `crypt.sha1(msg)` | SHA-1 hash |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Base64 encoding |
| `crypt.base64decode(data)` | Base64 decoding |
| `crypt.hexencode(data)` | Hex encoding |
| `crypt.hexdecode(data)` | Hex decoding |

---

## skynet.profile ([DebugConsole](DebugConsole.md))

| API | Description |
|---|---|
| `profile.start([co])` | Start timing |
| `profile.stop([co])` | Stop timing |
| `profile.resume(co, ...)` | Resume with timing |
| `profile.wrap(f)` | Create a timing wrapper |


