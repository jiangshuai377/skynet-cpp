# Build
## 当前实现状态

当前版本使用 preload 启动链路：设置 `SKYNET_THREAD` 控制 worker 数，设置 `SKYNET_PRELOAD` 选择 preload 脚本。preload 负责配置 Lua path/cpath/service path、启动 launcher 和业务入口。测试入口已拆为 `tests/logic`、`tests/stress`、`tests/perf`，coverage 和 Linux Docker perf 有独立工具脚本。Actor 调度已经迁移到 `ActorQueue` + sharded registry + atomic wakeup 模型，Lua callback 和 `skynet.core` actor context 均走缓存路径。

> skynet-cpp 编译构建指南

---

## 获取源代码

```bash
git clone <skynet-cpp-repository-url>
cd skynet-cpp
git lfs pull
```

---

## 依赖

skynet-cpp 的所有依赖已包含在 `3rdparty/` 目录中，无需额外安装：

| 依赖 | 版本 | 说明 |
|---|---|---|
| **Asio** | 1.28.2 (standalone) | 跨平台异步 IO 库（无需 Boost） |
| **moodycamel::ConcurrentQueue** | latest | 高性能无锁 MPMC 队列 |
| **Lua** | 5.5.0 (skynet 修改版) | 含 codecache 的 Lua VM |

---

## 编译工具

### Windows (推荐)

- **Visual Studio 2022** (MSVC 19.41+)
- **CMake** 3.20+（VS2022 自带）

### Linux

- **GCC** 12+ 或 **Clang** 15+
- **CMake** 3.20+

### macOS

- **Clang** (Xcode Command Line Tools)
- **CMake** 3.20+

---

## 编译

### Windows (Visual Studio)

```bat
cd skynet-cpp
mkdir build
cd build
cmake ..
cmake --build . --config Debug
```

或使用 VS2022 自带的 CMake：

```bat
"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" -S . -B build
"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" --build build --config Debug
```

### Linux / macOS

```bash
cd skynet-cpp
mkdir build && cd build
cmake ..
make -j$(nproc)
```

编译成功后，可执行文件位于 `build/Debug/skynet-cpp.exe`（Windows）或 `build/skynet-cpp`（Linux/macOS）。

---

## 发布包

推荐用 CMake install 或工具脚本生成可发布目录：

```bat
tools\package.bat --build-config Release
tools\run_package_smoke.bat
```

发布目录默认是 `dist/skynet-cpp/`，布局为 `bin/`、`lualib/`、`service/`、`examples/`、`doc/`。从发布目录根启动，`SKYNET_PRELOAD` 使用相对 cwd 的路径，例如 `examples/preload.lua`。

---

## 运行

```bash
cd build/Debug
./skynet-cpp
```

skynet-cpp 启动后会自动执行 the configured preload script 作为用户入口脚本。

---

## 关于 Lua

skynet-cpp 自带了一份 Lua 5.5.0 的源代码，是 skynet 修改版，含 **codecache** 机制——多个 Lua VM 可以共享编译后的字节码，节省内存并加速 VM 初始化。详见 [CodeCache](CodeCache.md)。

---

## 与原版 skynet 的差异

| 方面 | 原版 skynet | skynet-cpp |
|---|---|---|
| 构建系统 | Makefile (GCC/Clang) | CMake 3.20+ (MSVC/GCC/Clang) |
| 平台 | Linux (epoll) | Windows/Linux/macOS (Asio) |
| 内存分配 | jemalloc + malloc hook | 标准 C++ allocator |
| Lua 版本 | 5.4 | 5.5.0 |

