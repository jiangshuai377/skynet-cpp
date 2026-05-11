# DebugConsole
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`；runtime 仓库只保留最小 verify/package/package smoke/Linux coverage smoke，full coverage、perf、Docker DB、soak 和 native 对比由父级 `testa/tools` 管理。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 调试控制台与调试协议

---

## 调试协议

每个 Lua 服务自动注册 `PTYPE_DEBUG` 协议，内置以下调试命令：

| 命令 | 说明 |
|---|---|
| `MEM` | 返回当前 Lua VM 内存占用（KB） |
| `GC` | 触发垃圾回收，报告内存变化 |
| `STAT` | 返回任务数、消息队列长度、CPU 统计 |
| `TASK` | 返回任务协程栈信息 |
| `INFO` | 调用服务注册的 `info_func` 回调获取自定义信息 |
| `EXIT` | 优雅退出服务 |
| `PING` | 存活检测（立即回应） |
| `RUN` | 注入并执行一段 Lua 代码 |

### 注册自定义调试命令

```lua
local skynet = require "skynet"
require "skynet.debug"

-- 注册自定义 INFO 回调
skynet.info_func(function(...)
    return { state = "running", connections = 42 }
end)

-- 注册自定义调试命令
local debug = require "skynet.debug"
debug.reg_debugcmd("CUSTOM", function(...)
    return "custom result"
end)
```

---

## 调试控制台

`debug_console.lua` 提供 TCP telnet 接口，可以连接后交互式执行调试命令。

### 启动

```lua
-- 在 preload.lua 中启动调试控制台
local console = skynet.newservice("debug_console", "127.0.0.1", "8000")
```

### 连接

```bash
telnet 127.0.0.1 8000
```

### 控制台命令

| 命令 | 参数 | 说明 |
|---|---|---|
| `help` | — | 列出所有命令 |
| `list` | — | 列出所有运行中的服务 |
| `mem` | [timeout] | 查询所有服务的内存状态 |
| `gc` | [timeout] | 对所有服务触发 GC |
| `stat` | [timeout] | 查询所有服务的统计信息 |
| `ping` | address | 检测服务是否存活 |
| `info` | address, ... | 获取服务自定义信息 |
| `exit` | address | 优雅退出指定服务 |
| `kill` | address | 强制终止指定服务 |
| `start` | name, ... | 启动新的 Lua 服务 |
| `inject` | address, code | 向服务注入 Lua 代码执行 |

---

## Profile 性能分析

```lua
local profile = require "skynet.profile"
```

通过 `lua_profile.cpp` C 模块提供协程级 CPU 计时：

| 函数 | 说明 |
|---|---|
| `profile.start([co])` | 开始对协程计时（默认当前线程） |
| `profile.stop([co])` | 停止计时，返回 CPU 时间（秒） |
| `profile.resume(co, ...)` | 带计时的 coroutine.resume |
| `profile.wrap(f)` | 创建带计时的协程包装器 |

```lua
profile.start()
-- 执行一些计算密集操作
local cpu_time = profile.stop()
print(string.format("CPU time: %.6f seconds", cpu_time))
```

---

## 与原版 skynet 的差异

- 调试协议命令集基本一致
- 原版有 `signal` 功能（中断死循环的 Lua 代码），skynet-cpp 暂未实现
- 原版有 `skynet.trace()` 消息跟踪日志，skynet-cpp 暂未实现

