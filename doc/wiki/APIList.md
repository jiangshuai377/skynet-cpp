# APIList
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 所有模块 API 速查表

---

## skynet ([LuaAPI](LuaAPI.md))

### 服务构建

| API | 说明 |
|---|---|
| `skynet.register_protocol(class)` | 注册消息处理机制 |
| `skynet.start(func)` | 初始化服务并注册回调 |
| `skynet.dispatch(type, func)` | 设定消息处理函数 |
| `skynet.getenv(key)` | 读取环境变量 |
| `skynet.setenv(key, value)` | 设置环境变量 |

### 框架构建

| API | 说明 |
|---|---|
| `skynet.newservice(name, ...)` | 启动新 Lua 服务 |
| `skynet.uniqueservice(name, ...)` | 启动唯一服务 |
| `skynet.queryservice(name)` | 查询唯一服务地址 |
| `skynet.localname(name)` | 查询本地名 |
| `skynet.appendpath(path)` | 追加 Lua module 目录 |
| `skynet.prependpath(path)` | 前置 Lua module 目录 |
| `skynet.appendcpath(path)` | 追加 C module 目录，自动适配 `.dll` / `.so` |
| `skynet.appendservicepath(path)` | 追加 service 搜索目录 |
| `skynet.getpath()` | 返回当前全局路径快照 |

### 任务调度

| API | 说明 |
|---|---|
| `skynet.sleep(ti)` | 挂起 ti 厘秒 |
| `skynet.yield()` | 让出 CPU |
| `skynet.wait(token)` | 等待唤醒 |
| `skynet.wakeup(token)` | 唤醒协程 |
| `skynet.fork(func, ...)` | 启动新协程 |
| `skynet.timeout(ti, func)` | 定时执行 |
| `skynet.now()` | 进程启动后经过的厘秒 |
| `skynet.starttime()` | 进程启动 UTC 时间 |
| `skynet.time()` | 当前 UTC 时间（秒） |
| `skynet.self()` | 当前服务地址 |
| `skynet.address(addr)` | 格式化地址字符串 |
| `skynet.exit()` | 退出当前服务 |

### 消息传递

| API | 说明 |
|---|---|
| `skynet.send(addr, type, ...)` | 异步发送 |
| `skynet.call(addr, type, ...)` | 同步 RPC 调用 |
| `skynet.rawsend(addr, type, msg, sz)` | 原始发送 |
| `skynet.rawcall(addr, type, msg, sz)` | 原始 RPC |
| `skynet.ret(msg, sz)` | 回应消息 |
| `skynet.retpack(...)` | 打包并回应 |
| `skynet.response([pack])` | 延迟回应闭包 |
| `skynet.redirect(addr, src, type, session, ...)` | 伪装发送 |
| `skynet.error(...)` | 发送日志 |
| `skynet.pack(...)` | 序列化 |
| `skynet.unpack(msg, sz)` | 反序列化 |
| `skynet.packstring(...)` | 序列化为 string |
| `skynet.tostring(msg, sz)` | lightuserdata → string |
| `skynet.trash(msg, sz)` | 释放 lightuserdata |

### 管理

| API | 说明 |
|---|---|
| `skynet.register(name)` | 注册服务名 |
| `skynet.name(name, addr)` | 为地址注册名字 |
| `skynet.kill(addr)` | 强制终止服务 |
| `skynet.harbor(addr)` | 始终返回 0 |
| `skynet.genid()` | 生成唯一 session |

---

## skynet.cluster ([Cluster](Cluster.md))

| API | 说明 |
|---|---|
| `cluster.call(node, addr, ...)` | 远程 RPC 调用 |
| `cluster.send(node, addr, ...)` | 远程异步推送 |
| `cluster.open(addr, port)` | 开启集群监听 |
| `cluster.reload(cfg)` | 重载集群配置 |
| `cluster.register(name, addr)` | 注册名字 |
| `cluster.unregister(name)` | 注销名字 |
| `cluster.query(node, name)` | 查询远程名字 |

---

## skynet.queue ([CriticalSection](CriticalSection.md))

| API | 说明 |
|---|---|
| `queue()` | 创建执行队列 |
| `cs(func, ...)` | 在队列中串行执行 |

---

## skynet.sharedata ([ShareData](ShareData.md))

| API | 说明 |
|---|---|
| `sharedata.new(name, value)` | 创建共享数据 |
| `sharedata.query(name)` | 查询共享数据 |
| `sharedata.update(name, value)` | 更新共享数据 |
| `sharedata.delete(name)` | 删除共享数据 |
| `sharedata.flush()` | 清除本地缓存 |
| `sharedata.deepcopy(name, ...)` | 深拷贝 |

---

## skynet.multicast ([Multicast](Multicast.md))

