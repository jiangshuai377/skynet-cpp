# Socket
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`；runtime 仓库只保留最小 verify/package/package smoke/Linux coverage smoke，full coverage、perf、Docker DB、soak 和 native 对比由父级 `testa/tools` 管理。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp Socket API

---

```lua
local socket = require "socket"
```

skynet-cpp 提供了一组阻塞模式的 Lua API 用于 TCP/UDP 读写。所谓阻塞模式，实际上是利用了 Lua 的 coroutine 机制。当你调用 socket API 时，服务有可能被挂起（时间片让给其他业务处理），待结果通过 socket 消息返回，coroutine 将延续执行。

---

## TCP API

### 服务端

```lua
-- 监听端口
local listener_id = socket.listen("0.0.0.0", 8888, function(event, conn_id, ...)
    if event == "accept" then
        -- 新连接接入
    elseif event == "close" then
        -- 连接关闭
    elseif event == "warning" then
        -- 发送缓冲区告警
    end
end)

-- 设置数据回调
socket.ondata(listener_id, function(conn_id, data)
    -- 收到数据
end)
```

- `socket.listen(host, port, handler)` — 监听端口，handler 接收 accept/close/warning 事件，返回 listener_id
- `socket.ondata(listener_id, handler)` — 设置数据回调 `handler(conn_id, data)`
- `socket.write(listener_id, conn_id, data)` — 在 listener 的连接上发送数据
- `socket.close_listener(listener_id)` — 关闭监听
- `socket.pause(listener_id, conn_id)` — 暂停连接读取（流量控制）
- `socket.resume(listener_id, conn_id)` — 恢复连接读取

### 客户端

```lua
local conn_id = socket.connect("127.0.0.1", 8888)
if conn_id then
    socket.send(conn_id, "hello\n")
    local line = socket.readline(conn_id, "\n")
    socket.close(conn_id)
end
```

- `socket.connect(host, port)` — 连接远程主机，阻塞直到连接建立或失败
- `socket.send(conn_id, data)` — 发送数据
- `socket.read(conn_id, sz)` — 读取 sz 字节，阻塞直到数据就绪或连接关闭
- `socket.readline(conn_id, sep)` — 读取直到分隔符（默认 `"\n"`），不含分隔符
- `socket.readall(conn_id)` — 读取所有可用数据
- `socket.close(conn_id)` — 关闭连接

---

## UDP API

```lua
local udp_id = socket.udp("0.0.0.0", 9999, function(data, from_addr, from_port)
    -- 收到 UDP 数据包
end)

socket.udp_send(udp_id, "hello", "127.0.0.1", 9999)
```

- `socket.udp(host, port, callback)` — 创建 UDP socket，回调接收数据包
- `socket.udp_send(id, data, host, port)` — 发送 UDP 数据包

---

## socketdriver (C 模块)

`socket.lua` 是对底层 C 模块 `socketdriver` 的协程封装。`socketdriver` 注册的函数包括：

| 函数 | 说明 |
|---|---|
| `socketdriver.listen(host, port, backlog)` | 创建 TCP 监听 |
| `socketdriver.connect(host, port)` | 创建 TCP 连接（异步） |
| `socketdriver.send(id, data)` | 通过 connector 发送数据 |
| `socketdriver.write(listener_id, conn_id, data)` | 通过 listener 的连接发送 |
| `socketdriver.close(id, [conn_id])` | 关闭 socket 或连接 |
| `socketdriver.pause(listener_id, conn_id)` | 暂停连接读取 |
| `socketdriver.resume(listener_id, conn_id)` | 恢复连接读取 |
| `socketdriver.udp(host, port)` | 创建 UDP socket |
| `socketdriver.udp_send(id, data, host, port)` | 发送 UDP |

---

## 与原版 skynet 的差异

- 原版使用 `socket.start(id)` 来接管 socket 控制权（因为多服务共享 socket id），skynet-cpp 的 listener/connector 天然绑定到创建者服务
- 原版有 `socket.abandon`（转交控制权），skynet-cpp 暂未实现
- 原版有 `socket.lwrite`（低优先级写队列），skynet-cpp 暂未实现
- 原版有 `socket.block`（等待可读），skynet-cpp 暂未实现

