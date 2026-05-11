# Build
## Estado Atual da Implementação

O runtime atual usa bootstrap por preload: `SKYNET_THREAD` define a quantidade de workers e `SKYNET_PRELOAD` seleciona o script preload. O preload configura Lua path/cpath/service path, inicia o launcher e escolhe a entrada da aplicação. As entradas de teste foram separadas em `tests/logic`, `tests/stress` e `tests/perf`; o repositório runtime mantém apenas ferramentas mínimas de verify/package/package smoke/Linux coverage smoke, enquanto full coverage, perf, Docker DB, soak e comparação nativa ficam na camada pai `testa/tools`. O scheduling de atores usa `ActorQueue`, registry particionado e atomic wakeup; o callback Lua e o actor context de `skynet.core` são cacheados no hot path.

> Guia de compilação e construção do skynet-cpp

---

## Obter o código-fonte

```bash
git clone <skynet-cpp-repository-url>
cd skynet-cpp
git lfs pull
```

---

## Dependências

Todas as dependências do skynet-cpp estão incluídas no diretório `3rdparty/`, sem necessidade de instalação adicional:

| Dependência | Versão | Descrição |
|---|---|---|
| **Asio** | 1.28.2 (standalone) | Biblioteca de IO assíncrono multiplataforma (sem necessidade de Boost) |
| **moodycamel::ConcurrentQueue** | latest | Fila MPMC lock-free de alto desempenho |
| **Lua** | 5.5.0 (versão modificada skynet) | VM Lua com codecache |

---

## Ferramentas de compilação

### Windows (recomendado)

- **Visual Studio 2022** (MSVC 19.41+)
- **CMake** 3.20+ (incluído no VS2022)

### Linux

- **GCC** 12+ ou **Clang** 15+
- **CMake** 3.20+

### macOS

- **Clang** (Xcode Command Line Tools)
- **CMake** 3.20+

---

## Compilação

### Windows (Visual Studio)

```bat
cd skynet-cpp
mkdir build
cd build
cmake ..
cmake --build . --config Debug
```

Ou usando o CMake incluído no VS2022:

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

Após a compilação bem-sucedida, o executável estará em `build/Debug/skynet-cpp.exe` (Windows) ou `build/skynet-cpp` (Linux/macOS).

---

## Pacote de Release

Use CMake install ou o script helper para produzir um pacote executável:

```bat
tools\package.bat --build-config Release
tools\run_package_smoke.bat
```

A raiz padrão é `dist/skynet-cpp/`, com `bin/`, `lualib/`, `service/`, `examples/` e `doc/`. Inicie da raiz do pacote e defina `SKYNET_PRELOAD` com um caminho relativo ao cwd como `examples/preload.lua`.

---

## Execução

```bash
cd build/Debug
./skynet-cpp
```

Após a inicialização, o skynet-cpp executará automaticamente the configured preload script como script de entrada do usuário.

---

## Sobre o Lua

O skynet-cpp inclui uma cópia do código-fonte do Lua 5.5.0, versão modificada do skynet, com o mecanismo de **codecache** — múltiplas VMs Lua podem compartilhar bytecode compilado, economizando memória e acelerando a inicialização da VM. Veja [CodeCache](CodeCache.md) para detalhes.

---

## Diferenças em relação ao skynet original

| Aspecto | Skynet original | skynet-cpp |
|---|---|---|
| Sistema de build | Makefile (GCC/Clang) | CMake 3.20+ (MSVC/GCC/Clang) |
| Plataforma | Linux (epoll) | Windows/Linux/macOS (Asio) |
| Alocação de memória | jemalloc + malloc hook | Allocator padrão C++ |
| Versão Lua | 5.4 | 5.5.0 |

