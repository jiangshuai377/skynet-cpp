# Build
## Estado Actual de Implementación

El runtime actual usa bootstrap por preload: `SKYNET_THREAD` define el número de workers y `SKYNET_PRELOAD` selecciona el script preload. El preload configura Lua path/cpath/service path, inicia launcher y elige la entrada de la aplicación. Las entradas de prueba se separaron en `tests/logic`, `tests/stress` y `tests/perf`; el repositorio runtime conserva solo herramientas mínimas de verify/package/package smoke/Linux coverage smoke, mientras full coverage, perf, Docker DB, soak y comparación nativa viven en la capa superior `testa/tools`. El scheduling de actores usa `ActorQueue`, registry particionado y atomic wakeup; el callback Lua y el actor context de `skynet.core` están cacheados en el hot path.

> Guía de compilación de skynet-cpp

---

## Obtener el código fuente

```bash
git clone <skynet-cpp-repository-url>
cd skynet-cpp
git lfs pull
```

---

## Dependencias

Todas las dependencias de skynet-cpp están incluidas en el directorio `3rdparty/`, no se requiere instalación adicional:

| Dependencia | Versión | Descripción |
|---|---|---|
| **Asio** | 1.28.2 (standalone) | Biblioteca de IO asíncrono multiplataforma (sin necesidad de Boost) |
| **moodycamel::ConcurrentQueue** | latest | Cola MPMC sin bloqueo de alto rendimiento |
| **Lua** | 5.5.0 (versión modificada de skynet) | VM de Lua con codecache |

---

## Herramientas de compilación

### Windows (recomendado)

- **Visual Studio 2022** (MSVC 19.41+)
- **CMake** 3.20+ (incluido con VS2022)

### Linux

- **GCC** 12+ o **Clang** 15+
- **CMake** 3.20+

### macOS

- **Clang** (Xcode Command Line Tools)
- **CMake** 3.20+

---

## Compilación

### Windows (Visual Studio)

```bat
cd skynet-cpp
mkdir build
cd build
cmake ..
cmake --build . --config Debug
```

O usando el CMake incluido en VS2022:

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

Tras una compilación exitosa, el ejecutable se encuentra en `build/Debug/skynet-cpp.exe` (Windows) o `build/skynet-cpp` (Linux/macOS).

---

## Paquete de Release

Use CMake install o el script helper para producir un paquete ejecutable:

```bat
tools\package.bat --build-config Release
tools\run_package_smoke.bat
```

La raíz por defecto es `dist/skynet-cpp/`, con `bin/`, `lualib/`, `service/`, `examples/` y `doc/`. Inicie desde la raíz del paquete y configure `SKYNET_PRELOAD` con una ruta relativa al cwd como `examples/preload.lua`.

---

## Ejecución

```bash
cd build/Debug
./skynet-cpp
```

Al iniciarse, skynet-cpp ejecuta automáticamente the configured preload script como script de entrada del usuario.

---

## Acerca de Lua

skynet-cpp incluye una copia del código fuente de Lua 5.5.0, una versión modificada de skynet que contiene el mecanismo de **codecache** — múltiples VM de Lua pueden compartir bytecode compilado, ahorrando memoria y acelerando la inicialización de las VM. Véase [CodeCache](CodeCache.md) para más detalles.

---

## Diferencias con el skynet original

| Aspecto | Skynet original | skynet-cpp |
|---|---|---|
| Sistema de compilación | Makefile (GCC/Clang) | CMake 3.20+ (MSVC/GCC/Clang) |
| Plataforma | Linux (epoll) | Windows/Linux/macOS (Asio) |
| Asignación de memoria | jemalloc + malloc hook | Allocator estándar de C++ |
| Versión de Lua | 5.4 | 5.5.0 |

