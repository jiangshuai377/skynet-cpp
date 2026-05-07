# Cluster
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 集群

---

```lua
local cluster = require "skynet.cluster"
```

skynet-cpp 实现了 cluster 模式来支持跨节点 RPC。每个节点是一个独立的 skynet-cpp 进程，节点间通过 TCP 连接进行消息传递。

---

## 快速开始

### 节点 A：监听 + 提供服务

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    local echo = skynet.newservice("echo")
    skynet.name(".echo", echo)

    -- 注册名字供远程访问
    cluster.register("echo", echo)

    -- 加载集群配置
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- 打开监听端口
    cluster.open("127.0.0.1", 19999)
end)
```

### 节点 B：远程调用

```lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

skynet.start(function()
    cluster.reload({
        nodeA = "127.0.0.1:19999",
        nodeB = "127.0.0.1:19998",
    })

    -- RPC 调用节点 A 的 echo 服务
    local result = cluster.call("nodeA", ".echo", "hello")
    print(result)

    -- 查询注册名
    local addr = cluster.query("nodeA", "echo")
end)
```

---

## API

| 函数 | 说明 |
|---|---|
| `cluster.call(node, addr, ...)` | 同步 RPC 调用远程节点的服务。阻塞等待回应 |
| `cluster.send(node, addr, ...)` | 异步推送消息到远程节点（无回应）。有丢失风险 |
| `cluster.open(addr, port)` | 打开监听端口，接受入站集群连接 |
| `cluster.reload(cfg)` | 重载集群配置。cfg 是 `{nodename = "host:port", ...}` 表 |
| `cluster.register(name, addr)` | 注册本地服务名供远程通过 `@name` 访问。addr 默认为自身 |
| `cluster.unregister(name)` | 注销已注册的名字 |
| `cluster.query(node, name)` | 查询远程节点通过 `cluster.register` 注册的服务地址 |

### 地址格式

`cluster.call` 的第二个参数 `addr` 可以是：

- **字符串名字**：如 `".echo"`，在目标节点上查找该名字
- **`@` 前缀名字**：如 `"@echo"`，通过 `cluster.register` 注册的名字查找
- **数字地址**：如果你已知远程服务的 handle

---

## 架构

cluster 系统由三个服务组成：

```
cluster.call("nodeB", ".svc", "CMD")
      │
      ▼
  clusterd ──sender──→ [TCP] ──→ clusteragent ──→ 本地服务
  (管理器)   (出站)                (入站)            ↓
      ▲                                          回应
      │                                            │
      └────────────────────── [TCP] ←───────────────┘
```

| 服务 | 数量 | 职责 |
|---|---|---|
| `clusterd` | 1 per node | 中央管理器：配置、sender/agent 生命周期、名字注册、监听 |
| `clustersender` | 1 per remote node | 维护到远程节点的 TCP 连接，通过 socketchannel 发送请求 |
| `clusteragent` | 1 per connection | 处理入站连接，解析请求分发到本地服务，回传响应 |

---

## 集群协议

`cluster.core` C 模块实现了集群线路协议：

- **封包格式**：2 字节大端长度头 + 负载
- **请求包**：类型标记 + session + 目标地址 + 序列化消息
- **回应包**：session + 成功/失败 + 序列化消息
- **大消息分片**：超过 32KB 的消息自动切分为多段传输

---

## 消息次序

cluster 间请求大部分按调用次序排序（先发先到）。但当单个包超过 32KB 时，包会被分片传输，大包可能后于小包到达。

请求和回应使用同一条 TCP 连接，次序有保证。

---

## 配置更新

通过 `cluster.reload(cfg)` 重载配置。如果修改了节点地址，reload 后的新请求会发到新地址。之前未完成的请求仍在旧地址上等待。

可以将节点地址设置为 `false` 来标记节点离线。

---

## 与原版 skynet 的差异

- skynet-cpp **不支持** master/slave (harbor) 模式，仅支持 cluster
- 原版 cluster 配置通过文件加载，skynet-cpp 通过 `cluster.reload(table)` 传入
- 原版有 `cluster.proxy(node, addr)` 创建本地代理，skynet-cpp 暂未实现
- 原版有 `cluster.snax` 支持远程 Snax 服务，skynet-cpp 不支持 Snax
- 原版配置支持 `__nowaiting = true`，skynet-cpp 暂未实现

