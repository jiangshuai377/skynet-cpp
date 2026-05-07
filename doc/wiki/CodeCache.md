# CodeCache
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> Lua 5.5 代码缓存机制

---

## 概述

skynet-cpp 使用的是 skynet 修改版 Lua 5.5.0，其中包含 **codecache** 机制。这个机制允许多个 Lua VM（即多个服务）共享已编译的 Lua 函数原型（Proto），从而：

1. **节省内存**：相同脚本只编译一份字节码
2. **加速启动**：后续 VM 加载同一脚本时直接复用，无需重新解析

---

## 工作原理

当一个 Lua 服务通过 `loadfile` 加载脚本时：

1. **首次加载**：正常编译，将编译后的函数原型存入全局缓存
2. **后续加载**：直接从缓存中克隆函数原型，跳过编译步骤

关键的 C API 扩展：
- `lua_clonefunction(L, proto)` — 从共享原型创建新的闭包
- `lua_sharefunction(L, index)` — 将函数原型加入共享池

---

## skynet-cpp 中的使用

在 `loader.lua` 中，codecache 默认被关闭（`cache.mode("OFF")`），原因是：

- skynet-cpp 的每个 `LuaActor` 拥有独立的 `lua_State`，各 VM 的 `_ENV` 完全隔离
- 如果 codecache 开启，多个 VM 共享同一个编译后的 Proto，但各 VM 的全局环境（`_ENV`）不同。当 Proto 中引用了 `require` 等全局函数时，会出现 `_ENV` 指向错误 VM 的问题
- 关闭 codecache 后，每个 VM 独立编译脚本，`_ENV` 指向正确

```lua
-- loader.lua
local cache = require "cache"
cache.mode("OFF")  -- 禁用共享缓存
```

---

## 手动控制

如果你确认某些纯函数脚本不依赖 `_ENV`，可以选择性地开启缓存：

```lua
local cache = require "cache"

-- 查询当前模式
local mode = cache.mode()

-- 设置模式：ON / OFF
cache.mode("ON")   -- 开启共享缓存
cache.mode("OFF")  -- 关闭共享缓存
```

---

## 与原版 skynet 的差异

- 原版 skynet 默认开启 codecache，skynet-cpp 默认关闭
- 原版通过 `require "skynet.codecache"` 获得控制接口，skynet-cpp 通过 `require "cache"` 控制
- 原版提供 `codecache.clear()` 清除缓存，skynet-cpp 暂不支持