| API | 说明 |
|---|---|
| `multicast.new(opts)` | 创建频道 |
| `mc:subscribe()` | 订阅 |
| `mc:unsubscribe()` | 取消订阅 |
| `mc:publish(...)` | 发布消息 |
| `mc:delete()` | 删除频道 |

---

## skynet.socket ([Socket](Socket.md))

| API | 说明 |
|---|---|
| `socket.listen(host, port, handler)` | 监听 TCP 端口 |
| `socket.ondata(id, handler)` | 设置数据回调 |
| `socket.connect(host, port)` | TCP 连接 |
| `socket.send(id, data)` | 发送数据 |
| `socket.write(lid, cid, data)` | 通过 listener 发送 |
| `socket.read(id, sz)` | 读取数据 |
| `socket.readline(id, sep)` | 按分隔符读取 |
| `socket.readall(id)` | 读取全部 |
| `socket.close(id)` | 关闭连接 |
| `socket.close_listener(id)` | 关闭监听 |
| `socket.pause(lid, cid)` | 暂停读取 |
| `socket.resume(lid, cid)` | 恢复读取 |
| `socket.udp(host, port, cb)` | 创建 UDP |
| `socket.udp_send(id, data, host, port)` | 发送 UDP |

---

## skynet.socketchannel ([SocketChannel](SocketChannel.md))

| API | 说明 |
|---|---|
| `socketchannel.channel(desc)` | 创建 channel |
| `channel:request(req, resp/session)` | 发送请求等待回应 |
| `channel:response(func)` | 仅接收回应 |
| `channel:connect(once)` | 显式连接 |
| `channel:close()` | 关闭 channel |
| `channel:changehost(host, port)` | 更换地址 |
| `channel:read(sz)` | 读取字节 |
| `channel:readline(sep)` | 按分隔符读取 |

---

## skynet.db.redis ([ExternalService](ExternalService.md#redis-驱动))

| API | 说明 |
|---|---|
| `redis.connect(conf)` | 连接 Redis |
| `redis.watch(conf)` | 创建 pub/sub 监听 |
| `db:*(...)` | 任意 Redis 命令 |
| `db:pipeline(ops)` | 批量执行 |
| `db:disconnect()` | 断开连接 |
| `watch:subscribe(...)` | 订阅频道 |
| `watch:message()` | 接收消息 |

---

## skynet.db.mysql ([ExternalService](ExternalService.md#mysql-驱动))

| API | 说明 |
|---|---|
| `mysql.connect(conf)` | 连接 MySQL |
| `db:query(sql)` | 执行查询 |
| `db:prepare(sql)` | 预编译语句 |
| `stmt:execute()` | 执行预编译 |
| `stmt:close()` | 关闭语句 |
| `db:disconnect()` | 断开连接 |

---

## skynet.db.mongo ([ExternalService](ExternalService.md#mongodb-驱动))

| API | 说明 |
|---|---|
| `mongo.client(conf)` | 连接 MongoDB |
| `client:getDB(name)` | 获取数据库 |
| `db:getCollection(name)` | 获取集合 |
| `db:runCommand(...)` | 执行命令 |
| `coll:insert(doc)` | 插入 |
| `coll:find(query, proj)` | 查询 |
| `coll:findOne(query, proj)` | 查询单条 |
| `coll:update(q, u, upsert, multi)` | 更新 |
| `coll:delete(query, single)` | 删除 |
| `coll:count(query)` | 计数 |
| `coll:aggregate(pipeline)` | 聚合 |
| `coll:createIndex(keys, opts)` | 创建索引 |
| `coll:drop()` | 删除集合 |
| `cursor:sort/skip/limit/hasNext/next/close/toArray` | 游标操作 |

---

## bson ([ExternalService](ExternalService.md#mongodb-驱动))

| API | 说明 |
|---|---|
| `bson.encode(doc)` | 编码 BSON |
| `bson.encode_order(k1, v1, ...)` | 保序编码 |
| `bson.decode(data)` | 解码 BSON |
| `bson.objectid(hex)` | ObjectId |
| `bson.int64(value)` | 64 位整数 |
| `bson.null` | null 常量 |

---

## skynet.crypt ([ExternalService](ExternalService.md#crypt-工具))

| API | 说明 |
|---|---|
| `crypt.sha1(msg)` | SHA-1 哈希 |
| `crypt.hmac_sha1(key, msg)` | HMAC-SHA1 |
| `crypt.base64encode(data)` | Base64 编码 |
| `crypt.base64decode(data)` | Base64 解码 |
| `crypt.hexencode(data)` | Hex 编码 |
| `crypt.hexdecode(data)` | Hex 解码 |

---

## skynet.profile ([DebugConsole](DebugConsole.md))

| API | 说明 |
|---|---|
| `profile.start([co])` | 开始计时 |
| `profile.stop([co])` | 停止计时 |
| `profile.resume(co, ...)` | 带计时的 resume |
| `profile.wrap(f)` | 创建计时包装器 |


