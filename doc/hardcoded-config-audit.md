# Hardcoded Configuration Audit

## Migrated to preload configuration

- Service startup is controlled by `SKYNET_PRELOAD`; C++ no longer starts launcher or the user service directly.
- Lua module paths, service paths, and C module paths are configured by preload scripts through `skynet.appendpath`, `skynet.prependpath`, `skynet.appendservicepath`, and `skynet.appendcpath`.
- Test and example entrypoints live in preload scripts:
  - `examples/preload.lua`
  - `tests/stress/preload.lua`
  - `tests/logic/preload.lua`
  - `tests/perf/preload.lua`

## Intentionally retained

- Built-in Lua C modules remain preloaded in C++ because they are linked into the executable, not discovered from disk.
- Coverage build flags remain CMake options and are not runtime configuration.
- Runtime tool wrappers keep only minimal CMake build, package smoke, and Linux coverage smoke logic.
- Linux coverage tooling remains a thin shell entrypoint run directly or through the Docker Python wrapper; tooling portability is separate from runtime portability.
- CMake retains platform branches for Asio's Windows target version, Windows socket libraries, Linux pthread linkage, and coverage compiler requirements.

## Migrated to standard C++ runtime helpers

- `src/platform.h` / `src/platform.cpp` centralize runtime helpers implemented with the C++ standard library: environment variables, binary file writes, profile timing, local-time conversion, and node name generation.
- The old compile-time source-root macro was removed; preload scripts now use `skynet.getcwd()`, `skynet.setpathbase(path)`, and `skynet.getpathbase()` to make Lua search-path configuration explicit and deployable.
- `lua_cluster.cpp` no longer includes platform headers directly; `cluster.core.nodename()` uses the platform helper.
- `lua_profile.cpp` no longer calls Windows or POSIX timer APIs directly; profiling uses the platform helper backed by standard `std::chrono`.
- `main.cpp` and `lua_binding.cpp` route environment access and coverage file writes through the platform helper.
- `service_logger.h` routes local-time conversion through the platform helper, which guards standard `std::localtime` with a mutex.
- `skynet.cpp` emits both `.dll` and `.so` Lua C module search patterns, avoiding platform-specific suffix selection in runtime code.

## Cross-platform validation

- Static scans should not find runtime platform headers or OS calls such as `windows.h`, `unistd.h`, `_WIN32`, `localtime_s`, `localtime_r`, process IDs, or hostname calls in `src/`.
- `network.cpp` and `network.h` should remain Asio-only and should not call system socket APIs directly.
- Linux runtime coverage smoke invokes `tools/run_linux_coverage.sh` after the CI environment installs Clang/LLVM/CMake/Ninja.
- Full coverage, performance, Docker DB stress, long-run validation, and native skynet comparison are owned by the parent best-practice project tooling.
- Design, wiki, and performance documentation now describe the preload bootstrap path instead of the old C++-hardcoded service startup path.
