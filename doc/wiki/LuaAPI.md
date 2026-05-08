# LuaAPI
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet Lua 服务 API 参考

---

```lua
local skynet = require "skynet"
```

每个 skynet-cpp 服务都需要引入 `skynet` 模块。此模块不能在 skynet-cpp 框架之外使用。

---

## 服务地址

每个服务都有一个 32bit 的数字地址（handle）。

- `skynet.self()` — 返回当前服务地址
- `skynet.address(addr)` — 将地址转换为可读字符串（`:xxxxxxxx` 格式）
- `skynet.register(name)` — 为当前服务注册别名（以 `.` 开头为本地名）
- `skynet.name(name, handle)` — 为指定 handle 的服务注册别名
- `skynet.localname(name)` — 查询本地名对应的地址（非阻塞）

所有接受服务地址的 API 参数，都可以传入字符串别名。

---

## 消息分发和回应

### skynet.dispatch(type, func)

注册特定类消息的处理函数。最常用写法：

```lua
local CMD = {}

skynet.dispatch("lua", function(session, source, cmd, ...)
    local f = assert(CMD[cmd])
    f(...)
end)
```

### skynet.register_protocol(class)

注册新的消息类别。class 需提供 `name`、`id`、`pack`、`unpack` 字段。

### skynet.ret(msg, sz)

将消息回应给当前请求源。在同一消息处理 coroutine 中只能调用一次。

### skynet.retpack(...)

`skynet.ret(skynet.pack(...))` 的快捷方式。

### skynet.response([packfunc])

生成延迟回应闭包，可在将来的其他协程中调用。

```lua
local resp = skynet.response()
-- 之后在其他地方调用：
resp(true, result1, result2)   -- 正常回应
resp(false)                     -- 抛出异常给请求者
```

---

## 消息推送和远程调用

### skynet.send(addr, typename, ...)

向 addr 发送类型为 typename 的消息。非阻塞 API，消息经过 pack 函数打包。

### skynet.call(addr, typename, ...)

向 addr 发送请求并阻塞等待回应。回应经过 unpack 解包后返回。**注意**：`skynet.call` 仅阻塞当前协程，服务仍可响应其他消息。

### skynet.rawsend(addr, typename, msg, sz)

原始发送，不经过 pack 打包。

### skynet.rawcall(addr, typename, msg, sz)

原始 RPC 调用，不经过 pack/unpack。

### skynet.redirect(addr, source, typename, session, ...)

伪装成 source 地址向 addr 发送消息。

---

## 时钟和线程

内部时钟精度为 1/100 秒（厘秒）。

- `skynet.now()` — 返回进程启动后经过的时间（厘秒）
- `skynet.starttime()` — 返回进程启动的 UTC 时间（秒）
- `skynet.time()` — 返回当前 UTC 时间（秒，精度为 10ms）

### skynet.sleep(ti)

挂起当前协程 ti 厘秒。返回 `"BREAK"` 表示被 `wakeup` 唤醒。

### skynet.yield()

等价于 `skynet.sleep(0)`。交出 CPU 控制权。

### skynet.timeout(ti, func)

在 ti 厘秒后，在新协程中执行 func。非阻塞 API。

### skynet.fork(func, ...)

启动新协程执行 func。比 `timeout(0, ...)` 更高效（不经过定时器）。

### skynet.wait(token)

挂起当前协程，等待 `wakeup` 唤醒。token 默认为 `coroutine.running()`。

### skynet.wakeup(token)

唤醒被 `sleep` 或 `wait` 挂起的协程。

---

## 服务的启动和退出

### skynet.start(func)

注册服务启动函数。**必须调用**，是服务的入口点。

### skynet.exit()

退出当前服务。之后的代码不会执行，挂起的协程也会中断。

### skynet.newservice(name, ...)

启动新的 Lua 服务。阻塞 API，等待被启动服务的 `start` 函数返回后才返回。

### skynet.uniqueservice(name, ...)

启动唯一服务。如果已启动则返回已有地址。

### skynet.queryservice(name)

查询唯一服务地址。若尚未启动则等待。

## 路径配置

这些 API 通常只在 preload 脚本中调用。参数只接收普通目录路径；内部会归一化 `/`、`\`、重复分隔符和尾部分隔符，并自动展开 Lua/C module 或 service 搜索规则。新创建的 LuaActor 会继承当前全局路径快照。

- `skynet.appendpath(path)` — 追加 Lua module 目录，展开为 `path/?.lua` 和 `path/?/init.lua`。
- `skynet.prependpath(path)` — 前置 Lua module 目录。
- `skynet.appendcpath(path)` — 追加 C module 目录，按平台展开为 `.dll` 或 `.so` 搜索规则。
- `skynet.appendservicepath(path)` — 追加 service 脚本目录，展开为 `path/?.lua`。
- `skynet.getpath()` — 返回当前 `{ path, cpath, service_path }` 快照。
- `skynet.getcwd()` — 返回进程当前工作目录，用于 preload 日志和定位路径问题。
- `skynet.setpathbase(path)` — 设置路径 API 的相对路径解析基准，不改变 OS cwd。
- `skynet.getpathbase()` — 返回当前 pathbase。
- `skynet.readfile(path)` / `skynet.writefile(path, data, append)` — 按 pathbase 解析文件路径的受控文件读写接口。
- `skynet.systemstat()` — 返回进程级 runtime 统计，如 actor 数、global queue backlog、worker 数。

---

## 序列化

- `skynet.pack(...)` — 将 Lua 值序列化为 `(lightuserdata, size)`
- `skynet.unpack(msg, sz)` — 反序列化为 Lua 值
- `skynet.packstring(...)` — 序列化为 Lua string
- `skynet.tostring(msg, sz)` — lightuserdata 转 Lua string
- `skynet.trash(msg, sz)` — 释放 lightuserdata 缓冲区

支持类型：string, boolean, number, lightuserdata, table（不含元表）。

---

## 日志

### skynet.error(...)

将参数拼接后发送到 logger 服务。Output 格式：`[HH:MM:SS.mmm][HANDLE][ERROR] message`

---

## 状态查询

- `skynet.info_func(func)` — 注册内部状态查询函数，供 debug 协议调用
- `skynet.stat(what)` — 查询服务内部状态：`"endless"`, `"mqlen"`, `"message"`, `"cpu"`

---

## 其他

- `skynet.getenv(key)` — 读取环境变量
- `skynet.setenv(key, value)` — 设置环境变量（不可覆盖）
- `skynet.genid()` — 生成唯一 session
- `skynet.harbor(addr)` — 始终返回 0（skynet-cpp 不支持 harbor）

---

## 与原版 skynet 的差异

- `skynet.harbor()` 始终返回 0
- 不支持 `skynet.forward_type` 和 `skynet.filter`（高级消息转发）
- `skynet.memlimit` 需在 `start` 之前调用
- 环境变量通过 `ActorSystem` 传入而非配置文件


