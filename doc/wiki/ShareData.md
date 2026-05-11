# ShareData
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`；runtime 仓库只保留最小 verify/package/package smoke/Linux coverage smoke，full coverage、perf、Docker DB、soak 和 native 对比由父级 `testa/tools` 管理。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 共享数据

---

```lua
local sharedata = require "sharedata"
```

当你把业务拆分到多个服务中后，数据如何共享是最常面临的问题。sharedata 模块用于在同一进程内的多个服务间共享只读结构化数据，典型用途是配置表分发。

---

## 使用方法

### 数据提供者

```lua
-- 创建共享数据
sharedata.new("game_config", {
    max_level = 100,
    exp_table = {100, 200, 400, 800},
})

-- 更新数据
sharedata.update("game_config", {
    max_level = 120,
    exp_table = {100, 200, 400, 800, 1600},
})

-- 删除数据
sharedata.delete("game_config")
```

### 数据消费者

```lua
-- 查询数据（首次查询会启动 monitor 协程，监控更新）
local config = sharedata.query("game_config")
print(config.max_level)  -- 100

-- 数据更新后，下次访问自动获取新版本
-- 获取深拷贝（一次性使用，效率更高）
local copy = sharedata.deepcopy("game_config")
```

---

## API

| 函数 | 说明 |
|---|---|
| `sharedata.new(name, value)` | 创建共享数据。value 可以是任意 Lua table |
| `sharedata.query(name)` | 查询共享数据。首次查询启动 monitor 协程，自动跟踪更新 |
| `sharedata.update(name, value)` | 更新共享数据。所有持有者的 monitor 会收到通知 |
| `sharedata.delete(name)` | 删除共享数据 |
| `sharedata.flush()` | 清除本地缓存，下次 query 时重新从服务端获取 |
| `sharedata.deepcopy(name, ...)` | 获取数据的深拷贝。额外参数作为 key 链索引子表 |

---

## 实现架构

```
sharedatad (唯一服务)                   sharedata 客户端 (每个使用者)
├─ data_store[name]                    ├─ local_cache[name]
│   ├─ data (Lua table)                │   ├─ data
│   └─ version (递增整数)              │   └─ version
└─ 命令:                               └─ monitor 协程:
    new/delete/query/update/monitor       长轮询 sharedatad 等待版本变化
```

**数据流**：
1. 服务 A 调用 `sharedata.new("cfg", data)` → sharedatad 存储数据
2. 服务 B 调用 `sharedata.query("cfg")` → 从 sharedatad 获取数据 + 启动 monitor
3. 服务 A 调用 `sharedata.update("cfg", new_data)` → sharedatad 更新 + 通知所有 monitor
4. 服务 B 的 monitor 收到通知 → 自动更新本地缓存

---

## 与原版 skynet 的差异

- 原版 sharedata 使用 C 共享内存，多个 Lua VM 可以直接读取同一块内存。skynet-cpp 通过消息传递深拷贝数据，功能等价但不共享内存
- 原版有 `sharetable` 模块（基于 `lua_clonefunction`），skynet-cpp 不支持
- 原版 query 到的对象可以像普通 table 一样读取（通过 `__index` 元方法），skynet-cpp 直接返回普通 table
- 原版有 STM / ShareMap 模块，skynet-cpp 不支持

