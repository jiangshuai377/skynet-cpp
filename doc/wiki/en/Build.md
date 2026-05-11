# Build
## Current Implementation Status

The current runtime uses the preload bootstrap path: set `SKYNET_THREAD` for worker count and `SKYNET_PRELOAD` for the preload script. The preload script configures Lua path/cpath/service path, starts launcher, and selects the application entry. Test entrypoints are split into `tests/logic`, `tests/stress`, and `tests/perf`; the runtime repository keeps only minimal verify/package/package smoke/Linux coverage smoke tools, while full coverage, perf, Docker DB, soak, and native comparisons live in the parent `testa/tools` layer. Actor scheduling now uses `ActorQueue`, sharded registry, and atomic wakeup; Lua callback and `skynet.core` actor context are cached on the hot path.

> skynet-cpp Build Guide

---

## Getting the Source Code

```bash
git clone <skynet-cpp-repository-url>
cd skynet-cpp
git lfs pull
```

---

## Dependencies

All dependencies for skynet-cpp are included in the `3rdparty/` directory — no additional installation is required:

| Dependency | Version | Description |
|---|---|---|
| **Asio** | 1.28.2 (standalone) | Cross-platform async IO library (no Boost required) |
| **moodycamel::ConcurrentQueue** | latest | High-performance lock-free MPMC queue |
| **Lua** | 5.5.0 (skynet modified) | Lua VM with codecache |

---

## Build Tools

### Windows (Recommended)

- **Visual Studio 2022** (MSVC 19.41+)
- **CMake** 3.20+ (bundled with VS2022)

### Linux

- **GCC** 12+ or **Clang** 15+
- **CMake** 3.20+

### macOS

- **Clang** (Xcode Command Line Tools)
- **CMake** 3.20+

---

## Compiling

### Windows (Visual Studio)

```bat
cd skynet-cpp
mkdir build
cd build
cmake ..
cmake --build . --config Debug
```

Or use the CMake bundled with VS2022:

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

After a successful build, the executable is located at `build/Debug/skynet-cpp.exe` (Windows) or `build/skynet-cpp` (Linux/macOS).

---

## Release Package

Use CMake install or the helper script to produce a runnable package:

```bat
tools\package.bat --build-config Release
tools\run_package_smoke.bat
```

The default package root is `dist/skynet-cpp/`, with `bin/`, `lualib/`, `service/`, `examples/`, and `doc/`. Launch from the package root and set `SKYNET_PRELOAD` to a cwd-relative path such as `examples/preload.lua`.

---

## Running

```bash
cd build/Debug
./skynet-cpp
```

After startup, skynet-cpp will automatically execute the configured preload script as the user entry script.

---

## About Lua

skynet-cpp ships with a copy of Lua 5.5.0 source code — a skynet-modified version that includes the **codecache** mechanism, allowing multiple Lua VMs to share compiled bytecode, saving memory and speeding up VM initialization. See [CodeCache](CodeCache.md) for details.

---

## Differences from Original skynet

| Aspect | Original skynet | skynet-cpp |
|---|---|---|
| Build system | Makefile (GCC/Clang) | CMake 3.20+ (MSVC/GCC/Clang) |
| Platform | Linux (epoll) | Windows/Linux/macOS (Asio) |
| Memory allocator | jemalloc + malloc hook | Standard C++ allocator |
| Lua version | 5.4 | 5.5.0 |

