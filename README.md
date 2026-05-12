# skynet-cpp

`skynet-cpp` is a modern C++20 runtime inspired by the
[Skynet](https://github.com/cloudwu/skynet) actor framework. It embeds Lua,
uses Asio for networking, and keeps startup configuration in Lua preload scripts
instead of baking source-tree paths into the executable.

中文说明：这是一个面向跨平台运行的 Skynet 风格 Actor runtime。C++ 只负责最小
bootstrap，Lua preload 负责配置路径、启动 launcher 和业务入口。

## Features

- C++20 actor runtime with sharded actor registry and native-like `ActorQueue`
  scheduling.
- Embedded Lua actor services with `skynet.call`, `skynet.send`,
  `skynet.timeout`, `skynet.newservice`, name service, launcher, logger, debug,
  cluster, sharedata, multicast, and socket APIs.
- Asio-based TCP/UDP networking with Lua socket bindings.
- Preload-managed runtime paths: no compiled-in `SKYNET_SOURCE_DIR`.
- Install/package friendly layout: `bin/`, `lualib/`, `service/`, `examples/`,
  and `doc/`.
- Minimal runtime verification tools in `tools/`.

## Repository Layout

```text
skynet-cpp/
├── 3rdparty/        # Vendored Lua, Asio, concurrentqueue, lua-rapidjson
├── src/             # C++ runtime, Lua bindings, network layer
├── lualib/          # Skynet-compatible Lua libraries
├── service/         # Built-in Lua services: launcher, debug, cluster, etc.
├── examples/        # Default preload and runnable example services
├── tests/           # Logic, stress, perf entrypoints and C++ unit coverage
├── tools/           # Minimal runtime build/package/smoke tools
└── doc/             # Design, wiki, audit, and performance documents
```

## Requirements

- CMake 3.20+
- A C++20 compiler
  - Windows: Visual Studio 2022 / MSVC
  - Linux: Clang or GCC
  - macOS: Clang
- Git
- Ninja is optional but recommended for command-line builds.

All runtime dependencies used by the C++ build are vendored under `3rdparty/`.

## Quick Start

### Windows

```bat
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Debug

set SKYNET_THREAD=8
set SKYNET_PRELOAD=examples/preload.lua
build\Debug\skynet-cpp.exe
```

### Linux / macOS

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build

export SKYNET_THREAD=8
export SKYNET_PRELOAD=examples/preload.lua
./build/skynet-cpp
```

If `SKYNET_PRELOAD` is not set, the runtime defaults to
`examples/preload.lua`.

## Runtime Startup Model

Only two environment variables are interpreted by the C++ entrypoint:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SKYNET_THREAD` | `8` | Worker thread count |
| `SKYNET_PRELOAD` | `examples/preload.lua` | Lua preload script path, resolved from process cwd |

The preload script is the only startup orchestration entrypoint. It usually:

1. prints `skynet.getcwd()` for debugging;
2. calls `skynet.setpathbase(".")`;
3. configures Lua search paths with `skynet.appendpath`,
   `skynet.appendcpath`, and `skynet.appendservicepath`;
4. starts `launcher`;
5. starts the application or test service.

Example:

```lua
local skynet = require "skynet"

print("[preload] cwd =", skynet.getcwd())
skynet.setpathbase(".")

skynet.appendpath("lualib")
skynet.appendservicepath("service")
skynet.appendservicepath("examples")
skynet.appendcpath("luaclib")

skynet.start(function()
    local launcher = skynet.newservice("launcher")
    skynet.call(launcher, "lua", "LIST")
    skynet.newservice("main")
end)
```

`setpathbase` does not call `chdir` and does not change the OS current working
directory. It only affects skynet-cpp path APIs.

## Package Build

The installed package is runnable without the source tree.

Windows:

```bat
tools\package.bat --build-config Release --clean
tools\run_package_smoke.bat --timeout-seconds 60
```

Linux / macOS:

```bash
bash tools/package.sh --build-config Release --clean
bash tools/run_package_smoke.sh --timeout-seconds 60
```

The package root defaults to `dist/skynet-cpp/` and contains:

```text
dist/skynet-cpp/
├── bin/
├── lualib/
├── service/
├── examples/
└── doc/
```

Launch from the package root and use a cwd-relative preload path:

```bat
set SKYNET_PRELOAD=examples/preload.lua
bin\skynet-cpp.exe
```

```bash
export SKYNET_PRELOAD=examples/preload.lua
./bin/skynet-cpp
```

## Verification

The runtime repository intentionally keeps only minimal tools:

```bat
tools\verify.bat --mode Quick
tools\package.bat --build-config Release --clean
tools\run_package_smoke.bat --timeout-seconds 60
```

```bash
bash tools/verify.sh --mode Quick
bash tools/package.sh --build-config Release --clean
bash tools/run_package_smoke.sh --timeout-seconds 60
```

Full coverage gates, performance benchmarks, Docker DB stress, soak tests, and
native skynet comparison live in the parent best-practice project tooling layer
when this runtime is used inside `testa/`.

## Documentation

- [Design documents](doc/design/README.md)
- [Chinese wiki](doc/wiki/Home.md)
- [English wiki](doc/wiki/en/Home.md)
- [Lua API](doc/wiki/LuaAPI.md)
- [Bootstrap model](doc/wiki/Bootstrap.md)
- [Build and package guide](doc/wiki/Build.md)
- [Performance optimization report](doc/performance-optimization/README.md)
- [Runtime tools](tools/README.md)
- [Tests](tests/README.md)

## Common Pitfalls

- Run examples and packages from the repository root or package root. Relative
  `SKYNET_PRELOAD` paths are resolved from the process cwd.
- Do not rely on the old `SKYNET_SOURCE_DIR` model. It has been removed.
- Configure all Lua module, C module, and service paths in preload.
- `setpathbase` affects skynet-cpp path APIs only; it does not affect arbitrary
  third-party file IO.

## License

This repository vendors several third-party dependencies under `3rdparty/`.
Check each vendored component for its own license terms.
