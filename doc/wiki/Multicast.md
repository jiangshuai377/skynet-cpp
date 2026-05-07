# Multicast
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 发布/订阅

---

```lua
local multicast = require "skynet.multicast"
```

Multicast 模块提供同一进程内的频道式发布/订阅消息机制。

---

## 使用方法

### 发布者

```lua
local multicast = require "skynet.multicast"

-- 创建新频道
local mc = multicast.new()
print("channel id:", mc.channel)

-- 发布消息（fire-and-forget）
mc:publish("event_name", { data = 123 })

-- 删除频道
mc:delete()
```

### 订阅者

```lua
local multicast = require "skynet.multicast"

-- 使用已有频道 ID
local mc = multicast.new({ channel = channel_id })

-- 设置接收回调
mc.dispatch = function(channel, source, ...)
    print("received from", source, ":", ...)
end

-- 订阅
mc:subscribe()

-- 取消订阅
mc:unsubscribe()
```

---

## API

| 方法 | 说明 |
|---|---|
| `multicast.new(opts)` | 创建频道对象。opts 可包含 `{channel=id}` 使用已有频道 |
| `mc:subscribe()` | 订阅当前服务到此频道 |
| `mc:unsubscribe()` | 取消订阅 |
| `mc:publish(...)` | 向所有订阅者发布消息 |
| `mc:delete()` | 删除此频道 |
| `mc.dispatch` | 设置为回调函数，接收发布的消息 |

---

## 实现架构

| 组件 | 说明 |
|---|---|
| `multicastd` 服务 | 唯一服务，管理频道 ID 分配、订阅者列表、广播消息 |
| `multicast.lua` 客户端 | 注册 `PTYPE_MULTICAST` 协议类型，提供面向对象 API |

消息发布流程：
1. 发布者调用 `mc:publish(...)`
2. 消息发送到 `multicastd` 服务
3. `multicastd` 遍历订阅者列表，向每个订阅者发送 `PTYPE_MULTICAST` 消息
4. 订阅者的 dispatch 回调被触发

---

## 与原版 skynet 的差异

- API 基本一致
- 原版支持跨节点多播（通过 datacenter 分发），skynet-cpp 仅支持同一进程内

