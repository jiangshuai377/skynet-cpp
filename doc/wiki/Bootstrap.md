# Bootstrap

## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

## 概述

skynet-cpp 的 C++ 入口只做最小 bootstrap：创建 `ActorSystem`、启动 logger、读取环境变量、启动 preload LuaActor，然后进入 worker/IO/monitor 事件循环。launcher 不再由 C++ 硬编码启动，而是由 preload 脚本显式调用 `skynet.newservice("launcher")`。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SKYNET_THREAD` | `8` | worker 线程数 |
| `SKYNET_PRELOAD` | `examples/preload.lua` | preload 脚本路径 |

## 启动流程

```text
main()
  -> read SKYNET_THREAD / SKYNET_PRELOAD
  -> ActorSystem workers=N
  -> spawn<ServiceLogger>()
  -> spawn<LuaActor>(preload)
  -> preload configures paths and starts launcher
  -> preload starts example, logic, stress, perf, or application service
  -> system.run()
```

## preload 职责

preload 是唯一启动编排入口，通常负责：

- 调用 `skynet.appendpath` / `skynet.prependpath` 配置 Lua module path。
- 调用 `skynet.appendcpath` 配置 C module path。
- 调用 `skynet.appendservicepath` 配置 service 搜索路径。
- 启动 `launcher`。
- 启动业务入口、示例入口或测试入口。

## 线程模型

| 线程 | 数量 | 职责 |
| --- | ---: | --- |
| Worker | `SKYNET_THREAD` | 从 global queue 取 `ActorQueue`，按权重批量 dispatch 消息 |
| IO | 1 | 运行 `asio::io_context`，处理网络 IO 和 timer |
| Monitor | 1 | 检测 worker 是否长时间卡在同一消息 |

## 示例 preload

```lua
local skynet = require "skynet"

skynet.appendpath("lualib")
skynet.appendservicepath("service")
skynet.appendservicepath("examples")

skynet.start(function()
    skynet.newservice("launcher")
    skynet.newservice("main")
end)
```

## 相关入口

- 示例：`examples/preload.lua`
- 逻辑测试：`tests/logic/preload.lua`
- 压力测试：`tests/stress/preload.lua`
- 性能测试：`tests/perf/preload.lua`
