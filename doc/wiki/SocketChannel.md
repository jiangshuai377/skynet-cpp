# SocketChannel
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp Socket 连接多路复用

---

```lua
local socketchannel = require "skynet.socketchannel"
```

请求回应模式是和外部服务交互时最常用的模式之一。socketchannel 提供了高层封装，支持两种协议设计：

1. **顺序模式 (Order Mode)**：每个请求对应一个回应，由 TCP 保证时序（如 Redis）
2. **会话模式 (Session Mode)**：每个请求携带唯一 session，回应带回 session 做匹配（如 MongoDB）

---

## 创建 Channel

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    -- 以下为可选参数：
    response = dispatch_func,   -- 若提供则进入 Session 模式
    auth = auth_func,           -- 连接建立后的认证回调
    nodelay = true,             -- TCP_NODELAY
}
```

socket channel 在创建时并不会立即建立连接。连接会推迟到第一次 `request` 时。连接断开后下次 `request` 会自动重连。

---

## 顺序模式 (Order Mode)

适用于 Redis 等每个请求必有一个按序回应的协议：

```lua
local resp = channel:request(req_string, function(sock)
    -- sock 是 channel 传入的读取对象
    local line = sock:readline()
    return true, line  -- 第一个返回值: 是否成功; 第二个: 回应内容
end)
```

response 函数的第一个返回值是 boolean：
- `true`：协议解析正常
- `false`：协议出错，连接将断开，request 抛出 error

---

## 会话模式 (Session Mode)

适用于 MongoDB 等可以乱序回应的协议。需要在创建时提供全局 `response` 函数：

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 27017,
    response = function(sock)
        -- 解析回应包
        local session = ...  -- 从回应中提取 session
        local ok = true
        local data = ...     -- 解析回应数据
        return session, ok, data
    end,
}

-- 发送请求，传入 session 而非 response 函数
local resp = channel:request(req_string, session_id)
```

---

## 认证

```lua
local channel = socketchannel.channel {
    host = "127.0.0.1",
    port = 6379,
    auth = function(sock)
        -- 连接建立后自动调用
        -- 可以做 AUTH / SELECT 等操作
        sock:request("AUTH password\r\n", function(s)
            return true, s:readline()
        end)
    end,
}
```

auth 函数在每次连接建立后立即执行。如果认证失败，在 auth 中抛出 error 即可。

---

## 其他 API

| 方法 | 说明 |
|---|---|
| `channel:connect(once)` | 显式连接。once=true 表示只尝试一次，失败抛错 |
| `channel:close()` | 关闭 channel，唤醒所有等待中的 request |
| `channel:changehost(host, port)` | 更换远程地址并重连 |
| `channel:read(sz)` | 从 channel 读取 sz 字节 |
| `channel:readline(sep)` | 从 channel 按分隔符读取 |
| `channel:response(func)` | 不发送请求，仅等待接收一条回应（用于 pub/sub） |

---

## 与原版 skynet 的差异

- API 基本一致
- 原版有 `padding` 参数和低优先级写（`socket.lwrite`），skynet-cpp 暂未实现
- 原版有 `backup` 备用地址（为 mongo 集群设计），skynet-cpp 暂未实现
- 原版有 `overload` 过载回调，skynet-cpp 暂未实现

