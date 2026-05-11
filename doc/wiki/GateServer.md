# GateServer
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`；runtime 仓库只保留最小 verify/package/package smoke/Linux coverage smoke，full coverage、perf、Docker DB、soak 和 native 对比由父级 `testa/tools` 管理。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 网关服务模板

---

网关服务 (GateServer) 是应用的接入层，基本功能是管理客户端连接、分割完整数据包、转发给逻辑服务。

skynet-cpp 提供了一个通用模板 `lualib/gateserver.lua`。

---

## 使用方法

```lua
local gateserver = require "gateserver"

local handler = {}

function handler.connect(conn_id, addr, port)
    -- 新客户端接入
end

function handler.disconnect(conn_id)
    -- 客户端断开
end

function handler.message(conn_id, data)
    -- 收到完整的业务数据包（已去掉长度头）
end

function handler.open(source, conf)
    -- Gate 打开监听端口
end

gateserver.start(handler)
```

注：`gateserver.start` 内部会调用 `skynet.start`。

---

## Handler 回调

| 回调 | 签名 | 说明 |
|---|---|---|
| `connect` | `(conn_id, addr, port)` | 新客户端 accept 后调用 |
| `disconnect` | `(conn_id)` | 连接断开时调用 |
| `message` | `(conn_id, data)` | 完整业务包（已由 netpack 分包）到达 |
| `error` | `(conn_id, msg)` | 连接异常 |
| `warning` | `(conn_id, bytes)` | 发送缓冲区超过 1M 告警 |
| `open` | `(source, conf)` | 监听端口打开时调用 |

---

## 分包协议

每个包 = **2 字节大端长度头** + **数据内容**

单个数据包最大不超过 65535 字节。如果业务需要传输更大的数据块，请在上层协议中解决。

### netpack API

```lua
local netpack = require "netpack"
```

| 函数 | 说明 |
|---|---|
| `netpack.pack(data)` | 将数据打包（加 2 字节长度头），返回 framed string |
| `netpack.unpack(buffer, offset)` | 从 buffer 提取一个完整帧，返回 (next_offset, payload) |
| `netpack.filter(buffer, new_data)` | 合并新数据并提取所有完整帧 |
| `netpack.tostring(msg, sz)` | lightuserdata 转 Lua string |

---

## 控制命令

其他服务可通过 lua 协议向 gate 发送以下命令：

```lua
-- 打开监听
skynet.call(gate, "lua", "OPEN", { port = 8888, address = "0.0.0.0" })

-- 发送带长度头的数据
skynet.call(gate, "lua", "SEND", conn_id, data)

-- 发送原始数据（不加长度头）
skynet.call(gate, "lua", "SENDRAW", conn_id, raw_data)

-- 关闭连接
skynet.call(gate, "lua", "CLOSE", conn_id)

-- 踢掉连接
skynet.call(gate, "lua", "KICK", conn_id)
```

---

## 与原版 skynet 的差异

- 原版的 gateserver 位于 `lualib/snax/gateserver.lua`，skynet-cpp 位于 `lualib/gateserver.lua`
- 原版有 `gateserver.openclient(fd)` / `gateserver.closeclient(fd)` 用于控制消息接收，skynet-cpp 的连接默认即接收消息
- 原版 message 回调传递 C 指针和长度 `(fd, msg, sz)`，skynet-cpp 传递 Lua string `(conn_id, data)`
- 原版不可与 socket 库在同一服务中混用，skynet-cpp 同样

