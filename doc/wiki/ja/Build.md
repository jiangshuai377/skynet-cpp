# Build
## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離されています。runtime リポジトリは最小限の verify/package/package smoke/Linux coverage smoke ツールのみを保持し、full coverage、perf、Docker DB、soak、native 比較は親 `testa/tools` レイヤーに置きます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

> skynet-cpp ビルドガイド

---

## ソースコードの取得

```bash
git clone <skynet-cpp-repository-url>
cd skynet-cpp
git lfs pull
```

---

## 依存関係

skynet-cpp の全依存はすべて `3rdparty/` ディレクトリに含まれており、追加インストールは不要です：

| 依存 | バージョン | 説明 |
|---|---|---|
| **Asio** | 1.28.2 (standalone) | クロスプラットフォーム非同期 IO ライブラリ（Boost 不要） |
| **moodycamel::ConcurrentQueue** | latest | 高性能ロックフリー MPMC キュー |
| **Lua** | 5.5.0 (skynet 修正版) | codecache 搭載の Lua VM |

---

## ビルドツール

### Windows（推奨）

- **Visual Studio 2022** (MSVC 19.41+)
- **CMake** 3.20+（VS2022 に同梱）

### Linux

- **GCC** 12+ または **Clang** 15+
- **CMake** 3.20+

### macOS

- **Clang** (Xcode Command Line Tools)
- **CMake** 3.20+

---

## ビルド

### Windows (Visual Studio)

```bat
cd skynet-cpp
mkdir build
cd build
cmake ..
cmake --build . --config Debug
```

または VS2022 同梱の CMake を使用：

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

ビルド成功後、実行ファイルは `build/Debug/skynet-cpp.exe`（Windows）または `build/skynet-cpp`（Linux/macOS）に生成されます。

---

## Release Package

CMake install または helper script で実行可能な package を作成します。

```bat
tools\package.bat --build-config Release
tools\run_package_smoke.bat
```

既定の package root は `dist/skynet-cpp/` で、`bin/`、`lualib/`、`service/`、`examples/`、`doc/` を含みます。package root から起動し、`SKYNET_PRELOAD` には `examples/preload.lua` のような cwd 相対パスを指定します。

---

## 実行

```bash
cd build/Debug
./skynet-cpp
```

skynet-cpp は起動後、自動的に the configured preload script をユーザーエントリスクリプトとして実行します。

---

## Lua について

skynet-cpp には Lua 5.5.0 のソースコードが同梱されています。これは skynet 修正版であり、**codecache** 機構を含んでいます——複数の Lua VM がコンパイル済みのバイトコードを共有でき、メモリ節約と VM 初期化の高速化を実現します。詳細は [CodeCache](CodeCache.md) を参照してください。

---

## オリジナル skynet との差異

| 項目 | オリジナル skynet | skynet-cpp |
|---|---|---|
| ビルドシステム | Makefile (GCC/Clang) | CMake 3.20+ (MSVC/GCC/Clang) |
| プラットフォーム | Linux (epoll) | Windows/Linux/macOS (Asio) |
| メモリアロケータ | jemalloc + malloc hook | 標準 C++ allocator |
| Lua バージョン | 5.4 | 5.5.0 |

