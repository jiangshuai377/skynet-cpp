# Build
## 현재 구현 상태

현재 런타임은 preload bootstrap을 사용합니다. `SKYNET_THREAD`는 worker 수를 지정하고 `SKYNET_PRELOAD`는 preload 스크립트를 선택합니다. preload는 Lua path/cpath/service path를 설정하고 launcher를 시작하며 애플리케이션 진입점을 선택합니다. 테스트 엔트리는 `tests/logic`, `tests/stress`, `tests/perf`로 분리되었고 coverage와 Linux Docker perf는 별도 runner를 사용합니다. Actor scheduling은 `ActorQueue`, sharded registry, atomic wakeup을 사용하며 Lua callback과 `skynet.core` actor context는 hot path에서 캐시됩니다.

> skynet-cpp 빌드 가이드

---

## 소스 코드 받기

```bash
git clone <skynet-cpp-repository-url>
cd skynet-cpp
git lfs pull
```

---

## 의존성

skynet-cpp의 모든 의존성은 `3rdparty/` 디렉토리에 포함되어 있으며, 추가 설치가 필요 없습니다:

| 의존성 | 버전 | 설명 |
|---|---|---|
| **Asio** | 1.28.2 (standalone) | 크로스 플랫폼 비동기 IO 라이브러리 (Boost 불필요) |
| **moodycamel::ConcurrentQueue** | latest | 고성능 락프리 MPMC 큐 |
| **Lua** | 5.5.0 (skynet 수정 버전) | codecache 포함 Lua VM |

---

## 빌드 도구

### Windows (권장)

- **Visual Studio 2022** (MSVC 19.41+)
- **CMake** 3.20+ (VS2022 내장)

### Linux

- **GCC** 12+ 또는 **Clang** 15+
- **CMake** 3.20+

### macOS

- **Clang** (Xcode Command Line Tools)
- **CMake** 3.20+

---

## 빌드

### Windows (Visual Studio)

```bat
cd skynet-cpp
mkdir build
cd build
cmake ..
cmake --build . --config Debug
```

또는 VS2022 내장 CMake 사용:

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

빌드 성공 후, 실행 파일은 `build/Debug/skynet-cpp.exe` (Windows) 또는 `build/skynet-cpp` (Linux/macOS)에 위치합니다.

---

## Release Package

CMake install 또는 helper script로 실행 가능한 package를 생성합니다.

```bat
tools\package.bat --build-config Release
tools\run_package_smoke.bat
```

기본 package root는 `dist/skynet-cpp/`이며 `bin/`, `lualib/`, `service/`, `examples/`, `doc/`를 포함합니다. package root에서 실행하고 `SKYNET_PRELOAD`는 `examples/preload.lua` 같은 cwd 상대 경로로 지정합니다.

---

## 실행

```bash
cd build/Debug
./skynet-cpp
```

skynet-cpp 시작 후 자동으로 the configured preload script를 사용자 진입 스크립트로 실행합니다.

---

## Lua에 대하여

skynet-cpp는 Lua 5.5.0 소스 코드를 내장하고 있으며, skynet 수정 버전으로 **codecache** 메커니즘을 포함합니다 — 다수의 Lua VM이 컴파일된 바이트코드를 공유하여 메모리를 절약하고 VM 초기화를 가속화합니다. 자세한 내용은 [CodeCache](CodeCache.md)를 참조하세요.

---

## 원본 skynet과의 차이점

| 측면 | 원본 skynet | skynet-cpp |
|---|---|---|
| 빌드 시스템 | Makefile (GCC/Clang) | CMake 3.20+ (MSVC/GCC/Clang) |
| 플랫폼 | Linux (epoll) | Windows/Linux/macOS (Asio) |
| 메모리 할당 | jemalloc + malloc hook | 표준 C++ allocator |
| Lua 버전 | 5.4 | 5.5.0 |

