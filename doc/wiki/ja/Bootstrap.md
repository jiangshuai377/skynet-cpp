# Bootstrap

## 現在の実装状態

現在のランタイムは preload bootstrap を使用します。`SKYNET_THREAD` で worker 数を指定し、`SKYNET_PRELOAD` で preload スクリプトを選択します。preload は Lua path/cpath/service path を設定し、launcher を起動し、アプリケーション入口を選択します。テスト入口は `tests/logic`、`tests/stress`、`tests/perf` に分離され、coverage と Linux Docker perf は専用 runner を持ちます。Actor scheduling は `ActorQueue`、sharded registry、atomic wakeup を使用し、Lua callback と `skynet.core` actor context は hot path でキャッシュされます。

## 概要

C++ エントリポイントは最小限の bootstrap のみを行います。`ActorSystem` を作成し、logger を起動し、環境変数を読み、preload LuaActor を起動してから worker/IO/monitor loop に入ります。launcher は C++ に hard-code されず、preload スクリプトが `skynet.newservice("launcher")` で明示的に起動します。

## 環境変数

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `SKYNET_THREAD` | `8` | worker thread 数 |
| `SKYNET_PRELOAD` | `examples/preload.lua` | preload script path |

## 起動フロー

```text
main()
  -> read SKYNET_THREAD / SKYNET_PRELOAD
  -> ActorSystem workers=N
  -> spawn<ServiceLogger>()
  -> spawn<LuaActor>(preload)
  -> preload configures paths and starts launcher
  -> preload starts example, logic, stress, perf, or application service
  -> system.run()
```

## preload の責務

preload は唯一の起動オーケストレーション入口です。通常は以下を行います。

- `skynet.appendpath` / `skynet.prependpath` で Lua module path を設定。
- `skynet.appendcpath` で C module path を設定。
- `skynet.appendservicepath` で service search path を設定。
- `launcher` を起動。
- application、example、logic、stress、perf の入口 service を起動。

## pathbase と package layout

相対 `SKYNET_PRELOAD` は process cwd から解決されます。release package は install root から起動し、`bin/`、`lualib/`、`service/`、`examples/`、`doc/` の layout を使います。既定 preload は `examples/preload.lua` です。preload は通常 `skynet.getcwd()` を出力し、`skynet.setpathbase(".")` を呼び、その後の相対 `appendpath` / `appendservicepath` / `appendcpath` は `skynet.getpathbase()` から解決されます。`setpathbase` は OS cwd を変更せず、第三者ライブラリの file IO に影響しません。

## スレッドモデル

| Thread | 数量 | 役割 |
| --- | ---: | --- |
| Worker | `SKYNET_THREAD` | global queue から `ActorQueue` を取り出し、重み付き batch で message を dispatch |
| IO | 1 | network IO と timer 用の `asio::io_context` を実行 |
| Monitor | 1 | 同じ message で長時間止まった worker を検出 |

## preload 例

```lua
local skynet = require "skynet"

skynet.appendpath("lualib")
skynet.appendservicepath("service")
skynet.appendservicepath("examples")

skynet.start(function()
    skynet.newservice("launcher")
    skynet.newservice("main")
end)
```

## 関連エントリ

- Example: `examples/preload.lua`
- Logic tests: `tests/logic/preload.lua`
- Stress tests: `tests/stress/preload.lua`
- Performance tests: `tests/perf/preload.lua`
